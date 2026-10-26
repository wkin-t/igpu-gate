# IGPUProbe —— Phase 1 只读探针 + Phase 2a 只读取证（kext）

> 本机：Dell OptiPlex Tower 7020 / ADL-S / iGPU `8086:4680` rev `0C`。
> Phase 1 证明四件事：**能被 OC 注入并加载、能发布可复核的读集、全程零 MMIO 写、四状态可判**。
> Phase 2a（`prep` 模式）在同样"零写"的前提下，把"接管前必须知道的事实"采集回来。
> 它**不**接管显示、**不**发布 IOFramebuffer、**不**写任何寄存器。

## 文件

| 文件 | 说明 |
|---|---|
| `IGPUProbe.cpp` | 驱动主体：boot-arg 解析、身份三元组校验、BAR0 只读映射、190 项快照、prep 取证 |
| `Info.plist` | bundle id `dev.igpu.probe`；`OSBundleRequired=Root`；personality 匹配 `IOPCIDevice` + `0x46808086` |
| `IGPUProbeState.hpp` | **生成物**（勿手改）：190 项读集表，由 `regs.txt` 生成 |
| `build.sh` | macOS 侧构建脚本（`nm` 定义符号门禁 + 架构检查） |
| `README.md` | 本文件 |

## 四种运行模式（boot-arg `igpu-driver=`，**不带前导 `-`**）

| 值 | 语义 | ioreg 表现 |
|---|---|---|
| 缺省 / `normal` | 匹配并发布 190 项快照 + 摘要属性 | 1 实例、属性完整 |
| `verbose` | 同 normal，另逐条打 IOLog | 1 实例、属性完整 |
| `off` | `probe()` 直接 `return 0`（行为 ≡ 无 kext） | **无实例、无属性**；`kmutil` 仍列出 |
| `prep` | **Phase 2a 只读取证**：身份校验 → BAR0 只读映射 → 断言/readiness → 发布属性 | 1 实例、prep 属性组 |

`-igpu-driver=off` 是无效写法：XNU 把前导 `-` 当布尔开关，`PE_parse_boot_argn` 永远匹配不到，会静默回落 `normal`。

## prep 模式发布什么（2026-10-20 红军评审 9 条修订后）

| 属性 | 内容 |
|---|---|
| `PrepMode` | 固定字符串 `prep: read-only evidence` |
| `PrepRoute` | A/B 两路 `TRANS_DDI_FUNC_CTL` / `TRANS_CLK_SEL` 原始值（hex 字符串）、端口/模式/时钟字段解码、**`EnableCount`** 与 **`TargetPortCount`** 分开统计、`ActivePipe`、`Failure` |
| `PrepAssert` | `A1..A7`，值形如 `pass` / `fail:<原因>` / `unknown:<原因>` |
| `PrepDisplay` | 活动 pipe 的原始值 hex + 宽高/stride 解码、`PlaneCtlRaw`、`PixelFormatContract` |
| `PrepGTT` | `Bar0Length`、`GttArrayOffset/Length`（MMIO 布局）、**`GmadrApertureLength`（GMA 孔径，真正的 SURF 上界）**、`SurfRaw` / `SurfOffset`（**bits[31:12]**）/ `SurfFlags`（**bits[11:0]**）、`BufferNeed`、`SurfInAperture`、`NeedFitsAperture`、`SurfaceLengthProven=no` |
| `PrepReadiness` | `IONDRVCount`、`EnumComplete`、`R2Detail`（provider 归属/inactive/枚举截断）、`HolderAlive`、`opened=unknown`、`verdict` |
| `PrepRegs` / `PrepRegState` | 15 个相关寄存器的读数与三态（`valid` / `invalid` / `unavailable`） |
| `PrepConnFlags` | `display-connect-flags`：优先在目标 framebuffer 子树找，记录 `Source`（candidate-subtree / pci-subtree / pci-self）、`SourceEntryID`、`BelongsToTarget`、`Type`。`OSNumber` 超过 32 位或 `numberOfBits>32` ⇒ `unknown:exceeds-32bit-contract`（保留 `RawBits`/`Raw64`）；`OSData` 长度 ≠ 4 ⇒ `unknown:data-length-contract` / `unknown:data-short`；回退命中（pci-subtree/self）只给 `unknown:not-target-display`，**不得**写成已确认 |
| 顶层标量 | `PhysicalIdentityVerified`（prep 成功路径也发布）、`PrepReadCount` / `PrepInvalidCount` / `PrepUnavailableCount` / `PrepPublishFailures`、`PrepRequiredBytes`、**`EvidenceComplete`**、`EvidenceErrors` |

