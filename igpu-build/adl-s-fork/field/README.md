# field/ —— ADL-S 8086:4680 现场包（P1 开机隔离 + P2 只激活加速器）

只适用于：Dell OptiPlex 7020 / UHD 770（`8086:4680` rev `0c`）/ macOS Tahoe `25G83` / U 盘上的 OpenCore（卷名 `OCEFI`，分区偏移 1048576）。

## 一条命令

```sh
sudo sh field/adl-s-field.sh            # 每次都跑这一条，脚本自己判断该做哪一步
sudo sh field/adl-s-field.sh --status   # 看进度（状态目录只有 root 可读，不带 sudo 也会自动提权）
sudo sh field/adl-s-field.sh --rollback # 一键回到部署前（之后重启）
```

| 第几次 | 做什么 | 之后 |
|---|---|---|
| 1 | 预检（系统版本、真实设备 ID、GFX0 完整路径、恢复 EFI 已验证、TGL 原料结构断言、预编译件收据），备份并写入 OC 增量 | 重启 |
| 2 | 确认 SIP 已放宽、`-allow3d` 已生效、GPU 已隔离（`device-id=ffff`）；工作副本收回写权限（root:wheel、go-w）；本机打补丁生成 TGL 运行时；放入 `/Library/Extensions` 并重建 AuxKC | 重启（如弹出“系统软件已被阻止”，先批准） |
| 3 | **P1 判定**：两个 kext 已加载且 UUID 与本次构建一致，GPU 仍隔离，GFX0 完整路径等于 `gate.cpp` 的 `kPCIPath`，只有 1 个固件帧缓冲，没有加速器 | 保存工作 |
| 4 | **P2**：`igpu-start --accel-only`，只等到加速器的 `start` 返回成功，不发布、不碰显示；判据见下节 | 带回证据 |

P2 若导致死机：重启后再跑同一条命令，脚本识别出"P2 期间重启"，只收集本次尝试时间之后的 panic 报告和日志，然后停下。运行时匹配规则只活在当次开机里，重启后自动回到 P1 状态。

Ctrl-C、关终端、进程被杀**不算崩溃**：阶段记为 `p2-interrupted`，这次开机里不许重试（GPU 可能已开始初始化），重启后再跑会先复核 P1。

## P2 判据：通过了说明什么

**`P2=PASS` 只说明 `IntelAccelerator` 的 `start` 返回成功，且日志没有失败行。它不证明 GPU 能工作**：GuC、固件、命令提交都没有被验证。

| 记录项（`summary.txt`） | 含义 |
|---|---|
| `found_device_id` / `found_revision` | `probe` 日志 `Found device with ID` 读到的真实身份，必须是 `0x46808086` / `0xc` |
| `patch_effective` | `HWCAPS - GPU Sku: 2` 且 `L3BankCount: 4`。这两个值是 P-0002/P-0003 改出来的，**只算补丁生效，不算硬件验证** |
| `hw_topology` | EU 32、1 slice、4 subslice，来自熔丝，才是硬件事实 |
| `igpu_lines` / `igpu_guc` / `igpu_firmware` / `igpu_fail` / `igpu_warn` | 全部 `[IGPU]` 行按 GuC / 固件 / 失败分类的计数，全量在 `igpu-classified.txt`，一行可带多个标签。`fail`（fail、error、panic、timeout、hang 等）大于 0 记 `P2=PARTIAL`；`warn`（disabled、invalid 等，在良性消息里也常见）只计数，不参与判定 |
| `found_device_id` 的格式 | 补丁脚本断言 TGL 原料里正好有一条 `Found device with ID 0x%08x, revision 0x%x,` 格式串，和解析器一致 |
| `firmware_version` | 见到 `Graphics Firmware Version` 就记版本，否则 `not-seen`（只是记录，不是判据） |
| `p2_outcome` | 见下表 |

| `p2_outcome` | 判定依据（session 的 `failure.json` 优先，其次 IOService 状态 + 日志） | 结论 |
|---|---|---|
| `preflight-failed` | `failure.json` 的 stage 是 preflight | 预检没过，GPU 未动 |
| `probe-failed` | 没有 `IntelAccelerator` 实例，日志没有 `Found device` 或有 `Failing probe`/`Failed to map` | `probe` 拒绝，或匹配没运行 |
| `start-failed` | 没有实例，但见过 `Found device` 且 `probe` 没拒绝 | `start` 返回了失败，实例被摘除 |
| `start-stuck` | 有实例，但 PCI 仍忙 | `start` 没有返回 |
| `start-returned` | 有实例、PCI 空闲、未发布 | `start` 返回成功 |

完整流程（不带 `--accel-only`）在 ADL-S 上一律拒绝：`session.py` 读探针的真实 `PhysicalDeviceID`，非 `0x46a3` 就在任何显示操作前停下；`gate.cpp` 的 `PrepareDisplay`/`CommitDisplay` 也返回 unsupported。显示代码（DesktopLink、原生帧缓冲）目前还是 ADL-P 专用。

## 前置

- 恢复 EFI 已人工验证：`echo ok > ~/RECOVERY-EFI-VERIFIED.txt`（门 G4，否则第 1 步拒绝）。
- 本地合法取得的 `AppleIntelTGLGraphics.kext`（16.0.0），默认放在 `/Volumes/CLONEZILLA/igpu-tgl-input/`，可用 `IGPU_TGL_INPUT` 覆盖。仓库不包含、也不分发它。
- `prebuilt/`：CI 产物 `adl-s-prebuilt`（ManualActivation kext、control、收据），放在仓库根下。

