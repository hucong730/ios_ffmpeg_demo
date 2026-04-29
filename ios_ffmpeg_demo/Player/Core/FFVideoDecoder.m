//==============================================================================
// FFVideoDecoder.m
// iOS FFmpeg Demo
//
// 视频解码器实现文件
// 基于 FFmpeg libavcodec 的视频解码功能封装。
//
// 核心解码流程：
//   1. 查找解码器（avcodec_find_decoder）
//   2. 创建并配置解码器上下文（avcodec_alloc_context3 / avcodec_parameters_to_context）
//   3. 设置多线程解码参数（thread_count = 0 表示自动选择线程数）
//   4. 打开解码器（avcodec_open2）
//   5. 异步解码循环：sendPacket -> receiveFrame
//   6. 刷新（flush）和关闭（close）
//
// FFmpeg 的异步解码模型（avcodec_send_packet / avcodec_receive_frame）说明：
//   - 这两个函数构成一个"生产者-消费者"式的异步接口。
//   - sendPacket 将压缩数据包送入解码器的内部输入队列，不阻塞等待解码完成。
//   - receiveFrame 从解码器的内部输出队列取出一帧已解码数据。
//   - 典型调用模式：
//       while (数据未读完) {
//           sendPacket(pkt);
//           while (receiveFrame(frame) == 0) { 使用 frame; }
//       }
//     flush 阶段：
//       sendPacket(NULL);  // 通知解码器冲刷剩余帧
//       while (receiveFrame(frame) == 0) { 使用 frame; }
//==============================================================================

#import "FFVideoDecoder.h"

@implementation FFVideoDecoder {
    AVCodecContext *_codecContext;      // 视频解码器上下文，承载解码器的运行状态
    AVCodecParameters *_codecParams;    // 编解码参数（从容器层传入，解码器不拥有此对象）
}

//==============================================================================
#pragma mark - 初始化与销毁
//==============================================================================

/**
 * 使用编解码参数初始化解码器
 *
 * 此处仅保存传入的编解码参数引用，实际的解码器打开操作延迟到 open 方法中执行。
 * 这种"两阶段初始化"设计使得调用方可以在 init 和 open 之间进行其他配置，
 * 同时也便于错误处理——open 失败时只需销毁实例即可。
 *
 * @param params 从 AVStream->codecpar 获取的编解码参数，包含 codec_id、分辨率等
 * @return 初始化后的解码器实例
 */
- (instancetype)initWithCodecParameters:(AVCodecParameters *)params {
    self = [super init];
    if (self) {
        _codecParams = params;
        _codecContext = NULL;  // 初始化为 NULL，open 时真正创建
    }
    return self;
}

/**
 * 析构方法，确保解码器资源被释放
 * 当 Objective-C 对象的引用计数降为 0 时自动调用。
 */
- (void)dealloc {
    [self close];
}

//==============================================================================
#pragma mark - 解码器生命周期
//==============================================================================

/**
 * 打开视频解码器
 *
 * 完整的打开流程包含以下步骤：
 *   1. 根据 codec_id 查找对应的解码器实现
 *   2. 分配解码器上下文 AVCodecContext
 *   3. 将容器层的编解码参数拷贝到解码器上下文中
 *   4. 设置多线程解码参数（自动选择线程数，启用帧和片级并行）
 *   5. 调用 avcodec_open2 初始化解码器实例
 *   6. 读取解码后的元数据（宽、高、像素格式）
 *
 * @return YES 表示打开成功，NO 表示失败
 */
- (BOOL)open {
    // 步骤 1：根据 codec_id 查找解码器
    // codec_id 来自容器层解封装后的 AVCodecParameters，例如 AV_CODEC_ID_H264
    const AVCodec *codec = avcodec_find_decoder(_codecParams->codec_id);
    if (!codec) {
        NSLog(@"FFVideoDecoder: codec not found for id %d", _codecParams->codec_id);
        return NO;
    }

    // 步骤 2：分配解码器上下文
    // avcodec_alloc_context3 会为 codec 分配默认的 AVCodecContext 并设置合理的默认值
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) return NO;

    // 步骤 3：将容器层的编解码参数拷贝到解码器上下文
    // 这一步必不可少，否则解码器无法正确初始化解码参数（如分辨率、比特率等）
    int ret = avcodec_parameters_to_context(_codecContext, _codecParams);
    if (ret < 0) {
        NSLog(@"FFVideoDecoder: avcodec_parameters_to_context failed: %d", ret);
        [self close];
        return NO;
    }

    // 步骤 4：设置多线程解码参数
    // thread_count = 0 表示让 FFmpeg 自动选择合适的线程数（通常等于 CPU 核心数）
    // thread_type 同时启用 FF_THREAD_FRAME（帧级并行）和 FF_THREAD_SLICE（片级并行）
    // 帧级并行：多个帧同时解码；片级并行：一帧内多个 slice 同时解码
    _codecContext->thread_count = 0;
    _codecContext->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    // 步骤 5：打开解码器
    // avcodec_open2 会真正初始化解码器实例，分配内部缓冲区，准备解码所需的资源
    ret = avcodec_open2(_codecContext, codec, NULL);
    if (ret < 0) {
        NSLog(@"FFVideoDecoder: avcodec_open2 failed: %d", ret);
        [self close];
        return NO;
    }

    // 步骤 6：读取解码后的元数据
    // avcodec_open2 成功后，解码器上下文中会填充完整的编解码信息
    // 其中包括可能由解码器推导出的实际分辨率（某些编解码器的分辨率在 open 后才能确定）
    _width = _codecContext->width;
    _height = _codecContext->height;
    _pixelFormat = _codecContext->pix_fmt;

    return YES;
}

