# FFmpeg + Metal iOS Video Player

基于 FFmpeg 解码 + Metal 渲染的 iOS 视频播放器 Demo，采用 B 站风格的交互 UI。

## 功能特性

- **硬解码/软解码**：基于 FFmpeg avcodec 异步解码（send/receive 模型）
- **Metal 渲染**：GPU 加速的 NV12 双平面纹理渲染，低功耗高性能
- **音视频同步**：基于外部时钟的 A/V 同步（`FFSyncClock`），支持暂停恢复无缝衔接
- **精准 Seek**：任意时间点跳转，保持音画同步
- **变速播放**：0.5x / 1.0x / 1.5x / 2.0x 速度切换
- **进度条交互**：拖拽 Seek + 点击进度条跳转到具体时间
- **B 站风格 UI**：顶部渐变栏、底部控制栏、中央播放按钮、倍速浮层
- **控制栏自动隐藏**：3 秒无操作自动隐藏，点击画面切换显隐
- **横竖屏切换**：支持 iOS 16+ 的 `requestGeometryUpdate` 全屏切换
- **多源支持**：本地文件、网络 URL（HTTP/HLS）

## 架构总览

```
┌──────────────────────────────────────────────────┐
│                FFPlayerViewController             │  ← 页面控制器
│  ┌────────────────┐  ┌─────────────────────────┐ │
│  │   FFMetalView  │  │  FFPlayerControlView    │ │  ← UI 层
│  │  (Metal 渲染)   │  │  (B站风格控制 UI)        │ │
│  └────────┬───────┘  └────────────┬────────────┘ │
│           │                       │               │
│  ┌────────┴───────────────────────┴────────────┐ │
│  │              FFPlayerCore (引擎)              │ │  ← 核心引擎
│  │  ┌─────────┐ ┌──────────┐ ┌──────────────┐ │ │
│  │  │ Demuxer │ │  Decoder │ │  SyncClock   │ │ │
│  │  │ (解复用) │ │  (解码)   │ │  (同步时钟)   │ │ │
│  │  └────┬─────┘ └────┬─────┘ └──────┬───────┘ │ │
│  │       │             │              │         │ │
│  │  ┌────┴─────┐ ┌────┴─────┐        │         │ │
│  │  │ PacketQ  │ │ FrameQ   │        │         │ │
│  │  │ (包队列)  │ │ (帧队列)  │        │         │ │
│  │  └──────────┘ └──────────┘        │         │ │
│  └───────────────────────────────────┴─────────┘ │
└──────────────────────────────────────────────────┘
```

### 线程架构（3 条后台 pthread + 2 条系统回调）

| 线程 | 入口 | 职责 |
|------|------|------|
| **Demux** | `_demuxLoop` | 循环读取 AVPacket → 分发到视频/音频包队列 |
| **Video Decode** | `_videoDecodeLoop` | 取包 → send/receive 解码 → 同步等待 → 格式转换 → Metal 送显 |
| **Audio Decode** | `_audioDecodeLoop` | 取包 → send/receive 解码 → 重采样 → 音频帧队列 |
| **MTKView 回调** | 系统驱动 | CADisplayLink 驱动 Metal 渲染 |
| **AudioQueue 回调** | 系统驱动 | 拉取音频帧填充 PCM 缓冲区 |

### 数据流向

```
[媒体文件/URL]
     │
     ▼
┌─────────┐  packet  ┌──────────┐  AVFrame  ┌───────────────┐  CVPixelBuffer  ┌──────────┐
│ Demuxer │─────────▶│ Decoder  │──────────▶│ FrameConverter│───────────────▶│ MetalView│
└─────────┘          └──────────┘           └───────────────┘                └──────────┘
     │                    │
     │              ┌─────┴─────┐
     │              │ Resampler │──▶ AudioFrameQueue ──▶ AudioQueue
     │              └───────────┘
     ▼
┌──────────┐
│ SyncClock│ ← 音视频同步基准
└──────────┘
```

### 音视频同步机制

采用**外部时钟同步**策略：

1. 同步时钟（`FFSyncClock`）作为播放时间基准，采用「锚点 + 增量」模型：
   ```
   currentTime = mediaTimeAtAnchor + (CACurrentMediaTime() - anchorWallTime) × speed
   ```
2. 暂停时冻结 `mediaTimeAtAnchor`，恢复时刷新 `anchorWallTime`
3. 视频帧与时钟比较 `diff = PTS - clockTime`：
   - `diff < -0.1` → 帧过时，丢弃
   - `diff ≤ 0.05` → 准时，送显
   - `diff > 0.05` → 过早，等待
4. 音频通过 AudioQueue 独立播放，不依赖时钟同步

### Seek 流程

