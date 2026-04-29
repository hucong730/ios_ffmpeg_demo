//
//  FFPlayerViewController.m
//  ios_ffmpeg_demo
//
//  播放器视图控制器的实现
//
//  核心职责（代理桥接模式）：
//    1. 作为 FFPlayerCoreDelegate：接收播放内核的状态回调和时间更新，驱动 UI 刷新
//    2. 作为 FFPlayerControlViewDelegate：接收用户交互事件，转换为对播放内核的操作
//
//  横竖屏处理：
//    - iOS 16+ 使用 UIWindowScene.requestGeometryUpdateWithPreferences 实现旋转
//    - iOS 15 及以下依赖设备旋转 + supportedInterfaceOrientations
//    - 通过 viewWillTransitionToSize 监听旋转事件，更新全屏状态
//
//  状态栏 & Home Indicator：
//    - 全屏时隐藏状态栏和 Home Indicator，实现沉浸式播放体验
//

#import "FFPlayerViewController.h"
#import "FFPlayerView.h"
#import "FFPlayerCore.h"
#import "FFMetalView.h"

/// 内部遵从两个代理协议：
///   FFPlayerCoreDelegate       - 接收播放内核的回调
///   FFPlayerControlViewDelegate - 接收用户交互事件
@interface FFPlayerViewController () <FFPlayerCoreDelegate, FFPlayerControlViewDelegate>
@end

@implementation FFPlayerViewController {
    /// 视频资源的 URL 字符串
    NSString *_url;
    /// 视频标题（显示在顶部栏）
    NSString *_videoTitle;
    /// 组合视图（metalView + controlView）
    FFPlayerView *_playerView;
    /// 播放内核实例
    FFPlayerCore *_playerCore;
    /// 当前是否为全屏（横屏）状态
    BOOL _isFullscreen;
    /// playerView 的高度约束（可用于调整播放器在竖屏下的显示比例）
    NSLayoutConstraint *_playerViewHeightConstraint;
}