### A1–A7 判据（每条都写明"为什么不会被空 pipe / 无效读数 / TC4 别名骗过"）

| 断言 | 判据 |
|---|---|
| A1 路由 | 两路 `TRANS_DDI_FUNC_CTL` 必须 `valid`；`EnableCount`（bit31）必须**恰为 1**（两路 enable ⇒ 拒绝，spec 字面）；端口字段按 TGL+ 口径 `(v>>27)&0xF` 必须 = **6（TC3）**；模式字段 `(v>>24)&7` 必须 = 2（DP SST）；`TRANS_CLK_SEL_{P}` 的 `bits[31:28]` 必须 = 6。**旧口径 `(v>>28)&7==3` 会让 TC4 例 `0xBA030106` 也得到 3**，本实现不再使用 |
| A2 使能 | `PLANE_CTL_1_{P}` 与 `DDI_BUF_CTL_TC3` 都必须 `valid` 且 bit31=1。**`0xFFFFFFFF` 是 invalid，不得当"使能"**（旧实现只看 bit31，会假绿） |
| A3 线性/未压缩/格式 | tile `bits[12:10]==0` **且** render decompression `bit15==0` **且** media decompression `bit4==0`（TGL+）**且** 格式字段 `(v & 0x0F800000) == 0x04000000`（**ICL+ 是 bits[27:23]**，XRGB8888/32bpp 合同）。**反例 `0x84800008` 的 bit23=1 ⇒ 字段值 9≠4 必须 fail**；旧写法只取高 4 位会把它误判成 4 |
| A4 尺寸 | `PIPESRC`（**高 16=宽-1、低 16=高-1**）与 `PLANE_SIZE_1_{P}`（**低 16=宽-1、高 16=高-1**）且**按完整 16 位**解码（`0xFFFF`），先查平台上限 8192，再要求两者一致且 = 1920×1080；任一读数非 valid 即 fail。**反例 `PLANE_SIZE=0x0437177F`（宽 6016）不能用 `&0xFFF` 掩成 1920** |
| A5 stride | `strideUnits = raw & 0xFFF`，`strideBytes = units × 64`（**从第一次乘法起 UInt64**）；高位 `raw & ~0xFFF` 非零即 fail。**反例 `0x04000078` 用 32 位整体乘会回绕成 7680 假绿** |
| A6 范围 | **三个空间分开**：BAR0 只是寄存器窗口，`GttArray*` 只是 MMIO 里的页表窗口，`PLANE_SURF` 是 **GMA 地址**，上界必须用 GMADR 孔径（实测 256 MiB）。允许 `SURF=0`；用 `need <= aperture - surf` 判末端（UInt64，避免加法溢出）；**不能证明现有扫描面长度 ⇒ 只能是 `unknown:surface-length-unproven`，不得用窗口长度冒充 pass** |
| A7 buffer | `bufferNeed = strideBytes × 高` **独立于 A6** 计算（BAR2 未映射/孔径未知时仍要发布真实需求，如 8,294,400）；只发布 `PrepRequiredBytes` 与状态 `recorded`；**本阶段不分配 buffer**，`recorded` 不代表"buffer 长度已验证" |

### verdict / EvidenceComplete

