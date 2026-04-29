//
//  FFPlayerControlView.m
//  ios_ffmpeg_demo
//
//  B站风格播放器控制层的实现
//
//  布局结构（由下到上）：
//    - 底部渐变栏（bottomBar）：播放/暂停 | 当前时间 | 进度条 | 总时长 | 倍速 | 全屏
//    - 中央播放按钮（centerPlayButton）：视频暂停时显示在画面正中央的大播放按钮
//    - 顶部渐变栏（topBar）：返回按钮 + 视频标题
//    - 倍速面板（speedPanel）：右下角弹出的倍速选择浮层
//
//  交互逻辑：
//    - 点击画面任意位置触发 showControls / hideControls 切换
//    - 控件显示后 3 秒无操作自动隐藏（autoHideTimer）
//    - 拖动进度条时暂停自动隐藏，松开后重启计时器
//

#import "FFPlayerControlView.h"

// MARK: - 时间格式化工具函数
/// 将秒数转换为 "mm:ss" 或 "h:mm:ss" 格式的文本
/// @param seconds 秒数
/// @return 格式化后的时间字符串
static NSString *formatTime(double seconds) {
    if (seconds < 0) seconds = 0;
    int totalSeconds = (int)seconds;
    int hours = totalSeconds / 3600;
    int mins = (totalSeconds % 3600) / 60;
    int secs = totalSeconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hours, mins, secs];
    }
    return [NSString stringWithFormat:@"%02d:%02d", mins, secs];
}

@implementation FFPlayerControlView {
    // MARK: - 顶部栏（topBar）
    /// 顶部背景栏容器，承载返回按钮和标题
    UIView *_topBar;
    /// 返回按钮（chevron.left 图标）
    UIButton *_backButton;
    /// 视频标题标签
    UILabel *_titleLabel;
    /// 顶部渐变层（从上到下：黑色透明 → 全透明），使顶部栏在亮色画面上更清晰
    CAGradientLayer *_topGradient;

    // MARK: - 底部栏（bottomBar）
    /// 底部背景栏容器，承载所有播放控制控件
    UIView *_bottomBar;
    /// 播放/暂停按钮
    UIButton *_playPauseButton;
    /// 当前播放时间标签（如 "01:23"）
    UILabel *_currentTimeLabel;
    /// 播放进度条滑块，取值范围 0.0 ~ 1.0（百分比）
    UISlider *_progressSlider;
    /// 视频总时长标签（如 "05:46"）
    UILabel *_totalTimeLabel;
    /// 倍速按钮，点击弹出 speedPanel
    UIButton *_speedButton;
    /// 全屏切换按钮
    UIButton *_fullscreenButton;
    /// 底部渐变层（从下到上：黑色透明 → 全透明），使底部栏在亮色画面上更清晰
    CAGradientLayer *_bottomGradient;

    // MARK: - 中央播放按钮（centerPlayButton）
    /// 视频暂停时显示在画面正中央的大播放按钮，播放中自动隐藏
    UIButton *_centerPlayButton;

    // MARK: - 倍速面板（speedPanel）
    /// 倍速选择浮层面板，包含 0.5x / 1.0x / 1.5x / 2.0x 选项
    UIView *_speedPanel;
    /// 倍速面板当前是否可见
    BOOL _speedPanelVisible;

    // MARK: - 内部状态
    /// 控制栏（顶部栏 + 底部栏）当前是否可见
    BOOL _controlsVisible;
    /// 用户是否正在拖拽进度条（拖拽期间不响应外部的进度更新，避免跳动）
    BOOL _isSeeking;
    /// 拖拽期间进度条值是否发生了变化（用于区分拖拽和点击）
    BOOL _sliderValueChangedDuringDrag;
    /// 视频总时长（秒），用于进度条值到实际时间的换算
    double _duration;
    /// 自动隐藏计时器：控件显示后开始计时，超时自动隐藏
    NSTimer *_autoHideTimer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 初始状态：控件可见、未拖拽、时长归零、倍速面板关闭
        _controlsVisible = YES;
        _isSeeking = NO;
        _duration = 0;
        _speedPanelVisible = NO;
        [self _setupUI];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 每当视图布局变化时，同步更新渐变层的 frame 以匹配父容器尺寸
    _topGradient.frame = _topBar.bounds;
    _bottomGradient.frame = _bottomBar.bounds;
}

