//
//  FFPlayerControlView.h
//  ios_ffmpeg_demo
//
//  视频播放器的控制层视图（B站风格UI）
//  职责：提供顶部栏（返回按钮 + 标题）、底部栏（播放/暂停、时间、进度条、倍速、全屏）、
//        中央播放按钮、倍速选择面板等交互控件，并通过 FFPlayerControlViewDelegate
//        将用户操作事件传递给代理对象处理。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 播放器控制视图的代理协议
 * 所有方法均为 @optional，由使用者选择性实现
 */
@protocol FFPlayerControlViewDelegate <NSObject>
@optional
/// 用户点击了播放/暂停按钮
- (void)controlViewDidTapPlayPause;
/// 用户点击了返回按钮
- (void)controlViewDidTapBack;
/// 用户点击了全屏切换按钮
- (void)controlViewDidTapFullscreen;
/// 用户开始拖动进度条（开始 Seeking）
- (void)controlViewDidBeginSeeking;
/// 用户拖动进度条到指定时间位置
/// @param seconds 目标时间点（秒）
- (void)controlViewDidSeekToTime:(double)seconds;
/// 用户选择了倍速播放
/// @param speed 倍速值（如 0.5、1.0、1.5、2.0）
- (void)controlViewDidSelectSpeed:(double)speed;
@end

/**
 * FFPlayerControlView
 * 视频播放器的覆盖控制层，采用 B 站风格的布局设计。
 * 包含顶部渐变栏、底部渐变栏、中央播放按钮和倍速面板。
 * 控件会在空闲 3 秒后自动隐藏。
 */
@interface FFPlayerControlView : UIView

/// 代理对象，用于回调用户交互事件
@property (nonatomic, weak, nullable) id<FFPlayerControlViewDelegate> delegate;
/// 视频标题文本
@property (nonatomic, copy) NSString *title;

/// 更新播放状态，刷新播放/暂停图标
/// @param isPlaying 当前是否正在播放
- (void)updatePlayState:(BOOL)isPlaying;
/// 更新当前播放时间和总时长
/// @param currentTime 当前播放位置（秒）
/// @param duration 视频总时长（秒）
- (void)updateCurrentTime:(double)currentTime duration:(double)duration;
/// 显示控制栏（带动画）
- (void)showControls;
/// 隐藏控制栏（带动画）
- (void)hideControls;
/// 更新倍速按钮上的显示文本
/// @param speed 当前倍速值
- (void)updateSpeedLabel:(double)speed;

@end

NS_ASSUME_NONNULL_END
