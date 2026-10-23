# Direct Swift/Skia interoperability gate (M01, partial)

This deliberately isolated compile check does not change the application's
VTE implementation or its SwiftPM targets. It compiles actual Skia drawing and
GPU-context calls with the global Swift compiler. It does **not** link Skia or
prove pixel correctness, runtime ownership or hardware acceleration.

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

`CSkia.apinotes` supplies compiler metadata without editing Skia or implementing
a C++ wrapper. It imports the three opaque objects as manually owned references
(the compiler's no-retain/no-release operations are named `immortal`; the Skia
objects are **not** actually immortal). The Swift code keeps owning `sk_sp`
values alive using `withExtendedLifetime`. Runtime tests must prove this
ownership arrangement before any production use.

References: [Clang API Notes](https://clang.llvm.org/docs/APINotes.html) and
[Swift C++ interoperability](https://www.swift.org/documentation/cxx-interop/).

## Remaining M01 work

Link a pinned Skia build, exercise real raster pixels and object disposal, wrap
GTK's OpenGL framebuffer and verify hardware-backed rendering, resize,
unrealize/recreate and forced software fallback. Extend the gate to the chosen
font fallback and shaping APIs. None of those are established by this check.

At initial execution, GN, Ninja and Zig were unavailable on PATH, and the
filesystem had approximately 2 GB free. No full native dependency build was
attempted. On Ubuntu the basic Skia build tools can be installed with:

```sh
sudo apt-get install ninja-build generate-ninja
```

The local Ghostty reference is `08a9518340e19487bd5fdf96963583fb32f0c41f` and
requires Zig **0.17.0 minimum**, unlike Ghostling's older Zig 0.16.x reference.
Select and verify a globally installed compatible Zig before building it.
