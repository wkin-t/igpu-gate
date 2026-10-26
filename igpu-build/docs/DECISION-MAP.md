# 依赖关系与"能否开始编码"判定表

> 目的：把"证据 → 判据 → 结论 → 下一步"写死，避免在没有前置证据的情况下写代码，
> 也避免把"某一步失败"误当成"结论"。**未测即未知，未知不得折算成兼容。**

## 1. 依赖图（谁产出、谁消费）

```
Windows 侧（离线，可反复）                    Tahoe 现场（一次会话，只读 + 3 次重启）
─────────────────────────────                 ────────────────────────────────────────
BIOS dump / VBT 提取 ──┐                      20-dell-trip.sh 阶段 0
regs.txt（190 寄存器）─┤                        ├─ 05-kcgate.sh ──► results-kcgate-*.txt ─┐
kext 源码 (CI 编译)  ──┼──► dist/IGPUProbe.kext│  ├─ 14-a0-gate.sh ─► results-a0-gate.txt ─┤
夹具/仿真（六套）    ──┘                        └─ 01-deploy.sh（注入 + 备份 + 基线）      │
                                                                                        │
                                              阶段 1 normal  ──► results-collect-1 ─────┤
                                                ├─ 13-fb-describe ─► results-fbdescribe ─┤
                                                └─ 15-pre2b-inventory ─► results-pre2b ──┤
                                              阶段 2 off（采完拔电）──► results-collect-2 │
                                              阶段 3 normal 冷启 ────► results-collect-3 │
                                                     └─ 09-grab / tar ─► 交付目录        │
                                                                                        ▼
                                                        16-coding-readiness.sh（消费全部证据）
                                                                  │
                                                        G1 2a ─ G2 容器 ─ G3 A1 ─ G4 回滚
                                                                  ▼
                                                          能否进入正式编码
```

**读法**：箭头左边是产出者，右边是消费者。任何一环缺失，下游判定必须是 `UNKNOWN`，
不允许用"看起来正常"替代。

## 2. 编码启动的四个门

| 门 | 判据（机器可判） | 不通过时怎么办 |
|---|---|---|
| **G1 2a 判物** | 3 轮 `results-collect-*` 齐全；`mode` 依序 `normal/off/normal`；`probe_loaded` 依序 `yes/no/yes`；每轮 `material_complete=yes` | 补齐缺轮；`dirty` 先查 boot-args 与 config 基线 |
| **G2 驱动容器** | `results-a0-gate.txt` 有确定 `RESULT`（不是 `GATE-INVALID`）；`results-pre2b/02-kc.txt` 给出模块在哪个 collection；`03-auxkc.txt` 给出 SIP 与 `/L/E`、aux KC 状态 | 若 A0 = `A0-CROSS-KC-IMPOSSIBLE` 且 AuxKC 不可行 ⇒ 2b 容器未定，**不能写接管代码** |
| **G3 A1 基线** | `results-fbdescribe-*` 里 `fb_like_nodes>=1`；`results-pre2b/16-edid.txt` 解出首选时序；collect 里有 `PLANE_SURF_1_A`/`PLANE_STRIDE_1_A` 读数 | 缺哪个补哪个；EDID 解不出就用 DTD 原始字节离线解 |
| **G4 回滚链路** | 恢复 EFI 实际启动验证过一次（人工确认，写进 `results-pre2b/INDEX.txt`） | 没有可启动的恢复入口，不进 A2 |

> G2 是**决定"写什么代码"**的门，不是"能不能写"的门。G2 未定时可以先写**与容器无关**的部分
> （证据解码器、寄存器/时序模型、测试替身、编译骨架），但不能写"怎么被加载/怎么接管"。

## 3. 各阶段消费的证据（防重复采集）

| 阶段 | 需要的输入 | 已在本趟采集 |
|---|---|---|
| 2b-A2 继承扫描面 | `PLANE_SURF_1_A`、`PLANE_STRIDE_1_A`、`PLANE_CTL_1_A`、`PIPESRC_A`、aperture、fb 节点快照 | ✅ probe + fb-describe + pre2b |
| 2b-A3 稳定性 | 显示模式基线、WindowServer 错误、`pmset` 睡眠边界 | ✅ pre2b 11/12/14 |
| 2b-A4 新扫描面 | iGPU BAR/`assigned-addresses`、`IODeviceMemory`、GGTT 相关寄存器 | ✅ pre2b 05 + probe |
| 2b-A5 模式设置 | EDID 时序、DDI_BUF_CTL、TRANS_*、TRANS_CLK_SEL、PLL 选择 | ✅ pre2b 16 + probe（PLL 仍需实测） |
| 2b-B* 复用 Apple 驱动 | `AppleIntelICL*` 的 KC 归属、匹配表、SIP/隔离手段 | ✅ pre2b 02/03 |

## 4. 纪律

1. 任何 `RESULT:` 是 `UNKNOWN`/`GATE-INVALID` 的项，都**不是结论**，不得据此选路线；
2. 每轮判物只认**当轮**证据，不跨轮借；
3. 换 SMBIOS/容器/注入方式 = 基线变了，必须重新过 G1–G4；
4. 现场脚本的改动必须先过六套仿真，再重封清单（`reseal-manifests.py`）。