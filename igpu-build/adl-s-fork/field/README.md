# ADL-S 现场包：P1 装载核验与 P2 加速器试验

仅限 Dell OptiPlex 7020、Intel UHD 770 `8086:4680` rev `0c`、Intel macOS Tahoe `25G83`。这是实验包，不是已证明兼容的图形驱动。

## 用户只记一条命令

复制到交换盘后的总入口：

```sh
sh /Volumes/CLONEZILLA/go.sh
```

卷名有空格时，用实际卷名并加引号。仓库直接入口如下：

```sh
sudo sh field/adl-s-field.sh
sudo sh field/adl-s-field.sh --status
sudo sh field/adl-s-field.sh --rollback
```

每次只推进一个阶段，不自动重启、不自动批准、不自动重试 P2。密码输入不可见是正常行为。失败证据会自动留下；暂存或集合状态未知时，不会为了“继续”而提前恢复 SIP 或删除备份。

## 2026-11-09 真机故障与修复范围

配置步骤已在真机完成；TGL 原料通过结构检查并生成了本地签名运行时。随后旧版 `kmutil install --update-all` 因没有匹配 KDK 而失败，两份安装源移出。后续同一条宽范围重建命令也失败。该事件不证明 staging、缓存或内存里完全没有残留。

新版不再使用 `install/create --update-all`，不手工写 Boot/System/AuxKC，不使用 `-L`、`-z` 或 `--allow-missing-kdk` 来消除错误。安装通过标准 kernelmanagerd 协议请求，撤出通过标准 `kmutil rebuild` 请求。