#pragma mark - UI Setup

/// 统一 UI 初始化入口
- (void)_setupUI {
    self.backgroundColor = [UIColor clearColor]; // 自身透明，让视频画面透出

    // 单击手势：点击画面切换控件显示/隐藏
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_toggleControls)];
    [self addGestureRecognizer:tap];

    // 依次创建各子视图组件
    [self _setupTopBar];
    [self _setupBottomBar];
    [self _setupCenterPlay];
    [self _setupSpeedPanel];
    // 启动自动隐藏计时器
    [self _startAutoHideTimer];
}

// MARK: - 顶部栏布局
/// 设置顶部栏：包含半透明渐变背景、返回按钮和视频标题
///
/// 布局参考 B 站风格：
///   - 顶部栏高度 80pt，内容居中偏下
///   - 返回按钮在左侧，标题紧跟其后
///   - 渐变层从黑（alpha 0.7）到全透明，确保文字在任何画面背景下均可读
- (void)_setupTopBar {
    _topBar = [[UIView alloc] init];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_topBar];

    // 创建顶部渐变层（上黑下透），用于提升顶部栏文字的可读性
    _topGradient = [CAGradientLayer layer];
    _topGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor],
        (id)[[UIColor clearColor] CGColor]
    ];
    [_topBar.layer insertSublayer:_topGradient atIndex:0];

    // 返回按钮（< 箭头图标）
    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *backImg = [UIImage systemImageNamed:@"chevron.left"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]];
    [_backButton setImage:backImg forState:UIControlStateNormal];
    _backButton.tintColor = [UIColor whiteColor];
    _backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_backButton addTarget:self action:@selector(_backTapped) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_backButton];

    // 视频标题标签，过长时尾部截断
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_topBar addSubview:_titleLabel];

    // Auto Layout 约束
    [NSLayoutConstraint activateConstraints:@[
        // 顶部栏撑满父视图宽度，高度 80pt
        [_topBar.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_topBar.heightAnchor constraintEqualToConstant:80],

        // 返回按钮距离左侧 12pt，距离底部 8pt
        [_backButton.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:12],
        [_backButton.bottomAnchor constraintEqualToAnchor:_topBar.bottomAnchor constant:-8],
        [_backButton.widthAnchor constraintEqualToConstant:40],
        [_backButton.heightAnchor constraintEqualToConstant:40],

        // 标题紧跟在返回按钮右侧
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_backButton.trailingAnchor constant:4],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_backButton.centerYAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-16],
    ]];
}

