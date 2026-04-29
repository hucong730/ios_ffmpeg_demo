//
//  FFDemuxer.m
//  ios_ffmpeg_demo
//
//  解封装器（Demuxer）实现文件
//
//  本文件实现了 FFDemuxer 类，基于 FFmpeg 的 libavformat 库完成音视频文件的解封装工作。
//  libavformat 负责读取多媒体容器格式（如 MP4、FLV、TS、MOV 等），
//  并将封装的数据分离为独立的音频流和视频流数据包（AVPacket）。
//
//  核心流程：
//  1. 初始化：记录媒体 URL，初始化解封装器状态
//  2. 打开：初始化网络模块 -> 分配 AVFormatContext -> 打开输入 -> 探测流信息 -> 解析音视频参数
//  3. 读取：反复调用 av_read_frame() 获取下一个原始数据包
//  4. 定位：通过 av_seek_frame() 跳转到指定时间位置
//  5. 关闭：调用 avformat_close_input() 释放所有资源
//

#import "FFDemuxer.h"
#import <libavutil/avutil.h>

@implementation FFDemuxer {
    NSString *_urlString;           // 媒体文件的 URL 或本地路径
    AVFormatContext *_formatContext; // FFmpeg 解封装上下文，管理输入流的所有状态
}

/**
 * 初始化方法
 * 保存媒体 URL，并将流索引初始化为 -1（表示未找到对应的流）。
 * @param urlString 媒体文件的路径或网络 URL
 * @return 实例对象
 */
- (instancetype)initWithURL:(NSString *)urlString {
    self = [super init];
    if (self) {
        // 保存 URL 副本，避免外部字符串被修改影响内部状态
        _urlString = [urlString copy];
        _formatContext = NULL;
        // 流索引初始化为 -1，表示尚未找到对应的流
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
    }
    return self;
}

/**
 * 析构方法
 * 对象销毁时自动调用 close 释放解封装器资源，防止资源泄漏。
 */
- (void)dealloc {
    [self close];
}

/**
 * 打开媒体文件/网络流
 *
 * 执行步骤：
 * 1. avformat_network_init() —— 初始化 FFmpeg 网络模块（仅首次调用有效），
 *    使 FFmpeg 能够通过 HTTP/HTTPS/RTMP 等网络协议读取远程媒体流。
 * 2. avformat_alloc_context() —— 分配并初始化 AVFormatContext 结构体。
 * 3. avformat_open_input() —— 打开输入文件或网络流，读取容器头部信息。
 *    这里通过 AVDictionary 设置了超时和断线重连参数，用于网络流场景。
 * 4. avformat_find_stream_info() —— 从媒体文件中探测并读取各流（音视频）的详细信息，
 *    包括编码参数、时长等。需要单独调用，因为 avformat_open_input 只读取容器头部，
 *    不一定包含完整的流信息（尤其是某些封装格式需要读取部分数据才能确定）。
 * 5. av_find_best_stream() —— 自动选择最佳的音频流和视频流索引。
 * 6. 解析音视频参数：从对应的 AVStream 的 codecpar 中提取编码参数、时基、帧率等元数据。
 * 7. 计算总时长：AVFormatContext->duration 以 AV_TIME_BASE（微秒）为单位，
 *    除以 AV_TIME_BASE 转换为秒。
 *
 * @return YES 表示成功，NO 表示失败
 */
