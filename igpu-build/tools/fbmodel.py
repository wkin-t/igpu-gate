"""显示时序与平面寄存器模型（纯计算，无 IOKit 依赖）。

为什么先写这个：Phase 2b-A2 要做"继承固件已建立的扫描面"，判断依据就是
**用 EDID 首选时序算出来的 stride/尺寸/寄存器值** 与 **探针实测值** 是否一致。
一旦一致，A2 才有可能"只换提供者、不动时序"；不一致就说明还有未捕获的
像素格式/平铺/偏移因素，不能盲接手。

寄存器编码来源（Intel display, i915 v6.12 同名寄存器）：
  PIPESRC_x     bits[28:16] = 水平像素数-1，bits[12:0] = 垂直像素数-1
  PLANE_SIZE_x  bits[29:16] = 高度-1，      bits[12:0] = 宽度-1   （注意与 PIPESRC 相反）
  PLANE_STRIDE  bits[9:0]  = stride / 64 字节（ADL 为 64B 单位）
  PLANE_SURF    bits[31:12] = 扫描面图形地址（4KB 对齐）
未知/存疑的位一律不解释，只保留原始值——宁缺毋错。
"""

from dataclasses import dataclass, asdict, field
from typing import Optional, List, Dict, Tuple

SCHEMA_VERSION = 1

# (名称, 每像素字节数)。只放我们真的可能用到、且语义明确的格式。
PIXEL_FORMATS: Dict[str, int] = {
    "XRGB8888": 4,
    "ARGB8888": 4,
    "XBGR2101010": 4,
    "RGB565": 2,
}

STRIDE_ALIGN = 64          # PLANE_STRIDE 以 64 字节为单位
SURFACE_ALIGN = 4096       # PLANE_SURF 低 12 位为 0


@dataclass(frozen=True)
class Timing:
    """一套显示时序。blank 是"包含 sync 与 back/front porch 的总消隐"。"""
    pixel_clock_khz: int
    hactive: int
    hblank: int
    vactive: int
    vblank: int

    @property
    def htotal(self) -> int:
        return self.hactive + self.hblank

    @property
    def vtotal(self) -> int:
        return self.vactive + self.vblank

    @property
    def refresh_hz(self) -> float:
        if self.htotal <= 0 or self.vtotal <= 0:
            return 0.0
        return self.pixel_clock_khz * 1000.0 / (self.htotal * self.vtotal)

    def describe(self) -> str:
        return "%dx%d @ %.2f Hz (pclk %.3f MHz, htotal=%d, vtotal=%d)" % (
            self.hactive, self.vactive, self.refresh_hz,
            self.pixel_clock_khz / 1000.0, self.htotal, self.vtotal)


def edid_dtd_to_timing(dtd: bytes) -> Optional[Timing]:
    """从 EDID 的 18 字节 Detailed Timing Descriptor 解出一套时序。

    返回 None 表示这不是一个有效 DTD（例如是 monitor descriptor / 空槽）。
    """
    if len(dtd) < 18:
        return None
    if dtd[0] == 0 and dtd[1] == 0:
        return None
    pclk_10khz = dtd[0] | (dtd[1] << 8)
    if pclk_10khz == 0:
        return None
    hactive = dtd[2] | ((dtd[4] & 0xF0) << 4)
    hblank = dtd[3] | ((dtd[4] & 0x0F) << 8)
    vactive = dtd[5] | ((dtd[7] & 0xF0) << 4)
    vblank = dtd[6] | ((dtd[7] & 0x0F) << 8)
    return Timing(pixel_clock_khz=pclk_10khz * 10,
                  hactive=hactive, hblank=hblank,
                  vactive=vactive, vblank=vblank)


def edid_preferred_timing(edid: bytes) -> Optional[Timing]:
    """EDID 第 54..71 字节是"首选时序"DTD。"""
    if len(edid) < 72:
        return None
    return edid_dtd_to_timing(edid[54:72])


def edid_all_dtds(edid: bytes) -> List[Timing]:
    out: List[Timing] = []
    for i in range(4):
        off = 54 + i * 18
        if len(edid) < off + 18:
            break
        t = edid_dtd_to_timing(edid[off:off + 18])
        if t is not None:
            out.append(t)
    return out


