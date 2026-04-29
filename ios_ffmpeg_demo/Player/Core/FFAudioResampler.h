//
//  FFAudioResampler.h
//  ios_ffmpeg_demo
//
//  音频重采样封装类
//  负责将解码后的音频帧（原始采样率、声道布局、样本格式）统一重采样为：
//   - 输出采样率 = 输入采样率（不变）
//   - 输出声道数 = 2（立体声 Stereo）
//   - 输出样本格式 = AV_SAMPLE_FMT_S16（16 位有符号整型）
//  这样做的目的是让音频播放器（如 AudioQueue、AudioUnit）能够以统一的格式消费数据，
//  而不需要关心原始音频的多样性（如单声道/5.1 声道、float/int 格式等）。
//

#import <Foundation/Foundation.h>
#import <libswresample/swresample.h>
#import <libavutil/channel_layout.h>
#import <libavutil/samplefmt.h>
#import <libavcodec/avcodec.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFAudioResampler : NSObject

// 输出采样率，与输入采样率保持一致（不做采样率转换）
@property (nonatomic, readonly) int outputSampleRate;
// 输出声道数，固定为 2（立体声）
@property (nonatomic, readonly) int outputChannels;

/**
 * 初始化重采样器
 *
 * @param srcRate   原始音频采样率（如 44100、48000）
 * @param srcLayout 原始声道布局（如 AV_CHANNEL_LAYOUT_STEREO、AV_CHANNEL_LAYOUT_MONO）
 * @param srcFmt    原始样本格式（如 AV_SAMPLE_FMT_FLTP、AV_SAMPLE_FMT_S16P）
 * @return 重采样器实例
 */
- (instancetype)initWithSourceSampleRate:(int)srcRate
                     sourceChannelLayout:(AVChannelLayout)srcLayout
                            sourceFormat:(enum AVSampleFormat)srcFmt;

/**
 * 打开重采样器，初始化 swr 上下文
 * 内部调用 swr_alloc_set_opts2 + swr_init 完成配置和初始化
 *
 * @return YES 表示成功，NO 表示失败
 */
- (BOOL)open;

/**
 * 对单个音频帧执行重采样
 *
 * @param frame   输入的音频帧（AVFrame）
 * @param outBuf  输出缓冲区指针（调用者需通过 av_free 释放）
 * @param outSize 输出数据大小（字节数）
 * @return 成功时返回重采样后的样本数（每个声道），失败返回负值
 */
- (int)resampleFrame:(AVFrame *)frame
        outputBuffer:(uint8_t *_Nullable *_Nonnull)outBuf
          outputSize:(int *)outSize;

/**
 * 关闭重采样器，释放所有内部资源
 */
- (void)close;

@end

NS_ASSUME_NONNULL_END
