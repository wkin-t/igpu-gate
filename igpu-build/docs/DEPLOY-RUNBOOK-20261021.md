# Dell 现场部署 Runbook（2026-10-21 v2，Route B 修完 N1–N11）

> 原则：**先取证、再门禁、最后改 ESP；每次改动都可撤销；验收判据分开列。**
> 依据：`codex` 两轮对抗评审（14 条 F + 11 条 N）；本版所有"通过"都以脚本退出码 + 字段为准。

## 0. 决策记录

| 编号 | 决策 | 理由 |
|---|---|---|
| F6 | normal/verbose 恢复发布 `IGPUProbeState`（190 项逐值） | Phase-1 原有，prep 重写时丢失；结构化交付比日志解析可靠 |
| N1 | 采集器**结构化核验** `IGPUProbeState`（190 键 / 每值 4B / `RegsTable=190`） | 只有 C++ 发布、没有验收，仍可能"计数 190、字典缺失" |
| F13 | 验收矩阵 = **3 次启动**：normal → off → normal 恢复 | 两次只覆盖两个状态 |
| N5 | KC 门禁**先于**部署，且与部署用**同一份 dist 二进制** | 门禁对象与部署对象必须同一 SHA |
| N6 | 回滚拆三种语义：`--kext-only`（默认）/ `--from-backup DIR` / `--config` | "回到部署前"与"回到基线"不是一回事 |
| N9 | Mac 自检默认 **verify-only**；`--build` 才重建 dist 并重封 | 自检不得破坏已封存的交付集合 |

## 1. 现场前置（只读，不写 ESP）

```sh
sudo diskutil mount /dev/<EFI 分区>
sh onsite/10-probe.sh
```

判物（全硬性）：`RESULT: PASS`，且包含 `ESP 找到`、`config.plist`、`classification=baseline|injected|dirty`、
`python 可执行`、`标准库导入`、`nm 可用`、`plutil -lint Info.plist`、`ESP 空间`。
找不到 ESP/config、`df` 不可判定、显式 `--config` 不存在、python/nm 真跑失败 —— 任一都直接 FAIL，不要继续。

只读补充取证（人工记录）：

```sh
csrutil status; nvram csr-active-config; nvram boot-args
diskutil info /dev/<EFI 分区> | egrep 'Read-Only|Mount Point|Free Space'
ls -l /Volumes/EFI/EFI/OC/ | egrep 'config|vault|OpenCore'
shasum -a 256 /Volumes/EFI/EFI/OC/config.plist
```

**不要**用 `testkit` 的历史快照（CSR 全零）宣称"SIP 已放宽"；SIP/CSR 只认现场 `csrutil`/`nvram`。

## 2. 现场分类

| 分类 | 判据 | 动作 |
|---|---|---|
| `baseline` | config 哈希 `991c9de0…` 或无探针条目 | 必须 `--reinject`；先手工 cp config 到 ESP 外并记 sha |
| `injected` | 探针恰 1 条，且 `state=normal`、`canonical=yes`、`Delete` 含 `boot-args` | 可直接部署 |
| `dirty` | 其它（多条/字段不符/off/verbose/prep 等） | 拒绝；先 `--reinject` 归一或人工修 |

## 3. 目标机 KC 门禁（**先跑**，不改 ESP）

```sh
sudo sh onsite/05-kcgate.sh
```

判物：`RESULT: PASS` 且退出码 0；输出里 `binary_sha256` 必须等于 `EXPECTED_BIN_SHA`。

判定范围（2026-10-21 修正）：**只看承载该 kext 的集合**——OC 注入的 kext 由
**Boot KC（AuxKC）** 承载，所以默认只要求 `BootKernelExtensions.kc` 全解析；
`SystemKernelExtensions.kc` 不承载它，其导出表不可读时判 `INVALID` 并仅作参考
（旧版把"读不到导出表"折算成 313 个假缺失，已修）。
需要"两个 KC 都必须过"时加 `--both-required`。

- 注入目标 KC：`PASS` 才算过；`FAIL`/`INVALID`/文件缺失一律非 0 退出，**不能替代 PASS**。
- `INVALID` 的两种含义：KC 导出表不可读（换承载集合重跑）或输入不合法（查文件）。
- KC PASS 只证明符号层，不证明 ABI/加载/MMIO 安全。

## 4. 部署（事务化）

