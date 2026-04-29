//
//  FFSyncClock.m
//  ios_ffmpeg_demo
//
//  Created by ffmpeg on 2025/3/2.
//

//==============================================================================
// FFSyncClock 实现
//
// 核心原理：
//   该时钟采用"锚点 + 增量"的方式计算当前媒体时间，避免了逐帧累加带来的
//   误差累积问题。每次查询 currentTime 时都基于系统挂钟时间实时计算。
//
//   时钟模型：
//     当前媒体时间 = _mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed
//
//   其中：
//     - _mediaTimeAtAnchor ：锚点处的媒体时间（单位：秒）
//     - _anchorWallTime    ：锚点处的系统挂钟时间（由 CACurrentMediaTime() 返回）
//     - _speed             ：播放速度倍率
//
//   暂停时，直接返回 _mediaTimeAtAnchor，不再累加时间增量。
//   速度变化时，先按旧速度将已流逝时间合并到 _mediaTimeAtAnchor 中，
//   再更新锚点挂钟时间和新速度，确保时间连续性。
//
//   线程安全：
//     所有对成员变量的读写操作均通过 os_unfair_lock 加锁保护，
//     支持在多线程环境下安全使用（如音频播放线程和视频渲染线程同时访问）。
//==============================================================================

#import "FFSyncClock.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

@implementation FFSyncClock {
    /// 锚点处的系统挂钟时间（单位：秒）
    ///
    /// 由 CACurrentMediaTime() 获取，表示上一次锚点更新时的系统绝对时间。
    /// 每次调用 start、resume、setTime: 或变更 speed 时会刷新此值。
    double _anchorWallTime;

    /// 锚点处的媒体时间（单位：秒）
    ///
    /// 表示在锚点时刻，媒体应该处于的时间位置。
    /// 暂停时直接返回此值；运行时基于此值加上时间增量计算当前时间。
    double _mediaTimeAtAnchor;

    /// 播放速度倍率
    ///
    /// 默认值为 1.0（正常速度）。
    /// currentTime 计算时，时间增量会乘以该系数以实现变速效果。
    double _speed;

    /// 暂停标志
    ///
    /// YES 表示时钟暂停，currentTime 始终返回 _mediaTimeAtAnchor；
    /// NO  表示时钟运行，currentTime 基于锚点实时计算。
    BOOL _paused;

    /// 线程安全锁
    ///
    /// 使用 os_unfair_lock（一种高效的低级自旋锁）保护所有成员变量的访问，
    /// 确保音频/视频线程并发读写不会产生竞态条件。
    os_unfair_lock _lock;
}

/// 初始化方法
///
/// 设置所有属性的默认值：
///   - 速度 = 1.0（正常播放）
///   - 暂停状态 = YES（初始为暂停，需调用 start 启动）
///   - 锚点时间 = 0
///   - 媒体时间 = 0
///   - 锁 = OS_UNFAIR_LOCK_INIT
- (instancetype)init {
    self = [super init];
    if (self) {
        _speed = 1.0;               // 默认正常速度
        _paused = YES;              // 初始为暂停状态
        _anchorWallTime = 0;        // 锚点挂钟时间归零
        _mediaTimeAtAnchor = 0;     // 锚点媒体时间归零
        _lock = OS_UNFAIR_LOCK_INIT; // 初始化线程锁
    }
    return self;
}

/// 获取当前媒体时间
///
/// 核心计算方法：
///   - 暂停状态：直接返回 _mediaTimeAtAnchor（时间冻结）
///   - 运行状态：_mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed
///
/// 公式解释：
///   (CACurrentMediaTime() - _anchorWallTime) 是自锚点以来经过的挂钟时间（秒），
///   乘以 _speed 得到"以媒体时间尺度衡量"的时间增量，
///   再加上 _mediaTimeAtAnchor 即得到当前媒体时间。
///
/// 以 2 倍速播放为例，每经过 1 秒挂钟时间，媒体时间推进 2 秒。
///
/// @return 当前媒体时间（单位：秒）
- (double)currentTime {
    os_unfair_lock_lock(&_lock);                        // 加锁，保证线程安全
    double time;
    if (_paused) {
        // 暂停状态：时间冻结在锚点媒体时间
        time = _mediaTimeAtAnchor;
    } else {
        // 运行状态：实时计算当前时间
        // currentTime = 锚点媒体时间 + (当前挂钟时间 - 锚点挂钟时间) * 播放速度
        time = _mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed;
    }
    os_unfair_lock_unlock(&_lock);                      // 解锁
    return time;
}

/// 获取当前播放速度
///
/// @return 当前速度倍率
- (double)speed {
    os_unfair_lock_lock(&_lock);                        // 加锁
    double s = _speed;
    os_unfair_lock_unlock(&_lock);                      // 解锁
    return s;
}

