//
//  FFMetalRenderer.m
//  ios_ffmpeg_demo
//
//  概述：Metal 渲染器的实现文件。
//  实现基于 Metal 的 NV12 双平面视频帧渲染管线。
//  核心流程：
//    1. 初始化阶段：绑定 MTKView，创建 MTLDevice、MTLCommandQueue、
//       MTLRenderPipelineState（包含顶点描述符：位置 + 纹理坐标），
//       以及 CVMetalTextureCache（用于将 CVPixelBuffer 桥接为 Metal 纹理）。
//    2. 渲染每帧时：从 CVPixelBuffer 创建两个 Metal 纹理——
//       Y 平面（MTLPixelFormatR8Unorm 单通道）和 UV 平面（MTLPixelFormatRG8Unorm 双通道）。
//       通过顶点缓冲区的 letterbox/pillarbox 计算，确保视频在视口中保持原始宽高比。
//    3. 清理阶段：通过 CVMetalTextureCacheFlush 管理纹理缓存的内存占用。
//

#import "FFMetalRenderer.h"

// 顶点数据结构：每个顶点包含位置坐标和纹理坐标
typedef struct {
    simd_float4 position;  // 顶点位置 (x, y, z, w)，用于定义矩形四角
    simd_float2 texCoord;  // 纹理坐标 (u, v)，映射到视频帧上的采样点
} FFVertex;

@implementation FFMetalRenderer {
    __weak MTKView *_metalView;              // 弱引用绑定的 MTKView，避免循环引用
    id<MTLDevice> _device;                   // Metal 设备对象，代表 GPU 抽象
    id<MTLCommandQueue> _commandQueue;       // 命令队列，用于提交渲染指令到 GPU
    id<MTLRenderPipelineState> _pipelineState; // 渲染管道状态，封装 shader 与顶点描述符配置
    id<MTLBuffer> _vertexBuffer;             // 顶点缓冲区，存储六顶点（两个三角形）数据
    CVMetalTextureCacheRef _textureCache;    // CoreVideo-Metal 纹理缓存桥接器
    CGSize _videoSize;                       // 视频原始尺寸，用于计算宽高比
    CGSize _viewportSize;                    // 视口尺寸，即 MTKView 的 drawable 大小
}

/// 初始化渲染器，绑定 MTKView 并记录初始尺寸
/// @param view 用于显示的 MTKView 实例
- (instancetype)initWithMetalView:(MTKView *)view {
    self = [super init];
    if (self) {
        // 保存弱引用绑定的 Metal 视图
        _metalView = view;
        // 从 MTKView 获取 MTLDevice，它是所有 Metal 对象（纹理、缓冲区、shader）的工厂
        _device = view.device;
        // 初始化视频尺寸为零，待后续通过 updateVideoSize: 设置
        _videoSize = CGSizeZero;
        // 记录当前视口尺寸，即 MTKView 的绘制缓冲区大小（以点为单位）
        _viewportSize = view.drawableSize;
    }
    return self;
}

/// 析构函数：释放纹理缓存，避免 CoreVideo 资源泄露
- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

