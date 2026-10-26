// model_test.cpp —— 模型自测：与 Python 侧 fbmodel.py 用同一组锚点，两边必须一致。
#include "IGPUModel.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace igpumodel;

static int g_pass = 0;
static int g_fail = 0;

static void check(bool cond, const std::string& what) {
    if (cond) {
        ++g_pass;
    } else {
        ++g_fail;
        std::printf("  FAIL %s\n", what.c_str());
    }
}

int main() {
    // 1) 实测锚点解码：PIPESRC/PLANE_SIZE 都是 1920x1080，stride 7680 字节
    const Decoded ps = decode_pipesrc(0x077F0437u);
    check(ps.width == 1920 && ps.height == 1080, "PIPESRC_A 解码为 1920x1080");
    const Decoded pz = decode_plane_size(0x0437077Fu);
    check(pz.width == 1920 && pz.height == 1080, "PLANE_SIZE_1_A 解码为 1920x1080");
    check(decode_stride(0x00000078u) == 7680, "PLANE_STRIDE_1_A 解码为 7680 字节");

    // 2) 1920x1080@60 标准时序 → 与实测完全一致（A2 继承前提）
    Timing t{};
    t.pixel_clock_khz = 148500;
    t.hactive = 1920;
    t.hblank = 280;
    t.vactive = 1080;
    t.vblank = 45;
    check(t.htotal() == 2200 && t.vtotal() == 1125, "htotal/vtotal");
    const double hz = t.refresh_hz();
    check(hz > 59.9 && hz < 60.1, "刷新率约 60Hz");

    const PlanePlan plan = plan_for(t, PixelFormat::XRGB8888);
    check(plan.stride == 7680, "计划 stride=7680");
    check(plan.stride_reg == 0x78, "stride 寄存器值=0x78");
    check(plan.pipesrc == 0x077F0437u, "PIPESRC 编码复现实测值");
    check(plan.plane_size == 0x0437077Fu, "PLANE_SIZE 编码复现实测值");
    check(plan.fb_bytes == 7680u * 1080u, "frame buffer 字节数");

    Measured m;
    m.has_pipesrc = true; m.pipesrc = 0x077F0437u;
    m.has_plane_size = true; m.plane_size = 0x0437077Fu;
    m.has_plane_stride = true; m.plane_stride = 0x78u;
    check(compare(plan, m).empty(), "与实测锚点无差异");

    // 3) 负例：stride 未对齐要抛异常
    bool threw = false;
    try {
        stride_bytes(Timing{100000, 1001, 10, 700, 10}, PixelFormat::XRGB8888);
        (void)0;
    } catch (const std::exception&) {
        threw = true;
    }
    check(!threw, "1001*4=4004 -> 向上对齐到 4032，不应抛异常");

    bool threw2 = false;
    try {
        Timing bad{100000, 0, 10, 700, 10};
        (void)stride_bytes(bad, PixelFormat::XRGB8888);
    } catch (const std::exception&) {
        threw2 = true;
    }
    check(threw2, "hactive=0 必须抛异常");

    // 4) EDID DTD 解码（构造一个 1920x1080 的 DTD）
    uint8_t dtd[18] = {0};
    const uint32_t pclk10 = 14850;  // 148.5MHz / 10kHz
    dtd[0] = static_cast<uint8_t>(pclk10 & 0xFF);
    dtd[1] = static_cast<uint8_t>(pclk10 >> 8);
    dtd[2] = static_cast<uint8_t>(1920 & 0xFF);
    dtd[3] = static_cast<uint8_t>(280 & 0xFF);
    dtd[4] = static_cast<uint8_t>(((1920 >> 8) & 0x0F) << 4 | ((280 >> 8) & 0x0F));
    dtd[5] = static_cast<uint8_t>(1080 & 0xFF);
    dtd[6] = static_cast<uint8_t>(45 & 0xFF);
    dtd[7] = static_cast<uint8_t>(((1080 >> 8) & 0x0F) << 4 | ((45 >> 8) & 0x0F));
    Timing dt{};
    check(edid_dtd_to_timing(dtd, &dt), "DTD 解析成功");
    check(dt.hactive == 1920 && dt.vactive == 1080 && dt.hblank == 280 && dt.vblank == 45,
          "DTD 解出 1920x1080 hblank=280 vblank=45");

    // 5) 差异检测：stride 不符要被报出来
    Measured m2 = m;
    m2.plane_stride = 0x80u;  // 8192 字节
    check(!compare(plan, m2).empty(), "stride 不符必须报差异");

    // 6) 扫描面地址低 12 位非 0 要被报出来
    Measured m3;
    m3.has_plane_surf = true;
    m3.plane_surf = 0x12345678u;
    check(!compare(plan, m3).empty(), "SURF 未对齐必须报差异");

    std::printf("===== PASS=%d  FAIL=%d =====\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}