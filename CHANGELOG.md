# Changelog / 更新日志

All notable changes to VideoBox are documented here. / VideoBox 的重要变更记录在此处。

## Unreleased / 未发布

## [0.2.1] - 2026-09-05

### English

- Add independent import, extraction, and same-kind ordering for video, audio, and subtitle tracks in the track and metadata workspace.
- Preview selected external video/audio tracks and timed text subtitles directly in the player without exporting a finished video first.
- Unify media preparation behind a single loading progress bar and remove compatibility-mode badges and automatic-switch notices.
- Make HEVC previews and QuickTime exports Apple-compatible with `hvc1`, validate generated previews with AVFoundation, and automatically transcode unsupported video/audio combinations.
- Add bundled dav1d software decoding so AV1 sources can generate compatible previews on Macs without AV1 hardware decoding.
- Build DMGs from a temporary app bundle so `dist/` no longer leaves a duplicate `VideoBox.app` indexed by Spotlight.
- Make the default project introduction Chinese-only and highlight lossless track selection and container remuxing.

### 中文

- 在“轨道与元数据”中新增视频、音频和字幕轨道的独立导入、提取导出及同类型排序。
- 外部视频/音频轨道和文本字幕可直接在播放器中按时间轴预览，无需先导出成片。
- 所有视频格式统一使用加载进度条，无需向用户显示兼容模式或自动切换提示。
- HEVC 预览及 QuickTime 导出自动使用 Apple 兼容的 `hvc1`；生成后由 AVFoundation 验证，必要时自动将不兼容音视频转为兼容预览。
- 内置 dav1d 软件解码，使不支持 AV1 硬件解码的 Mac 也能为 AV1 片源生成兼容预览。
- DMG 打包改用临时 App Bundle，避免 `dist/` 中残留被 Spotlight 索引的重复 `VideoBox.app`。
- 默认项目简介改为纯中文，并重点说明无需重新压缩的轨道调整与封装转换能力。

## [0.2.0] - 2026-09-04

### English

- Bundled native Apple Silicon `ffmpeg` and `ffprobe` executables, so users no longer need Homebrew or a separate FFmpeg installation.
- Retained software H.264 (`libx264`) and H.265/HEVC (`libx265`) encoding, alongside SVT-AV1, Opus, ProRes, and VideoToolbox hardware encoding.
- Added subtitle burn-in support through libass, with the required text-shaping and font libraries included statically.
- Added repeatable, checksum-pinned FFmpeg runtime builds and corresponding-source archives for every release.
- Added in-app third-party license notices and runtime build metadata.
- Adopted the MIT License for the VideoBox application source.

### 中文

- 内置 Apple Silicon 原生 `ffmpeg` 与 `ffprobe`，用户无需再安装 Homebrew 或单独配置 FFmpeg。
- 保留 H.264（`libx264`）与 H.265/HEVC（`libx265`）软件编码，并继续提供 SVT-AV1、Opus、ProRes 和 VideoToolbox 硬件编码。
- 通过 libass 提供字幕烧录，并静态包含所需的文字整形与字体依赖。
- 新增固定版本与校验值、可重复执行的 FFmpeg 构建流程，并为每个版本发布对应源码归档。
- 在 App 内附带第三方许可证与运行时构建信息。
- VideoBox 应用源码采用 MIT License。

## [0.1.0] - 2026-09-04

### English

- First public preview of the native SwiftUI macOS app.
- Added media inspection, AVFoundation playback, clip editing, track and metadata editing, and an export queue.
- Added stream-copy and transcoding workflows powered by FFmpeg and ffprobe.
- Added repeatable universal app/DMG packaging with checksum generation.

### 中文

- 首个公开预览版，采用 SwiftUI 构建原生 macOS 应用。
- 提供媒体信息检查、AVFoundation 播放、片段剪辑、轨道与元数据编辑和导出队列。
- 通过 FFmpeg 与 ffprobe 提供码流复制及转码工作流。
- 新增可重复执行的通用架构 App/DMG 打包与校验值生成流程。
