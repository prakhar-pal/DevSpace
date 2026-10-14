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