/// 设置完整的 Metal 渲染管线
/// 依次完成：命令队列创建、shader 加载、渲染管道状态构建、纹理缓存创建
/// @return YES 表示全部设置成功，NO 表示任一环节失败
- (BOOL)setup {
    // 创建 MTLCommandQueue：用于向 GPU 提交命令缓冲区的串行队列
    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) return NO;

    // 从 App 的默认 Metal 库（default.metallib）中加载已编译的 shader 函数
    id<MTLLibrary> library = [_device newDefaultLibrary];
    if (!library) {
        NSLog(@"FFMetalRenderer: newDefaultLibrary failed");
        return NO;
    }

    // 按函数名查找顶点 shader 和片元 shader
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragmentShader"];
    if (!vertexFunc || !fragmentFunc) {
        NSLog(@"FFMetalRenderer: shader functions not found");
        return NO;
    }

    // 配置 MTLVertexDescriptor（顶点描述符）：
    // 描述顶点数据在缓冲区中的布局，包括位置（float4）和纹理坐标（float2）
    MTLVertexDescriptor *vertexDesc = [[MTLVertexDescriptor alloc] init];
    // attribute[0]：顶点位置，类型 float4，从 FFVertex.position 偏移处开始，绑定到 buffer index 0
    vertexDesc.attributes[0].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[0].offset = offsetof(FFVertex, position);
    vertexDesc.attributes[0].bufferIndex = 0;
    // attribute[1]：纹理坐标，类型 float2，从 FFVertex.texCoord 偏移处开始，绑定到 buffer index 0
    vertexDesc.attributes[1].format = MTLVertexFormatFloat2;
    vertexDesc.attributes[1].offset = offsetof(FFVertex, texCoord);
    vertexDesc.attributes[1].bufferIndex = 0;
    // layout[0]：定义整个顶点结构体的步长，按逐顶点方式读取
    vertexDesc.layouts[0].stride = sizeof(FFVertex);
    vertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // 构建 MTLRenderPipelineDescriptor（渲染管道描述符），
    // 它将顶点 shader、片元 shader、顶点描述符和颜色附件格式封装在一起
    MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.vertexDescriptor = vertexDesc;
    // 颜色附件像素格式与 MTKView 的 colorPixelFormat 保持一致
    pipelineDesc.colorAttachments[0].pixelFormat = _metalView.colorPixelFormat;

    // 根据描述符创建 MTLRenderPipelineState（渲染管道状态）
    NSError *error = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    if (!_pipelineState) {
        NSLog(@"FFMetalRenderer: pipeline state creation failed: %@", error);
        return NO;
    }

    // 创建 CVMetalTextureCacheRef —— 核心桥接器，用于将 CVPixelBuffer
    // 转换为 Metal 纹理（id<MTLTexture>），实现零拷贝或最小拷贝的 GPU 上传
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache);
    if (status != kCVReturnSuccess) {
        NSLog(@"FFMetalRenderer: CVMetalTextureCacheCreate failed: %d", status);
        return NO;
    }

    // 初始化顶点缓冲区（根据当前视频尺寸和视口尺寸计算适配比例）
    [self _updateVertexBuffer];

    return YES;
}

/// 更新视频尺寸，并重新计算顶点缓冲区以适配宽高比
/// 传入 CGSizeZero 时仅触发视口适配重算（如横竖屏切换），不改变原始视频尺寸
/// @param videoSize 新的视频宽高尺寸（CGSizeZero 表示仅刷新视口适配）
- (void)updateVideoSize:(CGSize)videoSize {
    // 仅在传入有效尺寸时更新视频原始尺寸
    // CGSizeZero 用作横竖屏切换等场景下仅触发重算的信号，不能覆盖已保存的 videoSize
    if (videoSize.width > 0 && videoSize.height > 0) {
        _videoSize = videoSize;
    }
    [self _updateVertexBuffer];
}

/// 内部方法：根据视频宽高比和视口宽高比计算 letterbox/pillarbox 缩放因子，
/// 并更新顶点缓冲区中的六顶点数据（两个三角形构成一个矩形）。
///
/// 计算逻辑：
/// - 如果视频宽高比 > 视口宽高比（视频更宽），则限制宽度撑满视口，高度留黑边（letterbox）
/// - 反之（视频更高），则限制高度撑满视口，宽度留黑边（pillarbox）
- (void)_updateVertexBuffer {
    // 默认顶点范围：从 (-1,-1) 到 (1,1)，即全屏矩形
    float vx = 1.0, vy = 1.0;

    if (_videoSize.width > 0 && _videoSize.height > 0) {
        // 获取当前 drawable 尺寸（可能因视图大小变化而改变）
        _viewportSize = _metalView.drawableSize;
        if (_viewportSize.width > 0 && _viewportSize.height > 0) {
            // 计算视频宽高比和视口宽高比
            float videoAspect = _videoSize.width / _videoSize.height;
            float viewAspect = _viewportSize.width / _viewportSize.height;
            if (videoAspect > viewAspect) {
                // 视频比视口更宽：宽度撑满，高度按比例缩小 -> 上下留黑边（letterbox）
                vy = viewAspect / videoAspect;
            } else {
                // 视频比视口更高：高度撑满，宽度按比例缩小 -> 左右留黑边（pillarbox）
                vx = videoAspect / viewAspect;
            }
        }
    }

    // 定义六个顶点（两个三角形构成一个矩形）：
    // 三角形1: 左下(0) -> 右下(1) -> 左上(2)
    // 三角形2: 右下(3) -> 右上(4) -> 左上(5)
    // 纹理坐标：原点(0,0) 在左上角，(1,1) 在右下角
    FFVertex vertices[] = {
        { .position = { -vx, -vy, 0.0, 1.0 }, .texCoord = { 0.0, 1.0 } },
        { .position = {  vx, -vy, 0.0, 1.0 }, .texCoord = { 1.0, 1.0 } },
        { .position = { -vx,  vy, 0.0, 1.0 }, .texCoord = { 0.0, 0.0 } },
        { .position = {  vx, -vy, 0.0, 1.0 }, .texCoord = { 1.0, 1.0 } },
        { .position = {  vx,  vy, 0.0, 1.0 }, .texCoord = { 1.0, 0.0 } },
        { .position = { -vx,  vy, 0.0, 1.0 }, .texCoord = { 0.0, 0.0 } },
    };

    // 用更新后的顶点数据重新创建 MTLBuffer（使用 Shared 模式，CPU 与 GPU 共享内存）
    _vertexBuffer = [_device newBufferWithBytes:vertices
                                         length:sizeof(vertices)
                                        options:MTLResourceStorageModeShared];
}

