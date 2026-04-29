//
//  FFPlayerCore.m
//  ios_ffmpeg_demo
//
//  核心播放引擎实现 —— 统筹管理所有组件、线程、音视频同步、Seek、变速播放。
//
//  ═══════════════════════════════════════════════════════════════
//  线程架构（共 3 条后台线程 + 2 条系统回调）：
//  ═══════════════════════════════════════════════════════════════
//
//  1. DEMUX 线程 (demuxThread)
//     └── _demuxLoop()
//         └── 循环调用 [_demuxer readPacket:]
//             ├── 视频包 → [_videoPacketQueue putPacket:]
//             ├── 音频包 → [_audioPacketQueue putPacket:]
//             └── 其他流  → av_packet_unref 丢弃
//         EOF 时向两个包队列各放入一个 flush 空包（data=NULL, size=0）
//         用于通知解码线程刷新解码器内部缓冲区
//
//  2. VIDEO DECODE 线程 (videoDecodeThread)
//     └── _videoDecodeLoop()
//         ├── [_videoPacketQueue getPacket:] 阻塞等待视频包
//         ├── 收到 flush 空包 → 调 sendPacket(NULL) 刷新解码器
//         │   └── 循环 receiveFrame 取出所有剩余帧 → _processVideoFrame
//         ├── sendPacket/packet → receiveFrame 异步模型
//         └── 每帧调用 _processVideoFrame → 同步等待 + 送显
//
//  3. AUDIO DECODE 线程 (audioDecodeThread)
//     └── _audioDecodeLoop()
//         ├── [_audioPacketQueue getPacket:] 阻塞等待音频包
//         ├── 收到 flush 空包 → 刷新解码器 + 回调主线程通知播放完成
//         ├── sendPacket/packet → receiveFrame + 重采样
//         └── resample → [_audioFrameQueue putFrame:] 入音频帧队列
//
//  4. MTKView 渲染回调（系统驱动，非此处创建）
//     └── 由 FFMetalView 内部 CADisplayLink 或 MTKViewDelegate 驱动
//         └── 从 _metalView 获取当前 pixelBuffer 渲染
//
//  5. AudioQueue 拉取回调（系统驱动，由 FFAudioOutput 创建）
//     └── _fillAudioBuffer:bufferSize:filledSize:
//         ├── 优先处理未消费完的 pending 音频帧
//         ├── 从 _audioFrameQueue 取帧 → 拷贝到 AudioQueue 缓冲区
//         └── 无数据时填静音 (silence)
//
//  ═══════════════════════════════════════════════════════════════
//  状态机：
//  ═══════════════════════════════════════════════════════════════
//    Idle → Preparing → Ready → Playing ⇄ Paused
//                              ↓         ↓
//                           Stopped   Completed
//                              ↓
//                           Error
//
//  ═══════════════════════════════════════════════════════════════
//  核心流程：
//  ═══════════════════════════════════════════════════════════════
//    Demux                  Decode                  Render/Output
//   ┌─────────┐   packet   ┌──────────┐   frame    ┌─────────────┐
//   │ Demuxer │───────────▶│ Decoder  │───────────▶│ Queue/Output│
//   └─────────┘            └──────────┘            └─────────────┘
//        │                       │                       │
//    readPacket             sendPacket              _fillAudioBuffer
//    putPacket              receiveFrame            MTKView draw
//

#import "FFPlayerCore.h"
#import "FFDemuxer.h"
#import "FFVideoDecoder.h"
#import "FFAudioDecoder.h"
#import "FFAudioResampler.h"
#import "FFVideoFrameConverter.h"
#import "FFPacketQueue.h"
#import "FFFrameQueue.h"
#import "FFSyncClock.h"
#import "FFAudioOutput.h"
#import "FFMetalView.h"
#import <pthread.h>
#import <libavutil/time.h>

// ══════════════════════════════════════════════════════════════════════════════
// 队列容量常量
// ══════════════════════════════════════════════════════════════════════════════

/// 视频包队列最大容量（解复用 → 视频解码）
static const NSUInteger kVideoPacketQueueCapacity = 60;
/// 音频包队列最大容量（解复用 → 音频解码）
static const NSUInteger kAudioPacketQueueCapacity = 60;
/// 视频帧队列最大容量（视频解码 → 送显同步，值小可降低内存但增加解码等待）
static const NSUInteger kVideoFrameQueueCapacity = 4;
/// 音频帧队列最大容量（音频解码 → AudioQueue 拉取，值大可缓冲更多音频防卡顿）
static const NSUInteger kAudioFrameQueueCapacity = 12;

