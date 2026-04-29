//
//  FFAudioResampler.m
//  ios_ffmpeg_demo
//
//  音频重采样器的具体实现
//
//  核心职责：
//  利用 FFmpeg 的 libswresample 库，将解码后的 AVFrame 音频数据
//  统一转换为固定的目标格式（立体声 S16、同采样率），以便后续送入
//  iOS 的音频播放单元（AudioQueue / AudioUnit）进行播放。
//
//  设计思路：
//  - 目标采样率 = 源采样率：本类仅处理声道布局和样本格式的转换，
//    不做采样率变换。如需变采样率，可由外部或上层模块处理。
//  - 目标声道 = 立体声（Stereo）：iOS 设备的音频输出通常是立体声，
//    统一为 Stereo 可简化下游播放逻辑。
//  - 目标格式 = AV_SAMPLE_FMT_S16：iOS AudioQueue/AudioUnit
//    对 S16 (signed 16-bit integer) 格式的支持最为广泛和高效，
//    同时也是最通用的 PCM 交换格式。
//
//  关键 API 说明：
//  - swr_alloc_set_opts2：libswresample 的现代 API，使用
//    AVChannelLayout 结构体（而非已废弃的 uint64_t channel_layout）。
//    该函数一次性完成 SwrContext 的分配和参数设置。
//  - swr_init：根据已设置的参数完成内部查找表、滤波器的初始化。
//  - swr_convert：执行实际的重采样转换。
//  - swr_get_out_samples：预估给定输入样本数对应的最大输出样本数，
//    用于提前分配足够大的输出缓冲区。
//

#import "FFAudioResampler.h"

@implementation FFAudioResampler {
    SwrContext *_swrContext;         // libswresample 重采样上下文
    int _srcSampleRate;              // 源音频采样率
    AVChannelLayout _srcLayout;      // 源声道布局
    enum AVSampleFormat _srcFormat;  // 源样本格式
    uint8_t *_outputBuffer;          // 内部暂存输出缓冲区（swr_convert 写入目标）
    int _outputBufferSize;           // 内部缓冲区已分配大小（字节）
}

/**
 * 初始化方法：记录源音频参数，设置默认输出参数
 *
 * @param srcRate   源采样率
 * @param srcLayout 源声道布局
 * @param srcFmt    源样本格式
 * @return 实例对象
 */
- (instancetype)initWithSourceSampleRate:(int)srcRate
                     sourceChannelLayout:(AVChannelLayout)srcLayout
                            sourceFormat:(enum AVSampleFormat)srcFmt {
    self = [super init];
    if (self) {
        // 保存源音频参数，供后续 open / resample 使用
        _srcSampleRate = srcRate;
        _srcLayout = srcLayout;
        _srcFormat = srcFmt;

        // 初始状态：所有指针置空，缓冲区大小归零
        _swrContext = NULL;
        _outputBuffer = NULL;
        _outputBufferSize = 0;

        // 输出参数初始化
        // 输出采样率与源采样率保持一致（本类不做采样率变换）
        _outputSampleRate = srcRate;
        // 输出声道数固定为 2（立体声），这是 iOS 音频播放最通用的配置
        _outputChannels = 2;
    }
    return self;
}

/**
 * dealloc 时确保资源释放
 */
- (void)dealloc {
    [self close];
}

/**
 * 打开重采样器
 *
 * 步骤：
 *  1. 声明目标声道布局为立体声（AV_CHANNEL_LAYOUT_STEREO）
 *  2. 调用 swr_alloc_set_opts2 分配并设置 SwrContext
 *  3. 调用 swr_init 完成内部初始化
 *
 * 关于 swr_alloc_set_opts2 的说明：
 *  这是 libswresample 推荐的现代 API，与旧的 swr_alloc_set_opts 相比，
 *  它使用 AVChannelLayout 结构体（支持更丰富的声道布局描述，如 7.1、22.2 等），
 *  而不是已废弃的 uint64_t bitmask 方式。
 *
 *  参数含义（按顺序）：
 *    - _swrContext:     输出参数，指向分配后的 SwrContext
 *    - &outLayout:      目标声道布局（立体声）
 *    - AV_SAMPLE_FMT_S16: 目标样本格式（16 位有符号整型）
 *    - _srcSampleRate:  目标采样率（与源相同）
 *    - &_srcLayout:     源声道布局
 *    - _srcFormat:      源样本格式
 *    - _srcSampleRate:  源采样率
 *    - 0, NULL:         日志参数，传 0 和 NULL 表示不启用日志
 *
 * @return YES 表示成功，NO 表示失败
 */
- (BOOL)open {
    // 定义目标声道布局为立体声
    // 选择 Stereo 的原因：iOS 设备扬声器和耳机均为立体声输出，
    // 将任意源声道（单声道、5.1 等）统一混音为立体声是最通用的处理方式
    AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;

    // 使用现代 API swr_alloc_set_opts2 一次性完成分配和参数设置
    // 注意：该 API 会内部分配 SwrContext，调用者无需预先分配
    int ret = swr_alloc_set_opts2(&_swrContext,
                                   &outLayout,            // 目标声道布局：立体声
                                   AV_SAMPLE_FMT_S16,     // 目标样本格式：S16（16-bit signed int）
                                   _srcSampleRate,        // 目标采样率：与源一致
                                   &_srcLayout,           // 源声道布局
                                   _srcFormat,            // 源样本格式
                                   _srcSampleRate,        // 源采样率
                                   0, NULL);              // 日志选项（不使用）
    if (ret < 0 || !_swrContext) {
        // swr_alloc_set_opts2 失败，可能原因：不支持的格式组合、无效参数等
        NSLog(@"FFAudioResampler: swr_alloc_set_opts2 failed: %d", ret);
        return NO;
    }

    // 初始化 SwrContext：根据已设置的参数构建内部重采样所需的
    // 转换矩阵、滤波器系数等，这一步必须在 swr_convert 之前完成
    ret = swr_init(_swrContext);
    if (ret < 0) {
        NSLog(@"FFAudioResampler: swr_init failed: %d", ret);
        // 初始化失败时需要手动释放已分配的 SwrContext
        swr_free(&_swrContext);
        return NO;
    }

    return YES;
}

