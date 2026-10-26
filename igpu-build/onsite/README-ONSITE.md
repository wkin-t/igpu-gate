# onsite/ —— 现场脚本（macOS 侧，一律 `sh xxx.sh`，不要 `./xxx.sh`）

FAT32 不保存可执行位，所以必须用 `sh` 调用。

| 顺序 | 命令 | 作用 | sudo |
|---|---|---|---|
| 1 | `sh onsite/00-build.sh` | 哈希校验 → R1–R8 → 构建 → `_kmod_info` 已定义判定 → 本机 KC 符号预检 | 否 |
| 2 | `sudo sh onsite/01-deploy.sh` | 三重身份校验 → 完整备份 → 暂存替换 → 双哈希复核 → sync/卸载 | 是 |
| 3 | `sudo reboot` | 重启进 Tahoe | — |
| 4 | `sh onsite/02-collect.sh` | 采集加载状态/实例/属性/OC 日志 → `results-collect-<时间>/` | 否（要 OC 日志建议 sudo） |
| 状态 | `sudo sh onsite/04-state.sh show` / `off` / `verbose` / `normal` | 切 boot-args（严格预检 + 独占备份 + 暂存 rename + 事后核对） | 是 |
| 回滚 | `sudo sh onsite/03-rollback.sh [--config]` | 从最近**完整**备份还原 kext（可选还原基线 config） | 是 |
| 取证 | `sh onsite/09-grab.sh [构建目录]` | 把构建报告/产物诊断搬到 U 盘，失败返回非零 | 否 |

## 通过标准

**第 1 步**必须出现这三行，缺一不可：

```
_kmod_info 已定义 ✓          （nm -gU 判定，不是 strings）
KC 符号预检：PASS
===== 结论：可以部署 =====
```

**第 2 步**会打印：

- `卷名/偏移: OCEFI / 1048576 ✓`
- `config.plist: d902a337… → 与部署版一致 ✓`
- 备份目录 `igpu-backup-<时间>/`，里面是 `STATE=complete` + `META` + `config.plist` + `IGPUProbe.kext` + `SHA256.old`
- 结束时 `二进制 ✓ plist ✓ config 未变 ✓` 与 `已卸载 ✓`

**第 4 步**看 `summary.txt`：

```
probe_loaded=yes
instances=1
identity=Yes
gpuaccess=none: MMIO reads only
regs_read=190
regs_suspect=0
oc_log=ok
evidence_complete=yes
```

> `GPUAccess` 是**字符串**不是 bool；`RegsRead` / `RegsSuspect` 是**整数**不是 Yes/No。
> 这三条以前写错过，采集脚本现在按真实类型取。

## 脚本自己会拦住的情况

| 情况 | 行为 |
|---|---|
| 产物没有**已定义**的 `_kmod_info`（`U _kmod_info` 不算） | 构建 exit 7、部署直接拒绝 |
| KC 符号预检失败 | 构建 exit 8，不允许部署 |
| 卷名不是 OCEFI / 偏移不是 1048576 / OCEFI 候选不止一个 | 中止并打印 `diskutil list` |
| `config.plist` 哈希不在白名单 | 中止（说明有人改过配置） |
| 备份不完整（`STATE≠complete`）或哈希缺失 | 回滚拒绝，不猜 |
| 暂存副本哈希不符 | 中止，原 kext 保留不动 |
| 替换过程中被 Ctrl-C / 断电 | EXIT 陷阱把旧 kext 放回；备份目录仍在 |

## 备份与回滚

每次部署都建 `ESP 根/igpu-backup-YYYYmmdd-HHMMSS/`。**不要删这些目录**，它们是唯一现场恢复点。
回滚只认 `STATE=complete`；`--config` 用的是 ESP 上那份 `config-before-probe-20261019.plist`（哈希必须是基线 `991c9de0…`），不会拿部署版备份冒充基线。
## 四状态矩阵（验收 b/d/e）

```sh
sudo sh onsite/04-state.sh show      # 只看当前状态，不改文件
sudo sh onsite/04-state.sh off       # 判据 d：off 应 ≡ 无 kext
sudo reboot
sysctl -n kern.bootargs              # 必须出现 igpu-driver=off
sudo sh onsite/02-collect.sh         # 加 sudo 才能拿到 OC 日志（evidence_complete=yes）
```