主源为 [Apple 安装指南](https://developer.apple.com/documentation/apple-silicon/installing-a-custom-kernel-extension.md) 与 [kmutil(8) 手册镜像](https://keith.github.io/xcode-man-pages/kmutil.8.html)。Apple 要求多个 kext 在同一次装载调用中传入，并明确用户批准、AuxKC 构建与重启是独立步骤。

**不能保证** 25G83 的正常 daemon 路径完全免 KDK：本次离线采样证实了命令/格式，不是该机的新装载结果。若标准请求仍失败，会保存原码与输出，不改用更宽的重建或跳过安全检查。

## 阶段含义

1. `start`：核对系统版本与目标卷 UUID、物理身份、GFX0 完整路径、恢复凭证、原料与预编译收据（校验脚本复制到 root 专属目录执行且禁用 `.pyc` 写入交换盘）；备份并写入 OC 增量。随后重启。
2. `config-applied`：在替换工作树或生成运行时前先确认无旧脏标记、无目标目录/残留链接；核对当前版本、系统卷、SIP、隔离和组件旧状态；在清洗 AppleDouble/Finder 碎片后的 root 专属副本中复核预编译控制器收据、生成运行时与不可变完整包装收据（覆盖可执行文件、`Info.plist` 与精确文件集合），写入复制标记后将两包从 root 副本复制到扩展目录并请求装载：

   ```sh
   kmutil load --load-style start-only -p /Library/Extensions/ReimsTGLBoot.kext -p /Library/Extensions/ReimsADLManualActivation.kext
   ```

   `start-only` 不重播 GPU personalities，但不等于“完全不执行任何内核启动代码”。运行时的自动 personalities 被清空；必须保留产物身份检查。
3. 原码 `27`：`awaiting-approval`，保留包和事务。去“系统设置 → 隐私与安全性”处理实际提示，使用提示里的“重新启动”。没有提示不要盲重启。
4. 原码 `0/28`：请求已处理/需要重启，不宣称 AuxKC 已采用；随后做 P1。未知码则撤本事务安装源并保持失败记录。
5. P1：验证本次组件的精确 ID/UUID、有效隔离、当前启动条件（含 `kern.safeboot=0` 与非 `-x`）、Boot/System 集合指纹未变与控制器只读服务。不把“缺少模块”自动解释成已经批准或只差重启。
6. P2：只在本次开机的 P1 有效且所有前置查询（含 `kern.safeboot=0`）均成功退出时请求加速器初始化。新开机先重新核验 P1，不复用历史进度直接跑 P2。

旧 `install-failed + KMUTIL_DIRTY` 或复制中断标记存在时，默认入口只进入受控恢复，不替换旧工作树、不生成新 runtime、不重新装载。历史 STAGE 不是当前硬件/政策状态证明。

## 回滚是多边界事务

- 若存在原安装 Boot/System 集合基线，回滚全流程与最终重启均对齐该不可变基线，不重采样洗白变化；旧遗留现场无原安装基线时明确记为 `original_system_baseline=unverified-legacy`。
- 先按完整收据核对安装源归属（可执行文件、`Info.plist` 元数据及包内文件集），逐包移出到本地备份，不删除。陌生同名包、改过包装的包或撤出失败必须停止恢复配置。
- 前台运行 `kmutil rebuild`，确认问题可见，原始退出码独立保存，不拿 `tee` 的退出码代替。
- `27` 为 `rollback-awaiting-approval`；`0/28` 为 `rollback-pending-reboot`。同一 Boot 重跑只提示，不重复请求。config、BACKUP、DIRTY 保留。
- 新的 Tahoe Boot 里，验证安装源不再出现、AuxKC 可用组件、未过滤内存清单、指定磁盘 AuxKC 均排除两份目标的任何版本（若无已批准第三方扩展导致 `kernelmanagerd` 移除磁盘 `AuxiliaryKernelExtensions.kc`，须同时验证目录可读且本次启动内核无任何可用 AuxKC 组件），Boot/System 集合指纹未变化。任一查询失败、未知格式、旧版本残留或目标卷改变都是 incomplete。
- 排除证据成立后才还原基线 config（若缺失备份记录则必须核实现网 ESP `delta=absent`，拒绝假称已还原），进入 `rollback-final-reboot`。再经同一 OC 启动，验证 NVRAM、`kern.safeboot=0`、实际设备/实例、当前 config 哈希、Boot/System 指纹、AuxKC/内存排除和启动来源（若 NVRAM 含 `boot-path` 必须与记录 ESP 一致；基线 `ExposeSensitiveData=6` 未发布 `boot-path` 时诚实记为 `boot_source=unverified-no-bootpath`，不静默修改 `ExposeSensitiveData`）后，才标记回滚完成并清恢复记录。幂等基线检查同样核对现网 ESP `delta=absent`。

不全局清 StagedExtensions/KextPolicy。标准 rebuild 按已移走的安装源评估；在新启动、磁盘和内存排除成立前，不能把保留的 staging 副本说成已净化。历史缓存痕迹也不必物理删光；未决加入或无法分类时继续留证/停止。

## 恢复边界

Windows 恢复演练只证明能找到 ESP、读写及使用一致的 config 备份。它**不证明**能进入 APFS Recovery 或撤掉 AuxKC。`-x` 只是试验性启动参数，不保证进入桌面或屏蔽 AuxKC 组件。

Windows 仅回退 config，不等于清理 macOS 内的 kext；可能造成 SIP/隔离已回退而旧缓存仍可用。装载故障优先保持实验配置，按受控回滚处理。Recovery 的 panic-medic 涉及全部第三方组件，并非两包定向移除；需要独立确认范围和授权，不自动调用，也不凭空添加 Recovery 参数。

## 配置与身份保持不变

[OC 增量工具](<./oc_delta.py>) 仍只修改既定四类键：

- GFX0 `device-id=FFFF0000`。
- 两条 Kernel/Block（Darwin 25）。Block 可能够不到 System/AuxKC，不能当核心保护依赖。
- `csr-active-config=03000000`，不额外放宽位。
- boot-args 增加 `-allow3d`。

SIP 和 DeviceProperties 隔离对经该 OC 启动的 Sonoma 也有效。`WriteFlash=true` 时，只改 config 不会立即恢复主板 NVRAM；需要再经此 OC 启动。恢复以真实 NVRAM 和设备状态核验为准。

## P2 证据含义

- `Found device with ID` 必须读到真实 `0x46808086` / `0xc`。
- SKU 2/L3Bank 4 只说明 P-0002/P-0003 生效，不是硬件验证。
- 32 EU、1 slice、4 subslice 是所记录的硬件拓扑。
- 全部 `[IGPU]` 行按 GuC、firmware、fail/warn 保留；不会因失败而跳过采集。
- 结果区分预检、probe、start 失败/卡住以及 start 返回成功。
- `P2=PASS` 不证明 GuC/固件/命令提交/Metal 或显示接管可用。完整显示流程对 0x4680 仍拒绝。

## 离线验证边界

[现场仿真](<./test/run-field.sh>) 用四层独立状态桩、合成扩展和假 ESP 重放失败与恢复条件；[解析器测试](<./test/test_field_check.py>) 与 [启动路径测试](<./test/test_boot_path.py>) 覆盖精确身份、完整收据、未知数据、控制器服务、原生输出路径绑定及 UEFI `boot-path` 解析。

CI 的只读命令样本来自 hosted ARM macOS runner，记录的是实际版本，不是 Intel 25G83 真机。它可以检验语法、命令存在性、格式和控制流；不能证明 Apple daemon 已在目标机成功装载、批准或采用 AuxKC，不能代替 Recovery/P1/P2 实测。