1. 设置 `_seeking = YES` → demux 线程空转等待
2. Abort 所有队列 → 唤醒阻塞线程
3. Flush 所有队列 + 解码器 → 清空旧数据
4. `av_seek_frame` 跳转到目标关键帧
5. 暂停同步时钟（防止时钟跑赢解码器追赶速度导致丢帧）**← 已修复的 Bug**
6. 首帧到达后用实际 PTS 对齐并恢复时钟
7. Reset 队列、清除标记

## 项目结构

```
ios_ffmpeg_demo/
├── ios_ffmpeg_demo/
│   ├── Player/
│   │   ├── Core/           ← 核心引擎层
│   │   │   ├── FFPlayerCore.h/m      播放引擎（线程管理/同步/Seek）
│   │   │   ├── FFDemuxer.h/m         解复用器
│   │   │   ├── FFVideoDecoder.h/m    视频解码器
│   │   │   ├── FFAudioDecoder.h/m    音频解码器
│   │   │   ├── FFAudioResampler.h/m  音频重采样器
│   │   │   ├── FFVideoFrameConverter.h/m  帧格式转换（AVFrame→CVPixelBuffer）
│   │   │   ├── FFPacketQueue.h/m     线程安全 AVPacket 队列
│   │   │   ├── FFFrameQueue.h/m      线程安全音频帧队列
│   │   │   └── FFSyncClock.h/m       同步时钟
│   │   ├── Render/         ← Metal 渲染层
│   │   │   ├── FFMetalRenderer.h/m   Metal 渲染器（NV12 双平面）
│   │   │   ├── FFMetalView.h/m       MTKView 子类（渲染载体）
│   │   │   └── Shaders.metal        Metal Shader（顶点/片元着色器）
│   │   ├── Audio/          ← 音频输出层
│   │   │   └── FFAudioOutput.h/m     AudioQueue 封装（播放/变速）
│   │   └── UI/             ← UI 层
│   │       ├── FFPlayerView.h/m              组合视图容器
│   │       ├── FFPlayerControlView.h/m        B站风格控制栏
│   │       └── FFPlayerViewController.h/m     播放页面控制器
│   ├── ViewController.h/m    ← 主界面（三个入口按钮）
│   ├── AppDelegate.h/m
│   └── Info.plist
├── frameworks/            ← FFmpeg xcframeworks
│   ├── avcodec.xcframework
│   ├── avformat.xcframework
│   ├── avutil.xcframework
│   ├── swresample.xcframework
│   └── swscale.xcframework
└── ios_ffmpeg_demo.xcodeproj
```

## 依赖

### FFmpeg 框架（已集成为 xcframework）

| 框架 | 用途 |
|------|------|
| `avformat` | 解复用、读取媒体文件/网络流 |
| `avcodec` | 音视频解码 |
| `avutil` | FFmpeg 工具函数 |
| `swresample` | 音频重采样 |
| `swscale` | 视频格式转换 |

### 系统框架

- `Metal.framework` / `MetalKit.framework` — GPU 渲染
- `AudioToolbox.framework` — AudioQueue 音频输出
- `CoreVideo.framework` — CVPixelBuffer 管理
- `QuartzCore.framework` — CADisplayLink / 动画
- `VideoToolbox.framework` — 硬件解码（可选，当前未启用）

## 编译与运行

### 环境要求

- macOS 12.0+
- Xcode 14.0+
- iOS 15.0+ 模拟器或真机

### 编译步骤

1. 打开项目
   ```bash
   open ios_ffmpeg_demo.xcodeproj
   ```

2. 在 Xcode 中选择目标设备（模拟器或真机）

3. 按 `Cmd + R` 编译运行

### 命令行编译

```bash
xcodebuild -project ios_ffmpeg_demo.xcodeproj \
  -scheme ios_ffmpeg_demo \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  build
```

## 使用说明

1. **播放本地视频**：将视频文件（如 `test.mp4`）添加到 App Bundle（Xcode → Target → Build Phases → Copy Bundle Resources）
2. **播放网络视频**：点击 "Play Network Video" 使用预置的 Big Buck Bunny 测试流
3. **输入 URL**：点击 "Input URL" 手动输入视频地址
4. **进度条操作**：
   - **拖拽**滑块跳转到任意位置
   - **点击**进度条空白处直接跳转
5. **倍速切换**：点击底部栏的倍速按钮（1.0x）选择速度
6. **全屏切换**：点击右下角全屏按钮或旋转设备
7. **返回**：点击左上角返回按钮退出播放

## 许可证

本项目仅用于学习和演示目的。FFmpeg 库遵循 LGPL/GPL 许可证，请遵守相关条款。

---

*Generated with Qoder*
