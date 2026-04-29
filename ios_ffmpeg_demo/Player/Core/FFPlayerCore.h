//
//  FFPlayerCore.h
//  ios_ffmpeg_demo
//
//  核心播放引擎 —— 统筹管理所有播放组件、线程、音视频同步、Seek、变速播放。
//
//  职责概述：
//  - 封装解复用器（FFDemuxer）、视频解码器（FFVideoDecoder）、音频解码器（FFAudioDecoder）、
//    音频重采样器（FFAudioResampler）、视频格式转换器（FFVideoFrameConverter）、
//    音视频包队列（FFPacketQueue）、音视频帧队列（FFFrameQueue）、同步时钟（FFSyncClock）、
//    音频输出（FFAudioOutput）等底层模块。
//  - 维护播放状态机：Idle → Preparing → Ready → Playing ⇄ Paused → Stopped / Completed / Error。
//  - 启动并协调三条后台线程：解复用线程、视频解码线程、音频解码线程。
//  - 提供播放、暂停、停止、Seek、变速等对外接口。
//  - 通过 delegate 向 UI 层回调状态变更、进度更新、错误信息。
//

#import <Foundation/Foundation.h>

@class FFMetalView;

NS_ASSUME_NONNULL_BEGIN

/**
 * 播放器状态枚举
 *
 * 状态流转：
 *   Idle        —— 初始状态，刚创建实例
 *   Preparing   —— 正在准备（打开文件、创建解码器等）
 *   Ready       —— 准备完毕，等待 play 指令
 *   Playing     —— 正在播放
 *   Paused      —— 暂停
 *   Stopped     —— 已停止（可重新 prepare）
 *   Completed   —— 播放完毕
 *   Error       —— 发生错误
 */
typedef NS_ENUM(NSInteger, FFPlayerState) {
    FFPlayerStateIdle,        // 空闲
    FFPlayerStatePreparing,   // 准备中
    FFPlayerStateReady,       // 就绪
    FFPlayerStatePlaying,     // 播放中
    FFPlayerStatePaused,      // 已暂停
    FFPlayerStateStopped,     // 已停止
    FFPlayerStateCompleted,   // 播放完成
    FFPlayerStateError        // 错误
};

/**
 * FFPlayerCore 代理协议
 *
 * 用于向 UI 层通知播放器内部状态变化、进度刷新以及错误信息。
 */
@protocol FFPlayerCoreDelegate <NSObject>
@optional
/// 播放器状态发生变化时回调
- (void)playerCoreDidChangeState:(FFPlayerState)state;
/// 播放进度更新时回调（由定时器驱动）
- (void)playerCoreDidUpdateCurrentTime:(double)currentTime duration:(double)duration;
/// 发生错误时回调
- (void)playerCoreDidEncounterError:(NSError *)error;
@end

/**
 * FFPlayerCore —— 核心播放引擎
 *
 * 使用方式：
 *   1. 调用 initWithURL:metalView: 创建实例
 *   2. 调用 prepareToPlay 异步准备
 *   3. 收到 Ready 状态后调用 play 开始播放
 *   4. 可随时调用 pause / seekToTime: / setPlaybackSpeed: 控制播放
 *   5. 播放完毕或需要释放时调用 stop
 */
@interface FFPlayerCore : NSObject

/// 代理对象，用于接收状态、进度、错误回调（弱引用）
@property (nonatomic, weak, nullable) id<FFPlayerCoreDelegate> delegate;
/// 当前播放器状态（只读）
@property (nonatomic, readonly) FFPlayerState state;
/// 媒体总时长（秒），准备完成后可用（只读）
@property (nonatomic, readonly) double duration;
/// 当前播放时间（秒），基于同步时钟（只读）
@property (nonatomic, readonly) double currentTime;
/// 播放速度，默认为 1.0；同时影响同步时钟和 AudioQueue 播放速率
@property (nonatomic, assign) double playbackSpeed;

/**
 * 使用媒体 URL 和 Metal 渲染视图初始化播放器
 *
 * @param url       媒体文件路径或网络 URL 字符串
 * @param metalView 用于渲染视频帧的 Metal 视图（弱引用）
 */
- (instancetype)initWithURL:(NSString *)url metalView:(FFMetalView *)metalView;

/**
 * 异步准备播放
 *
 * 内部会在全局队列中执行：
 *   - 打开解复用器
 *   - 创建视频/音频解码器、重采样器、格式转换器
 *   - 通知 Metal 视图视频尺寸
 * 完成后状态切换为 Ready。
 */
- (void)prepareToPlay;

/**
 * 开始或恢复播放
 *
 * - 暂停状态 → 恢复时钟和音频输出
 * - 完成状态 → Seek 到开头再播放
 * - 就绪状态 → 启动后台线程、音频输出、进度定时器
 */
- (void)play;

/**
 * 暂停播放
 *
 * 暂停同步时钟和音频输出，视频解码线程因帧队列同步等待而自然阻塞。
 */
- (void)pause;

/**
 * 停止播放
 *
 * 完整停止流程：
 *   1. 设置停止标记
 *   2. Abort 所有队列以唤醒阻塞线程
 *   3. Join 等待三条后台线程退出
 *   4. 停止音频输出、重置时钟
 *   5. Flush + Reset 所有队列
 *   6. Close 并释放所有底层模块
 */
- (void)stop;

/**
 * 跳转到指定时间点
 *
 * Seek 序列：
 *   1. 设置 seeking 标记
 *   2. Abort + Flush 所有队列
 *   3. Flush 解码器内部缓冲区
 *   4. 调用解复用器 seek
 *   5. 重置同步时钟到目标时间
 *   6. Reset 队列（清除 abort 标记）
 *   7. 清除 seeking 标记
 *
 * @param seconds 目标时间（秒），会自动 clamp 到 [0, duration] 范围
 */
- (void)seekToTime:(double)seconds;

@end

NS_ASSUME_NONNULL_END
