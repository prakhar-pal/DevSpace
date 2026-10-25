# Direct Swift/Skia interoperability gate (M01)

These isolated acceptance executables do not change the application's VTE
implementation or SwiftPM targets. Compile-only and runtime checks are separate:
successful object compilation does **not** prove hardware acceleration.

## Reproduce

Use the revision in `skia-revision.txt`. A small header-only checkout suffices:

```sh
git clone --depth 1 --filter=blob:none --sparse https://skia.googlesource.com/skia.git .tmp/ghostty-skia/skia
git -C .tmp/ghostty-skia/skia fetch --depth 1 origin 5f8aa127c855a8aabdb5708454afd07deebae643
git -C .tmp/ghostty-skia/skia checkout --detach 5f8aa127c855a8aabdb5708454afd07deebae643
git -C .tmp/ghostty-skia/skia sparse-checkout set include
bash scripts/check-skia-interop.sh
```

For an existing checkout, set `SKIA_SOURCE=/absolute/path/to/skia`. Override
`SWIFTC` only to select an already installed compiler. No toolchain is installed
by this check. Temporary compiler output is confined to `.tmp/ghostty-skia`.

## Import decisions

Unannotated upstream headers fail with Swift 6.4.1: `SkCanvas` is not imported
as an ordinary value type, and `sk_sp.get()` is hidden as potentially returning
an interior pointer. Annotating forward declarations did not reliably attach
the required ownership attributes to the definitions.

`CSkia.apinotes` supplies compiler metadata without editing Skia. It imports
opaque objects and their relevant base classes as manually owned references
(the compiler's no-retain/no-release operations are named `immortal`; the Skia
objects are **not** actually immortal). The Swift code keeps owning `sk_sp`
values alive using `withExtendedLifetime`. Raster tests check smart-pointer
copy/reset behavior and actual pixel/glyph output before any production use.

Swift does not support converting a derived foreign reference to its C++ base.
The user approved one inline `static_cast` helper for `GrDirectContext` to
`GrRecordingContext`. It borrows the object without retaining or transferring
ownership. All actual drawing and platform integration remain Swift.

References: [Clang API Notes](https://clang.llvm.org/docs/APINotes.html) and
[Swift C++ interoperability](https://www.swift.org/documentation/cxx-interop/).

## Build and run the runtime checks

For native compilation, materialize the pinned checkout's build sources:

```sh
git -C .tmp/ghostty-skia/skia sparse-checkout set include src modules gn third_party bin tools
bash scripts/build-skia-interop.sh
bash scripts/check-skia-runtime.sh --raster
GDK_BACKEND=x11 xvfb-run -a bash scripts/check-skia-runtime.sh --gpu
```

The Skia build uses installed Clang, GN and Ninja, plus system Fontconfig,
FreeType, HarfBuzz and ICU. GTK's OpenGL context is EGL-backed: the Skia build
must use `skia_use_egl=true`, not its default GLX loader. The build script is
an optimized, reduced-dependency **feasibility configuration**, not a shipping
dependency policy. PartitionAlloc, unrelated image codecs and tools are not
enabled in this experiment. No compiler is downloaded or installed.

Raster acceptance verifies literal pixel colors, real system-font glyph output,
smart-pointer ownership transitions and 64 differently sized surface lifecycles.
GPU acceptance runs the same Swift drawing against a GTK framebuffer, reads
pixels back, resizes and repeatedly recreates/disposes Skia contexts.

The GPU executable opens only its own clearly labeled test window. It never
starts a DevPod, touches the clipboard or replaces a production bundle. To
require hardware on the actual desktop, rather than accept software OpenGL:

```sh
DEVSPACE_REQUIRE_HARDWARE=1 bash scripts/check-skia-runtime.sh --gpu
```

Xvfb/llvmpipe success proves the OpenGL integration, **not hardware acceleration**.

## libghostty-vt ABI check

The local Ghostty reference is `08a9518340e19487bd5fdf96963583fb32f0c41f`.
Verify that checkout and use globally installed Zig **0.17.0** (not the older
0.16.x specified by the independent Ghostling reference):

```sh
(
  cd references/ghostty
  ZIG_LOCAL_CACHE_DIR="$OLDPWD/.tmp/ghostty-skia/zig-cache" \
  ZIG_GLOBAL_CACHE_DIR="$OLDPWD/.tmp/ghostty-skia/zig-global-cache" \
    zig build -Demit-lib-vt -Doptimize=ReleaseFast -j2 \
      --prefix "$OLDPWD/.tmp/ghostty-skia/ghostty-vt"
)
bash scripts/check-ghostty-interop.sh
```

Ghostty's revision pins its package dependencies. The ABI check links the actual
static library into Swift and verifies ANSI text formatting and disposal over
32 terminal lifecycles. It is not the production terminal adapter.

## Verified checkpoint and remaining work

On the Ubuntu 26.04 host with global Swift 6.4.1 and Zig 0.17.0:

- The pinned Ghostty static library passes its Swift ABI/ANSI parsing check.
- Skia raster pixels, Fontconfig/FreeType glyphs and smart-pointer copy/reset
  pass over repeated surface lifecycles.
- GTK/EGL pixel readback, resize, context disposal and widget recreation pass
  on a private X11 display using llvmpipe.
- The initial actual-desktop Wayland hardware attempt exited **77** because
  the host supplied llvmpipe; that historical result was not a hardware pass.
- On 2026-10-26, strict Wayland terminal GPU acceptance passes with accelerated
  VirGL backed by Intel UHD Graphics 630 (OpenGL 4.3, Mesa 26.0.8), including
  pixel/glyph readback, resize, widget recreation and context disposal. The
  actual GTK terminal adapter also selects OpenGL without a software override
  and passes resize/recreation. This validates hardware-backed virtual 3D on
  this host, not GPU passthrough or general hardware performance.

The user approved moving hardware verification to the final M05 cutover gate
because the host then had no hardware renderer. That deferred rendering gate
is now verified on the accelerated VirGL host. M01's implementation gate is met.
M03 adds actual contextual terminal shaping/font fallback tests and M04 adds a
development-only GTK frontend with automatic raster fallback. See
`Tests/SkiaRenderer/README.md`, `Tests/GhosttyGTK/README.md` and the current plan.
The primitive M01 glyph sample alone does not establish complex-script shaping.
VTE remains the default; production cutover is not complete.

At initial execution, GN, Ninja and Zig were unavailable on PATH, and the
filesystem had approximately 2 GB free. Those tools are now installed, and the
native dependencies have been built using them. On Ubuntu the basic Skia build
tools can be installed with:

```sh
sudo apt-get install ninja-build generate-ninja
```

Native dependency builds require network for initially fetching the pinned
sources; cached builds do not need a replacement toolchain.
