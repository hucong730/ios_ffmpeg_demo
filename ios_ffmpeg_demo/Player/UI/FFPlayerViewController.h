//
//  FFPlayerViewController.h
//  ios_ffmpeg_demo
//
//  播放器视图控制器
//  职责：管理整个播放器页面的生命周期，桥接 FFPlayerCore（播放内核）
//        和 FFPlayerControlView（控制 UI），处理横竖屏切换和全屏逻辑。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * FFPlayerViewController
 * 全屏模态展示的播放器页面。
 * 初始化时传入视频 URL 和可选标题，内部自动创建播放内核和 UI 组件。
 *
 * 主要职责：
 *   - 管理 FFPlayerCore 播放内核的生命周期
 *   - 作为 FFPlayerCoreDelegate 响应播放状态变化并更新 UI
 *   - 作为 FFPlayerControlViewDelegate 响应用户操作并控制播放内核
 *   - 处理 iOS 16+ 的 requestGeometryUpdate 横竖屏切换
 */
@interface FFPlayerViewController : UIViewController

/// 初始化播放器视图控制器
/// @param url 视频资源的 URL 字符串
/// @param title 视频标题（可选，传 nil 时将使用 URL 的文件名）
- (instancetype)initWithURL:(NSString *)url title:(nullable NSString *)title;

@end

NS_ASSUME_NONNULL_END