// MARK: - 底部栏布局
/// 设置底部栏：包含渐变背景、播放控制按钮、时间标签、进度条、倍速和全屏按钮
///
/// 布局参考 B 站风格（从左到右）：
///   [播放/暂停] [当前时间] [====进度条====] [总时长] [倍速] [全屏]
///
/// 进度条采用粉色主题色（#FB5E73），与 B 站标志色一致
- (void)_setupBottomBar {
    _bottomBar = [[UIView alloc] init];
    _bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_bottomBar];

    // 创建底部渐变层（下黑上透），用于提升底部栏文字的可读性
    _bottomGradient = [CAGradientLayer layer];
    _bottomGradient.colors = @[
        (id)[[UIColor clearColor] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor]
    ];
    [_bottomBar.layer insertSublayer:_bottomGradient atIndex:0];

    // 播放/暂停按钮（使用 SF Symbols 的 play.fill / pause.fill）
    _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self _updatePlayPauseIcon:NO];
    _playPauseButton.tintColor = [UIColor whiteColor];
    _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_playPauseButton addTarget:self action:@selector(_playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_playPauseButton];

    // 当前播放时间标签（使用等宽数字字体，避免数字变化时宽度抖动）
    _currentTimeLabel = [[UILabel alloc] init];
    _currentTimeLabel.text = @"00:00";
    _currentTimeLabel.textColor = [UIColor whiteColor];
    _currentTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _currentTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_bottomBar addSubview:_currentTimeLabel];

    // 播放进度条
    _progressSlider = [[UISlider alloc] init];
    _progressSlider.minimumTrackTintColor = [UIColor colorWithRed:0.98 green:0.34 blue:0.45 alpha:1.0]; // B站标志粉色
    _progressSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    _progressSlider.translatesAutoresizingMaskIntoConstraints = NO;

    // 自定义滑块圆形 thumbs，白色 14x14
    UIImage *thumbImage = [self _createThumbImageWithSize:CGSizeMake(14, 14)];
    [_progressSlider setThumbImage:thumbImage forState:UIControlStateNormal];

    // 进度条事件绑定：
    //   TouchDown → 标记 isSeeking，暂停自动隐藏
    //   ValueChanged → 实时更新时间显示
    //   TouchUpInside/Outside/Cancel → 完成 Seek，恢复自动隐藏
    [_progressSlider addTarget:self action:@selector(_sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [_progressSlider addTarget:self action:@selector(_sliderValueChanged) forControlEvents:UIControlEventValueChanged];
    [_progressSlider addTarget:self action:@selector(_sliderTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_bottomBar addSubview:_progressSlider];

    // 点击手势：单击进度条任意位置跳转到对应时间点
    // 与拖拽互不冲突：拖拽会触发 ValueChanged → _sliderValueChangedDuringDrag = YES，
    // 点击不会改变值，_sliderTouchUp 检测到值未变化则跳过 seek，由本手势接管
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_sliderTapped:)];
    [_progressSlider addGestureRecognizer:tapGesture];

    // 视频总时长标签
    _totalTimeLabel = [[UILabel alloc] init];
    _totalTimeLabel.text = @"00:00";
    _totalTimeLabel.textColor = [UIColor whiteColor];
    _totalTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _totalTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_bottomBar addSubview:_totalTimeLabel];

    // 倍速按钮（点击弹出 speedPanel）
    _speedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_speedButton setTitle:@"1.0x" forState:UIControlStateNormal];
    _speedButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [_speedButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _speedButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_speedButton addTarget:self action:@selector(_speedTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_speedButton];

    // 全屏切换按钮（使用 SF Symbols 的箭头缩放图标）
    _fullscreenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *fsImg = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"
                                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]];
    [_fullscreenButton setImage:fsImg forState:UIControlStateNormal];
    _fullscreenButton.tintColor = [UIColor whiteColor];
    _fullscreenButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_fullscreenButton addTarget:self action:@selector(_fullscreenTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_fullscreenButton];

    // 底部栏 Auto Layout 约束
    [NSLayoutConstraint activateConstraints:@[
        // 底部栏撑满父视图宽度，高度 80pt
        [_bottomBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_bottomBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_bottomBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_bottomBar.heightAnchor constraintEqualToConstant:80],

        // 播放按钮在底部栏左端，垂直居中偏上
        [_playPauseButton.leadingAnchor constraintEqualToAnchor:_bottomBar.leadingAnchor constant:12],
        [_playPauseButton.topAnchor constraintEqualToAnchor:_bottomBar.topAnchor constant:16],
        [_playPauseButton.widthAnchor constraintEqualToConstant:32],
        [_playPauseButton.heightAnchor constraintEqualToConstant:32],

        // 当前时间紧接播放按钮右侧
        [_currentTimeLabel.leadingAnchor constraintEqualToAnchor:_playPauseButton.trailingAnchor constant:8],
        [_currentTimeLabel.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],

        // 进度条占据中间大部分空间
        [_progressSlider.leadingAnchor constraintEqualToAnchor:_currentTimeLabel.trailingAnchor constant:8],
        [_progressSlider.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],

        // 总时长在进度条右侧
        [_totalTimeLabel.leadingAnchor constraintEqualToAnchor:_progressSlider.trailingAnchor constant:8],
        [_totalTimeLabel.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],

        // 倍速按钮
        [_speedButton.leadingAnchor constraintEqualToAnchor:_totalTimeLabel.trailingAnchor constant:8],
        [_speedButton.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],
        [_speedButton.widthAnchor constraintEqualToConstant:40],

        // 全屏按钮在底部栏最右端
        [_fullscreenButton.leadingAnchor constraintEqualToAnchor:_speedButton.trailingAnchor constant:4],
        [_fullscreenButton.trailingAnchor constraintEqualToAnchor:_bottomBar.trailingAnchor constant:-12],
        [_fullscreenButton.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],
        [_fullscreenButton.widthAnchor constraintEqualToConstant:32],
        [_fullscreenButton.heightAnchor constraintEqualToConstant:32],
    ]];
}

