<div align="center">
  <img src="Assets/AppIcon.png" width="128" alt="VideoBox app icon">
  <h1>VideoBox</h1>
  <p>A native macOS workspace for inspecting, editing, remuxing, and compressing video.</p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
</div>

![VideoBox editor](Documentation/Images/editor.png)

VideoBox combines a SwiftUI interface and AVFoundation playback with the power of FFmpeg. It keeps media processing local, exposes the generated FFmpeg command, and puts quick stream-copy exports and configurable transcoding in one workspace.

> [!IMPORTANT]
> VideoBox is an early preview. The current interface is in Simplified Chinese, FFmpeg and ffprobe must be installed separately, and the preview DMG is ad-hoc signed rather than Apple-notarized.

## Highlights

- Drag-and-drop import with AVPlayer preview and media inspection.
- A thumbnail timeline with split, delete, duplicate, reorder, and sequential composition.
- Per-clip speed, rotation, horizontal/vertical flip, volume, and scale controls.
- Video, audio, subtitle, attachment, chapter, and metadata inspection.
- Track selection plus per-track title, language, and default-track editing.
- Fast stream-copy export or configurable transcoding to MP4, MOV, MKV, and WebM.
- H.264, H.265/HEVC, AV1, and ProRes options, including VideoToolbox hardware encoding.
- Resolution, frame-rate, pixel-format, bitrate, target-size, audio, subtitle, and container controls.
- A serial background export queue and an inspectable FFmpeg command preview.

## Requirements

- macOS 13 Ventura or later.
- Apple Silicon or Intel Mac.
- `ffmpeg` and `ffprobe` available through Homebrew or your `PATH`.

Install the media tools with Homebrew:

```bash
brew install ffmpeg
```

VideoBox checks `PATH`, `/opt/homebrew/bin`, `/opt/homebrew/opt/ffmpeg-full/bin`, `/usr/local/bin`, and `/usr/bin`.

## Install the preview

1. Download the latest universal `.dmg` from [GitHub Releases](https://github.com/magiconline/VideoBox/releases).
2. Open it and drag **VideoBox** to **Applications**.
3. Because the preview is not notarized, Control-click the app and choose **Open** the first time if macOS blocks a normal launch.
4. Install FFmpeg with the command above before exporting.

The release page includes a `.sha256` file so you can verify the download:

```bash
shasum -a 256 -c VideoBox-0.1.0-macOS-universal.dmg.sha256
```

## Build from source

Open `Package.swift` in Xcode, select the **VideoBox** scheme and **My Mac**, then run the app. A Swift 5.9-compatible toolchain is required.

Command-line development:

```bash
swift build
swift test
```

Create a universal, ad-hoc-signed app and DMG:

```bash
./Scripts/create_dmg.sh release
```

Artifacts are written to `dist/`. For Developer ID signing and notarization:

```bash
VIDEOBOX_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VIDEOBOX_NOTARY_PROFILE="notary-profile" \
./Scripts/create_dmg.sh release
```

The notary profile must already exist in Keychain through `xcrun notarytool store-credentials`.

## Project layout

```text
Assets/                 App icon source assets
Documentation/          Screenshots and versioned release notes
Packaging/              macOS bundle metadata
Scripts/                Repeatable app and DMG packaging
Sources/VideoBox/
├── App/                 App entry point and dependency container
├── UI/                  SwiftUI screens and components
├── Media/               Probe results and media models
├── Player/              AVFoundation playback
├── Editing/             Non-destructive edit timeline
├── Export/              Export models and presets
├── Engines/             FFmpeg/ffprobe process integration
├── Jobs/                Export jobs and queue
└── System/              External-tool discovery
Tests/VideoBoxTests/     Unit and integration tests
```

## Development status

VideoBox is useful today as a local preview, but it is not yet a polished consumer release. Planned release work includes English UI localization, bundling or guided installation of compatible media tools, Developer ID signing, notarization, and broader real-world media compatibility testing.

Bug reports and focused pull requests are welcome through [GitHub Issues](https://github.com/magiconline/VideoBox/issues).

## License

VideoBox is released under the [MIT License](LICENSE). FFmpeg is a separate project with its own LGPL/GPL licensing terms and is not included in the current DMG.
