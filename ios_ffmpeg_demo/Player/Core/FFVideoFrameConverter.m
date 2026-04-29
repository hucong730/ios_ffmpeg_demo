//
//  FFVideoFrameConverter.m
//  ios_ffmpeg_demo
//
//  实现：将 FFmpeg AVFrame（YUV420P）通过 sws_scale 转换为 CVPixelBuffer（NV12）。
//
//  整体流程：
//    1. open 时创建 sws_scale 上下文和 CVPixelBufferPool
//    2. convertFrame 时从 pool 取出 CVPixelBuffer，锁定地址
//    3. 将 Y 和 UV 平面的指针传给 sws_scale 进行转换
//    4. 解锁地址，返回 CVPixelBuffer
//    5. close 时释放所有资源
//
//  关键设计决策：
//    - CVPixelBufferPool：复用 CVPixelBuffer，避免每帧重复创建/销毁，
//      降低 CPU 开销，减少内存碎片。（详见 kCVPixelBufferPoolMinimumBufferCountKey）
//    - NV12 格式：双平面（Y + UV 交错），与 Metal 双平面纹理一一对应，
//      可在 GPU 中零拷贝直接采样。
//    - kCVPixelBufferMetalCompatibilityKey = YES：允许 CVMetalTextureCache
//      基于此 CVPixelBuffer 创建 Metal 纹理，实现 GPU 显存直接访问。
//    - stride（字节行跨度）：CVPixelBuffer 的 stride 可能大于视频宽度（因对齐），
//      必须使用 CVPixelBufferGetBytesPerRowOfPlane 获取实际 stride，
//      而非简单使用 width，否则画面会出现偏移或撕裂。
//

#import "FFVideoFrameConverter.h"
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>

@implementation FFVideoFrameConverter {
    int _width;                     // 视频宽度（像素）
    int _height;                    // 视频高度（像素）
    enum AVPixelFormat _srcFormat;  // 源像素格式（如 AV_PIX_FMT_YUV420P）

    struct SwsContext *_swsContext;          // sws_scale 转换上下文
    CVPixelBufferPoolRef _pixelBufferPool;   // CVPixelBuffer 复用池
}

/**
 * 初始化方法
 *
 * 仅保存参数，不创建实际资源。资源在 open 中创建。
 */
- (instancetype)initWithWidth:(int)width
                       height:(int)height
             sourcePixelFormat:(enum AVPixelFormat)srcFmt {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _srcFormat = srcFmt;
        _swsContext = NULL;
        _pixelBufferPool = NULL;
    }
    return self;
}

/**
 * dealloc —— 确保资源释放
 *
 * 调用 close 释放 sws_scale 上下文和 CVPixelBufferPool。
 */
- (void)dealloc {
    [self close];
}

/**
 * 打开转换器
 *
 * 步骤：
 *  1. 创建 sws_scale 上下文，定义源格式 → NV12 的转换参数
 *  2. 创建 CVPixelBufferPool，配置最小缓冲数量、像素格式、宽高、
 *     IOSurface 支持和 Metal 兼容性
 *
 * @return YES 成功，NO 失败
 */
