//
//  FFAudioOutput.m
//  ios_ffmpeg_demo
//
//  概述：基于 AudioQueue 的拉模式（Pull-mode）音频输出实现。
//  功能：以 LinearPCM S16 交错格式驱动音频硬件，配合 AUGraph TimePitch 实现变速播放。
//
//  核心设计：
//    1. 音频格式：LinearPCM、有符号 16 位整型、交错（packed）——最通用的跨平台 PCM 表示。
//    2. 缓冲区策略：3 缓冲区环形队列（kNumberBuffers = 3），
//       确保在回调间隙有足够缓冲避免 underrun（数据供给不足导致的爆音/卡顿）。
//    3. 缓冲区大小计算：
//       bufferSize = sampleRate × channels × sizeof(int16_t) × durationMs / 1000
//       即每帧（frame）包含 channels 个采样点，每个采样点 2 字节。
//    4. 拉模式回调：AudioQueueNewOutput 注册 FFAudioQueueOutputCB，
//       AudioQueue 在需要数据时自动调用该回调，外部通过 audioDataRequestBlock 填充数据。
//    5. TimePitch 变速：
//       - 启用 kAudioQueueProperty_EnableTimePitch 激活内置变速单元。
//       - 算法选择 kAudioQueueTimePitchAlgorithm_Spectral（频谱算法），
//         相比默认算法音质更好，适合音乐播放场景。
//       - 通过 kAudioQueueParam_PlayRate 设置播放倍速。
//    6. 防 underrun：当外部未提供有效数据时（filledSize <= 0），
//       填充静音（全零）并视为缓冲区已满，保证 AudioQueue 持续运转。
//    7. AVAudioSession 配置：设置为 AVAudioSessionCategoryPlayback，
//       使 App 在静音模式下也能正常出声，并激活会话。
//

#import "FFAudioOutput.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

// 缓冲区数量（环形队列深度）。3 个缓冲区可在回调处理延迟时提供足够余量，防止 underrun。
static const int kNumberBuffers = 3;
// 单个缓冲区承载的音频时长（毫秒）。50ms = 每缓冲区约 0.05 秒音频。
static const int kBufferDurationMs = 50;

@implementation FFAudioOutput {
    AudioQueueRef _audioQueue;                           // AudioQueue 实例引用
    AudioQueueBufferRef _buffers[kNumberBuffers];        // 缓冲区数组（环形）
    AudioStreamBasicDescription _asbd;                   // 音频数据格式描述
    int _sampleRate;                                     // 采样率
    int _channels;                                       // 声道数
    int _bufferSize;                                     // 单缓冲区字节大小
    BOOL _started;                                       // 是否已启动
    BOOL _paused;                                        // 是否已暂停
}

/**
 *  AudioQueue 输出回调（C 函数）。
 *  当 AudioQueue 内部消费完一个缓冲区后，将其交还给此回调重新填充数据。
 *  这是典型的"拉模式"：硬件驱动 AudioQueue → AudioQueue 回调请求数据 → 外部提供 PCM。
 *
 *  @param inUserData 用户自定义数据（通过 AudioQueueNewOutput 传入的 self）
 *  @param inAQ       触发回调的 AudioQueue 实例
 *  @param inBuffer   需要重新填充数据的 AudioQueue 缓冲区
 */