//==============================================================================
#pragma mark - 解码接口（异步模型）
//==============================================================================

/**
 * 向解码器发送一个 AVPacket 进行解码
 *
 * 这是 FFmpeg 异步解码模型的"生产者"端。
 * avcodec_send_packet 将压缩数据送入解码器的内部输入队列后立即返回，
 * 实际的解码工作可能在工作线程中异步进行。
 *
 * 返回值说明：
 *   - 0：成功接收数据包
 *   - AVERROR(EAGAIN)：解码器输入队列已满，需要先调用 receiveFrame 消耗输出
 *   - 其他负值：输入错误或解码器未打开
 *
 * 特殊用法：传 NULL 表示"冲刷"（flush）模式，
 * 此时解码器会尝试输出所有尚未取出的剩余帧。
 *
 * @param packet 待解码的 AVPacket，传 NULL 表示冲刷模式
 * @return 返回值 >= 0 表示成功，负值表示错误
 */
- (int)sendPacket:(AVPacket *)packet {
    if (!_codecContext) return AVERROR(EINVAL);
    return avcodec_send_packet(_codecContext, packet);
}

/**
 * 从解码器接收一个已解码的 AVFrame
 *
 * 这是 FFmpeg 异步解码模型的"消费者"端。
 * avcodec_receive_frame 从解码器的内部输出队列取出一帧解码后的原始图像数据。
 *
 * 返回值说明：
 *   - 0：成功获取一帧，frame 中包含完整解码数据
 *   - AVERROR(EAGAIN)：当前没有可输出的帧，需要发送更多数据包
 *   - AVERROR_EOF：解码器已完全耗尽（通常在 flush 后返回）
 *   - 其他负值：解码错误
 *
 * 使用方在收到 frame 后应尽快处理或拷贝，
 * 因为 frame 内部的数据指针指向解码器内部的缓冲区，
 * 下次调用 receiveFrame 时可能被覆盖。
 *
 * @param frame 预先分配的 AVFrame，用于接收解码后的图像数据
 * @return 0 成功，AVERROR(EAGAIN) 需要更多数据，AVERROR_EOF 解码结束
 */
- (int)receiveFrame:(AVFrame *)frame {
    if (!_codecContext) return AVERROR(EINVAL);
    return avcodec_receive_frame(_codecContext, frame);
}

//==============================================================================
#pragma mark - 刷新与关闭
//==============================================================================

/**
 * 刷新解码器内部缓冲区
 *
 * 在 seek 操作或切换视频轨道时需要调用此方法。
 * avcodec_flush_buffers 会丢弃解码器内部缓存的帧数据，
 * 重置解码器的状态机，使其恢复到可以接收新关键帧的初始状态。
 *
 * 注意：flush 后需要先 send NULL packet 来驱动解码器输出残留帧，
 * 然后才能发送新的关键帧数据。
 */
- (void)flush {
    if (_codecContext) {
        avcodec_flush_buffers(_codecContext);
    }
}

/**
 * 关闭解码器，释放所有资源
 *
 * avcodec_free_context 会：
 *   1. 关闭解码器（如果尚未关闭）
 *   2. 释放 AVCodecContext 内部所有动态分配的资源（缓冲区、线程等）
 *   3. 将传入的指针置为 NULL（传入的是 &_codecContext，所以本地指针也被置空）
 *
 * 此方法是幂等的，可以多次安全调用。
 */
- (void)close {
    if (_codecContext) {
        avcodec_free_context(&_codecContext);
        _codecContext = NULL;
    }
}

@end