## OC 增量（`oc_delta.py`，除此之外不改任何键）

- `DeviceProperties/Add/PciRoot(0x0)/Pci(0x2,0x0)/device-id = FFFF0000`
- `Kernel/Block`：`com.apple.driver.AppleIntelTGLGraphics`、`lab.reims.ReimsADLDesktopLink`（Exclude，Darwin 25）。**这两条可能无效**：OC 的 Block 只作用于它处理的 Boot KC，而 TGL 在 System KC、我们的运行时在 AuxKC，都够不到。真正挡住自动匹配的是开机隔离（`device-id=FFFF`）和运行时 kext 里被清空的 `IOKitPersonalities`，不要依赖 Block。
- `csr-active-config = 03000000`（`CSR_ALLOW_UNTRUSTED_KEXTS | CSR_ALLOW_UNRESTRICTED_FS`）。**未经真机验证**：它不含 `0x200`（`CSR_ALLOW_UNAPPROVED_KEXTS`），装进 AuxKC 的第三方 kext 可能要在“系统设置 → 隐私与安全性”里批准；ad-hoc 签名的 kext 是否有“允许”按钮也未知。P1 失败时脚本会抓 `kmutil inspect --show-aux` 和 kernelmanagerd/syspolicyd 日志，用来区分“等批准”和“加载失败”。
- `boot-args` 加 `-allow3d`：TGL 加速器对非仿真设备 ID 不带此参数会直接拒绝 probe

**这些改动对经这个 OC 启动的所有系统都生效，Sonoma 也一样（已确认接受）**：Sonoma 同样 SIP 放宽、GPU 隔离成 `device-id=FFFF`，只能走固件帧缓冲。`Kernel/Block` 限定 Darwin 25，但前两项不分系统。

**WriteFlash**：样本配置 `NVRAM/WriteFlash=true`，`csr-active-config` 会写进主板 NVRAM。回滚只改了 ESP 上的 config，要**再经这个 OC 启动一次**才会把 NVRAM 写回 `00000000`；回滚后直接从别的启动项进系统，SIP 仍是放宽的。

## 失败与回滚

- 每一步失败都只停在当前阶段，保留证据目录（默认 `/Volumes/CLONEZILLA/igpu/results-adl-s-*`），失败终态不自动重试。收到 Ctrl-C/TERM/HUP 时，脚本按当前步骤收尾（撤 kext、删暂存文件、卸载 ESP）后以 130 退出。
- `--rollback` 的顺序：**先撤 kext**（从 `/Library/Extensions` **移到** `/var/igpu-adl-s/removed-*`，不删除）并重建 AuxKC，**再还原 config**。原因：先还原 config 的话，SIP 恢复全开后 AuxKC 里的未签名 kext 可能卡开机。
- 回滚的每一步失败都**继续做后面的步骤**，最后阶段记为 `rollback-incomplete`、退出 1、备份指针保留，可以再跑一次。
- 还原前核对 config 哈希：现网既不是改前版本也不是本工具写入的版本（有人动过）时拒绝覆盖，把现网副本存进证据目录，记 `rollback-incomplete`。ESP 备份不可用时改用 `/var/igpu-adl-s/config-backups/` 的本地备份（同样校验哈希）。
- ESP 按**分区 UUID** 定位（`Disk / Partition UUID`）：第 1 步先试 OC 暴露的本次启动分区（`boot-path`，**仅当 `Misc/Security/ExposeSensitiveData` 含 `0x01` 时才有**；样本配置是默认值 6，不含，所以实际会走下一条），取不到就要求卷名 `OCEFI` 唯一。用到的来源记在 `summary.txt` 的 `esp_source`。UUID 记下后，回滚只认它，磁盘号变化、出现同名卷都不影响。ESP 上的 `igpu-fork-backup-*` 永不删除。
- 回滚时如果 kext 没撤干净或 AuxKC 重建失败，**不还原 config**（SIP 保持放宽），以免出现"SIP 全开 + AuxKC 里还有未签名 kext"这种可能卡开机的组合；修好后再跑一次 `--rollback`。
- 辅助脚本（`field_check.py`、`oc_delta.py`）先复制到 root 专属的 `/var/igpu-adl-s/tools-*` 再执行，因为交换盘是 FAT32，任何人都能改。

## 离线验证

`bash field/test/run-field.sh`：桩命令模拟 macOS，覆盖完整推进、未重启续跑、回滚（顺序、每步失败继续、`rollback-incomplete`、哈希核对、本地备份、UUID 定位）、设备/路径不符、G4 缺失、SIP 未生效（含旧值 `430a0000`）、kmutil 失败、P1/P2 失败、probe 失败与 start 卡住、`[IGPU]` 全量分类、P2 崩溃按时间过滤、Ctrl-C 与崩溃分开、各步骤 trap、`--status` 走 sudo、工作副本权限、probe 比较链断言、中文邻接变量门禁。CI 在 macos-26 的真 `sh` 与 bash 3.2 下跑。

**未执行**：以上都是仿真，没有一条在真机上跑过。`ioreg`、`diskutil`、`nvram`、`kmutil` 的输出格式来自桩，真机差异只有现场能暴露。
