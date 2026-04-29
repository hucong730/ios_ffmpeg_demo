//
//  FFMetalRenderer.h
//  ios_ffmpeg_demo
//
//  概述：Metal 渲染器的头文件。
//  本渲染器基于 Metal 框架实现视频帧的 GPU 渲染管线。
//  核心功能：接收 CVPixelBuffer（NV12 格式），
//  通过 Metal 管道完成 Y 和 UV 双平面纹理的上传与最终绘制。
//  支持根据视频尺寸自动计算 letterbox/pillarbox 适配比例，
//  确保视频在视口中保持原始宽高比显示。
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFMetalRenderer : NSObject

/// 初始化渲染器，绑定 MTKView 用于显示
/// @param view 用于显示 Metal 内容的 MTKView 实例
- (instancetype)initWithMetalView:(MTKView *)view;

/// 设置 Metal 渲染管线
/// 包括：创建命令队列、加载 shader、构建渲染管道状态、创建纹理缓存
/// @return YES 表示设置成功，NO 表示失败
- (BOOL)setup;

/// 渲染一帧视频数据
/// 将 CVPixelBuffer 中的 NV12 双平面数据通过 Metal 渲染到屏幕上
/// @param pixelBuffer 待渲染的视频帧，期望为 NV12 格式（kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange）
- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// 更新视频尺寸，触发顶点缓冲区的重新计算以适配宽高比
/// @param videoSize 新的视频宽高尺寸
- (void)updateVideoSize:(CGSize)videoSize;

@end

NS_ASSUME_NONNULL_END
