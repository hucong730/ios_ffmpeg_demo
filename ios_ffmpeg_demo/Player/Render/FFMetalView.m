//
//  FFMetalView.m
//  ios_ffmpeg_demo
//
//  说明：
//  FFMetalView 的实现文件。
//  本文件实现了 MTKView 子类的完整生命周期管理，包括：
//  1. 视图初始化与 Metal 设备创建
//  2. CVPixelBuffer 的线程安全存取（通过 os_unfair_lock）
//  3. MTKViewDelegate 回调驱动的渲染循环
//  4. 播放器解码像素缓冲区到 Metal 纹理的桥接
//
//  线程模型：
//   - setCurrentPixelBuffer: 由外部播放器线程调用（生产方）
//   - drawInMTKView: 由 Metal 框架在渲染循环中调用（消费方）
//   - 两者通过 os_unfair_lock 实现无等待锁保护
//

#import "FFMetalView.h"
#import "FFMetalRenderer.h"
#import <os/lock.h>

@interface FFMetalView () <MTKViewDelegate>
@end

@implementation FFMetalView {
    FFMetalRenderer *_renderer;            // Metal 渲染器，负责纹理转换与绘制
    CVPixelBufferRef _currentPixelBuffer;  // 当前待渲染的像素缓冲区（受 _lock 保护）
    os_unfair_lock _lock;                  // 用于保护 _currentPixelBuffer 的线程安全锁
}

#pragma mark - 初始化方法

/**
 * 通过代码创建视图时的初始化入口（initWithFrame:）
 *
 * 流程：
 *  1. 创建系统默认 Metal 设备
 *  2. 调用父类 initWithFrame:device: 初始化
 *  3. 执行公共初始化逻辑 _commonInit
 */
- (instancetype)initWithFrame:(CGRect)frame {
    // 创建系统默认的 Metal GPU 设备
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:device];
    if (self) {
        [self _commonInit];
    }
    return self;
}

/**
 * 通过 Interface Builder / Storyboard 创建时的初始化入口（initWithCoder:）
 *
 * 注意：使用此初始化路径时，父类不会自动设置 Metal device，
 * 因此需要手动创建并赋值。
 */
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        // Storyboard 方式需要在初始化后手动设置 Metal 设备
        self.device = MTLCreateSystemDefaultDevice();
        [self _commonInit];
    }
    return self;
}

/**
 * 公共初始化方法，被所有初始化入口调用
 *
 * 配置内容包括：
 *  - 初始化线程锁
 *  - 设置 MTKView 渲染属性（像素格式、帧缓冲模式、刷新策略等）
 *  - 创建并设置 Metal 渲染器
 */
- (void)_commonInit {
    // --- 初始化线程同步锁 ---
    // 使用 os_unfair_lock（轻量级自旋锁）保护 _currentPixelBuffer 的读写。
    // 相比 pthread_mutex，os_unfair_lock 在无竞争时性能更优，适用于高频短临界区的场景。
    _lock = OS_UNFAIR_LOCK_INIT;
    _currentPixelBuffer = NULL;

    // --- 配置 MTKView 的 Metal 属性 ---

    // colorPixelFormat: 颜色渲染目标的像素格式
    // MTLPixelFormatBGRA8Unorm 是 Metal 最常用的 32 位像素格式，
    // 与 CVPixelBuffer 的 BGRA 排列兼容，无需额外格式转换。
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

    // framebufferOnly: 帧缓冲是否仅用于渲染输出
    // 设置为 NO 表示允许将 drawable 纹理作为纹理读取（采样）使用，
    // 某些渲染路径（如 Core Image 介入）需要此设置。
    self.framebufferOnly = NO;

    // enableSetNeedsDisplay: 是否允许通过 setNeedsDisplay 触发重绘
    // 设置为 NO 表示完全由 Metal 框架的定时器驱动渲染循环，
    // 避免手动调用导致的额外开销。
    self.enableSetNeedsDisplay = NO;

    // paused: 是否暂停渲染循环
    // 设置为 NO 使 Metal 持续驱动 drawInMTKView: 回调。
    self.paused = NO;

    // preferredFramesPerSecond: 目标帧率
    // 设为 30 fps，适用于直播或普通视频播放场景；
    // Metal 会尽可能接近此值，实际帧率受硬件和渲染负载影响。
    self.preferredFramesPerSecond = 30;

    // clearColor: 未绘制区域的清除色
    // RGBA(0, 0, 0, 1) 即纯黑色不透明背景。
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    // 设置代理为自己，由本类处理 MTKViewDelegate 回调
    self.delegate = self;

    // --- 创建 Metal 渲染器 ---
    // FFMetalRenderer 负责实际的 Metal 渲染管线配置与绘制指令编码。
    _renderer = [[FFMetalRenderer alloc] initWithMetalView:self];
    [_renderer setup];
}

#pragma mark - 销毁

