# W1 移植面清单：IntelIGPU-Tahoe → ADL-S 8086:4680

日期：2026-11-06 | fork：`D:\IntelIGPU-Tahoe`（`adl-s` 分支，基于上游 `9baa4bb`）
证据等级：**源码** = 读 fork 源码；**反汇编** = 用 capstone 读 TGL 原料 `tgl-samples/ng/tgl_sle.bin`（NootedGreen SLE 线，LC_UUID 与上游输入一致，整文件哈希不同）；**推测** = 未验证。
工具：`.scratch/igpu-driver/tools/tgl_devid_scan.py`、`tgl_disasm.py`、`tgl_disasm_all.py`、`tgl_extrel.py`（只读）。

## 1. 结论先说

1. **P2 所需的"只初始化加速器、显示仍走 IONDRV"上游已经有了**：`ManualActivation` 的 `PrepareRuntime` 动作只加 runtime personality，加速器 `start` 时跳过 `registerService`（6 字节 NOP），IONDRV 一直在，直到 `CommitDisplay` 才发布（源码：`gate.cpp:185-198`、`session.py:191-234`）。我们只需要把流程截在 `PrepareRuntime` 之后，不调 `PrepareDisplay`/`CommitDisplay`。
2. **TGL 加速器在 `probe` 里按设备 ID 映射 SKU，0x4680 不在表里，不改会 panic**（反汇编，见第 3 节）。表里只有 `0x9a40`、`0x9a48`（→ SKU 2 = TGL GT2 LP）以及仿真用的 `0xff20`、`0xdeafbeef`。P-0002 替换的是 `0xff20` 那一项，因为只有它在 `0x46808086` 走得到的分支上。映射失败走 `probe.cold.1`，打印 `Failed to map Device ID ... to GPU SKU!` 后进入 panic 路径（`@tgl/IntelAccelerator.cpp:1141`）。
3. **上游 46a3 同样不在这张表里**，所以上游实际用的二进制（SHA `ae99582b…`）几乎可以肯定在这里打过补丁。这也能解释票 05 里"结构断言全过、整文件哈希不同"：差异未必只是重签名（推测，上游未公开）。
4. **ADL-S GT1 的拓扑会落到一条"仅仿真器可用"的分支**：`getGPUInfo` 在 SKU 2 下只接受 1 slice × 12 subslice（96EU），或 1 slice × 4 subslice 但要求 `+0x1190` 的 bit5（`setInSimulator` 置位，只有设备 ID 为 `ff20`/`deafbeef` 时才置）。本机 32EU = 2 DSS = 4 subslice，非仿真器 ⇒ 打印 `Invalid NumSlice or NumSubSlices for TGLLP GT2` 后**继续**执行，但 `L3BankCount`（`+0x1164`）不会被赋值（推测保持 0）。需要再补一个字节补丁让它走 4-subslice 分支（L3BankCount = 4）。
5. 读取设备 ID 用的是真实 PCI 配置空间（`IOPCIDevice::extendedConfigRead32`，反汇编 `0x2399d`）。OC 注入的 `device-id=ffff` 只改 IORegistry 属性和 `savedConfig`，**不改**硬件读取（IOPCIFamily-726 源码：`IOPCIBridge::checkProperties` 只写 `savedConfig`；`IOPCIDevice::configRead32` 直通 parent）。所以 SKU 映射看到的是真 ID `0x46808086`。

## 2. P1/P2 范围内的移植项

