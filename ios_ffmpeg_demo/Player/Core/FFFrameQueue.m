//==============================================================================
// FFFrameQueue.m
// iOS FFmpeg Demo
//
// 简介：该文件实现了 FFFrameQueue.h 中声明的两个线程安全队列。
// 内部使用单向链表存储帧节点，通过 pthread_mutex 保证线程互斥，
// 通过 pthread_cond 实现生产/消费的同步等待与唤醒。
// 视频帧和音频帧队列的核心逻辑类似，区别在于：
//   - 视频帧的 CVPixelBuffer 需要 retain/release 管理引用计数
//   - 音频帧的 data 缓冲区需要手动 malloc/free
//   - 音频帧额外提供了 tryGetFrame 非阻塞方法
//==============================================================================

#import "FFFrameQueue.h"
#import <pthread.h>

//==============================================================================
#pragma mark - FFVideoFrameQueue 实现
//==============================================================================

// 视频帧链表节点结构体
// 每个节点持有一个 FFVideoFrame 数据以及指向下一个节点的指针
typedef struct VideoFrameNode {
    FFVideoFrame frame;              // 帧数据
    struct VideoFrameNode *next;     // 指向下一个节点的指针
} VideoFrameNode;

@implementation FFVideoFrameQueue {
    VideoFrameNode *_head;           // 链表头节点（出队端）
    VideoFrameNode *_tail;           // 链表尾节点（入队端）
    NSUInteger _count;               // 当前队列中的帧数量
    NSUInteger _capacity;            // 队列最大容量
    BOOL _aborted;                   // 队列是否已被终止
    pthread_mutex_t _mutex;          // 互斥锁，保护队列所有共享数据的访问
    pthread_cond_t _putCond;         // 生产者条件变量：队列未满时通知等待的 putter
    pthread_cond_t _getCond;        // 消费者条件变量：队列非空时通知等待的 getter
}

//------------------------------------------------------------------------------
// 初始化方法
// 设置队列容量，初始化链表指针、计数器，并初始化互斥锁和条件变量。
//------------------------------------------------------------------------------
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _capacity = capacity;               // 设置最大容量
        _head = NULL;                       // 空队列，头尾均为 NULL
        _tail = NULL;
        _count = 0;                         // 帧计数清零
        _aborted = NO;                      // 初始状态为未终止
        pthread_mutex_init(&_mutex, NULL);   // 初始化互斥锁（默认属性）
        pthread_cond_init(&_putCond, NULL);  // 初始化 put 条件变量
        pthread_cond_init(&_getCond, NULL); // 初始化 get 条件变量
    }
    return self;
}

//------------------------------------------------------------------------------
// dealloc
// 释构时先清空队列，再销毁 mutex 和 condition variables。
//------------------------------------------------------------------------------
- (void)dealloc {
    [self flush];                           // 清空队列，释放所有节点内存
    pthread_mutex_destroy(&_mutex);         // 销毁互斥锁
    pthread_cond_destroy(&_putCond);        // 销毁 put 条件变量
    pthread_cond_destroy(&_getCond);       // 销毁 get 条件变量
}

//------------------------------------------------------------------------------
// count 属性的 getter 方法
// 加锁读取 _count，保证多线程环境下读取到的值是准确的。
//------------------------------------------------------------------------------
- (NSUInteger)count {
    pthread_mutex_lock(&_mutex);            // 加锁
    NSUInteger c = _count;                  // 读取当前队列帧数
    pthread_mutex_unlock(&_mutex);          // 解锁
    return c;
}