// MARK: - 中央播放按钮布局
/// 设置中央大播放按钮：仅在视频暂停时显示，点击后触发播放/暂停
///
/// B 站风格的半透明圆形按钮，使用 play.fill 大图标
- (void)_setupCenterPlay {
    _centerPlayButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _centerPlayButton.translatesAutoresizingMaskIntoConstraints = NO;

    // 使用大尺寸 play.fill 图标（40pt）
    UIImage *playImg = [UIImage systemImageNamed:@"play.fill"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightMedium]];
    [_centerPlayButton setImage:playImg forState:UIControlStateNormal];
    _centerPlayButton.tintColor = [UIColor whiteColor];
    _centerPlayButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];  // 半透明黑色背景
    _centerPlayButton.layer.cornerRadius = 35;   // 圆形，直径 70pt
    _centerPlayButton.clipsToBounds = YES;
    _centerPlayButton.hidden = YES;               // 初始隐藏（默认状态为播放中）
    [_centerPlayButton addTarget:self action:@selector(_playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_centerPlayButton];

    // 居中布局，宽高 70x70
    [NSLayoutConstraint activateConstraints:@[
        [_centerPlayButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_centerPlayButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_centerPlayButton.widthAnchor constraintEqualToConstant:70],
        [_centerPlayButton.heightAnchor constraintEqualToConstant:70],
    ]];
}

// MARK: - 倍速面板布局
/// 设置倍速选择面板：从底部栏倍速按钮附近弹出
///
/// 面板包含四个选项：0.5x / 1.0x / 1.5x / 2.0x
/// 使用垂直 UIStackView 排列，整体半透明黑色背景
/// 面板默认隐藏，点击倍速按钮时切换显示/隐藏
- (void)_setupSpeedPanel {
    _speedPanel = [[UIView alloc] init];
    _speedPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _speedPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    _speedPanel.layer.cornerRadius = 8;
    _speedPanel.hidden = YES;       // 默认隐藏
    [self addSubview:_speedPanel];

    // 倍速选项数组
    NSArray *speeds = @[@0.5, @1.0, @1.5, @2.0];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;  // 垂直排列
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_speedPanel addSubview:stack];

    // 遍历创建每个倍速按钮
    for (NSNumber *speed in speeds) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:[NSString stringWithFormat:@"%.1fx", speed.doubleValue] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        btn.tag = (NSInteger)(speed.doubleValue * 10);  // 用 tag 存储倍速值（如 1.5 → 15）
        [btn addTarget:self action:@selector(_speedOptionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [btn.heightAnchor constraintEqualToConstant:36].active = YES;
        [stack addArrangedSubview:btn];
    }

    // 面板定位在底部栏上方右侧（倍速按钮附近）
    [NSLayoutConstraint activateConstraints:@[
        [_speedPanel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-60],
        [_speedPanel.bottomAnchor constraintEqualToAnchor:_bottomBar.topAnchor constant:-8],
        [_speedPanel.widthAnchor constraintEqualToConstant:80],

        // StackView 填充面板内边距
        [stack.topAnchor constraintEqualToAnchor:_speedPanel.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:_speedPanel.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:_speedPanel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_speedPanel.trailingAnchor],
    ]];
}

#pragma mark - Helpers

// MARK: - 工具方法
/// 生成一个纯白色圆形的滑块 thumb 图片
/// @param size 图片尺寸
/// @return 圆形白色 UIImage
- (UIImage *)_createThumbImageWithSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size.width, size.height)];
    [[UIColor whiteColor] setFill];
    [path fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

/// 更新播放/暂停按钮的图标
/// @param isPlaying YES 显示暂停图标，NO 显示播放图标
- (void)_updatePlayPauseIcon:(BOOL)isPlaying {
    NSString *name = isPlaying ? @"pause.fill" : @"play.fill";
    UIImage *img = [UIImage systemImageNamed:name
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]];
    [_playPauseButton setImage:img forState:UIControlStateNormal];
}

