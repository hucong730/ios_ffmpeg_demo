//
//  FFPlayerView.m
//  ios_ffmpeg_demo
//
//  组合视图的实现：初始化时创建 metalView 和 controlView，
//  并让它们完全填充自身 bounds，形成"视频画面在下、控制层在上"的层级结构。
//

#import "FFPlayerView.h"
#import "FFMetalView.h"

@implementation FFPlayerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 背景设为黑色，在视频未渲染时显示纯黑
        self.backgroundColor = [UIColor blackColor];
        [self _setupSubviews];
    }
    return self;
}

/// 创建并添加子视图：metalView（视频画面）+ controlView（控制层）
/// 两者均使用 Auto Layout 撑满整个容器
- (void)_setupSubviews {
    // 视频画面渲染层：用于显示 FFmpeg 解码后的视频帧（通过 Metal 渲染）
    _metalView = [[FFMetalView alloc] initWithFrame:self.bounds];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_metalView];

    // 控制层覆盖层：响应触摸事件，提供播放控制 UI
    _controlView = [[FFPlayerControlView alloc] initWithFrame:self.bounds];
    _controlView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_controlView];

    // 两个子视图均撑满父视图（metalView 在下，controlView 在上）
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_metalView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [_controlView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_controlView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_controlView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_controlView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
}

@end
