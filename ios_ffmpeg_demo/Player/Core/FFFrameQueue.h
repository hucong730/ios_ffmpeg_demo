//==============================================================================
// FFFrameQueue.h
// iOS FFmpeg Demo
//
// 简介：该文件定义了视频帧和音频帧的数据结构，以及对应的线程安全队列。
// 视频帧队列（FFVideoFrameQueue）和音频帧队列（FFAudioFrameQueue）均基于
// 链表和 pthread 互斥锁 + 条件变量实现，支持多线程环境下的生产-消费模式。
//==============================================================================

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

//==============================================================================
// FFVideoFrame — 视频帧结构体
// 包含一个 CVPixelBuffer（视频像素数据）、PTS（显示时间戳）和时长。
//==============================================================================
typedef struct {
    CVPixelBufferRef pixelBuffer;   // 视频帧的像素缓冲（CVPixelBuffer），由 CoreVideo 管理
    double pts;                      // 显示时间戳（Presentation Timestamp），单位秒
    double duration;                 // 该帧的持续时间，单位秒
} FFVideoFrame;

//==============================================================================
// FFAudioFrame — 音频帧结构体
// 包含 PCM 音频数据缓冲区、数据大小、读取偏移量以及 PTS。
//==============================================================================
typedef struct {
    uint8_t *data;   // PCM 音频数据缓冲区指针（堆上分配的内存）
    int size;        // 音频数据的总大小（字节数）
    int offset;      // 当前读取的偏移量（用于跟踪已消费的数据位置）
    double pts;      // 该音频帧的显示时间戳，单位秒
} FFAudioFrame;

//==============================================================================
// FFVideoFrameQueue — 线程安全的视频帧队列
// 基于链表实现的有界队列，支持 put/get/peek 操作。
// 使用 pthread_mutex 保证互斥，使用条件变量实现生产者和消费者之间的同步等待。
//==============================================================================
@interface FFVideoFrameQueue : NSObject

// 队列中当前缓存的视频帧数量（线程安全读取）
@property (nonatomic, readonly) NSUInteger count;

// 初始化队列，指定最大容量（最多可缓存的帧数）
- (instancetype)initWithCapacity:(NSUInteger)capacity;

// 向队列尾部放入一帧视频数据。
// 如果队列已满则阻塞等待，直到有空闲位置或队列被终止。
// 返回 YES 表示放入成功，NO 表示队列已终止。
- (BOOL)putFrame:(FFVideoFrame)frame;

// 从队列头部取出一帧视频数据（阻塞模式）。
// 如果队列为空则阻塞等待，直到有新帧或队列被终止。
// 返回 YES 表示取出成功，NO 表示队列为空且已终止。
- (BOOL)getFrame:(FFVideoFrame *)frame;

// 窥视队列头部的一帧视频数据（非阻塞，不移除）。
// 如果队列为空则直接返回 NO。
- (BOOL)peekFrame:(FFVideoFrame *)frame;

// 清空队列中所有缓存的视频帧，释放相关内存，并唤醒所有等待的线程。
- (void)flush;

// 终止队列，唤醒所有等待的线程。终止后 putFrame 和 getFrame 将返回 NO。
- (void)abort;

// 重置队列的终止状态，使队列恢复正常工作。
- (void)reset;

@end

//==============================================================================
// FFAudioFrameQueue — 线程安全的音频帧队列
// 与 FFVideoFrameQueue 结构类似，但操作的是音频帧数据。
// 额外提供 tryGetFrame 非阻塞获取方法。
//==============================================================================
@interface FFAudioFrameQueue : NSObject

// 队列中当前缓存的音频帧数量（线程安全读取）
@property (nonatomic, readonly) NSUInteger count;

// 初始化队列，指定最大容量
- (instancetype)initWithCapacity:(NSUInteger)capacity;

// 向队列尾部放入一帧音频数据（阻塞模式）
- (BOOL)putFrame:(FFAudioFrame)frame;

// 从队列头部取出一帧音频数据（阻塞模式）
- (BOOL)getFrame:(FFAudioFrame *)frame;

// 尝试从队列头部取出一帧音频数据（非阻塞模式）。
// 如果队列为空则立即返回 NO，不会阻塞等待。
- (BOOL)tryGetFrame:(FFAudioFrame *)frame;

// 清空队列中所有缓存的音频帧，释放相关内存
- (void)flush;

// 终止队列，唤醒所有等待的线程
- (void)abort;

// 重置队列的终止状态
- (void)reset;

@end

NS_ASSUME_NONNULL_END