@implementation FFPlayerCore {
    // ════════════════════════════════════════════════════════════════════════
    // 外部注入
    // ════════════════════════════════════════════════════════════════════════

    /// 媒体 URL 字符串
    NSString *_url;
    /// Metal 渲染视图（弱引用，避免循环引用）
    __weak FFMetalView *_metalView;

    // ════════════════════════════════════════════════════════════════════════
    // 底层模块
    // ════════════════════════════════════════════════════════════════════════

    /// 解复用器 —— 负责读取媒体文件/网络流，分离音视频包
    FFDemuxer *_demuxer;
    /// 视频解码器 —— 将压缩的视频包解码为 YUV/RGB 帧
    FFVideoDecoder *_videoDecoder;
    /// 音频解码器 —— 将压缩的音频包解码为 PCM 帧
    FFAudioDecoder *_audioDecoder;
    /// 音频重采样器 —— 将解码后的音频帧重采样为目标格式（如 s16le、44100Hz、立体声）
    FFAudioResampler *_audioResampler;
    /// 视频帧格式转换器 —— 将解码后的视频帧转换为 CVPixelBuffer（供 Metal 渲染）
    FFVideoFrameConverter *_videoConverter;

    /// 视频包队列 —— 解复用线程写入，视频解码线程消费（线程安全有界阻塞队列）
    FFPacketQueue *_videoPacketQueue;
    /// 音频包队列 —— 解复用线程写入，音频解码线程消费（线程安全有界阻塞队列）
    FFPacketQueue *_audioPacketQueue;
    /// 视频帧队列 —— 视频解码线程写入，同步逻辑消费（实际上直接送显，队列暂未使用）
    FFVideoFrameQueue *_videoFrameQueue;
    /// 音频帧队列 —— 音频解码线程写入，AudioQueue 拉取回调消费（线程安全有界阻塞队列）
    FFAudioFrameQueue *_audioFrameQueue;

    /// 同步时钟 —— 管理播放时间基准，支持暂停/恢复/变速
    FFSyncClock *_syncClock;
    /// 音频输出 —— 封装 AudioQueue，提供音频播放和拉取回调
    FFAudioOutput *_audioOutput;

    // ════════════════════════════════════════════════════════════════════════
    // 后台线程
    // ════════════════════════════════════════════════════════════════════════

    /// 解复用线程（pthread）
    pthread_t _demuxThread;
    /// 视频解码线程（pthread）
    pthread_t _videoDecodeThread;
    /// 音频解码线程（pthread）
    pthread_t _audioDecodeThread;

    /// 解复用线程运行标志
    BOOL _demuxThreadRunning;
    /// 视频解码线程运行标志
    BOOL _videoDecodeThreadRunning;
    /// 音频解码线程运行标志
    BOOL _audioDecodeThreadRunning;

    // ════════════════════════════════════════════════════════════════════════
    // 播放控制标志
    // ════════════════════════════════════════════════════════════════════════

    /// 全局停止标记 —— 设为 YES 后所有线程应尽快退出循环
    BOOL _stopped;
    /// Seek 进行中标记 —— 设为 YES 时 demux 线程等待、解码线程跳过帧
    BOOL _seeking;
    /// 文件读取完毕标记 —— 解复用线程读到 EOF 时设为 YES
    BOOL _eof;

    /// Seek 后等待首帧视频同步标记 —— YES 时表示时钟已被暂停，等待第一帧视频到达后恢复
    /// 用于解决 seek 后因时钟提前运行导致视频帧被大量丢弃、画面卡住的 bug
    BOOL _postSeekVideoSync;

    /// 进度定时器（主线程），每 0.25 秒向 delegate 回调当前播放进度
    NSTimer *_progressTimer;

    // ════════════════════════════════════════════════════════════════════════
    // 部分音频帧追踪
    // ════════════════════════════════════════════════════════════════════════
    // AudioQueue 每次拉取固定大小的缓冲区，但解码出的音频帧大小不固定。
    // 当一帧数据大于 AudioQueue 本次剩余空间时，需要拆分成多次提供。
    // _pendingAudioFrame 用于暂存未消费完的音频帧，下次拉取时继续提供。
    //
    // 场景示例：
    //   AudioQueue 每次拉取 4096 字节，解码出一帧 6000 字节
    //   第一次填充前 4096 字节，剩余 1904 字节存入 pending
    //   下次拉取时先取 pending 的 1904 字节，再取下一帧

    /// 暂存未完全消费的音频帧
    FFAudioFrame _pendingAudioFrame;
    /// 是否存在未消费完的音频帧
    BOOL _hasPendingAudioFrame;
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 初始化与销毁
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 使用媒体 URL 和 Metal 渲染视图初始化播放器
 *
 * @param url       媒体文件路径或网络 URL
 * @param metalView 用于显示视频帧的 Metal 视图
 *
 * 初始化流程：
 *   1. 保存 URL 和 metalView 引用
 *   2. 设置初始状态为 Idle
 *   3. 创建同步时钟和各队列（此时队列为空，后续 prepare 时才会使用）
 */
- (instancetype)initWithURL:(NSString *)url metalView:(FFMetalView *)metalView {
    self = [super init];
    if (self) {
        _url = [url copy];
        _metalView = metalView;
        _state = FFPlayerStateIdle;
        _playbackSpeed = 1.0;
        _stopped = YES;
        _seeking = NO;
        _eof = NO;
        _postSeekVideoSync = NO;
        _hasPendingAudioFrame = NO;

        // 创建同步时钟 —— 管理播放时间基准（暂停、变速基于此时钟）
        _syncClock = [[FFSyncClock alloc] init];
        // 创建视频包队列 —— 解复用 → 视频解码的"管道"
        _videoPacketQueue = [[FFPacketQueue alloc] initWithCapacity:kVideoPacketQueueCapacity];
        // 创建音频包队列 —— 解复用 → 音频解码的"管道"
        _audioPacketQueue = [[FFPacketQueue alloc] initWithCapacity:kAudioPacketQueueCapacity];
        // 创建视频帧队列（预留，当前版本直接送显，队列暂未实际使用）
        _videoFrameQueue = [[FFVideoFrameQueue alloc] initWithCapacity:kVideoFrameQueueCapacity];
        // 创建音频帧队列 —— 音频解码 → AudioQueue 的"管道"
        _audioFrameQueue = [[FFAudioFrameQueue alloc] initWithCapacity:kAudioFrameQueueCapacity];
    }
    return self;
}

/**
 * 析构方法 —— 确保播放器被释放时停止所有线程和模块
 */
- (void)dealloc {
    [self stop];
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 属性访问器
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 当前播放时间
 *
 * 直接委托给同步时钟，由 FFSyncClock 根据开始时间 + 已播放时长（考虑暂停、变速）计算。
 * 不依赖音视频帧的 PTS，因此 Seek 后时钟会被重置，进度条也随之跳转。
 */
- (double)currentTime {
    return [_syncClock currentTime];
}

/**
 * 媒体总时长
 *
 * 委托给解复用器，解复用器在 open 时从 avformat 获取。
 * prepareToPlay 完成后即可安全读取。
 */
- (double)duration {
    return _demuxer.duration;
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 状态管理
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 设置播放器状态（内部方法）
 *
 * 状态变更时通过 delegate 在主线程回调通知外部。
 * 如果新状态与当前状态相同则忽略，避免重复回调。
 *
 * @param state 新状态
 */
- (void)_setState:(FFPlayerState)state {
    if (_state == state) return;
    _state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(playerCoreDidChangeState:)]) {
            [self.delegate playerCoreDidChangeState:state];
        }
    });
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 准备
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 异步准备播放（对外接口）
 *
 * 状态约束：仅在 Idle、Stopped、Error 状态下可调用。
 * 在全局队列中执行 _prepareInternal，不阻塞主线程。
 *
 * 准备流程：
 *   1. 打开解复用器 → 获取流信息
 *   2. 如果有视频流：创建视频解码器 + 格式转换器，更新 Metal 视图尺寸
 *   3. 如果有音频流：创建音频解码器 + 重采样器 + 音频输出
 *   4. 状态 → Ready
 */