/// 初始化方法
/// @param url 视频 URL
/// @param title 视频标题（可选，传 nil 时使用 URL 的文件名）
- (instancetype)initWithURL:(NSString *)url title:(NSString *)title {
    self = [super init];
    if (self) {
        _url = [url copy];
        _videoTitle = [title copy] ?: [url lastPathComponent];  // 未提供标题时用文件名
        _isFullscreen = NO;
        self.modalPresentationStyle = UIModalPresentationFullScreen;  // 全屏模态展示
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    [self _setupPlayerView];
    [self _setupPlayer];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 视图已经展示后开始准备播放（此时 metalView 已就绪）
    [_playerCore prepareToPlay];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 离开页面时停止播放，释放解码资源
    [_playerCore stop];
}

#pragma mark - Setup

/// 创建并布局播放器组合视图（FFPlayerView）
/// 包含 metalView（视频画面）和 controlView（控制层）
- (void)_setupPlayerView {
    _playerView = [[FFPlayerView alloc] initWithFrame:CGRectZero];
    _playerView.translatesAutoresizingMaskIntoConstraints = NO;
    // 设置控制层的代理为 self
    _playerView.controlView.delegate = self;
    _playerView.controlView.title = _videoTitle;
    [self.view addSubview:_playerView];

    // 播放器视图撑满整个屏幕
    [NSLayoutConstraint activateConstraints:@[
        [_playerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_playerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_playerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_playerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

/// 初始化播放内核（FFPlayerCore），绑定 metalView 用于渲染
- (void)_setupPlayer {
    _playerCore = [[FFPlayerCore alloc] initWithURL:_url metalView:_playerView.metalView];
    _playerCore.delegate = self;  // 设置播放内核的代理为 self
}

#pragma mark - Status Bar / Orientation

// MARK: - 状态栏 & 屏幕旋转控制

/// 始终隐藏状态栏（全屏沉浸式体验）
- (BOOL)prefersStatusBarHidden {
    return YES;
}

/// 状态栏隐藏/显示使用淡入淡出动画
- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}

/// 全屏时自动隐藏 Home Indicator（底部横条），避免干扰视频观看
- (BOOL)prefersHomeIndicatorAutoHidden {
    return _isFullscreen;
}

/// 支持所有方向（除倒置外），允许自动旋转
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

/// 监听视图控制器尺寸变化（横竖屏切换时触发）
/// 根据宽高比判断是否为全屏横屏状态，并更新 Home Indicator 和状态栏
/// @param size 新的视图尺寸
/// @param coordinator 转场协调器
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // 宽 > 高 判定为横屏全屏状态
    _isFullscreen = size.width > size.height;
    // 通知系统重新查询 prefersHomeIndicatorAutoHidden
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    // 通知系统重新查询 prefersStatusBarHidden
    [self setNeedsStatusBarAppearanceUpdate];
}

#pragma mark - FFPlayerCoreDelegate

// MARK: - 播放内核代理回调
// 这些方法由 FFPlayerCore 在内部状态变化时调用，用于驱动 UI 更新

/// 播放器状态变化回调
/// @param state 新的播放器状态（Ready / Playing / Paused / Completed / Failed）
- (void)playerCoreDidChangeState:(FFPlayerState)state {
    // 根据状态更新控制视图的播放/暂停按钮和中央播放按钮
    BOOL isPlaying = (state == FFPlayerStatePlaying);
    [_playerView.controlView updatePlayState:isPlaying];

    // 播放器准备就绪后自动开始播放
    if (state == FFPlayerStateReady) {
        [_playerCore play];
    }
}

/// 播放时间更新回调（约每秒 4~10 次，取决于解码帧率）
/// @param currentTime 当前播放时间（秒）
/// @param duration 视频总时长（秒）
- (void)playerCoreDidUpdateCurrentTime:(double)currentTime duration:(double)duration {
    // 桥接：将播放内核的时间信息传递给控制视图更新进度条和时间标签
    [_playerView.controlView updateCurrentTime:currentTime duration:duration];
}

/// 播放出错回调
/// @param error 错误信息
- (void)playerCoreDidEncounterError:(NSError *)error {
    // 弹出错误提示，点击后关闭播放器
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                   message:error.localizedDescription
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - FFPlayerControlViewDelegate

// MARK: - 控制视图代理回调
// 这些方法由 FFPlayerControlView 在用户交互时调用，用于控制播放内核

/// 用户点击了播放/暂停按钮
/// 根据当前播放状态切换播放或暂停
- (void)controlViewDidTapPlayPause {
    if (_playerCore.state == FFPlayerStatePlaying) {
        [_playerCore pause];
    } else if (_playerCore.state == FFPlayerStatePaused || _playerCore.state == FFPlayerStateCompleted) {
        [_playerCore play];
    }
}

/// 用户点击了返回按钮 → 停止播放并关闭播放器
- (void)controlViewDidTapBack {
    [_playerCore stop];
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// 用户点击了全屏切换按钮
///
/// iOS 16+ 通过 UIWindowSceneGeometryPreferencesIOS 请求系统旋转：
///   - 当前为竖屏 → 请求横屏（LandscapeRight）
///   - 当前为横屏 → 请求竖屏（Portrait）
///
/// iOS 15 及以下依赖系统自动旋转 + supportedInterfaceOrientations
- (void)controlViewDidTapFullscreen {
    if (_isFullscreen) {
        // 当前为全屏横屏 → 切换回竖屏
        if (@available(iOS 16.0, *)) {
            // 获取当前 UIWindowScene
            UIWindowScene *scene = self.view.window.windowScene;
            // 配置几何偏好：竖屏
            UIWindowSceneGeometryPreferencesIOS *prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
            // 向系统请求更新窗口几何属性（触发旋转）
            [scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
        }
        // iOS 15 以下由 supportedInterfaceOrientations 自动处理，无需额外代码
    } else {
        // 当前为竖屏 → 切换为横屏全屏
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = self.view.window.windowScene;
            // 配置几何偏好：横屏（右侧 Home 键方向）
            UIWindowSceneGeometryPreferencesIOS *prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
            [scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
        }
    }
}

/// 用户开始拖拽进度条
/// 可在此处暂停播放以实现"拖拽预览"效果（当前为空实现，可按需扩展）
- (void)controlViewDidBeginSeeking {
    // 可以在这里暂停播放，实现拖拽时静帧预览
    // 例如：[_playerCore pause];
}

/// 用户完成拖拽，确定跳转目标时间
/// @param seconds 目标时间点（秒）
- (void)controlViewDidSeekToTime:(double)seconds {
    [_playerCore seekToTime:seconds];
}

/// 用户选择了倍速播放
/// @param speed 倍速值（如 0.5 / 1.0 / 1.5 / 2.0）
- (void)controlViewDidSelectSpeed:(double)speed {
    _playerCore.playbackSpeed = speed;
}

@end
