# Rebuilding the VideoBox FFmpeg runtime

The bundled media runtime is built from the unmodified upstream source trees in this archive. It is a separate command-line program invoked by VideoBox and is not linked into the MIT-licensed VideoBox executable.

## Requirements

- macOS 13 or later
- Current Xcode Command Line Tools or Xcode
- CMake, NASM, and pkg-config (`brew install cmake nasm pkgconf`)

## Build

From the root of the corresponding-source archive, run:

```bash
VIDEOBOX_FFMPEG_SOURCE_ROOT="$PWD/Sources" \
VIDEOBOX_FFMPEG_ARCHS="arm64 x86_64" \
./Scripts/build_ffmpeg_runtime.sh
```

In a VideoBox repository checkout, omit `VIDEOBOX_FFMPEG_SOURCE_ROOT`; the script downloads the pinned archives and verifies every SHA-256 checksum before extraction.

The script verifies every source checksum, builds all non-system dependencies statically for each architecture, creates universal `ffmpeg` and `ffprobe` executables, performs smoke encodes with x264, 8/10-bit x265, SVT-AV1, Opus, and libass, and rejects every non-system runtime dependency.

The significant FFmpeg configuration choices are:

```text
--enable-gpl
--enable-libx264
--enable-libx265
--enable-libsvtav1
--enable-libopus
--enable-libass
--enable-static
--disable-shared
--disable-autodetect
--disable-network
```

`--enable-version3` and `--enable-nonfree` are intentionally not used. The exact generated configuration is recorded in `metadata/ffmpeg-buildconf.txt` beside the runtime output.