- (BOOL)open {
    // 初始化 FFmpeg 网络模块，使 avformat_open_input 支持 http、https、rtmp 等协议
    // 该函数内部有保护，多次调用仅首次生效
    avformat_network_init();

    // 分配 AVFormatContext 结构体，FFmpeg 通过它管理输入流的全部状态
    _formatContext = avformat_alloc_context();
    if (!_formatContext) return NO;

    // 设置打开选项：通过 AVDictionary 传递键值对参数给 avformat_open_input
    AVDictionary *options = NULL;
    av_dict_set(&options, "timeout", "10000000", 0);   // 设置 IO 超时时间为 10 秒（单位：微秒）
    av_dict_set(&options, "reconnect", "1", 0);        // 启用断线重连，适用于不稳定的网络流

    // 打开输入媒体文件或网络流
    // 参数：_formatContext 会被填充流信息；urlString 转为 UTF8 C 字符串；
    //       NULL 表示自动选择解封装器（demuxer）；options 传入额外参数
    int ret = avformat_open_input(&_formatContext, [_urlString UTF8String], NULL, &options);
    av_dict_free(&options); // 使用完毕后释放 options 字典
    if (ret < 0) {
        NSLog(@"FFDemuxer: avformat_open_input failed: %d", ret);
        return NO;
    }

    // 从媒体文件中探测完整的流信息（编码参数、时长等）
    // 有些容器格式（如 MP4）的流信息在文件尾部，需要 avformat_find_stream_info 读取并解析
    ret = avformat_find_stream_info(_formatContext, NULL);
    if (ret < 0) {
        NSLog(@"FFDemuxer: avformat_find_stream_info failed: %d", ret);
        [self close];
        return NO;
    }

    // 自动寻找最佳的视频流索引（-1 表示没有视频流）
    _videoStreamIndex = av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    // 自动寻找最佳的音频流索引（-1 表示没有音频流）
    _audioStreamIndex = av_find_best_stream(_formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);

    // 如果存在视频流，解析其编码参数和元数据
    if (_videoStreamIndex >= 0) {
        AVStream *stream = _formatContext->streams[_videoStreamIndex];
        // codecpar 包含初始化对应解码器所需的所有编码参数
        _videoCodecParameters = stream->codecpar;
        // 视频流的时基（time_base），用于将数据包的 PTS/DTS 转换为秒：
        // seconds = pts * time_base.num / time_base.den
        _videoTimeBase = stream->time_base;
        _videoWidth = _videoCodecParameters->width;         // 视频宽度（像素）
        _videoHeight = _videoCodecParameters->height;       // 视频高度（像素）
        _videoPixelFormat = (enum AVPixelFormat)_videoCodecParameters->format; // 像素格式

        // 估算视频的实际帧率
        // av_guess_frame_rate 通过分析流的时间基和帧间隔来估算帧率，
        // 适用于可变帧率（VFR）和固定帧率（CFR）的场景
        AVRational frameRate = av_guess_frame_rate(_formatContext, stream, NULL);
        if (frameRate.den > 0 && frameRate.num > 0) {
            // av_q2d 将 AVRational 有理数转换为 double：num / den
            _videoFPS = av_q2d(frameRate);
        } else {
            // 如果无法获取帧率，默认使用 30 FPS
            _videoFPS = 30.0;
        }
    }

    // 如果存在音频流，解析其编码参数和元数据
    if (_audioStreamIndex >= 0) {
        AVStream *stream = _formatContext->streams[_audioStreamIndex];
        _audioCodecParameters = stream->codecpar;
        _audioTimeBase = stream->time_base;              // 音频流的时基
        _audioSampleRate = _audioCodecParameters->sample_rate; // 采样率（Hz）
        _audioChannels = _audioCodecParameters->ch_layout.nb_channels; // 声道数
        _audioSampleFormat = (enum AVSampleFormat)_audioCodecParameters->format; // 采样格式
        _audioChannelLayout = _audioCodecParameters->ch_layout; // 声道布局
    }

    // 计算媒体总时长
    // AVFormatContext->duration 以 AV_TIME_BASE 为单位（微秒，AV_TIME_BASE = 1,000,000）
    // AV_NOPTS_VALUE 表示时长未知（如某些直播流）
    if (_formatContext->duration != AV_NOPTS_VALUE) {
        // 将微秒转换为秒：duration_in_seconds = duration_in_microseconds / AV_TIME_BASE
        _duration = (double)_formatContext->duration / AV_TIME_BASE;
    } else {
        _duration = 0;
    }

    return YES;
}

/**
 * 读取一个原始音视频数据包
 *
 * 内部调用 av_read_frame()，每次返回一个 AVPacket。
 * 返回值规则：
 * - 0：成功读取一个数据包
 * - AVERROR_EOF：已读取到文件结尾
 * - 其他负值：读取错误
 *
 * 注意：调用方在数据处理完毕后必须调用 av_packet_unref(packet) 释放包内数据，
 *       否则会导致内存泄漏。
 *
 * @param packet 输出参数，存放读取到的数据包
 * @return 0 成功，负数失败/结束
 */
- (int)readPacket:(AVPacket *)packet {
    if (!_formatContext) return AVERROR_EOF;
    // av_read_frame 返回下一个音视频数据包（已分配好数据缓冲区）
    return av_read_frame(_formatContext, packet);
}

/**
 * 跳转到指定的时间位置（Seek）
 *
 * 将传入的秒数转换为 AV_TIME_BASE 时基的微秒时间戳，然后调用 av_seek_frame。
 * 使用 AVSEEK_FLAG_BACKWARD 标志表示 Seek 到指定时间之前的最近关键帧，
 * 这样可以保证解码器能从关键帧开始正确解码。
 *
 * @param seconds 目标时间位置，单位：秒
 */
- (void)seekToTime:(double)seconds {
    if (!_formatContext) return;
    // 将秒转换为 AV_TIME_BASE 时基下的时间戳：timestamp = seconds * AV_TIME_BASE
    // AV_TIME_BASE = 1,000,000（微秒），所以实际是 seconds * 1,000,000
    int64_t timestamp = (int64_t)(seconds * AV_TIME_BASE);
    // av_seek_frame 执行跳转：
    // 参数：stream_index = -1 表示以 AV_TIME_BASE 为时基，在所有流中跳转；
    //       AVSEEK_FLAG_BACKWARD 表示跳转到指定时间之前的最近关键帧
    av_seek_frame(_formatContext, -1, timestamp, AVSEEK_FLAG_BACKWARD);
}

/**
 * 关闭解封装器，释放资源
 *
 * 调用 avformat_close_input() 会执行以下操作：
 * 1. 关闭输入文件或网络连接
 * 2. 释放 AVFormatContext 及其内部所有子结构体（streams 等）
 * 3. 将传入的指针置为 NULL
 *
 * 同时重置所有流索引和参数指针，防止野指针访问。
 */
- (void)close {
    if (_formatContext) {
        // avformat_close_input 会关闭流并释放 AVFormatContext 及其所有内部资源
        // 传入 &_formatContext 会将 _formatContext 置为 NULL
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    // 重置所有流相关状态，避免后续误用
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    _videoCodecParameters = NULL;
    _audioCodecParameters = NULL;
}

@end
