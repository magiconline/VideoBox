<div align="center">
  <img src="Assets/AppIcon.png" width="128" alt="VideoBox 应用图标">
  <h1>VideoBox</h1>
  <p>原生 macOS 视频处理工具：无需重新压缩，即可调整视频文件的轨道与封装格式。</p>
</div>

![VideoBox 编辑器](Documentation/Images/editor.png)

VideoBox 使用 SwiftUI 构建原生界面，以 AVFoundation 提供播放预览，并通过内置的 FFmpeg 运行时完成媒体分析与导出。它的核心能力是在不重新编码视频和音频的情况下选择、保留或移除媒体轨道、修改轨道信息，并更换文件的封装格式；需要调整画质、尺寸或编码格式时，也可以使用完整的转码与压缩功能。所有处理均在本机完成。

> [!IMPORTANT]
> VideoBox 目前是早期预览版，界面暂为简体中文。FFmpeg 与 ffprobe 已包含在 App 内；预览版 DMG 仅做临时签名，尚未通过 Apple 公证。

## 主要功能

- **无需重新压缩即可调整视频文件的轨道与封装**：通过码流复制选择、保留或移除视频、音频与字幕轨道，修改轨道标题、语言及默认状态，并在原始编码兼容的前提下重新封装为 MP4、MOV、MKV 或 WebM。视频和音频码流保持不变，速度快且无画质损失。
- 在“轨道与元数据”中分别导入、单独导出及排序视频、音频和字幕轨道；导入轨道可来自独立媒体文件，并按界面顺序写入成片。
- 导入后可立即在播放器中切换并播放外部视频/音频轨道，文本字幕会随播放头直接显示，无需先导出成片。
- 拖放导入、AVPlayer 预览与媒体信息检查。
- 带缩略图的时间线，以及分割、删除、复制、拖放重排和顺序拼接。
- 每个片段可独立设置速度、旋转、水平/垂直镜像、音量与缩放。
- 检查视频、音频、字幕、附件、章节和文件元数据。
- 可配置转码与压缩，支持 MP4、MOV、MKV 与 WebM。
- H.264、H.265/HEVC、AV1 与 ProRes，并支持 VideoToolbox 硬件编码。
- 分辨率、帧率、像素格式、码率、目标大小、音频、字幕与容器设置。
- 串行后台导出队列，以及可检查的 FFmpeg 命令预览。

## 运行要求

- macOS 13 Ventura 或更高版本。
- Apple Silicon Mac。
- 安装 DMG 后可直接使用，无需 Homebrew 或额外媒体工具。

## 安装预览版

1. 从 [GitHub Releases](https://github.com/magiconline/VideoBox/releases) 下载最新的 Apple Silicon 版 `.dmg`。
2. 打开 DMG，将 **VideoBox** 拖入 **Applications（应用程序）**。
3. 由于预览版尚未公证，如果 macOS 阻止首次启动，请按住 Control 点击应用，再选择“打开”。

Release 页面会同时提供 `.sha256` 文件，可用于校验下载：

```bash
shasum -a 256 -c VideoBox-0.2.1-macOS-arm64.dmg.sha256
```

## 从源码构建

在 Xcode 中打开 `Package.swift`，选择 **VideoBox** scheme 与 **My Mac** 后运行。需要兼容 Swift 5.9 的工具链。在 App Bundle 之外运行的开发版本，可继续使用 `PATH` 或常见 Homebrew 路径中的 FFmpeg。

命令行开发：

```bash
swift build
swift test
```

制作可分发 DMG 时，脚本还会从源码编译固定版本的 FFmpeg 运行时。请先安装仅用于构建的工具：

```bash
brew install cmake meson ninja nasm pkgconf
```

然后生成 Apple Silicon 原生、临时签名的 DMG：

```bash
./Scripts/create_dmg.sh release
```

DMG 与校验文件会写入 `dist/`。中间 App Bundle 在临时目录中生成并自动清理，因此不会作为第二个应用出现在 Spotlight 搜索结果中。如需 Developer ID 签名与公证：

```bash
VIDEOBOX_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VIDEOBOX_NOTARY_PROFILE="notary-profile" \
./Scripts/create_dmg.sh release
```

公证配置需要事先通过 `xcrun notarytool store-credentials` 保存到钥匙串。

生成与 DMG 同时发布的完整对应源码归档：

```bash
./Scripts/create_ffmpeg_source_archive.sh
```

运行时的版本与校验值固定在 `Scripts/ffmpeg_versions.sh` 中，详情见[运行时构建说明](ThirdParty/FFmpeg/BUILDING.md)。

## 项目结构

```text
Assets/                 应用图标源文件
Documentation/          截图与分版本发布说明
Packaging/              macOS App 元数据
Scripts/                可重复执行的 App/DMG 打包脚本
ThirdParty/FFmpeg/      运行时构建说明与第三方许可信息
Sources/VideoBox/
├── App/                 App 入口与依赖容器
├── UI/                  SwiftUI 页面与组件
├── Media/               媒体探测结果与模型
├── Player/              AVFoundation 播放能力
├── Editing/             非破坏性剪辑时间线
├── Export/              导出模型与预设
├── Engines/             FFmpeg/ffprobe 进程集成
├── Jobs/                导出任务与队列
└── System/              内置运行时与外部工具探测
Tests/VideoBoxTests/     单元测试与集成测试
```

## 当前状态

VideoBox 目前适合作为本地预览工具使用，还不是完整的消费级正式版本。后续发布工作包括 Developer ID 签名与公证，以及覆盖更多真实媒体文件的兼容性测试。

欢迎通过 [GitHub Issues](https://github.com/magiconline/VideoBox/issues) 提交问题，也欢迎范围明确的 Pull Request。

## 开源许可

VideoBox 应用源码使用 [MIT License](LICENSE) 发布。DMG 内另行包含可执行的 FFmpeg 运行时，其中含 x264、x265 等 GPL 组件，按 GPL-2.0-or-later 与各组件适用许可证分发。所有内置运行时的版本均同时提供完整对应源码与构建脚本，详情见[第三方许可说明](ThirdParty/FFmpeg/THIRD_PARTY_NOTICES.md)。