/**
 * 对单个音频帧执行重采样
 *
 * 处理流程：
 *  1. 通过 swr_get_out_samples 预估最大输出样本数
 *  2. 根据预估样本数分配/扩展内部缓冲区
 *  3. 调用 swr_convert 执行重采样
 *  4. 将重采样后的数据拷贝到新分配的缓冲区并返回给调用者
 *
 * 注意：输出缓冲区由调用者通过 av_free 释放（本方法内使用 malloc 分配，
 *       但遵循 FFmpeg 惯例由 av_free 释放是安全的，因为 av_free 内部
 *       也是对 free 的封装）。
 *
 * @param frame   输入音频帧
 * @param outBuf  输出缓冲区指针的指针（方法内分配内存）
 * @param outSize 输出数据大小（字节数）
 * @return 成功时返回每个声道的输出样本数，失败返回负值
 */
- (int)resampleFrame:(AVFrame *)frame
        outputBuffer:(uint8_t **)outBuf
          outputSize:(int *)outSize {
    // 确保重采样器已成功初始化
    if (!_swrContext) return -1;

    // swr_get_out_samples 根据输入样本数和内部重采样参数，
    // 返回可能的最大输出样本数（这是上限估计，实际输出可能小于此值）。
    // 用这个值来预分配输出缓冲区可以保证缓冲区足够大，避免溢出。
    int outSamples = swr_get_out_samples(_swrContext, frame->nb_samples);

    // 计算所需的缓冲区大小（字节数）
    // 输出格式为 S16（每个样本 2 字节），声道数为 _outputChannels（2）
    // 所以总字节数 = 输出样本数 × 声道数 × sizeof(int16_t)
    int requiredSize = outSamples * _outputChannels * sizeof(int16_t);

    // 如果当前缓冲区不够大，则重新分配
    // 使用 "所需大小 × 2" 的策略来避免频繁 realloc：
    // 这是一个常见的空间换时间优化——每次扩容都翻倍，
    // 可以减少后续帧的内存分配次数
    if (requiredSize > _outputBufferSize) {
        // 释放旧缓冲区
        if (_outputBuffer) free(_outputBuffer);
        // 分配新缓冲区，大小翻倍以减少未来重新分配的概率
        _outputBufferSize = requiredSize * 2;
        _outputBuffer = (uint8_t *)malloc(_outputBufferSize);
    }

    // 执行重采样
    // swr_convert 参数说明：
    //   - 第一个参数：SwrContext
    //   - 第二个参数：输出缓冲区数组（这里只有一个平面，因为 S16 是 packed 格式）
    //   - 第三个参数：输出缓冲区中每个声道可容纳的最大样本数
    //   - 第四个参数：输入缓冲区数组（frame->extended_data 是 AVFrame 的数据指针数组）
    //   - 第五个参数：输入样本数
    // 返回值：每个声道实际输出的样本数，失败返回负值
    // 注意：frame->extended_data 在大多数情况下与 frame->data 指向相同，
    //       但对于 planar 格式，extended_data 包含了所有声道的数据指针
    int converted = swr_convert(_swrContext,
                                 &_outputBuffer, outSamples,
                                 (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (converted < 0) {
        NSLog(@"FFAudioResampler: swr_convert failed: %d", converted);
        return converted;
    }

    // 计算实际输出的数据大小
    // converted 是每个声道的样本数，乘以声道数和样本字节数得到总字节数
    int dataSize = converted * _outputChannels * sizeof(int16_t);

    // 将重采样后的数据拷贝到新分配的缓冲区
    // 之所以要再拷贝一次而不是直接返回 _outputBuffer，是因为：
    // 1) _outputBuffer 是内部缓冲区，下次调用会被覆写
    // 2) 调用者需要获得一块独立的内存，由调用者负责生命周期管理
    uint8_t *buf = (uint8_t *)malloc(dataSize);
    memcpy(buf, _outputBuffer, dataSize);

    // 通过指针参数返回输出缓冲区和大小
    *outBuf = buf;
    *outSize = dataSize;

    // 返回每个声道的输出样本数
    return converted;
}

/**
 * 关闭重采样器，释放所有内部资源
 *
 * 需要释放的资源：
 *  1. SwrContext —— 通过 swr_free 释放，该函数会将指针置为 NULL
 *  2. 内部输出缓冲区 —— 通过 free 释放
 *
 * 这个方法在 dealloc 中也会被调用，同时也可以在播放中途
 * 主动调用以提前释放资源。
 */
- (void)close {
    // 释放重采样上下文
    if (_swrContext) {
        // swr_free 会先调用 swr_close 清理内部状态，然后释放内存，
        // 最后将指针置为 NULL
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    // 释放内部输出缓冲区
    if (_outputBuffer) {
        free(_outputBuffer);
        _outputBuffer = NULL;
        _outputBufferSize = 0;
    }
}

@end