def stride_bytes(timing: Timing, fmt: str) -> int:
    """按行宽对齐到 64 字节算 stride（显卡要求 stride 是 64B 的整数倍）。"""
    if fmt not in PIXEL_FORMATS:
        raise ValueError("未知像素格式：%s" % fmt)
    raw = timing.hactive * PIXEL_FORMATS[fmt]
    return ((raw + STRIDE_ALIGN - 1) // STRIDE_ALIGN) * STRIDE_ALIGN


def stride_reg_value(stride_in_bytes: int) -> int:
    if stride_in_bytes % STRIDE_ALIGN:
        raise ValueError("stride 必须是 %d 的整数倍：%d" % (STRIDE_ALIGN, stride_in_bytes))
    v = stride_in_bytes // STRIDE_ALIGN
    if v > 0x3FF:
        raise ValueError("stride 超出 PLANE_STRIDE 的 10 位字段：%d 字节" % stride_in_bytes)
    return v


def pipesrc_reg(width: int, height: int) -> int:
    """PIPESRC_x：水平在 [28:16]、垂直在 [12:0]，都是"减一"。"""
    if not (1 <= width <= 0x1FFF and 1 <= height <= 0x1FFF):
        raise ValueError("PIPESRC 尺寸超出 13 位字段：%dx%d" % (width, height))
    return (((width - 1) & 0x1FFF) << 16) | ((height - 1) & 0x1FFF)


def plane_size_reg(width: int, height: int) -> int:
    """PLANE_SIZE_x：高度在 [29:16]、宽度在 [12:0]，都是"减一"。

    注意与 PIPESRC 的字段顺序**相反**——这是最容易抄错的一处。
    """
    if not (1 <= width <= 0x1FFF and 1 <= height <= 0x1FFF):
        raise ValueError("PLANE_SIZE 尺寸超出 13 位字段：%dx%d" % (width, height))
    return (((height - 1) & 0x1FFF) << 16) | ((width - 1) & 0x1FFF)


def decode_pipesrc(value: int) -> Tuple[int, int]:
    return ((value >> 16) & 0x1FFF) + 1, (value & 0x1FFF) + 1


def decode_plane_size(value: int) -> Tuple[int, int]:
    return (value & 0x1FFF) + 1, ((value >> 16) & 0x1FFF) + 1


def decode_stride(value: int) -> int:
    return (value & 0x3FF) * STRIDE_ALIGN


def align_up(n: int, a: int) -> int:
    return ((n + a - 1) // a) * a


@dataclass
class PlanePlan:
    """A2"继承当前扫描面"需要的完整参数。"""
    timing: Timing
    fmt: str
    stride: int
    fb_bytes: int
    pipesrc: int
    plane_size: int
    stride_reg: int
    surf_align: int = SURFACE_ALIGN

    def to_dict(self) -> dict:
        d = asdict(self)
        d["timing"]["refresh_hz"] = round(self.timing.refresh_hz, 3)
        return d


def plan_for(timing: Timing, fmt: str = "XRGB8888") -> PlanePlan:
    st = stride_bytes(timing, fmt)
    return PlanePlan(
        timing=timing,
        fmt=fmt,
        stride=st,
        fb_bytes=st * timing.vactive,
        pipesrc=pipesrc_reg(timing.hactive, timing.vactive),
        plane_size=plane_size_reg(timing.hactive, timing.vactive),
        stride_reg=stride_reg_value(st),
    )


@dataclass
class Measured:
    """探针实测到的、已确认语义的寄存器取值（缺项为 None）。"""
    pipesrc: Optional[int] = None
    plane_size: Optional[int] = None
    plane_stride: Optional[int] = None
    plane_surf: Optional[int] = None

    def to_dict(self) -> dict:
        return asdict(self)


def compare(plan: PlanePlan, measured: Measured) -> List[str]:
    """比对"按 EDID 算出来的"与"硬件当前的"。空列表 = 完全一致。

    不一致的每一条都要能解释（像素格式/平铺/偏移/缩放），解释不了就不能继承。
    """
    diffs: List[str] = []
    if measured.pipesrc is not None:
        w, h = decode_pipesrc(measured.pipesrc)
        if (w, h) != (plan.timing.hactive, plan.timing.vactive):
            diffs.append("PIPESRC 实测 %dx%d ≠ EDID 首选 %dx%d"
                         % (w, h, plan.timing.hactive, plan.timing.vactive))
    if measured.plane_size is not None:
        w, h = decode_plane_size(measured.plane_size)
        if (w, h) != (plan.timing.hactive, plan.timing.vactive):
            diffs.append("PLANE_SIZE 实测 %dx%d ≠ EDID 首选 %dx%d"
                         % (w, h, plan.timing.hactive, plan.timing.vactive))
    if measured.plane_stride is not None:
        got = decode_stride(measured.plane_stride)
        if got != plan.stride:
            diffs.append("PLANE_STRIDE 实测 %d 字节 ≠ 按 %s 算的 %d 字节"
                         % (got, plan.fmt, plan.stride))
    if measured.plane_surf is not None:
        addr = measured.plane_surf & ~(SURFACE_ALIGN - 1)
        if addr == 0:
            diffs.append("PLANE_SURF 实测地址为 0（平面可能未启用）")
        elif measured.plane_surf & (SURFACE_ALIGN - 1):
            diffs.append("PLANE_SURF 低 12 位非 0（0x%08X），不符合 4KB 对齐" % measured.plane_surf)
    return diffs


def main() -> int:
    """自检：用本机实测锚点验证模型与硬件一致。"""
    # plane_surf 留 None：这套锚点里没有可信的扫描面地址，不能拿 0 冒充。
    measured = Measured(pipesrc=0x077F0437, plane_size=0x0437077F,
                        plane_stride=0x00000078, plane_surf=None)
    w, h = decode_pipesrc(measured.pipesrc)
    print("实测解码：%dx%d，stride=%d 字节" % (w, h, decode_stride(measured.plane_stride)))
    timing = Timing(pixel_clock_khz=148500, hactive=w, hblank=280, vactive=h, vblank=45)
    print("按 1920x1080@60 标准时序推：%s" % timing.describe())
    plan = plan_for(timing, "XRGB8888")
    print("模型算出的 stride=%d 字节（寄存器值 0x%03X），PIPESRC=0x%08X，PLANE_SIZE=0x%08X"
          % (plan.stride, plan.stride_reg, plan.pipesrc, plan.plane_size))
    diffs = compare(plan, measured)
    print("与实测差异：%s" % ("无（模型与硬件一致）" if not diffs else "; ".join(diffs)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())