//------------------------------------------------------------------------------
// 向队列尾部放入一帧视频
// 如果队列已满则阻塞等待（通过 _putCond）；若已终止则返回 NO。
// 成功时会将帧包装为节点追加到链表尾部，并 retain 视频帧的 pixelBuffer，
// 然后发送 _getCond 信号唤醒可能正在等待的消费者。
//------------------------------------------------------------------------------
- (BOOL)putFrame:(FFVideoFrame)frame {
    pthread_mutex_lock(&_mutex);            // 加锁保护共享数据
    // 当队列满且未终止时，等待消费者取出帧腾出空间
    while (_count >= _capacity && !_aborted) {
        pthread_cond_wait(&_putCond, &_mutex); // 等待 _putCond 信号
    }
    // 队列已终止，不允许再添加帧
    if (_aborted) {
        pthread_mutex_unlock(&_mutex);      // 解锁
        return NO;
    }
    // 分配新的链表节点
    VideoFrameNode *node = (VideoFrameNode *)malloc(sizeof(VideoFrameNode));
    node->frame = frame;                    // 拷贝帧数据到节点
    // 如果帧持有 pixelBuffer，需要 retain 以增加引用计数
    // 因为外部可能在放入后立即 release，而队列需要继续持有该 buffer
    if (frame.pixelBuffer) {
        CVPixelBufferRetain(frame.pixelBuffer);
    }
    node->next = NULL;                      // 新节点作为新的尾节点，next 为 NULL
    // 将新节点追加到链表尾部
    if (_tail) {
        _tail->next = node;                 // 原尾节点的 next 指向新节点
    } else {
        _head = node;                       // 空队列时，新节点也是头节点
    }
    _tail = node;                           // 更新尾节点指针
    _count++;                               // 帧计数加 1
    pthread_cond_signal(&_getCond);         // 通知等待的消费者队列非空
    pthread_mutex_unlock(&_mutex);          // 解锁
    return YES;
}

//------------------------------------------------------------------------------
// 从队列头部取出一帧视频（阻塞模式）
// 如果队列为空则阻塞等待（通过 _getCond）；若已终止且队列为空则返回 NO。
// 取出后释放节点内存，并发送 _putCond 信号唤醒可能正在等待的生产者。
//------------------------------------------------------------------------------
- (BOOL)getFrame:(FFVideoFrame *)frame {
    pthread_mutex_lock(&_mutex);            // 加锁
    // 当队列为空且未终止时，等待生产者放入新帧
    while (_count == 0 && !_aborted) {
        pthread_cond_wait(&_getCond, &_mutex); // 等待 _getCond 信号
    }
    // 队列已终止且没有剩余帧可消费
    if (_aborted && _count == 0) {
        pthread_mutex_unlock(&_mutex);      // 解锁
        return NO;
    }
    // 从链表头部取出节点
    VideoFrameNode *node = _head;
    _head = node->next;                     // 头指针后移
    if (!_head) _tail = NULL;               // 如果队列变空，尾指针也置 NULL
    _count--;                               // 帧计数减 1
    *frame = node->frame;                   // 将帧数据拷贝到输出参数
    free(node);                             // 释放已取出节点的内存
    pthread_cond_signal(&_putCond);         // 通知等待的生产者队列有空位
    pthread_mutex_unlock(&_mutex);          // 解锁
    return YES;
}

//------------------------------------------------------------------------------
// 窥视队列头部的帧数据（非阻塞，不移除）
// 如果队列为空则返回 NO；不为空则将头部帧数据拷贝到输出参数。
// 注意：数据只是拷贝，节点仍保留在队列中。
//------------------------------------------------------------------------------
- (BOOL)peekFrame:(FFVideoFrame *)frame {
    pthread_mutex_lock(&_mutex);            // 加锁
    if (_count == 0) {
        pthread_mutex_unlock(&_mutex);      // 队列为空，直接返回
        return NO;
    }
    *frame = _head->frame;                  // 拷贝头节点的帧数据
    pthread_mutex_unlock(&_mutex);          // 解锁
    return YES;
}