- (void)prepareToPlay {
    if (_state != FFPlayerStateIdle && _state != FFPlayerStateStopped && _state != FFPlayerStateError) return;
    [self _setState:FFPlayerStatePreparing];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _prepareInternal];
    });
}

/**
 * 内部准备逻辑（在全局队列中执行）
 *
 * 步骤详解：
 *   1. 创建并打开解复用器（FFDemuxer），失败则回调错误
 *   2. 如果有视频流：
 *      a. 创建并打开视频解码器（FFVideoDecoder）
 *      b. 创建视频帧格式转换器（FFVideoFrameConverter），将解码后的 YUV 转 CVPixelBuffer
 *      c. 在主线程通知 Metal 视图更新视频尺寸
 *   3. 如果有音频流：
 *      a. 创建并打开音频解码器（FFAudioDecoder）
 *      b. 创建音频重采样器（FFAudioResampler），统一输出 PCM s16le 44100Hz 立体声
 *      c. 创建音频输出（FFAudioOutput），设置 AudioQueue 拉取回调
 *   4. 状态 → Ready
 */
- (void)_prepareInternal {
    // ── 打开解复用器 ──────────────────────────────────────────────────────
    _demuxer = [[FFDemuxer alloc] initWithURL:_url];
    if (![_demuxer open]) {
        [self _notifyError:@"Failed to open media"];
        return;
    }

    // ── 设置视频解码器与格式转换器 ─────────────────────────────────────────
    if (_demuxer.videoStreamIndex >= 0) {
        _videoDecoder = [[FFVideoDecoder alloc] initWithCodecParameters:_demuxer.videoCodecParameters];
        if (![_videoDecoder open]) {
            [self _notifyError:@"Failed to open video decoder"];
            return;
        }

        // 确定源像素格式，避免 AV_PIX_FMT_NONE 导致转换器初始化失败
        enum AVPixelFormat srcFmt = _videoDecoder.pixelFormat;
        if (srcFmt == AV_PIX_FMT_NONE) srcFmt = AV_PIX_FMT_YUV420P;

        // 创建视频帧转换器（解码帧 → CVPixelBuffer）
        _videoConverter = [[FFVideoFrameConverter alloc] initWithWidth:_videoDecoder.width
                                                                height:_videoDecoder.height
                                                      sourcePixelFormat:srcFmt];
        if (![_videoConverter open]) {
            [self _notifyError:@"Failed to open video converter"];
            return;
        }

        // 在主线程更新 Metal 视图的视频尺寸，以便渲染层调整显示比例
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_metalView updateVideoSize:CGSizeMake(self->_videoDecoder.width, self->_videoDecoder.height)];
        });
    }

    // ── 设置音频解码器、重采样器与音频输出 ─────────────────────────────────
    if (_demuxer.audioStreamIndex >= 0) {
        _audioDecoder = [[FFAudioDecoder alloc] initWithCodecParameters:_demuxer.audioCodecParameters];
        if (![_audioDecoder open]) {
            [self _notifyError:@"Failed to open audio decoder"];
            return;
        }

        // 创建音频重采样器，将解码后的音频转换为 AudioQueue 所需的格式（默认 s16、44100Hz、立体声）
        _audioResampler = [[FFAudioResampler alloc] initWithSourceSampleRate:_audioDecoder.sampleRate
                                                         sourceChannelLayout:_audioDecoder.channelLayout
                                                                sourceFormat:_audioDecoder.sampleFormat];
        if (![_audioResampler open]) {
            [self _notifyError:@"Failed to open audio resampler"];
            return;
        }

        // 创建音频输出，内部创建 AudioQueue 并启动拉取回调线程
        _audioOutput = [[FFAudioOutput alloc] initWithSampleRate:_audioDecoder.sampleRate channels:2];
        __weak typeof(self) weakSelf = self;
        // 设置 AudioQueue 拉取回调 —— 当 AudioQueue 需要音频数据时调用此 block
        _audioOutput.audioDataRequestBlock = ^(uint8_t *buffer, int bufferSize, int *filledSize) {
            [weakSelf _fillAudioBuffer:buffer bufferSize:bufferSize filledSize:filledSize];
        };
    }

    // ── 准备完成 ──────────────────────────────────────────────────────────
    [self _setState:FFPlayerStateReady];
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 播放 / 暂停 / 停止
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 开始或恢复播放（对外接口）
 *
 * 根据当前状态采用不同策略：
 *   - Paused: 恢复时钟 + 恢复音频输出
 *   - Completed: Seek 到 0 秒，重置标记，重新播放
 *   - Ready: 启动后台线程、音频输出、进度定时器
 *
 * 从 Ready 启动时的完整流程：
 *   1. 重置 _stopped、_eof 标记
 *   2. 启动同步时钟
 *   3. 创建并启动 3 条后台线程（demux、video decode、audio decode）
 *   4. 启动音频输出（AudioQueue）
 *   5. 在主线程启动进度定时器
 *   6. 状态 → Playing
 */