#pragma mark - Public

// MARK: - 公开方法实现

/// 设置视频标题
- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
}

/// 更新播放状态，同步更新底部按钮图标和中央播放按钮的显隐
/// @param isPlaying 当前是否正在播放
- (void)updatePlayState:(BOOL)isPlaying {
    [self _updatePlayPauseIcon:isPlaying];
    // 播放时隐藏中央大播放按钮，暂停时显示
    _centerPlayButton.hidden = isPlaying;
}

/// 更新当前播放时间和进度条位置
/// 注意：当用户正在拖拽进度条（_isSeeking == YES）时，不更新滑块位置，
///       避免拖拽过程中滑块跳动，影响用户体验
/// @param currentTime 当前时间（秒）
/// @param duration 总时长（秒）
- (void)updateCurrentTime:(double)currentTime duration:(double)duration {
    _duration = duration;
    _currentTimeLabel.text = formatTime(currentTime);
    _totalTimeLabel.text = formatTime(duration);
    // 仅在非拖拽状态下更新滑块位置
    if (!_isSeeking && duration > 0) {
        _progressSlider.value = (float)(currentTime / duration);
    }
}

/// 更新倍速按钮的显示文本
/// @param speed 当前倍速值
- (void)updateSpeedLabel:(double)speed {
    [_speedButton setTitle:[NSString stringWithFormat:@"%.1fx", speed] forState:UIControlStateNormal];
}

/// 带动画显示控制栏（顶部栏 + 底部栏），并重启自动隐藏计时器
- (void)showControls {
    _controlsVisible = YES;
    [UIView animateWithDuration:0.3 animations:^{
        self->_topBar.alpha = 1.0;
        self->_bottomBar.alpha = 1.0;
    }];
    [self _startAutoHideTimer];
}

/// 带动画隐藏控制栏（顶部栏 + 底部栏），同时关闭倍速面板
- (void)hideControls {
    _controlsVisible = NO;
    _speedPanel.hidden = YES;       // 隐藏控制栏时同时关闭倍速面板
    _speedPanelVisible = NO;
    [UIView animateWithDuration:0.3 animations:^{
        self->_topBar.alpha = 0.0;
        self->_bottomBar.alpha = 0.0;
    }];
}

#pragma mark - Actions

// MARK: - 按钮事件处理

/// 切换控制栏显示/隐藏状态
/// 如果倍速面板正在显示，则优先关闭面板而非切换控制栏
- (void)_toggleControls {
    if (_speedPanelVisible) {
        // 倍速面板打开时点击 → 关闭面板
        _speedPanel.hidden = YES;
        _speedPanelVisible = NO;
        return;
    }
    if (_controlsVisible) {
        [self hideControls];
    } else {
        [self showControls];
    }
}

/// 播放/暂停按钮点击 → 回调代理，并重置自动隐藏计时器
- (void)_playPauseTapped {
    [self _resetAutoHideTimer];
    if ([_delegate respondsToSelector:@selector(controlViewDidTapPlayPause)]) {
        [_delegate controlViewDidTapPlayPause];
    }
}

/// 返回按钮点击 → 回调代理
- (void)_backTapped {
    if ([_delegate respondsToSelector:@selector(controlViewDidTapBack)]) {
        [_delegate controlViewDidTapBack];
    }
}

/// 全屏按钮点击 → 回调代理，并重置自动隐藏计时器
- (void)_fullscreenTapped {
    [self _resetAutoHideTimer];
    if ([_delegate respondsToSelector:@selector(controlViewDidTapFullscreen)]) {
        [_delegate controlViewDidTapFullscreen];
    }
}

/// 倍速按钮点击 → 切换倍速面板的显示/隐藏，并重置自动隐藏计时器
- (void)_speedTapped {
    _speedPanelVisible = !_speedPanelVisible;
    _speedPanel.hidden = !_speedPanelVisible;
    [self _resetAutoHideTimer];
}

