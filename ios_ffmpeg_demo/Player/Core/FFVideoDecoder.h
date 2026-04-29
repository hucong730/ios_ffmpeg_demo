//==============================================================================
// FFVideoDecoder.h
// iOS FFmpeg Demo
//
// 视频解码器头文件
// 封装 FFmpeg 的视频解码功能，提供面向对象的 Objective-C 接口。
// 职责：管理视频解码器的生命周期（初始化、打开、解码、刷新、关闭），
//       以及暴露解码后的视频元数据（宽、高、像素格式）。
//==============================================================================

#import <Foundation/Foundation.h>
#import <libavcodec/avcodec.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * FFVideoDecoder
 *
 * 视频解码器类，基于 FFmpeg libavcodec 实现。
 * 使用 avcodec_send_packet / avcodec_receive_frame 异步解码模型，
 * 支持多线程帧/片级并行解码。
 */
@interface FFVideoDecoder : NSObject

/// 视频宽度（像素），在 open 成功后有效
@property (nonatomic, readonly) int width;
/// 视频高度（像素），在 open 成功后有效
@property (nonatomic, readonly) int height;
/// 像素格式（如 AV_PIX_FMT_YUV420P），在 open 成功后有效
@property (nonatomic, readonly) enum AVPixelFormat pixelFormat;

/**
 * 使用编解码参数初始化解码器
 * @param params 从容器层（如 AVStream->codecpar）获取的编解码参数
 * @return 初始化后的解码器实例
 */
- (instancetype)initWithCodecParameters:(AVCodecParameters *)params;

/**
 * 打开解码器
 * 内部步骤：查找解码器 -> 创建 AVCodecContext -> 拷贝参数 -> 设置多线程 -> 打开解码器
 * @return YES 成功，NO 失败
 */
- (BOOL)open;

/**
 * 向解码器发送一个 AVPacket 进行解码
 * 对应 avcodec_send_packet，采用异步解码模型：
 * 该函数将压缩数据送入解码器内部缓冲区，不保证立即输出帧。
 * @param packet 待解码的压缩数据包（传 NULL 表示"冲刷"模式，驱动解码器输出剩余帧）
 * @return 0 成功，负值表示错误（如 AVERROR(EAGAIN) 表示解码器已满，应先接收帧）
 */
- (int)sendPacket:(AVPacket *)packet;

/**
 * 从解码器接收一个已解码的 AVFrame
 * 对应 avcodec_receive_frame，必须与 sendPacket 配对使用。
 * 典型的异步循环模式：
 *   sendPacket(pkt) -> while (receiveFrame(frame) == 0) { 处理帧 }
 * @param frame 预先分配的 AVFrame，用于接收解码后的原始图像数据
 * @return 0 成功，AVERROR(EAGAIN) 表示需要发送更多数据，
 *         AVERROR_EOF 表示已完全耗尽（flush 后）
 */
- (int)receiveFrame:(AVFrame *)frame;

/**
 * 刷新解码器内部缓冲区
 * 在 seek 操作或切换流时调用，丢弃解码器内部缓存的帧数据。
 * 内部调用 avcodec_flush_buffers。
 */
- (void)flush;

/**
 * 关闭解码器，释放所有资源
 * 内部调用 avcodec_free_context 释放 AVCodecContext。
 * 可在 dealloc 中自动调用，也可手动提前释放。
 */
- (void)close;

@end

NS_ASSUME_NONNULL_END
