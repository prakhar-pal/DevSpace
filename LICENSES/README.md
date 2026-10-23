# Third-party license notices

These files retain their upstream licenses and are not relicensed under the
DevSpace project's GPL declaration.

## ICU 76.1

`ICU-76.1.txt` is the complete, unmodified notice from
https://github.com/unicode-org/icu/blob/release-76-1/LICENSE, including its
third-party data notices. It applies to the upstream ICU material, not only to
the Apache-licensed Swift Foundation ICU wrapper.

The global Swift.org 6.4.1 Ubuntu 26.04 runtime was checked directly through
`lib_FoundationICU.so`'s exported `swift_u_getVersion` function and reported
76.1.0.0. The corresponding `swift-6.4.1-RELEASE` Swift Foundation ICU source
also declares major 76/minor 1 in
`icuSources/include/_foundation_unicode/uvernum.h`.

Linux Makefile targets supply this notice through `LINUX_ICU_LICENSE`.
When changing toolchains, verify the embedded ICU version and provide the
matching complete notice with `LINUX_ICU_LICENSE=/path/to/notice`. Direct
assembly requires `--icu-license` whenever the runtime contains
`lib_FoundationICU.so`; the assembler does not infer an ICU version or grant
distribution rights merely from a supplied filename.

Swift runtime licenses are taken from the selected toolchain at assembly time.
The custom DevSpace icons are GPL-3.0-or-later, as confirmed by their creator.
`packaging/debian/copyright` records the Linux binary inventory for the verified
Swift.org 6.4.1 toolchain. It must be reviewed again when bundled components
change; it does not relicense third-party libraries.

## Experimental Linux Ghostty/Skia renderer

`make linux-ghostty-bundle-dev` collects a separate pinned notice tree and copies
it into `share/doc/devspace/third-party`. The collector checks both source Git
revisions and rejects tracked modifications. It records SHA-256 values for
every copied notice and the three native archives. This is build provenance,
not proof of a reproducible build or approval of a production dependency policy.

The current inventory preserves Ghostty's MIT notice, Skia/skcms BSD notices,
the Khronos GLSL header notice, simdutf 9.0.0's MIT/Apache notices and complete
vendored header/source (including embedded third-party notices), uucode's MIT/Unicode/Hoehrmann
notices, the cached Wuffs/Highway/pixels/zlib notices, and Zig's MIT plus musl
copyright notices. Zig's linked compiler runtime contains musl-derived math
routines, so its top-level MIT notice alone is insufficient for this inventory.
simdutf's vendored header reports version 9.0.0; the older wrapper package
version is not used to select its notice.

Some uucode notices are omitted by its Zig package's `.paths` list. The collector
therefore verifies checksum-pinned copies from the exact upstream commit. It
can fetch only those notices and simdutf's notice with `--fetch-missing`; it
never downloads a compiler. Other notices come from the pinned native source
and Zig dependency cache already used for compilation. Copied native notices
retain upstream terms; DevSpace's GPL-3.0-or-later declaration does not replace
them. System GTK/GL/Fontconfig/FreeType/HarfBuzz libraries remain system-provided.

The current native profile remains **experimental and development-only**.
Before production cutover, review native compiler flags, exact linked inventory,
source-distribution obligations and the Debian manifest together. The existing
Debian manifest describes the default VTE package, not a Ghostty release.
