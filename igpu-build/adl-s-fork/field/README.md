# field/ —— ADL-S 8086:4680 现场包（P1 开机隔离 + P2 只激活加速器）

只适用于：Dell OptiPlex 7020 / UHD 770（`8086:4680` rev `0c`）/ macOS Tahoe `25G83` / U 盘上的 OpenCore（卷名 `OCEFI`，分区偏移 1048576）。

## 一条命令

```sh
sudo sh field/adl-s-field.sh            # 每次都跑这一条，脚本自己判断该做哪一步
sh field/adl-s-field.sh --status        # 看进度
sudo sh field/adl-s-field.sh --rollback # 一键回到部署前（之后重启）
```

| 第几次 | 做什么 | 之后 |
|---|---|---|
| 1 | 预检（系统版本、真实设备 ID、恢复 EFI 已验证、TGL 原料结构断言、预编译件收据），备份并写入 OC 增量 | 重启 |
| 2 | 确认 SIP 已放宽、`-allow3d` 已生效、GPU 已隔离（`device-id=ffff`）；本机打补丁生成 TGL 运行时；放入 `/Library/Extensions` 并重建 AuxKC | 重启（如弹出“系统软件已被阻止”，先批准） |
| 3 | **P1 判定**：两个 kext 已加载且 UUID 与本次构建一致，GPU 仍隔离，只有 1 个固件帧缓冲，没有加速器 | 保存工作 |
| 4 | **P2**：`igpu-start --accel-only`，加速器初始化到隐藏就绪，不发布、不碰显示；核对 `[IGPU] HWCAPS` 日志（SKU 2、32 EU、1×4、L3Bank 4） | 带回证据 |

P2 若导致死机：重启后再跑同一条命令，脚本识别出"P2 期间重启"，收集 panic 报告后停下。运行时匹配规则只活在当次开机里，重启后自动回到 P1 状态。

## 前置

- 恢复 EFI 已人工验证：`echo ok > ~/RECOVERY-EFI-VERIFIED.txt`（门 G4，否则第 1 步拒绝）。
- 本地合法取得的 `AppleIntelTGLGraphics.kext`（16.0.0），默认放在 `/Volumes/CLONEZILLA/igpu-tgl-input/`，可用 `IGPU_TGL_INPUT` 覆盖。仓库不包含、也不分发它。
- `prebuilt/`：CI 产物 `adl-s-prebuilt`（ManualActivation kext、control、收据），放在仓库根下。

## OC 增量（`oc_delta.py`，除此之外不改任何键）

- `DeviceProperties/Add/PciRoot(0x0)/Pci(0x2,0x0)/device-id = FFFF0000`
- `Kernel/Block`：`com.apple.driver.AppleIntelTGLGraphics`、`lab.reims.ReimsADLDesktopLink`（Exclude，Darwin 25）
- `csr-active-config = 430A0000`：**整机生效，Sonoma 也一起放宽**（已确认接受）
- `boot-args` 加 `-allow3d`：TGL 加速器对非仿真设备 ID 不带此参数会直接拒绝 probe

## 失败与回滚

- 每一步失败都只停在当前阶段，保留证据目录（默认 `/Volumes/CLONEZILLA/igpu/results-adl-s-*`），失败终态不自动重试。
- `--rollback`：按备份指针还原 config（哈希校验），把两个 kext 从 `/Library/Extensions` **移到** `/var/igpu-adl-s/removed-*`（不删除），重建 AuxKC。ESP 上的 `igpu-fork-backup-*` 永不删除。

## 离线验证

`bash field/test/run-field.sh`：桩命令模拟 macOS，覆盖完整推进、未重启续跑、回滚、设备不符、G4 缺失、SIP 未生效、kmutil 失败、P1/P2 失败、P2 崩溃、HWCAPS 不符、中文邻接变量门禁。CI 在 macos-26 的真 `sh` 与 bash 3.2 下跑。
