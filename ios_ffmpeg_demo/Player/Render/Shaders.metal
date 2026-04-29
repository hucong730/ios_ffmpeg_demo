// ============================================================
// iOS FFmpeg 视频播放器 — Metal 着色器
// 功能：顶点着色器（直通）+ 片段着色器（NV12 YUV → BT.709 RGB 转换）
// ============================================================
#include <metal_stdlib>
using namespace metal;

// 顶点输入结构体
// position  : 顶点位置（归一化设备坐标，范围 [-1, 1]），attribute(0) 表示来自顶点缓冲区的第 0 个属性
// texCoord  : 纹理坐标（范围 [0, 1]），attribute(1) 表示来自顶点缓冲区的第 1 个属性
struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// 顶点输出结构体（同时也是片元着色器的输入）
// position  : 经过变换后的裁剪空间坐标，[[position]] 修饰符表示这是光栅化所需的最终位置
// texCoord  : 传递到片元阶段的纹理坐标，用于纹理采样
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// 顶点着色器 — 直通（pass-through）着色器
// 作用：将输入的顶点位置和纹理坐标原样传递到光栅化阶段，不做任何几何变换。
// 因为 iOS 端已经预先计算好了归一化设备坐标，Metal 只需直通即可。
// 参数：
//   in       : 从 CPU 传入的顶点数据（位置 + 纹理坐标），[[stage_in]] 表示每个顶点调用一次
// 返回：
//   VertexOut: 传递给片元着色器的数据，包含裁剪空间位置和纹理坐标
vertex VertexOut vertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = in.position;    // 直通顶点位置
    out.texCoord = in.texCoord;    // 直通纹理坐标
    return out;
}

// 片段着色器 — NV12 双纹理 YUV → BT.709 RGB 转换
// 作用：对 NV12 格式的视频帧进行解码，将 Y（亮度）和 UV（色度）两个纹理合并
//       并通过 BT.709 颜色矩阵转换为 RGB，最终输出给屏幕显示。
// NV12 格式说明：
//   - Y 纹理（单通道）存储亮度信息
//   - UV 纹理（双通道，r = U, g = V）交错存储色度信息
// 参数：
//   in        : 来自顶点着色器的光栅化数据（含纹理坐标）
//   yTexture  : 亮度纹理（texture(0)），格式通常为 R8Unorm，单通道
//   uvTexture : 色度纹理（texture(1)），格式通常为 RG8Unorm，双通道
// 返回：
//   float4    : RGBA 颜色值，r/g/b 范围 [0, 1]，a 通道恒为 1.0（不透明）
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> yTexture [[texture(0)]],
                                texture2d<float> uvTexture [[texture(1)]]) {
    // 纹理采样器配置
    // mag_filter::linear : 放大时使用线性插值，使像素放大后边缘平滑，避免锯齿
    // min_filter::linear : 缩小时使用线性插值，使像素缩小时同样平滑
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    // 采样 Y 纹理的 r 通道，得到亮度值 y（范围 [0, 1]）
    float y = yTexture.sample(texSampler, in.texCoord).r;
    // 采样 UV 纹理的 rg 通道，分别得到 U 和 V 色度值（范围 [0, 1]）
    float2 uv = uvTexture.sample(texSampler, in.texCoord).rg;

    // BT.709 video range YUV to RGB conversion
    // ------------------------------------------------------------
    // BT.709 是高清电视（HDTV）的标准色彩空间，广泛用于 H.264/H.265 视频。
    //
    // 【Video Range（视频范围）vs Full Range（全范围）】
    // 视频数据采用 "limited range"（有限范围/视频范围）编码：
    //   - Y 分量范围：16 ~ 235（8-bit），而非全范围的 0 ~ 255
    //   - UV 分量范围：16 ~ 240（8-bit），中心值为 128
    // 这样设计是为了在模拟信号中预留保护带（headroom/footroom），
    // 防止信号过冲（overshoot）导致硬件损坏。
    // 因此解码时需要对 Y 减去 16/255，UV 减去 128/255 来恢复到以 0 为中心的正交空间。
    //
    // 【BT.709 颜色矩阵公式】
    // 第一步：归一化到 [0, 1] 范围并去除偏移
    float Y = 1.164 * (y - 16.0 / 255.0);    // 亮度 Y：缩放因子 1.164 = 255 / (235 - 16)，还原到正常动态范围
    float U = uv.r - 128.0 / 255.0;           // 色度 U：减去 128/255 使中心归零（范围变为 [-0.5, 0.5]）
    float V = uv.g - 128.0 / 255.0;           // 色度 V：同上

    // 第二步：通过 BT.709 矩阵将 YUV 转换为线性 RGB
    // BT.709 转换矩阵（从 YCbCr 到 R'G'B'）：
    //   R' = Y + 0.0000 * U + 1.5748 * V    ≈ Y + 1.793 * V
    //   G' = Y - 0.1873 * U - 0.4681 * V    ≈ Y - 0.213 * U - 0.533 * V
    //   B' = Y + 1.8556 * U + 0.0000 * V    ≈ Y + 2.112 * U
    //
    // 系数取整后的计算（实际使用的系数是针对归一化后的 YUV 调整过的）：
    float R = Y + 1.793 * V;    // R 分量主要受 Y（亮度）和 V（红蓝色差）影响
    float G = Y - 0.213 * U - 0.533 * V;  // G 分量同时受 U 和 V 影响，系数为负表示减色
    float B = Y + 2.112 * U;    // B 分量主要受 Y（亮度）和 U（蓝黄色差）影响

    // 将 RGB 值 clamp 到 [0, 1] 范围，防止溢出（由于浮点运算精度或越界 YUV 值），
    // Alpha 通道设为 1.0（完全不透明）
    return float4(clamp(R, 0.0, 1.0),
                  clamp(G, 0.0, 1.0),
                  clamp(B, 0.0, 1.0),
                  1.0);
}