/// 渲染一帧 CVPixelBuffer 到 MTKView 上
/// 流程：
///   1. 检查视口尺寸变化，必要时重新计算顶点缓冲区
///   2. 从 CVPixelBuffer 创建 Y 平面纹理（R8Unorm）和 UV 平面纹理（RG8Unorm）
///   3. 设置渲染命令编码器，绑定管道状态、顶点缓冲区和纹理
///   4. 绘制两个三角形（6 个顶点）完成一帧渲染
///   5. 提交命令缓冲区并刷新纹理缓存
/// @param pixelBuffer 待渲染的视频帧，期望为 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // 前置检查：确保像素缓冲区、管道状态和纹理缓存均有效
    if (!pixelBuffer || !_pipelineState || !_textureCache) return;

    MTKView *view = _metalView;
    if (!view) return;

    // 检测视口尺寸是否发生变化（如屏幕旋转、视图布局变化），
    // 若变化则更新顶点缓冲区以重新适配宽高比
    CGSize drawableSize = view.drawableSize;
    if (drawableSize.width != _viewportSize.width || drawableSize.height != _viewportSize.height) {
        _viewportSize = drawableSize;
        [self _updateVertexBuffer];
    }

    // 获取 CVPixelBuffer 的宽高（像素维度）
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    // ---- 创建 Y 平面纹理（plane 0） ----
    // NV12 格式中，plane 0 存储 Y（亮度）分量，单通道，格式为 MTLPixelFormatR8Unorm
    CVMetalTextureRef yTextureRef = NULL;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _textureCache, pixelBuffer,
        NULL, MTLPixelFormatR8Unorm,
        width, height, 0, &yTextureRef);
    if (status != kCVReturnSuccess || !yTextureRef) return;

    // ---- 创建 UV 平面纹理（plane 1） ----
    // NV12 格式中，plane 1 存储 CbCr（色度）分量，双通道交错，格式为 MTLPixelFormatRG8Unorm
    // 色度平面的尺寸是亮度平面的一半（width/2, height/2）
    CVMetalTextureRef uvTextureRef = NULL;
    status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _textureCache, pixelBuffer,
        NULL, MTLPixelFormatRG8Unorm,
        width / 2, height / 2, 1, &uvTextureRef);
    if (status != kCVReturnSuccess || !uvTextureRef) {
        CFRelease(yTextureRef);
        return;
    }

    // 从 CVMetalTextureRef 提取实际的 Metal 纹理对象 id<MTLTexture>
    id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
    id<MTLTexture> uvTexture = CVMetalTextureGetTexture(uvTextureRef);

    // 从 MTKView 获取当前帧的渲染目标描述符
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!passDesc) {
        CFRelease(yTextureRef);
        CFRelease(uvTextureRef);
        return;
    }
    // 设置清屏颜色为纯黑（背景色，letterbox/pillarbox 区域显示黑色）
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    // 创建命令缓冲区并从描述符创建渲染命令编码器
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];

    // 设置渲染管道状态
    [encoder setRenderPipelineState:_pipelineState];
    // 绑定顶点缓冲区（包含宽高比适配后的顶点数据）到 index 0
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    // 绑定 Y 平面纹理到片元 shader 的 texture index 0
    [encoder setFragmentTexture:yTexture atIndex:0];
    // 绑定 UV 平面纹理到片元 shader 的 texture index 1
    [encoder setFragmentTexture:uvTexture atIndex:1];
    // 绘制 6 个顶点（两个三角形构成的矩形）
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];

    // 提交命令缓冲区并立即显示绘制结果
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];

    // 释放临时的纹理引用（Metal 纹理本身受引用计数管理，但 CVMetalTextureRef 需要手动释放）
    CFRelease(yTextureRef);
    CFRelease(uvTextureRef);

    // 刷新纹理缓存，及时回收不再需要的纹理对象，防止内存无限增长
    CVMetalTextureCacheFlush(_textureCache, 0);
}

@end
