//
//  FFMetalView.h
//  ios_ffmpeg_demo
//
//  说明：
//  FFMetalView 是 MTKView 的子类，负责将 FFPlayerCore 解码后的 CVPixelBuffer
//  通过 Metal 渲染管线呈现在屏幕上。
//  该类作为视频画面渲染的入口，向上对接播放器引擎，向下驱动 Metal 渲染器。
//  核心职责包括：管理 CVPixelBuffer 的线程安全传递、配置 Metal 视图属性、
//  以及协调 MTKViewDelegate 回调驱动的渲染循环。
//

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * FFMetalView
 *
 * 基于 Metal 的视频渲染视图，继承自 MTKView。
 * 通过外部注入 CVPixelBuffer 实现逐帧渲染，适用于 FFmpeg 解码场景。
 *
 * 主要功能：
 * - 接收解码后的 CVPixelBuffer 并传递给 Metal 渲染器
 * - 支持播放过程中动态更新视频尺寸
 * - 使用 os_unfair_lock 保证多线程环境下像素缓冲区的安全读写
 */
@interface FFMetalView : MTKView

/**
 * 设置当前待渲染的像素缓冲区
 *
 * 由播放器线程（通常是音频/视频解码回调线程）调用，
 * 将解码后的 CVPixelBuffer 安全地传递给渲染层。
 * 方法内部通过锁机制保证与渲染线程之间的数据一致。
 *
 * @param pixelBuffer 解码输出或待渲染的 CVPixelBuffer，传入 nil 可清空当前缓冲
 */
- (void)setCurrentPixelBuffer:(nullable CVPixelBufferRef)pixelBuffer;

/**
 * 更新视频画面尺寸
 *
 * 当视频分辨率发生变化时调用，通知渲染器重新计算顶点缓冲和变换矩阵。
 *
 * @param videoSize 新的视频宽高尺寸（单位：像素）
 */
- (void)updateVideoSize:(CGSize)videoSize;

@end

NS_ASSUME_NONNULL_END