```sh
sudo sh onsite/01-deploy.sh --reinject        # 默认使用 dist/IGPUProbe.kext
# 或显式： sudo sh onsite/01-deploy.sh --reinject dist/IGPUProbe.kext
```

内部顺序：分类 → 只读检查（ESP 只读/空间/基线文件/工具真跑）→ 改前备份（ESP + `/var/tmp` 双份、唯一目录）→
暂存副本注入 + 归一到 normal → 严格校验 → 原子 `mv` → 回读 → 才替换 kext。任何失败自动恢复 config + kext。

判物：`config_before` 哈希 = 进入前哈希；探针恰 1 条；`state=normal`、`canonical=yes`、`nvram_delete_bootargs=yes`；
`binary_sha256` 与 `EXPECTED_BIN_SHA` 一致；`nm` 的 `_kmod_info` 门禁 PASS。

产物身份（kit 内 dist，勿改签）：

```
binary_sha256 = 2f0d35595c0d6c5e38d95ee4e5c9468ba647a0165b108f34df49336b2e928d84
binary_bytes  = 79976
```

## 5. 三次启动验收矩阵

| 轮次 | 启动前状态 | 采集 | 判物（脚本字段，逐项） |
|---|---|---|---|
| 1 | normal | `sudo sh onsite/02-collect.sh` | `functional_ok=yes`：身份 Yes、`RegsRead=190`、`RegsSuspect=0`、无 ProbeError、恰 1 实例、`IGPUProbeState` 190 键且每值 4 字节、`RegsTable=190`、`log_mode=last-boot`、`LOG_EVENTS>0`、`oc_log=ok`、`oc_bound=ok` |
| 2 | off | `sudo sh onsite/04-state.sh off && sudo reboot` → 采集 | `material_complete=yes` 且实例 0、属性 0（off 分支不看普通读数） |
| 3 | normal | `sudo sh onsite/04-state.sh normal && sudo reboot` → 采集 | 与第 1 轮身份/计数/字典一致，`functional_ok=yes`，证明能恢复 |

第 1 轮必须包含：`ioreg-probe.plist`、`state-verify.txt`、`kmutil showloaded`、本次启动内核日志、
OC 日志（含成功注入行、`oc_bound=ok`）、`summary.txt`、`MANIFEST.sha256`。
`log show --last boot` 不可用时降级 `fallback-30m`，只能算材料齐全，**不算功能验收**。

## 6. 导出

```sh
sh onsite/09-grab.sh --dest /Volumes/CLONEZILLA/igpu
```

必须导出：每个 `results-collect-*` 整目录（先自校验其 `MANIFEST.sha256`）、`dist/BUILD-REPORT*`、
`dist/SHA256SUMS`、`EXPECTED_BIN_SHA`、`kcgate-*.txt`、`GRAB-MANIFEST`；
复制后脚本会比对源/目标路径集合与哈希，任一不符非 0。

## 7. 回滚（三种语义，别混用）

```sh
sudo sh onsite/03-rollback.sh                     # ① 只回滚 kext（默认，不动 config/boot-args）
sudo sh onsite/03-rollback.sh --from-backup /Volumes/EFI/igpu-backup-<ts>-<pid>   # ② 回到本次部署前（config_before + kext）
sudo sh onsite/03-rollback.sh --config            # ③ 回到已知基线 config（哈希必须 = 991c9de0…）
```

② 会从该备份的 `META` 读 `config_before`/`config_before_sha`，恢复后核对哈希，再按 `EXISTED_KEXT` 恢复/移除 kext。
ESP 上的 `igpu-backup-*` / `igpu-state-*` 一律**不删**。

## 8. prep 模式（不在本轮矩阵内）

`igpu-driver=prep` 走自己的协议（`PrepMode`、`EvidenceComplete`、`PrepReadCount`、`PrepAssert` A1–A7），
**不发布** `RegsRead/RegsSuspect/IGPUProbeState`；采集器的 prep 分支已按此判定。
只有在 3 轮 normal/off/normal 验收之后才使用 prep；把 prep 当普通 normal 看会得到必然失败的判据。

## 9. 红线

- 不签名、不改签；任何签名实验都算新产物（换哈希、重登记、重封清单）。
- 不做 `reset --hard` / push；不删用户文件；不删既有备份目录。
- 现场任何一步失败：保留输出，按 ② 回滚，别在机器上改脚本。
- 若最终故意留在 off 态，必须登记为"未完成项"，不能算验收通过。