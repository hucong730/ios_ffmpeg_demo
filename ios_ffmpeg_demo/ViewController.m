//
//  ViewController.m
//  ios_ffmpeg_demo
//
//  主屏幕视图控制器
//  功能：提供应用程序主界面，包含标题、三个功能按钮（播放本地视频、播放网络视频、输入 URL），
//        用户点击按钮后跳转到 FFPlayerViewController 进行视频播放。
//  布局：使用 Auto Layout 和 UIStackView 实现垂直居中布局。
//

#import "ViewController.h"
#import "FFPlayerViewController.h"

@interface ViewController ()
@end

@implementation ViewController

/**
 * viewDidLoad
 *
 * 视图加载完成后的初始化方法。
 * 设置背景色、创建标题标签、创建三个操作按钮，并通过 UIStackView 和 Auto Layout 进行布局。
 */
- (void)viewDidLoad {
    [super viewDidLoad];
    // 设置视图背景色为系统背景色（支持浅色/深色模式自适应）
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 创建标题标签，显示应用程序名称
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"FFmpeg + Metal Player";          // 标题文本
    titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];  // 字体：粗体 24 号
    titleLabel.textAlignment = NSTextAlignmentCenter;     // 居中对齐
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;  // 禁用自动转换约束，使用 Auto Layout
    [self.view addSubview:titleLabel];                   // 将标题标签添加到视图中

    // 创建三个功能按钮：播放本地视频、播放网络视频、输入 URL
    UIButton *localButton = [self _createButtonWithTitle:@"Play Local Video" action:@selector(_playLocalVideo)];
    UIButton *networkButton = [self _createButtonWithTitle:@"Play Network Video" action:@selector(_playNetworkVideo)];
    UIButton *inputButton = [self _createButtonWithTitle:@"Input URL" action:@selector(_inputURL)];

    // 使用 UIStackView 垂直排列三个按钮，方便布局管理
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[localButton, networkButton, inputButton]];
    stack.axis = UILayoutConstraintAxisVertical;  // 垂直方向排列
    stack.spacing = 16;                           // 按钮之间的间距为 16
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    // 激活 Auto Layout 约束
    [NSLayoutConstraint activateConstraints:@[
        // 标题标签：水平居中，顶部距安全区域 60 像素
        [titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:60],

        // 按钮栈：水平居中，垂直居中，左右边缘分别距父视图边缘 40 像素
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
    ]];
}

/**
 * _createButtonWithTitle:action:
 *
 * 创建并返回一个统一样式的按钮。
 *
 * @param title  按钮上显示的文本
 * @param action 按钮点击时触发的 Selector
 * @return 配置完成的 UIButton 实例
 *
 * 按钮样式：白色文字，粉色圆角背景，高度 50，点击时触发指定的 action。
 */
- (UIButton *)_createButtonWithTitle:(NSString *)title action:(SEL)action {
    // 创建系统类型按钮
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    // 设置按钮在不同状态下的标题文本
    [button setTitle:title forState:UIControlStateNormal];
    // 设置标题字体：中等字重 17 号
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    // 设置按钮背景色为粉色 (RGB: 0.98, 0.34, 0.45)
    button.backgroundColor = [UIColor colorWithRed:0.98 green:0.34 blue:0.45 alpha:1.0];
    // 设置标题颜色为白色
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    // 设置按钮圆角半径为 12
    button.layer.cornerRadius = 12;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    // 固定按钮高度为 50
    [button.heightAnchor constraintEqualToConstant:50].active = YES;
    // 添加按钮点击事件，绑定到指定的 action 方法
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

/**
 * _playLocalVideo
 *
 * 播放本地视频。
 * 首先尝试从 App Bundle 中查找 "test.mp4"，若不存在则尝试 "sample.mp4"。
 * 如果都找不到，弹出提示框告知用户添加视频文件。
 */
- (void)_playLocalVideo {
    // 尝试从应用 Bundle 中查找名为 "test" 类型为 "mp4" 的视频文件
    NSString *path = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"mp4"];
    if (!path) {
        // 如果 test.mp4 不存在，尝试查找 sample.mp4
        path = [[NSBundle mainBundle] pathForResource:@"sample" ofType:@"mp4"];
    }
    if (!path) {
        // 如果本地视频文件不存在，弹出警告提示框
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Local Video"
                                                                       message:@"Please add a video file named 'test.mp4' to the app bundle."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // 找到视频文件，跳转播放
    [self _playURL:path title:@"Local Video"];
}

/**
 * _playNetworkVideo
 *
 * 播放网络视频。
 * 使用预置的 Big Buck Bunny 测试流地址（HLS m3u8 格式）进行播放。
 */
- (void)_playNetworkVideo {
    // Big Buck Bunny 测试流 URL（Mux 提供的 HLS 测试地址）
    NSString *url = @"https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
    [self _playURL:url title:@"Big Buck Bunny"];
}

/**
 * _inputURL
 *
 * 弹出输入框让用户输入视频 URL。
 * 包含一个文本输入框，用户输入 URL 后点击 "Play" 按钮进行播放；
 * 点击 "Cancel" 按钮则取消操作。
 */
- (void)_inputURL {
    // 创建 UIAlertController 作为输入对话框（样式为弹窗）
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Input Video URL"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // 添加文本输入框，配置占位提示与键盘类型
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"http:// or https://";   // 占位文本
        textField.keyboardType = UIKeyboardTypeURL;        // URL 键盘类型
        textField.autocorrectionType = UITextAutocorrectionTypeNo;  // 关闭自动纠正
    }];
    // 添加 "Cancel" 取消按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // 添加 "Play" 播放按钮，点击时获取输入的 URL 并开始播放
    [alert addAction:[UIAlertAction actionWithTitle:@"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *url = alert.textFields.firstObject.text;  // 获取用户输入的 URL
        if (url.length > 0) {
            [self _playURL:url title:@"Network Video"];     // 调用播放方法
        }
    }]];
    // 弹出输入对话框
    [self presentViewController:alert animated:YES completion:nil];
}

/**
 * _playURL:title:
 *
 * 通用的视频播放方法。
 * 创建 FFPlayerViewController 实例并传入视频 URL 和标题，然后以模态方式呈现播放界面。
 *
 * @param url   视频资源的 URL（支持本地文件路径和网络地址）
 * @param title 视频标题，用于播放界面显示
 */
- (void)_playURL:(NSString *)url title:(NSString *)title {
    // 初始化播放器视图控制器，传入视频 URL 和标题
    FFPlayerViewController *vc = [[FFPlayerViewController alloc] initWithURL:url title:title];
    // 以模态方式弹出播放器界面
    [self presentViewController:vc animated:YES completion:nil];
}

@end