static void FFAudioQueueOutputCB(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    FFAudioOutput *self = (__bridge FFAudioOutput *)inUserData;
    [self _fillBuffer:inBuffer];
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _channels = channels;
        _audioQueue = NULL;
        _started = NO;
        _paused = NO;
        _volume = 1.0;

        // 计算缓冲区大小：sampleRate × channels × bytesPerSample × durationMs / 1000
        // 每个采样点 2 字节（int16_t），每帧包含 channels 个采样点。
        _bufferSize = (_sampleRate * _channels * sizeof(int16_t) * kBufferDurationMs) / 1000;

        // --- 配置 AudioStreamBasicDescription（线性 PCM 16 位交错格式） ---
        memset(&_asbd, 0, sizeof(_asbd));
        _asbd.mSampleRate = sampleRate;                          // 采样率（如 44100 Hz）
        _asbd.mFormatID = kAudioFormatLinearPCM;                 // 线性 PCM（无压缩）
        _asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger // 有符号整型
                           | kLinearPCMFormatFlagIsPacked;       // 交错排列（数据连续存放）
        _asbd.mChannelsPerFrame = channels;                      // 每帧声道数
        _asbd.mBitsPerChannel = 16;                              // 位深：16 bit
        _asbd.mBytesPerFrame = channels * sizeof(int16_t);       // 每帧字节数
        _asbd.mFramesPerPacket = 1;                              // 每个 packet 包含 1 帧（PCM 固定值）
        _asbd.mBytesPerPacket = _asbd.mBytesPerFrame;            // 每个 packet 字节数
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start {
    if (_started) return YES;

    // --- 配置 AVAudioSession ---
    // 设置为 Playback 类别：即使设备处于静音模式也能播放音频。
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [session setActive:YES error:&error];

    // --- 创建 AudioQueue（输出类型）---
    // 参数说明：
    //   &_asbd       : 音频数据格式描述
    //   FFAudioQueueOutputCB : 缓冲区填充回调（C 函数）
    //   (__bridge void *)self : 传入 self 作为用户数据，供回调中转换为 OC 对象
    //   NULL         : CFRunLoop（NULL 表示在内部线程回调）
    //   NULL         : 回调运行的 RunLoop mode
    //   0            : 预留参数
    //   &_audioQueue : 输出新创建的 AudioQueue 实例
    OSStatus status = AudioQueueNewOutput(&_asbd,
                                           FFAudioQueueOutputCB,
                                           (__bridge void *)self,
                                           NULL, NULL, 0,
                                           &_audioQueue);
    if (status != noErr) {
        NSLog(@"FFAudioOutput: AudioQueueNewOutput failed: %d", (int)status);
        return NO;
    }

    // --- 启用 TimePitch（时间音高模块），实现变速不变调 ---
    // 设置 enableTimePitch = 1 激活内置的变速处理单元。
    UInt32 enableTimePitch = 1;
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_EnableTimePitch, &enableTimePitch, sizeof(enableTimePitch));

    // 选择 TimePitch 算法：Spectral（频谱算法）。
    // 相比默认的快速算法，Spectral 算法在变速时保留更多音质细节，适合高品质播放场景。
    UInt32 algorithm = kAudioQueueTimePitchAlgorithm_Spectral;
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_TimePitchAlgorithm, &algorithm, sizeof(algorithm));

    // 设置初始音量
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, _volume);

    // --- 分配并填充缓冲区（3 缓冲区环形队列）---
    // 预分配 kNumberBuffers 个缓冲区并首次填充数据，
    // 确保 AudioQueue 启动后立即有数据可供播放。
    for (int i = 0; i < kNumberBuffers; i++) {
        status = AudioQueueAllocateBuffer(_audioQueue, _bufferSize, &_buffers[i]);
        if (status != noErr) {
            NSLog(@"FFAudioOutput: AudioQueueAllocateBuffer failed: %d", (int)status);
            [self stop];
            return NO;
        }
        [self _fillBuffer:_buffers[i]];
    }

    // --- 启动 AudioQueue ---
    // NULL 表示立即开始播放，不指定启动时间。
    status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) {
        NSLog(@"FFAudioOutput: AudioQueueStart failed: %d", (int)status);
        [self stop];
        return NO;
    }

    _started = YES;
    _paused = NO;
    return YES;
}

- (void)stop {
    if (_audioQueue) {
        // true 表示同步停止：等待队列内所有缓冲区播放完毕后才返回。
        AudioQueueStop(_audioQueue, true);
        // true 表示同步释放：释放 AudioQueue 及其关联的所有缓冲区。
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    _started = NO;
    _paused = NO;
}

- (void)pause {
    // 仅在已启动且非暂停状态下执行暂停操作。
    if (_audioQueue && _started && !_paused) {
        AudioQueuePause(_audioQueue);
        _paused = YES;
    }
}

- (void)resume {
    // 仅在已启动且已暂停状态下执行恢复操作。
    if (_audioQueue && _started && _paused) {
        AudioQueueStart(_audioQueue, NULL);
        _paused = NO;
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, volume);
    }
}

/**
 *  设置播放倍速。
 *  通过 kAudioQueueParam_PlayRate 参数控制 TimePitch 模块的播放速率。
 *  该参数仅在 EnableTimePitch 启用后生效，典型取值范围 0.5 ~ 2.0。
 *
 *  @param rate 播放倍速（如 0.5 = 半速，1.0 = 正常，2.0 = 双倍速）
 */
- (void)setPlaybackRate:(double)rate {
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, (AudioQueueParameterValue)rate);
    }
}

/**
 *  填充 AudioQueue 缓冲区（内部方法）。
 *  通过 audioDataRequestBlock 回调从外部获取 PCM 数据写入缓冲区。
 *
 *  防 underrun 策略：
 *  当外部未提供有效数据（filledSize <= 0）时，填充静音（全零）并视缓冲区为已满，
 *  保证 AudioQueue 持续运转，避免因数据断流导致的破音或卡顿。
 *
 *  @param buffer 需要填充数据的 AudioQueue 缓冲区
 */
- (void)_fillBuffer:(AudioQueueBufferRef)buffer {
    int filledSize = 0;         // 外部回调实际写入的有效数据字节数
    if (self.audioDataRequestBlock) {
        self.audioDataRequestBlock(buffer->mAudioData, _bufferSize, &filledSize);
    }
    // underrun 保护：无有效数据时填充静音（全零），防止硬件输出噪声。
    if (filledSize <= 0) {
        memset(buffer->mAudioData, 0, _bufferSize);
        filledSize = _bufferSize;
    }
    buffer->mAudioDataByteSize = filledSize;
    // 将填充完毕的缓冲区重新排入 AudioQueue，等待硬件消费。
    if (_audioQueue) {
        AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    }
}

@end