/**
 * 析构方法，释放持有的像素缓冲区
 *
 * 在对象销毁前必须释放 _currentPixelBuffer，避免内存泄漏。
 * 加锁保证在释放过程中没有其他线程正在读/写该缓冲区。
 */
- (void)dealloc {
    os_unfair_lock_lock(&_lock);
    if (_currentPixelBuffer) {
        // 释放之前持有的像素缓冲区
        CVPixelBufferRelease(_currentPixelBuffer);
        _currentPixelBuffer = NULL;
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 像素缓冲区注入

/**
 * 设置当前待渲染的像素缓冲区（由外部播放器线程调用）
 *
 * 这是播放器解码线程到渲染线程的唯一数据通道。
 *
 * 线程安全说明：
 *  - 使用 os_unfair_lock 保护 _currentPixelBuffer 的读写
 *  - 方法内部会对传入的 pixelBuffer 执行 retain，
 *    确保在跨线程传递过程中缓冲区不会被提前释放
 *
 * 使用方式：
 *  - 外部调用方（如 FFPlayerCore）在解码回调中调用此方法
 *  - 传入 nil 可清空当前缓冲，通常用于 seek 或停止播放时
 *
 * @param pixelBuffer 解码后的像素缓冲区，可传入 nil
 */
- (void)setCurrentPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // 加锁保护 _currentPixelBuffer 的写入操作
    os_unfair_lock_lock(&_lock);

    // 释放旧的像素缓冲区
    if (_currentPixelBuffer) {
        CVPixelBufferRelease(_currentPixelBuffer);
    }

    // 更新为新的像素缓冲区
    _currentPixelBuffer = pixelBuffer;

    // 对新缓冲区执行 retain，确保本对象持有其所有权
    if (_currentPixelBuffer) {
        CVPixelBufferRetain(_currentPixelBuffer);
    }

    // 解锁
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - 视频尺寸更新

/**
 * 更新视频画面尺寸
 *
 * 当播放器检测到视频分辨率变化时调用此方法，
 * 驱动渲染器重新计算顶点数据、纹理坐标和变换矩阵，
 * 以适配新的画面比例。
 *
 * @param videoSize 新的视频尺寸
 */
- (void)updateVideoSize:(CGSize)videoSize {
    [_renderer updateVideoSize:videoSize];
}

#pragma mark - MTKViewDelegate 回调

/**
 * MTKView 渲染回调 — 每帧绘制入口
 *
 * 这是整个渲染流程的核心方法，由 Metal 框架按照 preferredFramesPerSecond
 * 设定的频率自动调用。在此方法中完成：
 *  1. 从 _currentPixelBuffer 取出一帧像素数据
 *  2. 交由 FFMetalRenderer 转换为 Metal 纹理并绘制到屏幕
 *
 * 线程安全说明：
 *  - 此方法在 Metal 渲染线程中执行
 *  - 通过 os_unfair_lock 从 _currentPixelBuffer 中安全取出缓冲区
 *  - 取出后对缓冲区执行 retain，确保在渲染完成前不会被释放
 *  - 渲染完成后在本地释放 retain，平衡引用计数
 */
- (void)drawInMTKView:(nonnull MTKView *)view {
    // --- 步骤 1：线程安全地获取当前像素缓冲区 ---
    // 在锁的保护下从共享变量 _currentPixelBuffer 中读取缓冲区，
    // 并对其 retain 以保证在后续渲染过程中不会被释放。
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _currentPixelBuffer;
    if (pb) {
        CVPixelBufferRetain(pb);
    }
    os_unfair_lock_unlock(&_lock);

    // --- 步骤 2：执行 Metal 渲染 ---
    // 只有在成功获取到像素缓冲区时才执行渲染，避免空帧绘制。
    if (pb) {
        // 将像素缓冲区传递给渲染器进行纹理转换和屏幕绘制
        [_renderer renderPixelBuffer:pb];

        // 渲染完成后释放本地持有的引用
        CVPixelBufferRelease(pb);
    }
    // 注意：如果 pb 为 NULL，此帧将跳过渲染，
    // 画面保持上一帧的内容或清除色（黑色）。
}

/**
 * MTKView 的 drawable 尺寸变化回调
 *
 * 当视图的 bounds 发生变化（如屏幕旋转、窗口大小调整）时，
 * Metal 会更新 drawable 尺寸并触发此回调。
 *
 * 当前实现中，当 drawable 尺寸变化时通知渲染器重新计算顶点缓冲区
 * 以适配新视口尺寸。传入 CGSizeZero 表示仅触发视口适配重算，
 * 不会覆盖已保存的视频原始尺寸（避免横竖屏切换后画面被拉伸）。
 */
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    // 触发顶点缓冲区重算以适配新视口（但不改变视频原始尺寸）
    [_renderer updateVideoSize:CGSizeZero];
}

@end