| # | 位置 | 原值 | ADL-S 目标 | 阶段 | 证据 |
|---|---|---|---|---|---|
| 1 | `desktop-manual-20260917/fix/manual-gate/gate.cpp:24` `isolatedADLP` | `DeviceID==0x46a3` | 白名单 `{0x46a3, 0x4680}`，编译期常量，不放通配 | P1/P2 | 源码 |
| 2 | 同上 `:25` | `RevisionID==0x0c` | 本机也是 `0x0c`，保持；改成与 #1 同一张表的成对条目 | P1/P2 | 源码 + 本机实测 |
| 3 | 同上 `:13` `kPCIPath` | `.../PC00/AppleACPIPCI/GFX0@2` | 本机 Tahoe 实测路径【待 P1 现场确认】；ADL-S 台式机 ACPI 名可能不是 `GFX0`（需 OC 重命名或 SSDT） | P1 | 推测 |
| 4 | `profiles.plist` / `profiles.hpp` runtime/selftest personality | 匹配 `device-id=ffff0000`、`revision-id=0c` | 不变（隔离值与设备无关） | — | 源码 |
| 5 | `prepare-deferred-runtime.py:10-11` | 整文件 SHA `ae99582b…` | 改为票 16 的结构断言 + LC_UUID（`F01`） | P1 | 源码 + 票 16 |
| 6 | `prepare-deferred-runtime.py` 新增补丁 P-0002 | TGL `0x23c54`：`81 ff 86 80 20 ff`（`cmp edi,0xff208086`） | 立即数改为 `0x46808086`（字节 `86 80 80 46`），0x4680 → SKU 2。**更正 2026-11-07**：原方案改 `0x23c2f`（`0x9a48` 项）走不到：比较链第一跳是有符号 `jg`，`0x46808086` 为正，永远进第二分支，见第 3 节。脚本现在模拟比较链来断言可达性 | P2 | 反汇编 + 比较链模拟（本地样本 `tgl_sle.bin`） |
| 7 | 新增补丁 P-0003 | TGL `0x287ea`：`74 12`（4-subslice 分支要求仿真器标志） | 改为 `90 90`，让 1×4 拓扑取 L3BankCount=4 | P2 | 反汇编；运行效果推测 |
| 8 | 同脚本 `:47` 版本号 | `16.0.3` | 保持；`ManualActivation`/`DesktopLink` 的 `OSBundleLibraries` 依赖这个版本 | — | 源码 |
| 9 | `session.py:136` | `sw_vers == 25G83` | 不变（本机同 build） | — | 源码 |
| 10 | `session.py` 流程 | cold → prepare → commit → video → desktop | 新增 `--accel-only` 模式：只等到 `start` 返回成功（代码里叫 `hidden_ready`：实例存在、未发布、PCI 空闲），不 `PrepareDisplay`、不加载 DesktopLink、不碰桌面。完整流程在非 `0x46a3` 上拒绝。Metal 枚举挪到 P3（未发布的加速器用户态看不到） | P2 | 源码 |
| 11 | `session.py` `verify_receipt_bundle(LINK, …)`、METAL | 必需 | `--accel-only` 下 DesktopLink 与 Metal 包都不检查、不加载 | P2 | 源码 |
| 12 | `docs/DEPLOY-SAME-HARDWARE.md` 背光 kext | OC `Kernel/Add` ReimsADLBacklight | 台式机不部署（外接显示器无 PWM 背光） | P1 | 源码 |
| 13 | OC 增量 | GFX0 `device-id=ffff0000`；Block `com.apple.driver.AppleIntelTGLGraphics`、`lab.reims.ReimsADLDesktopLink`（Exclude, Darwin 25） | 相同；DevicePath `PciRoot(0x0)/Pci(0x2,0x0)` 本机一致【P1 核对】。Block 只作用于 Boot KC，对 System KC/AuxKC 里的 kext **可能无效**，不能当保护依赖；`device-id` 隔离对 Sonoma 也生效 | P1 | 源码；Block 效果推测 |
| 14 | SIP | 上游文档未写 | `csr-active-config=03000000`（放宽未签名 kext + 文件系统）。不含 `0x200`，新装 kext 需用户批准一次（与上游部署文档一致，现场脚本有 `awaiting-approval` 阶段）。**整机生效，无法只放宽 Tahoe**（已确认接受）；`WriteFlash=true` 时回滚后要再经这个 OC 启动一次才写回 `00000000` | P1 | 取值未经真机验证 |