预期（判据 d）：`kmutil showloaded` 仍能看到 `dev.igpu.probe`，但
`ioreg -r -c IGPUProbe` **无实例、无属性**（驱动在 probe 阶段 `return 0`）。

切换 `verbose` 只增加日志量，属性应仍然完整；切回 `normal` 应去掉
`igpu-driver=` 令牌，得到与**首次部署态**逐项一致的寄存器快照（用于等价性对照）。

`04-state.sh` 会拒绝的情况（都不会改动配置）：

- `NVRAM/Delete` 里没有 `boot-args`（OC 的 Add 只在变量不存在时写入，改了不生效）；
- 探针条目不是"恰好一条 + 字段完全匹配 + Enabled=true"；
- boot-args 里出现非规范写法（`-igpu-driver=off`、大写、重复 token）时会**先归一化再写**，
  但若归一后的状态已经等于目标，则直接退出、不建备份。

每次切换都会新建 `ESP/igpu-state-<时间>-<pid>-<n>/`（`TYPE=config-state`、`old_sha`、`mode_from/to`），
与回滚脚本认的 `igpu-backup-*` **前缀不同**，不会互相抢占。
## 第五轮补强（codex F5/F7/F8/F9）

### F5：部署前必须补跑目标机 KC 门禁（只能在 Dell 上做）

`sh onsite/00-build.sh` 的 KC 预检用的是**构建机**的 KernelCollections；Mac mini 的 PASS 不能替代 Dell。
部署前单独跑：

```sh
sudo sh onsite/05-kcgate.sh
# 或显式指定：sudo sh onsite/05-kcgate.sh --boot-kc <path> --system-kc <path>
```

判物：每个 KC 单独给 `PASS` / `FAIL` / `UNKNOWN`，最后一行 `RESULT: PASS` 才算过；
`UNKNOWN`（KC 缺失或门禁 INVALID）**不能替代 PASS**，退出码非 0。
默认路径是 `/System/Library/KernelCollections/BootKernelExtensions.kc` /
`SystemKernelExtensions.kc`；BootKC 缺失时会按 Preboot 唯一候选回退。
它只覆盖符号层，不证明可加载、ABI 兼容或运行正常。

### F7：`summary.txt` 现在是两段式

```
material_complete=yes|no      # 材料：工具、文件、归档、OC 日志文件、启动证据
material_fail=<清单>           # no 时列出缺哪项
functional_ok=yes|no          # 探针功能：身份/读数/实例数/日志绑定/注入证据/prep 属性
functional_fail=<清单>         # no 时列出失败项（identity、regs-read、instances-not-1…）
evidence_complete=yes|no      # 仅当上面两者都 yes
```

normal/verbose/prep 的功能判据（缺一即 no）：`PhysicalIdentityVerified=Yes`、
`GPUAccess` 以 `none: MMIO reads only` 开头、`RegsRead=190`、`RegsSuspect=0`、无 `ProbeError`、
**恰好 1 个实例**、`log_mode=last-boot`、`oc_log=ok`；prep 另加 `PrepMode=prep`、
`EvidenceComplete=Yes`、`PrepReadCount>0`。off 仍是"已加载 + 0 实例"。

### F8：日志与 OC 证据绑定本次启动

- `log_mode=last-boot` 才算功能验收；降级记 `log_mode=fallback-30m`，只算材料齐全。
- OC 日志除了非空，还要求其中含 `IGPUProbe`/`igpu-driver` 注入行，并与 `kern.boottime`
  做 mtime 关联（`oc_boot_bound=ok|mismatch|unknown`）；否则 `oc_log=unverified`，功能验收不过。
- `opencore-latest.txt`、`injection-lines.txt` 已进 `CORE_FILES`，受 `MANIFEST.sha256` 保护。

### F9：`09-grab.sh` 重写

```sh
sh onsite/09-grab.sh [--dest DIR]
```

- 默认源 = **脚本所在 kit 根**（`onsite/..`），不再假设 `~/igpu-build`；
- 默认目标 `/Volumes/CLONEZILLA/igpu`，否则 `<kit>/evidence-export`；
- 导出所有 `results-collect-*` 整目录、`results-*/report.md|summary.txt`、`config*.plist` 快照；
- 复制后逐文件复核 sha256，生成 `GRAB-MANIFEST` 并再复核；任一失败或**没有任何采集目录**即返回非零。
