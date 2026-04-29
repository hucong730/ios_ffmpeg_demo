//
//  FFPacketQueue.m
//  ios_ffmpeg_demo
//
//  基于链表的线程安全 AVPacket 队列实现
//  使用 pthread 互斥锁保证线程安全，条件变量实现生产者-消费者同步
//  当队列满时，生产者（put）阻塞等待；队列空时，消费者（get）阻塞等待
//

#import "FFPacketQueue.h"
#import <pthread.h>

// 链表节点结构体
// 每个节点包含一个 AVPacket 数据和指向下一个节点的指针
typedef struct PacketNode {
    AVPacket packet;            // FFmpeg 数据包
    struct PacketNode *next;    // 指向下一个节点的指针
} PacketNode;

@implementation FFPacketQueue {
    PacketNode *_head;      // 链表头节点，出队时从头部取出
    PacketNode *_tail;      // 链表尾节点，入队时追加到尾部
    NSUInteger _count;      // 当前队列中的数据包数量
    NSUInteger _size;       // 当前队列中所有数据包的总字节数
    NSUInteger _capacity;   // 队列最大容量（最大数据包数量）
    BOOL _aborted;          // 中止标志，设置为 YES 后所有阻塞操作立即返回
    pthread_mutex_t _mutex; // 互斥锁，保护队列的并发访问
    pthread_cond_t _putCond; // 生产者条件变量，队列满时等待，有空间时被唤醒
    pthread_cond_t _getCond; // 消费者条件变量，队列空时等待，有数据时被唤醒
}

/**
 *  初始化队列
 *
 *  初始化互斥锁和条件变量，设置队列容量上限。
 *  初始状态下队列为空，未被中止。
 *
 *  @param capacity 队列最大容量
 *  @return 初始化后的实例
 */
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _capacity = capacity;
        _head = NULL;
        _tail = NULL;
        _count = 0;
        _size = 0;
        _aborted = NO;
        // 初始化 POSIX 线程同步原语
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_putCond, NULL);
        pthread_cond_init(&_getCond, NULL);
    }
    return self;
}

/**
 *  析构方法
 *
 *  释放队列中所有未处理的数据包，然后销毁互斥锁和条件变量。
 */
- (void)dealloc {
    [self flush];                        // 清空所有未处理的数据包
    pthread_mutex_destroy(&_mutex);      // 销毁互斥锁
    pthread_cond_destroy(&_putCond);     // 销毁生产者条件变量
    pthread_cond_destroy(&_getCond);     // 销毁消费者条件变量
}

/**
 *  获取当前队列中的数据包数量（线程安全）
 *
 *  通过互斥锁保护对 _count 的读取操作，确保多线程环境下的数据一致性。
 *
 *  @return 当前数据包数量
 */
- (NSUInteger)count {
    pthread_mutex_lock(&_mutex);
    NSUInteger c = _count;
    pthread_mutex_unlock(&_mutex);
    return c;
}

/**
 *  获取当前队列中所有数据包的总字节大小（线程安全）
 *
 *  通过互斥锁保护对 _size 的读取操作。
 *
 *  @return 总字节数
 */
- (NSUInteger)size {
    pthread_mutex_lock(&_mutex);
    NSUInteger s = _size;
    pthread_mutex_unlock(&_mutex);
    return s;
}

/**
 *  将一个数据包放入队列尾部
 *
 *  如果队列已满，生产者线程会在 _putCond 条件变量上等待，
 *  直到消费者取出数据包腾出空间，或者队列被中止。
 *  使用 av_packet_move_ref 转移数据包所有权，避免数据拷贝。
 *
 *  @param packet 要放入队列的 AVPacket
 *  @return YES 表示成功，NO 表示队列已被中止
 */