## 3. TGL 加速器设备识别（反汇编摘录）

```
probe (0x238e2):
  0x2399d  extendedConfigRead32(2)          -> [this+0x1118]   ; 真实 VID/DID
  0x239e9  cmp eax,0xdeafbeef / 0x239f0 cmp eax,0xff208086 ; 仿真 ID 跳过 -allow3d 检查
  0x23a01  PE_parse_boot_argn("-allow3d")   ; 非仿真 ID 且无 -allow3d → "Failing probe"
  0x23c1f  cmp edi,0xdeafbeee; jg 0x23c3c    ; 有符号比较，把设备 ID 分成两支
  0x23c27  cmp edi,0x9a408086  -> SKU 2      ; 负数一支：真 TGL ID 高位为 1
  0x23c2f  cmp edi,0x9a488086  -> SKU 2      ; 0x46808086 为正，走不到这里
  0x23c37  call probe.cold.1
  0x23c3c  cmp edi,0xdeafbeef  -> SKU 1      ; 正数一支（含大于 0xdeafbeee 的负数）
  0x23c54  cmp edi,0xff208086  -> SKU 2      ; ← P-0002 改成 0x46808086
  else     probe.cold.1: "Failed to map Device ID: 0x%x to GPU SKU!" (IntelAccelerator.cpp:1141)
getGPUInfo (0x2847e):
  SKU 2: slice==1 && subslice==12 → L3Bank=8；
         slice==1 && subslice==4 && (flags&0x20) → L3Bank=4   ; 0x287ea je ← P-0003 NOP
         否则打印 Invalid … TGLLP GT2 并继续
initHardwareCaps (0x2a666): 按 SKU 1/2 分支，其余失败
```

**`-allow3d` 前提**：非仿真设备 ID 必须带 boot-arg `-allow3d`，否则 probe 直接失败（安全，不 panic）。上游部署文档没写这一条，推测上游 boot-args 里有。P2 现场包要在 Tahoe 的 boot-args 里加 `-allow3d`。

## 4. 其余 46a3 / ADL-P 绑定（P3 以后）

| 位置 | 内容 | 阶段 |
|---|---|---|
| `ReimsADLDesktopLink.cpp:22,152,295,346,514,566-567` | `kADLP46A3`、RCS 策略"exact-46a3"（Wa_1607297627） | P3 |
| `intel_framebuffer.cpp:300` | 设备 ID、1920×1080、pipe A、plane 1 | P3 |
| `display_timing.hpp:4,29-76` | display 13、transcoder A → combo PHY A、DP SST | P3 |
| `command_capture.hpp:3` | "ADL-P 46a3 rev 0c only" | P3 |
| `video-decode-candidate/.../publisher.cpp:31` | 设备 ID | P3 之后 |
| `source/backlight/*` | 背光 PWM、`0x46a38086` personality | 不移植 |

## 5. 未知项（必须靠 P2 现场回答）

1. 改了 SKU 映射后，`initHardwareCaps`、`InitTglLpHwWaTable(devid, rev)`、GuC 固件加载能否在 ADL-S 上通过（ADL-S 的 GuC 固件版本与 TGL 不同，TGL 驱动自带的固件能否被 ADL-S 硬件接受是最大风险）。
2. 32EU 拓扑下用户态 MTL 驱动与 libigdmd 是否有自己的 EU/SKU 假设。
3. ADL-S 的 GT 工作区（Wa）与 TGL-LP 的差异；RCS 挂起风险。
4. Tahoe 上 ACPI 节点名与 `kPCIPath` 是否一致（现场第 1 步和 P1 都逐字核对）。

**P2 通过的含义**：`IntelAccelerator` 的 `start` 返回成功、日志无失败行。SKU 2 和 L3Bank 4 是补丁改出来的，只说明补丁生效，不是硬件验证；上面这些未知项，P2 通过也不算回答了，要读 `igpu-classified.txt` 里的 GuC/固件行。