- (void)play {
    // ── 从暂停恢复 ─────────────────────────────────────────────────────────
    if (_state == FFPlayerStatePaused) {
        [_syncClock resume];
        [_audioOutput resume];
        [self _setState:FFPlayerStatePlaying];
        return;
    }

    // ── 播放完成重新开始 ───────────────────────────────────────────────────
    if (_state == FFPlayerStateCompleted) {
        [self seekToTime:0];
        [_syncClock start];
        _eof = NO;
        [self _setState:FFPlayerStatePlaying];
        [_audioOutput start];
        return;
    }

    // ── 非就绪状态忽略 ────────────────────────────────────────────────────
    if (_state != FFPlayerStateReady) return;

    // ── 首次启动播放 ──────────────────────────────────────────────────────
    _stopped = NO;
    _eof = NO;
    [_syncClock start];
    [_syncClock setSpeed:_playbackSpeed];

    // 启动解复用线程、视频解码线程、音频解码线程
    [self _startThreads];

    // 启动音频输出（创建 AudioQueue 并开始播放）
    if (_audioOutput) {
        [_audioOutput setPlaybackRate:_playbackSpeed];
        [_audioOutput start];
    }

    // 启动进度的 UI 定时器
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _startProgressTimer];
    });

    [self _setState:FFPlayerStatePlaying];
}

/**
 * 暂停播放（对外接口）
 *
 * 暂停流程：
 *   1. 暂停同步时钟（时间不再前进）
 *   2. 暂停音频输出（AudioQueue 暂停，拉取回调停止）
 *   3. 状态 → Paused
 *
 * 注意：视频解码线程因 _processVideoFrame 中等待时钟同步而自然阻塞，
 *       无需单独暂停视频渲染。
 */
- (void)pause {
    if (_state != FFPlayerStatePlaying) return;
    [_syncClock pause];
    [_audioOutput pause];
    [self _setState:FFPlayerStatePaused];
}

/**
 * 停止播放（对外接口）
 *
 * 完整停止流程（按顺序）：
 *   1. 设置 _stopped = YES —— 所有线程在下一次循环检测时退出
 *   2. Abort 所有队列 —— 唤醒阻塞在 getPacket/getFrame 上的线程
 *   3. Join 等待三条后台线程安全退出
 *   4. 停止音频输出、重置同步时钟
 *   5. Flush + Reset 所有队列（清除残留数据）
 *   6. 清除 pending 音频帧
 *   7. Close 并释放所有底层模块（demuxer、decoder、resampler、converter、audioOutput）
 *   8. 在主线程停止进度定时器
 *   9. 状态 → Stopped
 *
 * 线程安全说明：
 *   - _stopped 在 stop 开始时设置，所有线程的循环条件都会检查此标志
 *   - abort 操作会唤醒可能因队列空/满而阻塞的线程
 *   - pthread_join 确保线程完全退出后再释放资源
 */
- (void)stop {
    if (_state == FFPlayerStateIdle || _state == FFPlayerStateStopped) return;

    _stopped = YES;

    // ── 1. Abort 所有队列（唤醒阻塞的线程，使队列操作立即返回） ────────────
    [_videoPacketQueue abort];
    [_audioPacketQueue abort];
    [_videoFrameQueue abort];
    [_audioFrameQueue abort];

    // ── 2. Join 等待后台线程退出 ──────────────────────────────────────────
    if (_demuxThreadRunning) {
        pthread_join(_demuxThread, NULL);
        _demuxThreadRunning = NO;
    }
    if (_videoDecodeThreadRunning) {
        pthread_join(_videoDecodeThread, NULL);
        _videoDecodeThreadRunning = NO;
    }
    if (_audioDecodeThreadRunning) {
        pthread_join(_audioDecodeThread, NULL);
        _audioDecodeThreadRunning = NO;
    }

    // ── 3. 停止音频输出并重置同步时钟 ─────────────────────────────────────
    [_audioOutput stop];
    [_syncClock reset];

    // ── 4. Flush + Reset 队列 ─────────────────────────────────────────────
    // Flush 清除队列中所有数据，Reset 恢复队列为非 abort 状态
    [_videoPacketQueue flush];
    [_audioPacketQueue flush];
    [_videoFrameQueue flush];
    [_audioFrameQueue flush];

    [_videoPacketQueue reset];
    [_audioPacketQueue reset];
    [_videoFrameQueue reset];
    [_audioFrameQueue reset];

    // ── 5. 清除 pending 音频帧 ────────────────────────────────────────────
    [self _clearPendingAudioFrame];

    // ── 6. 关闭并释放所有底层模块 ─────────────────────────────────────────
    [_videoDecoder close];
    [_audioDecoder close];
    [_audioResampler close];
    [_videoConverter close];
    [_demuxer close];

    _demuxer = nil;
    _videoDecoder = nil;
    _audioDecoder = nil;
    _audioResampler = nil;
    _videoConverter = nil;
    _audioOutput = nil;

    // ── 7. 停止进度定时器 ─────────────────────────────────────────────────
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _stopProgressTimer];
    });

    // ── 8. 更新状态 ───────────────────────────────────────────────────────
    [self _setState:FFPlayerStateStopped];
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - Seek（跳转）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 跳转到指定时间点（对外接口）
 *
 * Seek 序列（确保干净的状态切换）：
 *   1. 参数校验 —— seconds clamp 到 [0, duration]
 *   2. 设置 _seeking = YES —— demux 线程见 seeking 则空转等待
 *   3. Abort 所有队列 —— 唤醒可能阻塞的 getPacket/getFrame
 *   4. Flush 所有队列 —— 清空残留的旧数据包/帧
 *   5. 清除 pending 音频帧
 *   6. Flush 解码器 —— 清空解码器内部缓冲帧（重要！否则会解码出旧帧）
 *   7. 调用 demuxer seek —— av_seek_frame 到目标时间
 *   8. 重置同步时钟到目标时间，然后暂停（如有视频流）——
 *      防止时钟跑赢解码器追赶速度，导致首帧被丢弃
 *   9. Reset 队列 —— 恢复队列为非 abort 状态，让线程继续工作
 *   10. 清除 _eof 标记
 *   11. 清除 _seeking 标记
 *
 * 关键设计：
 *   - abort + flush + reset 的顺序组合确保队列被彻底清空后重新启用
 *   - 解码器 flush 必须在队列 flush 之后、demuxer seek 之前
 *   - 时钟在 seek 后暂停，等待 _processVideoFrame 收到首帧时用帧 PTS
 *     对齐后恢复，解决 seek 后视频卡住不动的 bug
 */