//------------------------------------------------------------------------------
// 清空队列
// 遍历整个链表，释放所有节点的帧资源（包括 pixelBuffer 的 release）后释放节点内存。
// 重置头尾指针和计数，然后广播唤醒所有因满/空而等待的生产者和消费者。
//------------------------------------------------------------------------------
- (void)flush {
    pthread_mutex_lock(&_mutex);            // 加锁
    VideoFrameNode *node = _head;
    // 遍历链表释放所有节点
    while (node) {
        VideoFrameNode *next = node->next;  // 先保存下一个节点指针
        // 如果帧持有 pixelBuffer，需要 release 以平衡之前的 retain
        if (node->frame.pixelBuffer) {
            CVPixelBufferRelease(node->frame.pixelBuffer);
        }
        free(node);                         // 释放节点内存
        node = next;                        // 移动到下一个节点
    }
    _head = NULL;                           // 头指针置空
    _tail = NULL;                           // 尾指针置空
    _count = 0;                             // 计数清零
    // 广播唤醒所有等待线程（包括 putter 和 getter）
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);          // 解锁
}

//------------------------------------------------------------------------------
// 终止队列
// 设置 _aborted = YES，然后广播唤醒所有等待的线程。
// 被唤醒的线程会在条件判断中检查 _aborted 标志并退出。
//------------------------------------------------------------------------------
- (void)abort {
    pthread_mutex_lock(&_mutex);            // 加锁
    _aborted = YES;                         // 设置终止标志
    // 广播唤醒所有等待的 putter 和 getter，让它们检测到终止状态后退出
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);          // 解锁
}

//------------------------------------------------------------------------------
// 重置终止状态
// 将 _aborted 恢复为 NO，使队列可以继续正常工作。
// 通常在 seek 或重新开始播放时调用。
//------------------------------------------------------------------------------
- (void)reset {
    pthread_mutex_lock(&_mutex);            // 加锁
    _aborted = NO;                          // 清除终止标志
    pthread_mutex_unlock(&_mutex);          // 解锁
}

@end

//==============================================================================
#pragma mark - FFAudioFrameQueue 实现
//==============================================================================

// 音频帧链表节点结构体
typedef struct AudioFrameNode {
    FFAudioFrame frame;                     // 帧数据
    struct AudioFrameNode *next;            // 指向下一个节点的指针
} AudioFrameNode;

@implementation FFAudioFrameQueue {
    AudioFrameNode *_head;                  // 链表头节点（出队端）
    AudioFrameNode *_tail;                  // 链表尾节点（入队端）
    NSUInteger _count;                      // 当前队列中的帧数量
    NSUInteger _capacity;                   // 队列最大容量
    BOOL _aborted;                          // 队列是否已被终止
    pthread_mutex_t _mutex;                 // 互斥锁
    pthread_cond_t _putCond;                // 生产者条件变量
    pthread_cond_t _getCond;               // 消费者条件变量
}

//------------------------------------------------------------------------------
// 初始化方法
//------------------------------------------------------------------------------
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _capacity = capacity;
        _head = NULL;
        _tail = NULL;
        _count = 0;
        _aborted = NO;
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_putCond, NULL);
        pthread_cond_init(&_getCond, NULL);
    }
    return self;
}

//------------------------------------------------------------------------------
// dealloc
//------------------------------------------------------------------------------
- (void)dealloc {
    [self flush];
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_putCond);
    pthread_cond_destroy(&_getCond);
}

//------------------------------------------------------------------------------
// count 属性的 getter 方法（线程安全）
//------------------------------------------------------------------------------
- (NSUInteger)count {
    pthread_mutex_lock(&_mutex);
    NSUInteger c = _count;
    pthread_mutex_unlock(&_mutex);
    return c;
}