- `verdict = ready` 需要：A1–A6 全 `pass`、R1/R2 全过、枚举完整、无 invalid/unavailable 读数；任一 fail/unknown ⇒ `not-ready:<原因>`。
- 按上面 A6 的口径，**prep 阶段 A6 必然是 `unknown:surface-length-unproven`** ⇒ 2a 的 `verdict` 预期就是 `not-ready`。
  因此 Phase-2b 的 GO 判据不能用"A1–A7 全 pass"，应改为
  "**A1–A5 pass + A6 的孔径检查通过（值为 unknown）+ A7 recorded + R1/R2 通过 + `EvidenceComplete=yes`**"。
- `EvidenceComplete` 只在"发布无失败 + 无 invalid/unavailable 读数 + 枚举完整 + 候选对象持有引用 + bufferNeed>0
  + **必需键/类型回读通过**"时为真。顶层标量（身份、计数、`PrepRequiredBytes` 等）也走带返回值的发布 helper，
  失败键名进 `EvidenceErrors`；`EvidenceComplete`/`EvidenceErrors` 自身发布失败会打 IOLog。
  它回答"这份报告是否齐全"，不回答"能否接管"。

## normal 模式的读数交付通道（F6）

- `RegsRead` / `RegsSuspect`：计数与可疑数（读回 0xFFFFFFFF 记 suspect）。
- **`IGPUProbeState`**：OSDictionary，键=寄存器名，值=`OSData` 4 字节小端 —— 190 项逐值都在这里。
- `RegsTable` / `RegsTableFormat`：发布条目数与格式标记，用于判断是否齐全。
- `verbose` 额外把同样的值逐行打进内核日志（冗余通道，不再是唯一来源）。

为什么恢复：Phase 1 的 normal 本来就有 `IGPUProbeState`；prep 重写时 `publishSummary()`
只剩计数，采集器因此拿不到逐项值。F6 把它恢复为结构化交付，避免让大家去解析日志。

## 红线（`tools/check-kext-source.py` 静态扫 + 人工复核）

1. **零 MMIO 写**：源码里不得出现 `OSWriteLittle*`/`outl`/裸指针赋值（当前仅注释提及）。
2. **不读 EDID**：GMBUS/AUX 事务需要写总线控制寄存器。
3. **身份不符不碰 MMIO**：vendor/device/revision 三元组必须先校验。
4. **fail-closed**：异常只记属性与日志，不阻塞启动。
5. prep 不 `message()`、不 `terminate()`、不 `attach()`、不切 `PLANE_SURF`；BAR 映射只读使用。

## 构建与验证

```sh
sh kext/IGPUProbe/build.sh          # macOS：clang + nm 定义符号门禁（缺 _kmod_info 即 exit 7）
```
- `_kmod_info` 必须由 `KMOD_EXPLICIT_DECL` 在源码里定义（`libkmod.a` 里只有未定义引用）；
- Windows 侧可跑：源码红线静态检查、桩件仿真（state/deploy/collect 共 92 项断言）。

## 已知未知

- macOS 专有构建门禁（`clang`/`nm`/`kcgate`/`kextutil`）只能在 Mac 上验证；
  本轮**未编译**，以下 API 依赖需在 Mac 构建时确认：
  `OSMetaClassBase::metaCast(const char *)`、`IOService::isInactive()`、`OSData::getBytesNoCopy(offset,len)`。
- A6 的"现有扫描面长度"在 prep 阶段无法取证 ⇒ 固定 `unknown`；2a 的 GO 判据必须相应改写（见上）。
- `opened` 无公开只读属性，prep 阶段只能诚实记 `unknown`。
- `GttArrayLength` 依赖 "BAR0 前 8 MiB 是寄存器窗口" 的 gen9+ 布局假设；它只作信息字段，不参与判定。

## 相关文档

- `.scratch/igpu-driver/spec.md` §1.3（Phase 1 验收）、§2（Phase 2 接管序列）
- `.trellis/tasks/10-19-phase2-dp-takeover/design.md` / `implement.md`
- `build/deploy-20261019/PHASE1-EXIT.md`、`relations-review-166.md`
- 红军评审：`.tmp/codex-prep-review-out.md`（9 条必修）、`.tmp/codex-prep-review2-out.md`
  （第二轮 8 条：N1–N6 + R1–R2，外加同文件要求的 R3；本版已逐条落实）
