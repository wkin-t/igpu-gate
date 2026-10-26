// IGPUModel.hpp —— 显示时序/平面寄存器模型（可移植 C++17，**不依赖 IOKit**）
//
// 为什么单独成库：Phase 2b 的容器（OC 注入 / AuxKC）还没定，但"时序怎么算、
// 寄存器怎么编码、和实测差在哪"与容器无关，可以先写、可以先测、可以进 CI。
// kext 那边以后只做一层薄封装（把这里的 plan 变成真实 MMIO 写入）。
//
// 编码依据（Intel display, i915 v6.12 同名寄存器）：
//   PIPESRC_x     [28:16]=水平-1，[12:0]=垂直-1
//   PLANE_SIZE_x  [29:16]=垂直-1，[12:0]=水平-1   （与 PIPESRC 顺序相反）
//   PLANE_STRIDE  [9:0]  = stride/64 字节
//   PLANE_SURF    [31:12]=图形地址（4KB 对齐）
// 语义不明的位一律不解释，只保留原始值。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace igpumodel {

constexpr uint32_t kStrideAlign = 64;
constexpr uint32_t kSurfaceAlign = 4096;

// 枚举值必须互不相同——别用 bpp 当枚举值（三种 32bpp 会撞成同一个 case）。
enum class PixelFormat : uint32_t {
    XRGB8888 = 0,
    ARGB8888 = 1,
    XBGR2101010 = 2,
    RGB565 = 3,
};

uint32_t bytes_per_pixel(PixelFormat f);
const char* format_name(PixelFormat f);
bool format_from_name(const std::string& name, PixelFormat* out);

struct Timing {
    uint32_t pixel_clock_khz = 0;
    uint32_t hactive = 0;
    uint32_t hblank = 0;
    uint32_t vactive = 0;
    uint32_t vblank = 0;

    // 显式构造函数：带默认成员初始化的聚合初始化是 C++14 才允许的，
    // 这里要兼容只会 C++11 的老编译器（本机 g++ 4.9 实测过）。
    Timing() = default;
    Timing(uint32_t pclk_khz, uint32_t hact, uint32_t hbl, uint32_t vact, uint32_t vbl)
        : pixel_clock_khz(pclk_khz), hactive(hact), hblank(hbl),
          vactive(vact), vblank(vbl) {}

    uint32_t htotal() const { return hactive + hblank; }
    uint32_t vtotal() const { return vactive + vblank; }
    double refresh_hz() const;
    std::string describe() const;
};

// EDID 的 18 字节目录（Detailed Timing Descriptor）。返回 false 表示不是有效 DTD。
bool edid_dtd_to_timing(const uint8_t* dtd18, Timing* out);
// EDID 第 54..71 字节是首选时序。
bool edid_preferred_timing(const std::vector<uint8_t>& edid, Timing* out);

struct PlanePlan {
    Timing timing{};
    PixelFormat format = PixelFormat::XRGB8888;
    uint32_t stride = 0;       // 字节
    uint32_t fb_bytes = 0;
    uint32_t pipesrc = 0;
    uint32_t plane_size = 0;
    uint32_t stride_reg = 0;
};

// 这是"继承当前扫描面"要的全部参数。抛 std::invalid_argument 表示参数非法。
PlanePlan plan_for(const Timing& timing, PixelFormat fmt = PixelFormat::XRGB8888);

uint32_t stride_bytes(const Timing& timing, PixelFormat fmt);

struct Measured {
    bool has_pipesrc = false;      uint32_t pipesrc = 0;
    bool has_plane_size = false;   uint32_t plane_size = 0;
    bool has_plane_stride = false; uint32_t plane_stride = 0;
    bool has_plane_surf = false;   uint32_t plane_surf = 0;
};

struct Decoded {
    uint32_t width = 0;
    uint32_t height = 0;
};

Decoded decode_pipesrc(uint32_t value);
Decoded decode_plane_size(uint32_t value);
uint32_t decode_stride(uint32_t value);
uint32_t surface_address(uint32_t value);

// 空 vector = 与实测一致；每条差异都要能解释，解释不了就不能继承。
std::vector<std::string> compare(const PlanePlan& plan, const Measured& measured);

}  // namespace igpumodel