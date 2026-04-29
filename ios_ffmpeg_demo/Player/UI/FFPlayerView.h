//
//  FFPlayerView.h
//  ios_ffmpeg_demo
//
//  播放器容器视图
//  职责：将视频渲染层（FFMetalView）和控制层（FFPlayerControlView）
//        组合在一起，作为播放器 UI 的顶层容器。
//        外部通过本视图访问 metalView（视频画面）和 controlView（控制 UI）。
//

#import <UIKit/UIKit.h>
#import "FFPlayerControlView.h"

@class FFMetalView;

NS_ASSUME_NONNULL_BEGIN

/**
 * FFPlayerView
 * 组合视图，包含两个子视图：
 *   1. metalView - 基于 Metal 的视频画面渲染视图
 *   2. controlView - B 站风格播放控制覆盖层
 *
 * 两个子视图均撑满整个父视图，controlView 覆盖在 metalView 之上。
 */
@interface FFPlayerView : UIView

/// 视频画面渲染视图（Metal 渲染）
@property (nonatomic, readonly) FFMetalView *metalView;
/// 播放控制覆盖层视图
@property (nonatomic, readonly) FFPlayerControlView *controlView;

@end

NS_ASSUME_NONNULL_END