- (BOOL)putPacket:(AVPacket *)packet {
    pthread_mutex_lock(&_mutex);

    // 当队列已满且未中止时，生产者阻塞等待
    while (_count >= _capacity && !_aborted) {
        pthread_cond_wait(&_putCond, &_mutex);
    }

    // 如果队列被中止，立即返回失败
    if (_aborted) {
        pthread_mutex_unlock(&_mutex);
        return NO;
    }

    // 分配新的链表节点
    PacketNode *node = (PacketNode *)malloc(sizeof(PacketNode));
    // 转移数据包的所有权，避免拷贝数据
    // av_packet_move_ref 会将源 packet 置空，目标 node->packet 获得数据
    av_packet_move_ref(&node->packet, packet);
    node->next = NULL;

    // 将节点追加到链表尾部
    if (_tail) {
        _tail->next = node;
    } else {
        // 队列为空时，头节点也指向新节点
        _head = node;
    }
    _tail = node;

    _count++;
    // 累加数据包的实际字节大小
    _size += node->packet.size;

    // 唤醒一个等待中的消费者线程（如果有数据可取）
    pthread_cond_signal(&_getCond);
    pthread_mutex_unlock(&_mutex);
    return YES;
}

/**
 *  从队列头部取出一个数据包
 *
 *  如果队列为空，消费者线程会在 _getCond 条件变量上等待，
 *  直到生产者放入新数据包，或者队列被中止。
 *  使用 av_packet_move_ref 将节点中的数据包转移到输出参数。
 *
 *  @param packet 用于接收取出的数据包
 *  @return YES 表示成功取出，NO 表示队列已被中止且队列为空
 */
- (BOOL)getPacket:(AVPacket *)packet {
    pthread_mutex_lock(&_mutex);

    // 当队列为空且未中止时，消费者阻塞等待
    while (_count == 0 && !_aborted) {
        pthread_cond_wait(&_getCond, &_mutex);
    }

    // 如果队列被中止且没有数据可读，返回失败
    // 注意：允许在中止后仍能读出队列中残留的数据包
    if (_aborted && _count == 0) {
        pthread_mutex_unlock(&_mutex);
        return NO;
    }

    // 从链表头部取出节点
    PacketNode *node = _head;
    _head = node->next;
    // 如果取走后链表为空，尾节点也要置空
    if (!_head) {
        _tail = NULL;
    }

    _count--;
    _size -= node->packet.size;

    // 将节点中的数据包所有权转移到输出参数
    av_packet_move_ref(packet, &node->packet);
    // 释放空的节点内存（数据已转移，不再拥有 packet 的所有权）
    free(node);

    // 唤醒一个等待中的生产者线程（如果有空间可写入）
    pthread_cond_signal(&_putCond);
    pthread_mutex_unlock(&_mutex);
    return YES;
}

/**
 *  清空队列
 *
 *  遍历链表释放所有节点及其持有的 AVPacket 数据。
 *  重置计数器和大小为零。
 *  广播唤醒所有等待的生产者和消费者线程。
 */
- (void)flush {
    pthread_mutex_lock(&_mutex);

    // 遍历链表，逐个释放节点
    PacketNode *node = _head;
    while (node) {
        PacketNode *next = node->next;
        av_packet_unref(&node->packet);  // 释放数据包内部的引用数据
        free(node);                      // 释放节点内存
        node = next;
    }

    _head = NULL;
    _tail = NULL;
    _count = 0;
    _size = 0;

    // 广播唤醒所有等待的线程，让它们重新检查条件
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);
}

/**
 *  中止队列操作
 *
 *  设置中止标志后，所有阻塞在 put/get 上的线程将立即返回。
 *  通常用于播放停止、seek 或错误恢复时快速唤醒所有等待线程。
 *  注意：调用 abort 后需要调用 reset 才能重新使用队列。
 */
- (void)abort {
    pthread_mutex_lock(&_mutex);
    _aborted = YES;
    // 广播唤醒所有等待的线程，让它们检测到中止状态并退出
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);
}

/**
 *  重置队列的中止状态
 *
 *  清除中止标志，使队列可以继续正常使用。
 *  不会清空队列中已有的数据包。
 */
- (void)reset {
    pthread_mutex_lock(&_mutex);
    _aborted = NO;
    pthread_mutex_unlock(&_mutex);
}

@end