//------------------------------------------------------------------------------
// 向队列尾部放入一帧音频（阻塞模式）
// 与视频帧队列类似，但音频帧不需要 retain/release，data 缓冲区由外部管理。
//------------------------------------------------------------------------------
- (BOOL)putFrame:(FFAudioFrame)frame {
    pthread_mutex_lock(&_mutex);
    // 队列满时等待
    while (_count >= _capacity && !_aborted) {
        pthread_cond_wait(&_putCond, &_mutex);
    }
    if (_aborted) {
        pthread_mutex_unlock(&_mutex);
        return NO;
    }
    AudioFrameNode *node = (AudioFrameNode *)malloc(sizeof(AudioFrameNode));
    node->frame = frame;                    // 直接拷贝帧数据（包括 data 指针的浅拷贝）
    node->next = NULL;
    // 追加到链表尾部
    if (_tail) {
        _tail->next = node;
    } else {
        _head = node;
    }
    _tail = node;
    _count++;
    pthread_cond_signal(&_getCond);         // 通知消费者
    pthread_mutex_unlock(&_mutex);
    return YES;
}

//------------------------------------------------------------------------------
// 从队列头部取出一帧音频（阻塞模式）
// 取出后释放节点本身的内存（但音频 data 缓冲区由外部负责释放）。
//------------------------------------------------------------------------------
- (BOOL)getFrame:(FFAudioFrame *)frame {
    pthread_mutex_lock(&_mutex);
    while (_count == 0 && !_aborted) {
        pthread_cond_wait(&_getCond, &_mutex);
    }
    if (_aborted && _count == 0) {
        pthread_mutex_unlock(&_mutex);
        return NO;
    }
    AudioFrameNode *node = _head;
    _head = node->next;
    if (!_head) _tail = NULL;
    _count--;
    *frame = node->frame;                   // 将帧数据（包含 data 指针）拷贝到输出参数
    free(node);                             // 释放节点内存（注意：不释放 frame.data，所有权转给了调用方）
    pthread_cond_signal(&_putCond);         // 通知生产者
    pthread_mutex_unlock(&_mutex);
    return YES;
}

//------------------------------------------------------------------------------
// 尝试取出一帧音频（非阻塞模式）
// 与 getFrame 的区别在于：如果队列为空，不会阻塞等待，而是直接返回 NO。
// 适用于不希望阻塞调用线程的场景（如音频渲染线程的快速检查）。
//------------------------------------------------------------------------------
- (BOOL)tryGetFrame:(FFAudioFrame *)frame {
    pthread_mutex_lock(&_mutex);
    if (_count == 0) {
        pthread_mutex_unlock(&_mutex);
        return NO;                          // 队列为空，立即返回 NO
    }
    AudioFrameNode *node = _head;
    _head = node->next;
    if (!_head) _tail = NULL;
    _count--;
    *frame = node->frame;
    free(node);
    pthread_cond_signal(&_putCond);         // 通知生产者队列有空位
    pthread_mutex_unlock(&_mutex);
    return YES;
}

//------------------------------------------------------------------------------
// 清空队列
// 遍历链表释放所有节点。对于音频节点，还需要释放 frame.data 缓冲区。
// 最后广播唤醒所有等待的线程。
//------------------------------------------------------------------------------
- (void)flush {
    pthread_mutex_lock(&_mutex);
    AudioFrameNode *node = _head;
    while (node) {
        AudioFrameNode *next = node->next;
        // 音频帧的 data 缓冲区是在堆上分配的，需要手动释放
        if (node->frame.data) {
            free(node->frame.data);
        }
        free(node);                         // 释放节点内存
        node = next;
    }
    _head = NULL;
    _tail = NULL;
    _count = 0;
    // 广播唤醒所有等待的生产者和消费者
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);
}

//------------------------------------------------------------------------------
// 终止队列
//------------------------------------------------------------------------------
- (void)abort {
    pthread_mutex_lock(&_mutex);
    _aborted = YES;
    pthread_cond_broadcast(&_putCond);
    pthread_cond_broadcast(&_getCond);
    pthread_mutex_unlock(&_mutex);
}

//------------------------------------------------------------------------------
// 重置终止状态
//------------------------------------------------------------------------------
- (void)reset {
    pthread_mutex_lock(&_mutex);
    _aborted = NO;
    pthread_mutex_unlock(&_mutex);
}

@end
