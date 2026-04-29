//
//  FFVideoFrameConverter.h
//  ios_ffmpeg_demo
//
//  视频帧格式转换器 —— 将 FFmpeg 解码后的 AVFrame（通常为 YUV420P）转换为
//  iOS 可渲染的 CVPixelBuffer（NV12 格式），供 Metal / Core Image 等框架直接使用。
//
//  核心流程：
//    AVFrame (YUV420P)
//      │
//      ▼  sws_scale 色彩空间转换 + 缩放
//    CVPixelBuffer (NV12, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
//      │
//      ▼  通过 CVPixelBufferPool 复用内存，避免频繁分配 / 释放
//
//  为什么要用 CVPixelBufferPool：
//    避免每帧都创建 / 销毁 CVPixelBuffer，大幅降低 CPU 开销和内存碎片。
//
//  为什么要用 NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)：
//    NV12 是双平面格式（Y 单独一个平面，UV 交错一个平面），
//    可直接映射到 Metal 双平面纹理（MTLPixelFormatR8Unorm + MTLPixelFormatRG8Unorm），
//    是 iOS 硬件解码和 Metal 渲染的事实标准格式。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <libavutil/frame.h>
#import <libavutil/pixfmt.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFVideoFrameConverter : NSObject

/**
 * 初始化转换器
 *
 * @param width     视频宽（像素）
 * @param height    视频高（像素）
 * @param srcFmt    源像素格式（FFmpeg AVPixelFormat，如 AV_PIX_FMT_YUV420P）
 */
- (instancetype)initWithWidth:(int)width
                       height:(int)height
             sourcePixelFormat:(enum AVPixelFormat)srcFmt;

/**
 * 打开转换器 —— 创建 sws_scale 上下文 + CVPixelBufferPool
 *
 * 必须先调用此方法才能进行 convertFrame 操作。
 *
 * @return YES 表示成功，NO 表示失败
 */
- (BOOL)open;

/**
 * 将 FFmpeg AVFrame 转换为 CVPixelBuffer（NV12）
 *
 * @param frame  FFmpeg 解码后的视频帧
 * @return       CVPixelBufferRef（调用者需要自行 CVPixelBufferRelease），
 *               失败时返回 NULL
 */
- (nullable CVPixelBufferRef)convertFrame:(AVFrame *)frame;

/**
 * 关闭转换器 —— 释放 sws_scale 上下文和 CVPixelBufferPool
 *
 * 调用后转换器不再可用，如需继续使用需重新 open。
 */
- (void)close;

@end

NS_ASSUME_NONNULL_END