/// 设置播放速度
///
/// 速度变更逻辑：
///   1. 如果时钟正在运行（非暂停），需要先将自锚点以来按旧速度累积的时间
///      合并到 _mediaTimeAtAnchor 中，并刷新锚点挂钟时间。
///      这样可以保证速度切换时，当前时间不会发生跳变。
///   2. 更新 _speed 为新值。
///
/// 示例：
///   假设当前速度为 1.0，已播放 10 秒媒体时间。
///   将速度改为 2.0 时，_mediaTimeAtAnchor 会先更新为 10（合并旧速度的时间增量），
///   _anchorWallTime 刷新为当前挂钟时间，此后按 2.0 倍速推进。
///
/// @param speed 新的播放速度倍率
- (void)setSpeed:(double)speed {
    os_unfair_lock_lock(&_lock);                        // 加锁
    if (!_paused) {
        // 时钟正在运行：将当前已流逝的时间按旧速度合并到锚点中
        // 这样旧速度时段的时间贡献被固化到 _mediaTimeAtAnchor 中
        _mediaTimeAtAnchor = _mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed;
        // 刷新锚点挂钟时间为当前时刻
        _anchorWallTime = CACurrentMediaTime();
    }
    // 设置新的播放速度（无论是否暂停，速度值都需要更新）
    _speed = speed;
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

/// 检查时钟是否处于暂停状态
///
/// @return YES 表示已暂停，NO 表示正在运行
- (BOOL)isPaused {
    os_unfair_lock_lock(&_lock);                        // 加锁
    BOOL p = _paused;
    os_unfair_lock_unlock(&_lock);                      // 解锁
    return p;
}

/// 启动时钟
///
/// 将媒体时间重置为 0，以当前挂钟时间作为锚点，并将 paused 置为 NO，
/// 使时钟开始从 0 计时。
///
/// 通常在开始播放新文件时调用。
- (void)start {
    os_unfair_lock_lock(&_lock);                        // 加锁
    _anchorWallTime = CACurrentMediaTime();             // 记录当前挂钟时间作为锚点
    _mediaTimeAtAnchor = 0;                             // 媒体时间归零
    _paused = NO;                                       // 设置为运行状态
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

/// 暂停时钟
///
/// 暂停逻辑：
///   1. 如果时钟正在运行，先将当前计算出的媒体时间固化为 _mediaTimeAtAnchor。
///      公式：_mediaTimeAtAnchor += (now - _anchorWallTime) * _speed
///   2. 将 _paused 置为 YES，此后 currentTime 返回 _mediaTimeAtAnchor（不再增长）。
///
/// 注意：
///   如果时钟已经是暂停状态，则不执行任何操作。
- (void)pause {
    os_unfair_lock_lock(&_lock);                        // 加锁
    if (!_paused) {
        // 将截至暂停时刻的媒体时间合并到锚点中
        _mediaTimeAtAnchor = _mediaTimeAtAnchor + (CACurrentMediaTime() - _anchorWallTime) * _speed;
        _paused = YES;                                  // 设置为暂停状态
    }
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

/// 恢复时钟（从暂停中恢复）
///
/// 恢复逻辑：
///   1. 刷新锚点挂钟时间为当前时刻（_anchorWallTime = CACurrentMediaTime()）。
///      这是关键步骤：恢复后，currentTime 的计算将基于新的锚点，
///      时间从 _mediaTimeAtAnchor 开始继续推进。
///   2. 将 _paused 置为 NO。
///
/// 注意：
///   如果时钟已经在运行状态，则不执行任何操作。
- (void)resume {
    os_unfair_lock_lock(&_lock);                        // 加锁
    if (_paused) {
        // 刷新锚点挂钟时间，使后续时间增量从当前时刻开始计算
        _anchorWallTime = CACurrentMediaTime();
        _paused = NO;                                   // 设置为运行状态
    }
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

/// 设置当前媒体时间（跳转/Seek）
///
/// 将时钟的媒体时间设置为指定的秒数，同时将锚点挂钟时间刷新为当前时刻。
/// 这意味着在 setTime: 之后，currentTime 会立即返回设定的时间值，
/// 然后从这个新位置继续按速度推进。
///
/// 典型使用场景：
///   用户拖动播放进度条（Seek操作）后，调用此方法更新时钟，
///   使后续时间计算从新的播放位置开始。
///
/// @param seconds 目标媒体时间（单位：秒）
- (void)setTime:(double)seconds {
    os_unfair_lock_lock(&_lock);                        // 加锁
    _mediaTimeAtAnchor = seconds;                       // 设置新的媒体时间
    _anchorWallTime = CACurrentMediaTime();             // 刷新锚点挂钟时间
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

/// 重置时钟
///
/// 将所有内部状态恢复为初始值：
///   - 锚点挂钟时间 → 0
///   - 锚点媒体时间 → 0
///   - 暂停状态 → YES
///   - 播放速度 → 1.0
///
/// 与 start 的区别：reset 将时钟置于暂停状态，而 start 会立即启动时钟。
/// reset 通常用于释放播放资源或重新初始化播放器时。
- (void)reset {
    os_unfair_lock_lock(&_lock);                        // 加锁
    _anchorWallTime = 0;                                // 锚点挂钟时间归零
    _mediaTimeAtAnchor = 0;                             // 锚点媒体时间归零
    _paused = YES;                                      // 设置为暂停状态
    _speed = 1.0;                                       // 速度恢复为正常
    os_unfair_lock_unlock(&_lock);                      // 解锁
}

@end
