//
//  FFSyncClock.h
//  ios_ffmpeg_demo
//
//  Created by ffmpeg on 2025/3/2.
//

//==============================================================================
// FFSyncClock — 音视频同步时钟
//
// 用途：
//   提供基于挂钟时间（wall clock）的音视频同步时钟。
//   该时钟记录一个"锚点"（anchor），通过锚点的媒体时间加上自锚点以来经过的
//   挂钟时间（乘以播放速度），来计算当前播放的媒体时间位置。
//
//   公式：currentTime = mediaTimeAtAnchor + (now - anchorWallTime) * speed
//
//   支持暂停/恢复、变速播放以及随机跳转（setTime:）操作。
//==============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 音视频同步时钟
///
/// 用于在音视频播放过程中跟踪当前的媒体时间位置，支持变速播放和暂停/恢复。
/// 内部使用 os_unfair_lock 保证线程安全。
@interface FFSyncClock : NSObject

/// 当前媒体时间（单位：秒）
///
/// 基于锚点时间与经过的挂钟时间计算得出。
/// 暂停状态下返回暂停时的媒体时间。
/// 计算方式：_mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed
@property (nonatomic, readonly) double currentTime;

/// 播放速度倍率
///
/// 1.0 表示正常速度，2.0 表示两倍速，0.5 表示半速。
/// 修改速度时会自动重新计算锚点，确保时间连续不跳变。
@property (nonatomic, assign) double speed;

/// 是否处于暂停状态
@property (nonatomic, readonly, getter=isPaused) BOOL paused;

/// 启动时钟
///
/// 将媒体时间重置为 0，记录当前挂钟时间作为锚点，并将时钟置于运行状态。
- (void)start;

/// 暂停时钟
///
/// 冻结当前媒体时间，暂停时时间不再向前推进。
/// 内部会将当前计算出的媒体时间记录到锚点中。
- (void)pause;

/// 恢复时钟
///
/// 从暂停状态恢复，重新记录锚点挂钟时间，时间继续向前推进。
- (void)resume;

/// 设置当前媒体时间（跳转）
///
/// 将时钟的媒体时间设定为指定的秒数，同时刷新锚点挂钟时间。
/// 常用于 seek（跳转）操作后同步时间。
///
/// @param seconds 要设置的媒体时间（单位：秒）
- (void)setTime:(double)seconds;

/// 重置时钟
///
/// 将所有状态恢复至初始值：速度恢复为 1.0，媒体时间归零，时钟进入暂停状态。
- (void)reset;

@end

NS_ASSUME_NONNULL_END