- (BOOL)open {
    // ── 1. 创建 sws_scale 上下文 ──
    // 源尺寸 = 目标尺寸（不缩放），仅做色彩空间转换：srcFmt → AV_PIX_FMT_NV12
    // SWS_BILINEAR 是折中的缩放算法，质量与性能平衡较好
    _swsContext = sws_getContext(_width, _height, _srcFormat,
                                 _width, _height, AV_PIX_FMT_NV12,
                                 SWS_BILINEAR, NULL, NULL, NULL);
    if (!_swsContext) {
        NSLog(@"FFVideoFrameConverter: sws_getContext failed");
        return NO;
    }

    // ── 2. 创建 CVPixelBufferPool ──
    // 使用 Pool 而非每次都创建新的 CVPixelBuffer，可以循环复用内存缓冲区，
    // 显著降低内存分配开销和碎片化问题。
    NSDictionary *poolAttrs = @{
        // 池中至少保留 4 个缓冲区，应对解码器输出与渲染器消费之间的速率波动
        (__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @(4)
    };
    NSDictionary *pixelBufferAttrs = @{
        // NV12 双平面格式 (Y + UV 交错)，直接映射 Metal 双平面纹理
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(_width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(_height),
        // 启用 IOSurface 支持，允许在 CPU 和 GPU 之间零拷贝共享内存
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        // 必须设置为 YES，否则 CVMetalTextureCacheCreateTextureFromImage 会失败
        // 这是 Metal 渲染管线的关键前提
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @(YES)
    };

    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttrs,
                                               (__bridge CFDictionaryRef)pixelBufferAttrs,
                                               &_pixelBufferPool);
    if (status != kCVReturnSuccess) {
        NSLog(@"FFVideoFrameConverter: CVPixelBufferPoolCreate failed: %d", status);
        return NO;
    }

    return YES;
}

/**
 * 转换一帧：AVFrame → CVPixelBuffer
 *
 * 步骤：
 *  1. 从 CVPixelBufferPool 取出一个 CVPixelBuffer
 *  2. 锁定地址，获取 Y 平面和 UV 平面的基地址及 stride
 *  3. 调用 sws_scale 将源帧数据转换并写入 CVPixelBuffer 的两个平面
 *  4. 解锁地址，返回 CVPixelBuffer
 *
 * 注意：
 *  - 返回的 CVPixelBufferRef 引用计数 +1，调用者使用完毕后
 *    必须调用 CVPixelBufferRelease 释放，否则会造成内存泄漏。
 *  - 建议定期调用 CVMetalTextureCacheFlush，清理 Metal 纹理缓存中
 *    不再被引用的陈旧纹理条目，防止显存无限增长。
 *
 * @param frame FFmpeg AVFrame（通常为 YUV420P）
 * @return CVPixelBufferRef（需调用者 release），失败返回 NULL
 */
- (CVPixelBufferRef)convertFrame:(AVFrame *)frame {
    if (!_swsContext || !_pixelBufferPool) return NULL;

    CVPixelBufferRef pixelBuffer = NULL;
    // 从 pool 取出（或创建）一个可复用的 CVPixelBuffer
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                          _pixelBufferPool,
                                                          &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        NSLog(@"FFVideoFrameConverter: CVPixelBufferPoolCreatePixelBuffer failed: %d", status);
        return NULL;
    }

    // 锁定基地址，确保 CPU 可以安全读写 CVPixelBuffer 的内存
    // 参数 0 表示不标记为准备渲染（非只读锁定）
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // ── 获取 NV12 两个平面的地址和 stride ──
    // Plane 0：Y 亮度平面（单通道灰度）
    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    // Plane 1：UV 色度平面（双通道交错：U 和 V 交替存储）
    uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    // 注意：CVPixelBuffer 的 bytesPerRow（stride）可能大于视频宽度（如 16 字节对齐），
    // 必须使用 GetBytesPerRowOfPlane 获取实际值，否则 sws_scale 写入位置会错位
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

    // ── 构造 sws_scale 目标参数 ──
    // dstData[0] = Y 平面地址
    // dstData[1] = UV 平面地址
    // dstLinesize[0] = Y 平面 stride（字节行跨度）
    // dstLinesize[1] = UV 平面 stride（通常是 Y stride 的 2 倍，因为 UV 交错）
    uint8_t *dstData[2] = { yPlane, uvPlane };
    int dstLinesize[2] = { (int)yStride, (int)uvStride };

    // ── 执行色彩空间转换 ──
    // frame->data:     FFmpeg 原始帧平面指针数组（YUV420P 有 3 个平面）
    // frame->linesize: FFmpeg 原始帧各平面的 stride
    // 0, _height:      输出区域的起始行和高度（0 表示从第一行开始到完整高度）
    // dstData:         目标 CVPixelBuffer 的平面指针数组
    // dstLinesize:     目标 CVPixelBuffer 各平面的 stride
    sws_scale(_swsContext,
              (const uint8_t *const *)frame->data, frame->linesize,
              0, _height,
              dstData, dstLinesize);

    // 解锁基地址，允许 GPU 等后续访问
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return pixelBuffer;
}

/**
 * 关闭转换器
 *
 * 释放 sws_scale 上下文和 CVPixelBufferPool，并将指针置 NULL。
 * 调用后如需继续转换，需重新调用 open。
 */
- (void)close {
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

@end
