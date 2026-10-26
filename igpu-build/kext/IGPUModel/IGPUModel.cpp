#include "IGPUModel.hpp"

#include <cstdio>
#include <stdexcept>

namespace igpumodel {

uint32_t bytes_per_pixel(PixelFormat f) {
    switch (f) {
        case PixelFormat::XRGB8888:
        case PixelFormat::ARGB8888:
        case PixelFormat::XBGR2101010:
            return 4;
        case PixelFormat::RGB565:
            return 2;
    }
    return 0;
}

const char* format_name(PixelFormat f) {
    switch (f) {
        case PixelFormat::XRGB8888: return "XRGB8888";
        case PixelFormat::ARGB8888: return "ARGB8888";
        case PixelFormat::XBGR2101010: return "XBGR2101010";
        case PixelFormat::RGB565: return "RGB565";
    }
    return "?";
}

bool format_from_name(const std::string& name, PixelFormat* out) {
    if (name == "XRGB8888") { *out = PixelFormat::XRGB8888; return true; }
    if (name == "ARGB8888") { *out = PixelFormat::ARGB8888; return true; }
    if (name == "XBGR2101010") { *out = PixelFormat::XBGR2101010; return true; }
    if (name == "RGB565") { *out = PixelFormat::RGB565; return true; }
    return false;
}

double Timing::refresh_hz() const {
    const uint32_t ht = htotal();
    const uint32_t vt = vtotal();
    if (ht == 0 || vt == 0) return 0.0;
    return static_cast<double>(pixel_clock_khz) * 1000.0 / (static_cast<double>(ht) * vt);
}

std::string Timing::describe() const {
    char buf[192];
    std::snprintf(buf, sizeof(buf), "%ux%u @ %.2f Hz (pclk %.3f MHz, htotal=%u, vtotal=%u)",
                  hactive, vactive, refresh_hz(),
                  static_cast<double>(pixel_clock_khz) / 1000.0, htotal(), vtotal());
    return std::string(buf);
}

bool edid_dtd_to_timing(const uint8_t* d, Timing* out) {
    if (d == nullptr || out == nullptr) return false;
    if (d[0] == 0 && d[1] == 0) return false;
    const uint32_t pclk_10khz = static_cast<uint32_t>(d[0]) | (static_cast<uint32_t>(d[1]) << 8);
    if (pclk_10khz == 0) return false;
    out->pixel_clock_khz = pclk_10khz * 10;
    out->hactive = static_cast<uint32_t>(d[2]) | ((static_cast<uint32_t>(d[4]) & 0xF0u) << 4);
    out->hblank = static_cast<uint32_t>(d[3]) | ((static_cast<uint32_t>(d[4]) & 0x0Fu) << 8);
    out->vactive = static_cast<uint32_t>(d[5]) | ((static_cast<uint32_t>(d[7]) & 0xF0u) << 4);
    out->vblank = static_cast<uint32_t>(d[6]) | ((static_cast<uint32_t>(d[7]) & 0x0Fu) << 8);
    return out->hactive > 0 && out->vactive > 0;
}

bool edid_preferred_timing(const std::vector<uint8_t>& edid, Timing* out) {
    if (edid.size() < 72) return false;
    return edid_dtd_to_timing(edid.data() + 54, out);
}

uint32_t stride_bytes(const Timing& t, PixelFormat fmt) {
    const uint32_t bpp = bytes_per_pixel(fmt);
    const uint32_t raw = t.hactive * bpp;
    if (raw == 0) throw std::invalid_argument("hactive 为 0，无法计算 stride");
    return ((raw + kStrideAlign - 1) / kStrideAlign) * kStrideAlign;
}

namespace {
uint32_t stride_reg_value(uint32_t stride) {
    if (stride % kStrideAlign != 0) throw std::invalid_argument("stride 未按 64 字节对齐");
    const uint32_t v = stride / kStrideAlign;
    if (v > 0x3FFu) throw std::invalid_argument("stride 超出 PLANE_STRIDE 的 10 位字段");
    return v;
}

uint32_t field13(uint32_t v, const char* what) {
    if (v == 0 || v > 0x1FFFu) throw std::invalid_argument(what);
    return v - 1u;
}
}  // namespace

PlanePlan plan_for(const Timing& t, PixelFormat fmt) {
    PlanePlan p;
    p.timing = t;
    p.format = fmt;
    p.stride = stride_bytes(t, fmt);
    p.fb_bytes = p.stride * t.vactive;
    p.pipesrc = (field13(t.hactive, "PIPESRC 宽度非法") << 16) | field13(t.vactive, "PIPESRC 高度非法");
    p.plane_size = (field13(t.vactive, "PLANE_SIZE 高度非法") << 16) | field13(t.hactive, "PLANE_SIZE 宽度非法");
    p.stride_reg = stride_reg_value(p.stride);
    return p;
}

Decoded decode_pipesrc(uint32_t v) {
    Decoded d;
    d.width = ((v >> 16) & 0x1FFFu) + 1u;
    d.height = (v & 0x1FFFu) + 1u;
    return d;
}

Decoded decode_plane_size(uint32_t v) {
    Decoded d;
    d.width = (v & 0x1FFFu) + 1u;
    d.height = ((v >> 16) & 0x1FFFu) + 1u;
    return d;
}

uint32_t decode_stride(uint32_t v) { return (v & 0x3FFu) * kStrideAlign; }

uint32_t surface_address(uint32_t v) { return v & ~(kSurfaceAlign - 1u); }

std::vector<std::string> compare(const PlanePlan& plan, const Measured& m) {
    std::vector<std::string> diffs;
    char buf[256];
    if (m.has_pipesrc) {
        const Decoded d = decode_pipesrc(m.pipesrc);
        if (d.width != plan.timing.hactive || d.height != plan.timing.vactive) {
            std::snprintf(buf, sizeof(buf), "PIPESRC 实测 %ux%u != EDID 首选 %ux%u",
                          d.width, d.height, plan.timing.hactive, plan.timing.vactive);
            diffs.emplace_back(buf);
        }
    }
    if (m.has_plane_size) {
        const Decoded d = decode_plane_size(m.plane_size);
        if (d.width != plan.timing.hactive || d.height != plan.timing.vactive) {
            std::snprintf(buf, sizeof(buf), "PLANE_SIZE 实测 %ux%u != EDID 首选 %ux%u",
                          d.width, d.height, plan.timing.hactive, plan.timing.vactive);
            diffs.emplace_back(buf);
        }
    }
    if (m.has_plane_stride) {
        const uint32_t got = decode_stride(m.plane_stride);
        if (got != plan.stride) {
            std::snprintf(buf, sizeof(buf), "PLANE_STRIDE 实测 %u 字节 != 按 %s 算的 %u 字节",
                          got, format_name(plan.format), plan.stride);
            diffs.emplace_back(buf);
        }
    }
    if (m.has_plane_surf) {
        const uint32_t addr = surface_address(m.plane_surf);
        if (addr == 0) {
            diffs.emplace_back("PLANE_SURF 实测地址为 0（平面可能未启用）");
        } else if ((m.plane_surf & (kSurfaceAlign - 1u)) != 0) {
            std::snprintf(buf, sizeof(buf), "PLANE_SURF 低 12 位非 0（0x%08X），不符合 4KB 对齐", m.plane_surf);
            diffs.emplace_back(buf);
        }
    }
    return diffs;
}

}  // namespace igpumodel