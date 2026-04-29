//
//  FFPacketQueue.h
//  ios_ffmpeg_demo
//
//  线程安全的 AVFoundation 数据包队列
//  基于 pthread 互斥锁和条件变量实现生产者-消费者模式
//  用于在解码线程和 demux 线程之间传递 AVPacket 数据
//

#import <Foundation/Foundation.h>
#import <libavcodec/avcodec.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  FFPacketQueue - 线程安全的 AVPacket 队列
 *
 *  使用链表结构存储 AVPacket，支持设置最大容量。
 *  提供线程安全的入队（put）和出队（get）操作，
 *  当队列满时阻塞生产者，队列空时阻塞消费者。
 *  支持清空（flush）、中止（abort）和重置（reset）操作。
 */
@interface FFPacketQueue : NSObject

/// 当前队列中的数据包数量（线程安全）
@property (nonatomic, readonly) NSUInteger count;

/// 当前队列中所有数据包的总字节大小（线程安全）
@property (nonatomic, readonly) NSUInteger size;

/**
 *  初始化队列并指定最大容量
 *
 *  @param capacity 队列可容纳的最大数据包数量
 *  @return 初始化后的 FFPacketQueue 实例
 */
- (instancetype)initWithCapacity:(NSUInteger)capacity;

/**
 *  将一个数据包放入队列
 *  如果队列已满，该方法会阻塞等待，直到有空间可用或队列被中止
 *
 *  @param packet 要放入队列的 AVPacket 指针
 *  @return YES 表示成功放入，NO 表示队列已被中止
 */
- (BOOL)putPacket:(AVPacket *)packet;

/**
 *  从队列中取出一个数据包
 *  如果队列为空，该方法会阻塞等待，直到有数据包可用或队列被中止
 *
 *  @param packet 用于接收取出的数据包的 AVPacket 指针
 *  @return YES 表示成功取出，NO 表示队列已被中止且队列为空
 */
- (BOOL)getPacket:(AVPacket *)packet;

/**
 *  清空队列中所有未处理的数据包
 *  释放所有节点内存并重置计数器和大小
 *  同时唤醒所有等待的生产者和消费者线程
 */
- (void)flush;

/**
 *  中止队列操作
 *  设置中止标志，唤醒所有等待的线程
 *  正在等待 put/get 的线程将立即返回
 *  用于播放停止或错误恢复场景
 */
- (void)abort;

/**
 *  重置队列的中止状态
 *  清除中止标志，使队列恢复正常工作状态
 *  通常在被 abort 后需要重新使用时调用
 */
- (void)reset;

@end

NS_ASSUME_NONNULL_END
