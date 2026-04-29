//
//  FFAudioOutput.h
//  ios_ffmpeg_demo
//
//  概述：基于 AudioQueue 的拉模式（Pull-mode）音频输出模块。
//  功能：以 LinearPCM S16 交错格式驱动音频硬件，配合 AUGraph TimePitch 实现变速播放。
//  核心机制：
//    - 通过 AudioQueueNewOutput 注册回调，以拉模式请求音频数据。
//    - 内部维护 3 个缓冲区的环形队列，避免因数据供给延迟导致的 underrun。
//    - 启用 TimePitch（Spectral 算法）并通过 kAudioQueueParam_PlayRate 控制播放速度。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  音频数据请求回调。
 *  每当 AudioQueue 需要填充缓冲区时，将调用此 block。
 *
 *  @param buffer       待填充的音频数据缓冲区指针
 *  @param bufferSize   缓冲区总容量（字节）
 *  @param filledSize   输出参数：实际写入的有效数据字节数
 */
typedef void (^FFAudioDataRequestBlock)(uint8_t *buffer, int bufferSize, int *filledSize);

@interface FFAudioOutput : NSObject

/// 音频数据提供回调。外部通过此 block 向 AudioQueue 输送 PCM 数据。
@property (nonatomic, copy, nullable) FFAudioDataRequestBlock audioDataRequestBlock;

/// 播放音量。取值范围 0.0 ~ 1.0，默认 1.0。
@property (nonatomic, assign) float volume;

/**
 *  初始化音频输出实例。
 *
 *  @param sampleRate 采样率（如 44100、48000）
 *  @param channels   声道数（1 = 单声道，2 = 立体声）
 *  @return 音频输出实例
 */
- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels;

/**
 *  启动音频输出。
 *  内部会完成：AVAudioSession 配置 → AudioQueue 创建 → 缓冲区分配 → 队列启动。
 *
 *  @return YES 表示启动成功，NO 表示失败
 */
- (BOOL)start;

/**
 *  停止音频输出。释放 AudioQueue 及所有缓冲区资源。
 */
- (void)stop;

/**
 *  暂停播放。暂停后可通过 resume 恢复。
 */
- (void)pause;

/**
 *  从暂停状态恢复播放。
 */
- (void)resume;

/**
 *  设置播放倍速。
 *  需配合 TimePitch 使用，支持 0.5x ~ 2.0x 等范围。
 *
 *  @param rate 播放倍速（如 1.0 = 正常速度，1.5 = 1.5 倍速）
 */
- (void)setPlaybackRate:(double)rate;

@end

NS_ASSUME_NONNULL_END