- (void)seekToTime:(double)seconds {
    if (!_demuxer) return;
    if (seconds < 0) seconds = 0;
    if (seconds > _demuxer.duration) seconds = _demuxer.duration;

    _seeking = YES;

    // ── 1. Abort 队列，唤醒可能阻塞的线程 ──────────────────────────────────
    [_videoPacketQueue abort];
    [_audioPacketQueue abort];
    [_videoFrameQueue abort];
    [_audioFrameQueue abort];

    // ── 2. Flush 队列，清空所有旧数据 ──────────────────────────────────────
    [_videoPacketQueue flush];
    [_audioPacketQueue flush];
    [_videoFrameQueue flush];
    [_audioFrameQueue flush];
    [self _clearPendingAudioFrame];

    // ── 3. Flush 解码器内部缓冲区 ──────────────────────────────────────────
    // 解码器可能缓存了多个帧（尤其是 B 帧场景），必须 flush 否则会解码出 seek 前的帧
    [_videoDecoder flush];
    [_audioDecoder flush];

    // ── 4. 执行解复用器 seek ───────────────────────────────────────────────
    [_demuxer seekToTime:seconds];

    // ── 5. 重置同步时钟到目标时间，然后暂停 ────────────────────────────────
    // 关键修复：seek 后解复用器定位到最近关键帧（在目标时间之前），
    // 解码器需要时间追赶。如果此时时钟继续运行，当首帧到达时时钟可能已
    // 推进过多，导致 _processVideoFrame 中 diff < -0.1 将所有帧丢弃，
    // 视频画面卡住。因此暂停时钟，交由 _processVideoFrame 在收到
    // 首帧时恢复，确保首帧 PTS 与时钟对齐。
    [_syncClock setTime:seconds];
    if (_videoDecoder) {
        [_syncClock pause];
        _postSeekVideoSync = YES;
    }

    // ── 6. Reset 队列（清除 abort 状态，恢复生产-消费） ────────────────────
    [_videoPacketQueue reset];
    [_audioPacketQueue reset];
    [_videoFrameQueue reset];
    [_audioFrameQueue reset];

    // ── 7. 清除标记 ────────────────────────────────────────────────────────
    _eof = NO;
    _seeking = NO;
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 变速播放
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 设置播放速度
 *
 * 速度控制通过两方面协同实现：
 *   1. 同步时钟变速 —— _syncClock setSpeed: 调整时钟推进速度
 *      - 例如 speed=2.0 时，时钟每秒推进 2 秒
 *      - 视频同步循环中帧 PTS 与加速后的时钟比较，等待时间相应缩短
 *   2. AudioQueue 播放速率 —— _audioOutput setPlaybackRate:
 *      - 直接修改 AudioQueue 的播放速率
 *      - 音频音调会随之变化（未做音调补偿）
 *
 * @param playbackSpeed 播放速度倍数（如 0.5、1.0、1.5、2.0）
 */
- (void)setPlaybackSpeed:(double)playbackSpeed {
    _playbackSpeed = playbackSpeed;
    [_syncClock setSpeed:playbackSpeed];
    [_audioOutput setPlaybackRate:playbackSpeed];
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 线程管理
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 启动三条后台线程
 *
 * 使用 POSIX pthread 而非 GCD/NSThread，因为：
 *   - pthread 可设置线程优先级（此处使用默认优先级）
 *   - 线程生命周期完全可控
 *   - 便于在 stop 时 join 等待
 *
 * 三条线程通过 C 函数桥接（static void *func(void *arg)）调用 Objective-C 方法：
 *   - demuxThreadFunc → _demuxLoop
 *   - videoDecodeThreadFunc → _videoDecodeLoop
 *   - audioDecodeThreadFunc → _audioDecodeLoop
 */
- (void)_startThreads {
    // 解复用线程
    _demuxThreadRunning = YES;
    pthread_create(&_demuxThread, NULL, demuxThreadFunc, (__bridge void *)self);

    // 视频解码线程（仅在存在视频流时创建）
    if (_videoDecoder) {
        _videoDecodeThreadRunning = YES;
        pthread_create(&_videoDecodeThread, NULL, videoDecodeThreadFunc, (__bridge void *)self);
    }

    // 音频解码线程（仅在存在音频流时创建）
    if (_audioDecoder) {
        _audioDecodeThreadRunning = YES;
        pthread_create(&_audioDecodeThread, NULL, audioDecodeThreadFunc, (__bridge void *)self);
    }
}

/**
 * 解复用线程入口函数（C 函数，pthread 回调）
 *
 * 将 void * 参数桥接回 FFPlayerCore 实例，调用 Objective-C 方法。
 * 使用 @autoreleasepool 确保线程内临时对象及时释放。
 */
static void *demuxThreadFunc(void *arg) {
    @autoreleasepool {
        FFPlayerCore *self = (__bridge FFPlayerCore *)arg;
        [self _demuxLoop];
    }
    return NULL;
}

/**
 * 视频解码线程入口函数（C 函数，pthread 回调）
 */
static void *videoDecodeThreadFunc(void *arg) {
    @autoreleasepool {
        FFPlayerCore *self = (__bridge FFPlayerCore *)arg;
        [self _videoDecodeLoop];
    }
    return NULL;
}

/**
 * 音频解码线程入口函数（C 函数，pthread 回调）
 */
static void *audioDecodeThreadFunc(void *arg) {
    @autoreleasepool {
        FFPlayerCore *self = (__bridge FFPlayerCore *)arg;
        [self _audioDecodeLoop];
    }
    return NULL;
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 解复用循环（Demux Loop）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 解复用主循环（在 demuxThread 中执行）
 *
 * 核心逻辑：
 *   1. 循环调用 [_demuxer readPacket:] 读取一个 AVPacket
 *   2. 根据 stream_index 将包分发到对应的包队列：
 *      - 视频流 → [_videoPacketQueue putPacket:]
 *      - 音频流 → [_audioPacketQueue putPacket:]
 *      - 其他流 → 直接 av_packet_unref 丢弃
 *   3. 读包失败处理：
 *      - AVERROR_EOF / feof → 设置 _eof，向两个包队列各放入一个 flush 空包
 *        （data=NULL, size=0），通知解码线程刷新解码器
 *      - 其他错误 → 短暂 sleep 后重试
 *   4. Seek 期间（_seeking=YES）→ 空转等待，不读取新包
 *
 * Flush 空包机制：
 *   FFmpeg 解码器在收到 NULL 包后会刷新内部缓冲区，吐出所有已缓存帧。
 *   当 demuxer 读到 EOF 时，后续可能仍有帧缓存在解码器中，必须 flush。
 *   具体做法：放入一个 data=NULL, size=0 的空包，解码线程识别后调 sendPacket(NULL)。
 */
- (void)_demuxLoop {
    // 分配一个可复用的 AVPacket，避免反复分配/释放
    AVPacket *packet = av_packet_alloc();

    while (!_stopped) {
        // ── Seeking 期间空转 ──────────────────────────────────────────────
        // 此时队列已被 flush，不能读新包；等待 seek 完成后继续
        if (_seeking) {
            av_usleep(10000);
            continue;
        }

        // ── 读取一个 AVPacket ─────────────────────────────────────────────
        int ret = [_demuxer readPacket:packet];
        if (ret < 0) {
            // ── EOF 处理 ──────────────────────────────────────────────────
            if (ret == AVERROR_EOF || avio_feof(_demuxer.videoCodecParameters ? NULL : NULL)) {
                _eof = YES;
                // 向视频包队列发送 flush 空包（data=NULL, size=0）
                AVPacket flushPkt;
                av_init_packet(&flushPkt);
                flushPkt.data = NULL;
                flushPkt.size = 0;
                if (_demuxer.videoStreamIndex >= 0) {
                    [_videoPacketQueue putPacket:&flushPkt];
                }
                // 向音频包队列发送 flush 空包
                if (_demuxer.audioStreamIndex >= 0) {
                    av_init_packet(&flushPkt);
                    flushPkt.data = NULL;
                    flushPkt.size = 0;
                    [_audioPacketQueue putPacket:&flushPkt];
                }
                break;  // 退出 demux 循环
            }
            // ── 临时错误，重试 ────────────────────────────────────────────
            av_usleep(10000);
            continue;
        }

        // ── 根据流类型分发包 ─────────────────────────────────────────────
        if (packet->stream_index == _demuxer.videoStreamIndex) {
            // 视频包入队列；队列满时 putPacket 返回 NO，由调用方负责 unref
            if (![_videoPacketQueue putPacket:packet]) {
                av_packet_unref(packet);
            }
        } else if (packet->stream_index == _demuxer.audioStreamIndex) {
            if (![_audioPacketQueue putPacket:packet]) {
                av_packet_unref(packet);
            }
        } else {
            // 不关心的流类型，释放包
            av_packet_unref(packet);
        }
    }

    av_packet_free(&packet);
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 视频解码循环（Video Decode Loop）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 视频解码主循环（在 videoDecodeThread 中执行）
 *
 * FFmpeg 解码采用异步 send/receive 模型：
 *   - sendPacket(pkt)  → 将压缩包送入解码器
 *   - receiveFrame()   → 取出一帧解码后的 AVFrame
 *   一个 send 可能对应 0~N 个 receive（因解码器内部可能缓存多帧）
 *
 * 循环逻辑：
 *   1. 从视频包队列取一个包（阻塞等待）
 *   2. 判断是否为 flush 空包（data=NULL, size=0）：
 *      - 是 → 调 sendPacket(NULL) 触发解码器 flush
 *            循环 receiveFrame 取出所有缓存的帧
 *      - 否 → 调 sendPacket(packet) 送入解码
 *   3. 循环 receiveFrame 取出所有可用帧：
 *      - EAGAIN → 需要更多包，跳出内层循环
 *      - EOF → 解码器已 flush 完毕
 *      - 成功 → 调用 _processVideoFrame 处理（同步等待 + 送显）
 */
- (void)_videoDecodeLoop {
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();

    while (!_stopped) {
        // ── 从队列获取一个视频包 ──────────────────────────────────────────
        // 队列为空时阻塞；队列被 abort 时返回 NO
        if (![_videoPacketQueue getPacket:packet]) {
            if (_stopped) break;
            continue;
        }

        // ── 处理 flush 空包（来自 demux 的 EOF 信号） ─────────────────────
        if (packet->data == NULL && packet->size == 0) {
            // 发送 NULL 包触发解码器 flush，取出所有已缓存帧
            [_videoDecoder sendPacket:NULL];
            while (!_stopped) {
                int ret = [_videoDecoder receiveFrame:frame];
                if (ret < 0) break;  // 没有更多帧了
                [self _processVideoFrame:frame];
                av_frame_unref(frame);
            }
            av_packet_unref(packet);
            continue;
        }

        // ── 发送包到解码器 ────────────────────────────────────────────────
        int ret = [_videoDecoder sendPacket:packet];
        av_packet_unref(packet);
        // EAGAIN 表示解码器暂时无法接收新包（内部缓冲满），可以继续 receive
        if (ret < 0 && ret != AVERROR(EAGAIN)) continue;

        // ── 接收解码后的帧 ────────────────────────────────────────────────
        // 一个包可能产生 0~N 帧；EAGAIN 意味着需要更多包才能继续解码
        while (!_stopped) {
            ret = [_videoDecoder receiveFrame:frame];
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            [self _processVideoFrame:frame];
            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&packet);
}

/**
 * 处理解码后的视频帧
 *
 * 核心功能：同步等待 + 格式转换 + 送显
 *
 * 音视频同步策略（基于同步时钟）：
 *   1. 计算帧 PTS 与当前时钟的差值 diff = pts - clockTime
 *   2. Seek 后预检：如果 _postSeekVideoSync == YES（时钟暂停在 seek 目标），
 *      在格式转换之前先丢弃 seek 目标之前的旧帧（关键优化！）
 *   3. 格式转换（AVFrame → CVPixelBuffer）
 *   4. 正常同步：根据 diff 决策丢弃/显示/等待
 *
 * @param frame 解码后的 AVFrame（包含 YUV 数据和 PTS）
 */
- (void)_processVideoFrame:(AVFrame *)frame {
    // ── 计算帧 PTS（秒） ──────────────────────────────────────────────────
    double pts = 0;
    if (frame->pts != AV_NOPTS_VALUE) {
        pts = frame->pts * av_q2d(_demuxer.videoTimeBase);
    }
    // 计算帧持续时长（若无 duration 则用 FPS 估算）
    double duration = frame->duration > 0 ?
        frame->duration * av_q2d(_demuxer.videoTimeBase) : (1.0 / _demuxer.videoFPS);

    // ═══════════════════════════════════════════════════════════════════════
    // Seek 后预检：在格式转换之前丢弃 seek 目标之前的旧帧
    //
    // 这是关键性能优化：
    //   解复用器 seek 到最近关键帧（在 seek 目标之前），解码器从关键帧开始
    //   输出帧。seek 目标之前的帧最终都会被丢弃，但格式转换（AVFrame →
    //   CVPixelBuffer）是 CPU/GPU 密集操作。如果把丢弃判断放在转换之后，
    //   几十甚至几百个旧帧的转换会累积成数秒延迟。
    //
    //   因此在这里先做 PTS 检查，旧帧直接 return，跳过昂贵的格式转换。
    // ═══════════════════════════════════════════════════════════════════════
    if (_postSeekVideoSync) {
        double clockTime = [_syncClock currentTime]; // 时钟被暂停在 seek 目标时间
        double diff = pts - clockTime;
        if (diff < -0.1) {
            // 帧在 seek 目标时间之前 → 直接丢弃，跳过格式转换
            return;
        }
    }

    // ── 格式转换：AVFrame → CVPixelBuffer ────────────────────────────────
    CVPixelBufferRef pixelBuffer = [_videoConverter convertFrame:frame];
    if (!pixelBuffer) return;

    // ── Seek 后首帧同步：时钟已在 seekToTime: 中被暂停 ─────────────────
    // 能走到这里说明帧 PTS ≥ 时钟 - 100ms，即已到达 seek 目标附近。
    // 用此帧的真实 PTS 对齐时钟并恢复运行。
    if (_postSeekVideoSync) {
        [_syncClock setTime:pts];
        [_syncClock resume];
        _postSeekVideoSync = NO;
    } else {
        // ── 正常同步等待：确保帧显示时间与时钟同步 ────────────────────────
        while (!_stopped && !_seeking) {
            double clockTime = [_syncClock currentTime];
            double diff = pts - clockTime;

            if (diff < -0.1) {
                // 帧来得太晚（落后时钟超过 100ms）→ 丢帧
                // 典型场景：解码速度跟不上播放速度
                CVPixelBufferRelease(pixelBuffer);
                return;
            }
            if (diff <= 0.05) {
                // 帧准时（误差 50ms 内）→ 显示
                // 50ms 是人眼不易察觉的误差范围
                break;
            }
            // 帧来得太早 → 等待
            // 等待策略：只睡 diff * 0.5 秒，避免过睡；
            // 循环回来重新检查 diff，可及时响应 stop/seeking
            av_usleep((int)(diff * 500000)); // diff 秒 → 微秒，* 500000 = 半程等待
        }
    }

    // ── 检查是否被 stop/seeking 中断 ──────────────────────────────────
    if (_stopped || _seeking) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    // ── 送显 ──────────────────────────────────────────────────────────
    // 将 pixelBuffer 设置到 Metal 视图，由视图的下一次渲染回调绘制
    [_metalView setCurrentPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 音频解码循环（Audio Decode Loop）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 音频解码主循环（在 audioDecodeThread 中执行）
 *
 * 逻辑与视频解码类似，额外多一步重采样：
 *   getPacket → sendPacket → receiveFrame → resample → push to audioFrameQueue
 *
 * 音频解码完成后（收到 flush 空包并处理完所有剩余帧），
 * 在主线程回调 _setState:Completed 并暂停同步时钟。
 */
- (void)_audioDecodeLoop {
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();

    while (!_stopped) {
        // ── 从队列获取一个音频包 ──────────────────────────────────────────
        if (![_audioPacketQueue getPacket:packet]) {
            if (_stopped) break;
            continue;
        }

        // ── 处理 flush 空包（EOF 信号） ───────────────────────────────────
        if (packet->data == NULL && packet->size == 0) {
            // 发送 NULL 包触发解码器 flush
            [_audioDecoder sendPacket:NULL];
            while (!_stopped) {
                int ret = [_audioDecoder receiveFrame:frame];
                if (ret < 0) break;
                [self _processAudioFrame:frame];
                av_frame_unref(frame);
            }
            av_packet_unref(packet);

            // ⚠️ 播放完成通知（在主线程执行）
            // 注意：此处在音频解码线程中捕获 eof 信号，
            // 但需要在主线程中切换状态和暂停时钟
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self->_stopped && self->_eof) {
                    [self _setState:FFPlayerStateCompleted];
                    [self->_syncClock pause];
                }
            });
            continue;
        }

        // ── 发送包到音频解码器 ────────────────────────────────────────────
        int ret = [_audioDecoder sendPacket:packet];
        av_packet_unref(packet);
        if (ret < 0 && ret != AVERROR(EAGAIN)) continue;

        // ── 接收解码后的帧并重采样 ────────────────────────────────────────
        while (!_stopped) {
            ret = [_audioDecoder receiveFrame:frame];
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            // 处理音频帧：重采样 → 入队列
            [self _processAudioFrame:frame];
            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&packet);
}

/**
 * 处理解码后的音频帧
 *
 * 处理流程：
 *   1. 计算帧 PTS（用于同步，但音频同步由 AudioQueue 的时钟驱动）
 *   2. 调用重采样器将解码帧转换为 AudioQueue 所需的格式
 *      （通常为 AV_SAMPLE_FMT_S16、44100Hz、立体声交错）
 *   3. 将重采样后的数据封装为 FFAudioFrame 并入队列
 *   4. 入队列失败则释放缓冲区
 *
 * @param frame 解码后的 AVFrame
 */
- (void)_processAudioFrame:(AVFrame *)frame {
    // ── 计算 PTS ──────────────────────────────────────────────────────────
    double pts = 0;
    if (frame->pts != AV_NOPTS_VALUE) {
        pts = frame->pts * av_q2d(_demuxer.audioTimeBase);
    }

    // ── 重采样 ────────────────────────────────────────────────────────────
    uint8_t *outBuf = NULL;
    int outSize = 0;
    int converted = [_audioResampler resampleFrame:frame outputBuffer:&outBuf outputSize:&outSize];
    if (converted > 0 && outBuf && outSize > 0) {
        // ── 封装并入队列 ──────────────────────────────────────────────────
        FFAudioFrame audioFrame;
        audioFrame.data = outBuf;
        audioFrame.size = outSize;
        audioFrame.offset = 0;
        audioFrame.pts = pts;
        // 如果队列满则丢弃（putFrame 返回 NO），并释放缓冲区
        if (![_audioFrameQueue putFrame:audioFrame]) {
            free(outBuf);
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 音频拉取回调（Audio Pull Callback）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * AudioQueue 音频数据拉取回调
 *
 * 由 FFAudioOutput 内部 AudioQueue 在需要音频数据时调用。
 * 此回调在 AudioQueue 的内部线程中执行（非主线程、非 playback 线程）。
 *
 * 核心逻辑：
 *   1. 优先处理 _pendingAudioFrame —— 上一轮未消费完的音频帧
 *   2. 从 _audioFrameQueue 取帧，拷贝到 AudioQueue 提供的缓冲区
 *   3. 如果帧数据超过缓冲区剩余空间，将剩余部分存入 _pendingAudioFrame
 *   4. 无数据可用时填充静音（memset 0）→ 防止 AudioQueue 播放噪声
 *
 * @param buffer     AudioQueue 提供的缓冲区（待填充）
 * @param bufferSize 缓冲区大小（字节）
 * @param filledSize 输出参数：实际填充的字节数
 */
- (void)_fillAudioBuffer:(uint8_t *)buffer bufferSize:(int)bufferSize filledSize:(int *)filledSize {
    int filled = 0;

    while (filled < bufferSize) {
        // ── 优先处理上一轮未消费完的音频帧 ────────────────────────────────
        if (_hasPendingAudioFrame) {
            int remaining = _pendingAudioFrame.size - _pendingAudioFrame.offset;
            int toCopy = MIN(remaining, bufferSize - filled);
            memcpy(buffer + filled, _pendingAudioFrame.data + _pendingAudioFrame.offset, toCopy);
            filled += toCopy;
            _pendingAudioFrame.offset += toCopy;
            // 如果此帧已全部拷贝完毕 → 释放内存，清除 pending 标记
            if (_pendingAudioFrame.offset >= _pendingAudioFrame.size) {
                free(_pendingAudioFrame.data);
                _hasPendingAudioFrame = NO;
            }
            continue;
        }

        // ── 从音频帧队列取帧 ──────────────────────────────────────────────
        FFAudioFrame frame;
        if ([_audioFrameQueue tryGetFrame:&frame]) {
            int toCopy = MIN(frame.size, bufferSize - filled);
            memcpy(buffer + filled, frame.data, toCopy);
            filled += toCopy;
            // 如果帧数据未能完全拷贝 → 剩余部分存入 pending
            if (toCopy < frame.size) {
                _pendingAudioFrame = frame;
                _pendingAudioFrame.offset = toCopy;
                _hasPendingAudioFrame = YES;
            } else {
                // 帧已完整消费 → 释放内存
                free(frame.data);
            }
        } else {
            // ── 无音频数据 → 填充静音（关键！防止 AudioQueue 播放噪声） ──
            // 典型场景：网络流卡顿、解码速度跟不上、Seek 后的短暂间隙
            memset(buffer + filled, 0, bufferSize - filled);
            filled = bufferSize;
        }
    }

    *filledSize = filled;
}

/**
 * 清除未消费完的音频帧
 *
 * 在 stop 和 seek 时调用，确保释放 pending 帧占用的内存。
 */
- (void)_clearPendingAudioFrame {
    if (_hasPendingAudioFrame) {
        if (_pendingAudioFrame.data) {
            free(_pendingAudioFrame.data);
        }
        _hasPendingAudioFrame = NO;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 进度定时器
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 启动进度定时器
 *
 * 在主线程创建一个重复 NSTimer（间隔 0.25 秒），
 * 每次触发时向 delegate 回调当前播放时间和总时长。
 *
 * 0.25 秒的间隔平衡了 UI 更新频率与性能消耗：
 *   - 太快（< 0.1s）→ 不必要的性能开销
 *   - 太慢（> 0.5s）→ 进度条更新不平滑
 */
- (void)_startProgressTimer {
    [self _stopProgressTimer];
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                      target:self
                                                    selector:@selector(_updateProgress)
                                                    userInfo:nil
                                                     repeats:YES];
}

/**
 * 停止进度定时器
 */
- (void)_stopProgressTimer {
    [_progressTimer invalidate];
    _progressTimer = nil;
}

/**
 * 进度更新回调
 *
 * 由 NSTimer 触发，向 delegate 报告当前同步时钟时间和媒体总时长。
 * 外部（如 UI 进度条）通过此信息刷新显示。
 */
- (void)_updateProgress {
    if ([self.delegate respondsToSelector:@selector(playerCoreDidUpdateCurrentTime:duration:)]) {
        [self.delegate playerCoreDidUpdateCurrentTime:[_syncClock currentTime] duration:_demuxer.duration];
    }
}

// ══════════════════════════════════════════════════════════════════════════════
#pragma mark - 错误处理
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 通知外部发生错误
 *
 * 流程：
 *   1. 设置状态为 Error
 *   2. 在主线程构造 NSError 并调用 delegate 回调
 *
 * @param message 错误描述字符串
 */
- (void)_notifyError:(NSString *)message {
    [self _setState:FFPlayerStateError];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(playerCoreDidEncounterError:)]) {
            NSError *error = [NSError errorWithDomain:@"FFPlayerCore" code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
            [self.delegate playerCoreDidEncounterError:error];
        }
    });
}

@end