/// 倍速选项按钮点击 → 读取 tag 中的倍速值，关闭面板，更新显示，回调代理
/// @param sender 被点击的倍速按钮
- (void)_speedOptionTapped:(UIButton *)sender {
    double speed = sender.tag / 10.0;  // tag 存储的是倍速 ×10（如 1.5 → 15）
    _speedPanel.hidden = YES;
    _speedPanelVisible = NO;
    [self updateSpeedLabel:speed];
    if ([_delegate respondsToSelector:@selector(controlViewDidSelectSpeed:)]) {
        [_delegate controlViewDidSelectSpeed:speed];
    }
}

// MARK: - 进度条拖拽处理

/// 进度条开始拖拽：标记正在 Seeking，停止自动隐藏计时器
/// 拖拽期间滑块位置由用户手势控制，不再响应外部进度更新
- (void)_sliderTouchDown {
    _isSeeking = YES;
    _sliderValueChangedDuringDrag = NO;  // 重置拖拽值变化标记
    [self _stopAutoHideTimer];
    if ([_delegate respondsToSelector:@selector(controlViewDidBeginSeeking)]) {
        [_delegate controlViewDidBeginSeeking];
    }
}

/// 进度条值变化：实时更新当前时间显示（预览拖拽位置的时间）
- (void)_sliderValueChanged {
    _sliderValueChangedDuringDrag = YES;  // 标记值已变化（拖拽有效）
    if (_duration > 0) {
        double time = _progressSlider.value * _duration;
        _currentTimeLabel.text = formatTime(time);
    }
}

/// 进度条拖拽结束：仅在值发生变化时才执行 Seek（点击不改变值则跳过）
/// 点击跳转由 _sliderTapped: 手势接管
- (void)_sliderTouchUp {
    _isSeeking = NO;
    if (_duration > 0 && _sliderValueChangedDuringDrag) {
        double time = _progressSlider.value * _duration;
        if ([_delegate respondsToSelector:@selector(controlViewDidSeekToTime:)]) {
            [_delegate controlViewDidSeekToTime:time];
        }
    }
    [self _startAutoHideTimer];
}

/// 进度条点击手势处理：单击进度条任意位置跳转到对应时间点
/// @param gesture 点击手势识别器
- (void)_sliderTapped:(UITapGestureRecognizer *)gesture {
    if (_duration <= 0) return;

    // 计算点击位置在进度条宽度上的比例
    CGPoint location = [gesture locationInView:_progressSlider];
    float fraction = (float)(location.x / _progressSlider.bounds.size.width);
    fraction = MAX(0.0f, MIN(1.0f, fraction)); // 限幅 [0, 1]

    // 带动画更新滑块位置
    [_progressSlider setValue:fraction animated:YES];

    // 更新时间显示
    double time = fraction * _duration;
    _currentTimeLabel.text = formatTime(time);

    // 通知代理执行 Seek
    if ([_delegate respondsToSelector:@selector(controlViewDidSeekToTime:)]) {
        [_delegate controlViewDidSeekToTime:time];
    }

    // 重置自动隐藏计时器
    [self _resetAutoHideTimer];
}

#pragma mark - Auto-hide Timer

// MARK: - 自动隐藏计时器管理
///
/// 控制栏显示后，启动一个 3 秒的单次计时器。
/// 计时器触发时自动隐藏控制栏。
/// 用户在控件上的任何交互都会重置计时器。
///

/// 启动自动隐藏计时器（3 秒后自动隐藏控制栏）
- (void)_startAutoHideTimer {
    [self _stopAutoHideTimer];  // 先取消之前的计时器
    _autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                      target:self
                                                    selector:@selector(_autoHideFired)
                                                    userInfo:nil
                                                     repeats:NO];  // 单次触发
}

/// 停止自动隐藏计时器
- (void)_stopAutoHideTimer {
    [_autoHideTimer invalidate];
    _autoHideTimer = nil;
}

/// 重置计时器（相当于重启倒计时）
- (void)_resetAutoHideTimer {
    [self _startAutoHideTimer];
}

/// 计时器触发回调：隐藏控制栏
- (void)_autoHideFired {
    [self hideControls];
}

@end
