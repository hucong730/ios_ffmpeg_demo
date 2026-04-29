//==============================================================================
// FFAudioDecoder.m
// iOS FFmpeg Demo
//
// 音频解码器实现文件
// 基于 FFmpeg libavcodec 的音频解码功能封装。
//
// 核心解码流程：
//   1. 查找解码器（avcodec_find_decoder）
//   2. 创建并配置解码器上下文（avcodec_alloc_context3 / avcodec_parameters_to_context）
//   3. 打开解码器（avcodec_open2）
//   4. 异步解码循环：sendPacket -> receiveFrame
//   5. 刷新（flush）和关闭（close）
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
//
// 与视频解码不同，音频解码一般不需要设置多线程（thread_count），
// 因为音频帧通常较小，解码速度快，多线程收益有限。
//==============================================================================

#import "FFAudioDecoder.h"

@implementation FFAudioDecoder {
    AVCodecContext *_codecContext;      // 音频解码器上下文，承载解码器的运行状态
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
 * @param params 从 AVStream->codecpar 获取的编解码参数，包含 codec_id、采样率、声道布局等
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
 * 打开音频解码器
 *
 * 完整的打开流程包含以下步骤：
 *   1. 根据 codec_id 查找对应的解码器实现
 *   2. 分配解码器上下文 AVCodecContext
 *   3. 将容器层的编解码参数拷贝到解码器上下文中
 *   4. 调用 avcodec_open2 初始化解码器实例
 *   5. 读取解码后的元数据（采样率、声道数、采样格式、声道布局）
 *
 * @return YES 表示打开成功，NO 表示失败
 */
- (BOOL)open {
    // 步骤 1：根据 codec_id 查找解码器
    // codec_id 来自容器层解封装后的 AVCodecParameters，例如 AV_CODEC_ID_AAC
    const AVCodec *codec = avcodec_find_decoder(_codecParams->codec_id);
    if (!codec) {
        NSLog(@"FFAudioDecoder: codec not found for id %d", _codecParams->codec_id);
        return NO;
    }

    // 步骤 2：分配解码器上下文
    // avcodec_alloc_context3 会为 codec 分配默认的 AVCodecContext 并设置合理的默认值
    _codecContext = avcodec_alloc_context3(codec);
    if (!_codecContext) return NO;

    // 步骤 3：将容器层的编解码参数拷贝到解码器上下文
    // avcodec_parameters_to_context 负责将 AVCodecParameters 中的字段
    // （如 sample_rate、ch_layout、sample_fmt 等）同步到 AVCodecContext 中。
    // 这一步必不可少，否则解码器无法正确初始化解码参数。
    int ret = avcodec_parameters_to_context(_codecContext, _codecParams);
    if (ret < 0) {
        NSLog(@"FFAudioDecoder: avcodec_parameters_to_context failed: %d", ret);
        [self close];
        return NO;
    }

    // 步骤 4：打开解码器
    // avcodec_open2 会真正初始化解码器实例，分配内部缓冲区（如 bitstream buffer），
    // 准备解码所需的资源。对于音频解码器，还会初始化内部的音频处理模块。
    ret = avcodec_open2(_codecContext, codec, NULL);
    if (ret < 0) {
        NSLog(@"FFAudioDecoder: avcodec_open2 failed: %d", ret);
        [self close];
        return NO;
    }

    // 步骤 5：读取解码后的元数据
    // avcodec_open2 成功后，从解码器上下文中提取音频属性信息。
    // 这些信息将用于后续的音频重采样和播放配置。
    _sampleRate = _codecContext->sample_rate;             // 采样率，如 44100 Hz
    _channels = _codecContext->ch_layout.nb_channels;     // 声道数，如 2（立体声）
    _sampleFormat = _codecContext->sample_fmt;             // 采样格式，如 AV_SAMPLE_FMT_FLTP
    _channelLayout = _codecContext->ch_layout;             // 声道布局结构体

    return YES;
}

//==============================================================================
#pragma mark - 解码接口（异步模型）
//==============================================================================

/**
 * 向解码器发送一个 AVPacket 进行解码
 *
 * 这是 FFmpeg 异步解码模型的"生产者"端。
 * avcodec_send_packet 将压缩音频数据送入解码器的内部输入队列后立即返回，
 * 解码器会在内部维护的输入缓冲区中积累数据，当积累到足够解码一帧时进行解码。
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
 * avcodec_receive_frame 从解码器的内部输出队列取出一帧解码后的原始 PCM 音频数据。
 *
 * 返回值说明：
 *   - 0：成功获取一帧，frame 中包含完整的 PCM 音频数据
 *   - AVERROR(EAGAIN)：当前没有可输出的帧，需要发送更多数据包
 *   - AVERROR_EOF：解码器已完全耗尽（通常在 flush 后返回）
 *   - 其他负值：解码错误
 *
 * 接收到的 AVFrame 中包含以下重要字段：
 *   - data[]：音频数据数组（对于平面格式，如 FLTP，每个声道有独立的数据指针）
 *   - linesize[]：每个数据平面的字节数
 *   - nb_samples：本帧包含的采样点数
 *   - sample_rate：采样率
 *   - ch_layout：声道布局
 *   - format：采样格式
 *
 * @param frame 预先分配的 AVFrame，用于接收解码后的 PCM 音频数据
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
 * 在 seek 操作或切换音频轨道时需要调用此方法。
 * avcodec_flush_buffers 会丢弃解码器内部缓存的帧数据，
 * 重置解码器的状态机，使其恢复到可以接收新数据的初始状态。
 *
 * 注意：flush 后需要先 send NULL packet 来驱动解码器输出残留帧，
 * 然后才能发送新的数据包开始正常解码。
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
 *   2. 释放 AVCodecContext 内部所有动态分配的资源
 *      （音频解码器会释放 bitstream 缓冲区、内部解码状态等）
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
