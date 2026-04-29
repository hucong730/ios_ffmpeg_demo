//
//  FFDemuxer.h
//  ios_ffmpeg_demo
//
//  解封装器（Demuxer）接口文件
//
//  该文件定义了 FFDemuxer 类，负责对音视频文件或网络流进行解封装（demuxing）。
//  解封装是 FFmpeg 播放流程的第一步，将输入文件/流中的音视频数据包（packet）分离出来，
//  并为后续的解码（decoding）步骤提供必要的流信息，如视频编码参数、音频编码参数、
//  时长、帧率等元数据。
//
//  核心职责：
//  1. 打开输入文件或网络流（支持 HTTP/HTTPS 等协议）
//  2. 探测并读取流信息（视频流、音频流等）
//  3. 提供按序读取原始数据包（AVPacket）的能力
//  4. 支持按时间定位（Seek）
//  5. 播放结束时关闭并释放资源
//

#import <Foundation/Foundation.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFDemuxer : NSObject

// 视频流在 AVFormatContext->streams 数组中的索引，-1 表示没有视频流
@property (nonatomic, readonly) int videoStreamIndex;
// 音频流在 AVFormatContext->streams 数组中的索引，-1 表示没有音频流
@property (nonatomic, readonly) int audioStreamIndex;

// 视频流的编码参数（codec parameters），用于初始化解码器
@property (nonatomic, readonly, nullable) AVCodecParameters *videoCodecParameters;
// 音频流的编码参数（codec parameters），用于初始化解码器
@property (nonatomic, readonly, nullable) AVCodecParameters *audioCodecParameters;

// 媒体文件的总时长，单位：秒
@property (nonatomic, readonly) double duration;

// 视频流的时基（time base），用于将 PTS/DTS 转换为秒：seconds = pts * (num / den)
@property (nonatomic, readonly) AVRational videoTimeBase;
// 音频流的时基（time base），用于将 PTS/DTS 转换为秒：seconds = pts * (num / den)
@property (nonatomic, readonly) AVRational audioTimeBase;

// 视频宽度（像素）
@property (nonatomic, readonly) int videoWidth;
// 视频高度（像素）
@property (nonatomic, readonly) int videoHeight;
// 视频帧率（frames per second），如 29.97、60.0 等
@property (nonatomic, readonly) double videoFPS;

// 音频采样率（Hz），如 44100、48000
@property (nonatomic, readonly) int audioSampleRate;
// 音频声道数，如 1（单声道）、2（立体声）
@property (nonatomic, readonly) int audioChannels;

// 视频像素格式，如 AV_PIX_FMT_YUV420P
@property (nonatomic, readonly) enum AVPixelFormat videoPixelFormat;
// 音频采样格式，如 AV_SAMPLE_FMT_FLTP
@property (nonatomic, readonly) enum AVSampleFormat audioSampleFormat;
// 音频声道布局，如 AV_CHANNEL_LAYOUT_STEREO
@property (nonatomic, readonly) AVChannelLayout audioChannelLayout;

/**
 * 初始化方法
 * @param urlString 媒体文件的本地路径或网络 URL 字符串
 * @return 实例对象
 */
- (instancetype)initWithURL:(NSString *)urlString;

/**
 * 打开媒体文件/网络流并探测流信息
 * 内部会依次调用 avformat_network_init()、avformat_open_input()、avformat_find_stream_info()，
 * 并解析出视频流、音频流的相关参数。
 * @return YES 表示成功，NO 表示失败
 */
- (BOOL)open;

/**
 * 读取一个原始数据包（AVPacket）
 * 每次调用返回下一个音视频数据包，由调用方负责 av_packet_unref() 释放。
 * @param packet 输出参数，用于接收读取到的数据包
 * @return 0 表示成功，负数表示错误或 EOF（AVERROR_EOF）
 */
- (int)readPacket:(AVPacket *)packet;

/**
 * 跳转到指定的时间位置（Seek）
 * @param seconds 目标时间位置，单位：秒
 */
- (void)seekToTime:(double)seconds;

/**
 * 关闭解封装器，释放所有相关资源
 * 包括关闭 AVFormatContext、重置流索引和参数指针。
 */
- (void)close;

@end

NS_ASSUME_NONNULL_END
