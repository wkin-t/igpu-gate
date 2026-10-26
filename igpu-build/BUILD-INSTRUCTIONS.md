# BUILD-INSTRUCTIONS —— 逐步说明

## 0. 前提

- macOS（Intel 或 Apple Silicon 都可以）
- Xcode Command Line Tools：`xcode-select --install` 之后 `xcode-select -p` 有输出
- 磁盘可写（构建会生成 `build/` 与 `IGPUProbe.kext/`，约几 MB）

> Apple Silicon 上默认就是 `-arch x86_64` **交叉编译**，这是正常的，不用改；
> 但**不能**在那台机上试加载（目标内核在 Dell 上）。

## 1. 校验

```
shasum -a 256 -c SHA256SUMS
```

全部 `OK` 才继续。任何一个 `FAILED` = 文件在传输中被改动/截断，重新拷一份，**不要**手工改哈希表。

## 2. 记录环境

```
sw_vers; xcode-select -p; clang --version; xcrun --show-sdk-version; uname -m
```

（`run-build.sh` 会自动写进报告；手工跑也请把五行带回来。）

## 3. 构建

```
cd kext/IGPUProbe
./build.sh          # 脚本用自身位置推导包根，不必传 REGS；也可显式 REGS=/abs/path/regs.txt
```

脚本四步：重算读集头文件 → 编译 → 链接 → 组装 bundle。

### 常见失败与处置

| 现象 | 处置 |
|---|---|
| `[1/4]` 报 `python: command not found` | 改用 `/usr/bin/python3`（CLT 自带） |
| `[3/4]` 报 `kmod_info` / `undefined symbol` / `-kext` 相关 | **把完整报错带回来**；可尝试调整链接参数，但禁止 `-undefined dynamic_lookup` |
| 报找不到 `Kernel.framework` 的 x86_64 头 | SDK 缺 x86_64 切片 ⇒ 装 **KDK**，或换 Intel 机 |
| `OSBundleLibraries` 版本不符告警 | 用 `kextlibs -xml IGPUProbe.kext` 的输出替换该段，**不要手猜版本号** |

## 4. 验产物

```
file IGPUProbe.kext/Contents/MacOS/IGPUProbe        # 期望: Mach-O 64-bit kext bundle x86_64
kextutil -n -print-diagnostics IGPUProbe.kext       # 期望: 无未解析符号
shasum -a 256 IGPUProbe.kext/Contents/MacOS/IGPUProbe
```

> `kextutil -n` 只做**离线**检查，不会加载。**不要**去掉 `-n`。

## 5. 交回什么

`results-20261019/`（含 `report.md` 与 `summary.txt`）+ `IGPUProbe.kext/Contents/MacOS/IGPUProbe`。
拿回来之后，符号层门禁在 Windows 侧跑（见 `docs/KC-GATE-NOTE.md`），通过才谈部署。
## 6. macOS 26/27 的三条硬约束（2026-10-19 实测，别再踩）

| 现象 | 原因 | 处置 |
|---|---|---|
| `unknown type name 'OSClassLoadInformation'` / `IOPCIDevice.h` 报 `New` 不能 override | 内核头用 `#if !KERNEL` 分内核/DriverKit 两支，没定义 `KERNEL` 就拉进用户态类体 | 编译加 `-DKERNEL=1`（`build.sh` 已带） |
| `'IOKit/IOMemoryMap.h' file not found` | SDK 26/27 把 `IOMemoryMap` 合并进 `IOMemoryDescriptor.h`，无独立头 | `build.sh` 已加 `-I compat-include`，那里是零内容转发头 |
| `kextutil: -n is not a supported kmutil mode` 但 exit 0 | kextutil 转 kmutil 后端，`-n` 模式被移除却没改退出码 | **别信这个 0**；`run-build.sh` 会返回 6，符号判决走 Windows `kc_gate` |

另：`$ARCH）` 这种"变量紧跟全角括号"在 bash 3.2 + C.UTF-8 下会被并进变量名，`set -u` 判 unbound
⇒ 以后写脚本一律 `"${VAR}"` 加花括号。

## 7. 本机符号检查为什么做不了

Apple Silicon 上：系统 kext 只有 Info.plist/签名（无 Mach-O）、没有 `/System/Library/KernelCollections/`、
没有 KDK ⇒ x86_64 目标没有可解析的库集合。`kextlibs` 会报"298 symbols not found in any library kext"，
那是**环境限制**，不是代码缺陷（同一批 298 个符号在 Windows 侧用 BootKC + SystemKC 全部解析成功）。
## 8. kmod_info 到底从哪来（2026-10-20 二次修正）

第一版注入失败的根因是二进制缺 `_kmod_info`（OC 的 `KextFindKmodAddress()` 找不到它就静默
返回 `Invalid Parameter`）。中间曾判断"要链 MacKernelSDK 的 `libkmod.a`"，**这个判断只对了一半**：

把 `libkmod.a` 拆开看（MacKernelSDK `Library/x86_64/libkmod.a`，仅 1,408 B）：

| 成员 | 定义了 | 引用了 |
|---|---|---|
| `c_start.o` | `__start`、`_OSKextGetCurrentIdentifier/LoadTag/VersionString` | `__realmain`、**`_kmod_info`（未定义）** |
| `c_stop.o` | `__stop` | `__antimain` |

也就是说 `libkmod.a` 里的 `_kmod_info` 是**未定义引用**——光加 `-l kmod` 不会产生定义。

**正确做法**：由源码提供定义，即 `<mach/kmod.h>` 的

    #define KMOD_EXPLICIT_DECL(name, version, start, stop)            \
        kmod_info_t KMOD_INFO_NAME = { 0, KMOD_INFO_VERSION, -1U,      \
                       { #name }, { version }, -1, 0, 0, 0, 0,     \
                           start, stop };

（`KMOD_INFO_NAME` = `kmod_info`，链接后即外部符号 `_kmod_info`。）

`IGPUProbe.cpp` 末尾已经加好：

    #include <mach/kmod.h>
    extern "C" kern_return_t IGPUProbe_kern_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
    extern "C" kern_return_t IGPUProbe_kern_stop (kmod_info_t *, void *) { return KERN_SUCCESS; }
    extern "C" {
    KMOD_EXPLICIT_DECL(dev.igpu.probe, "0.1.0", IGPUProbe_kern_start, IGPUProbe_kern_stop)
    }

**因此：不需要 MacKernelSDK，也不需要下载任何东西。** 需要的只是 SDK 自带的 `mach/kmod.h`
（`$SDK/System/Library/Frameworks/Kernel.framework/Headers/mach/kmod.h`）。

三道门禁仍然保留，缺一不可：

| 门禁 | 检查什么 | 失败退出码 |
|---|---|---|
| `kc_gate`（现可在本机跑） | 298 个未定义符号能在 KC 里全部解析 | 8 |
| `_kmod_info` 存在性 | OpenCore 能否定位 kmod | 7 |
| `kextutil -n` | 假绿色，只做参考，不作判据 | — |

## 9. 在 Dell 自己的 Tahoe 上构建（推荐，2026-10-20 实测）

不需要家里那台 Apple Silicon——Dell 自带 Tahoe 就是**原生 x86_64**：

| 项 | 实测值 |
|---|---|
| 系统 | macOS 26.6.2 / 25G83（x86_64） |
| 工具链 | `/Library/Developer/CommandLineTools`，Apple clang 21.0.0 |
| 目标 | `x86_64-apple-darwin25.6.0`，SDK 26.5 |

**不要在 U 盘上编译**（FAT32 无执行位、易出错），拷到本地再编：

    cp -R /Volumes/CLONEZILLA/igpu-handoff-20261019 ~/igpu-build
    cd ~/igpu-build && chmod +x run-build.sh && ./run-build.sh

## 10. 在 Tahoe 上按顺序跑四个脚本（不再手敲命令）

```sh
# 0) 把最新包拷到本地（APFS 上跑，别在 FAT32 上编）
rm -rf ~/igpu-build && cp -R /Volumes/CLONEZILLA/igpu-handoff-20261019 ~/igpu-build
cd ~/igpu-build

# 1) 构建 + 四道门禁（哈希 / R1-R8 / _kmod_info 已定义 / 本机 KC 符号）
sh onsite/00-build.sh

# 2) 部署（三重身份校验 + 完整备份 + 暂存替换 + 双哈希复核）
sudo sh onsite/01-deploy.sh

# 3) 重启
sudo reboot

# 4) 回 Tahoe 后采集
sh onsite/02-collect.sh
```

**第 1 步必须看到**：

```
_kmod_info 已定义 ✓          <- 用 nm -gU 判定，不是 strings
KC 符号预检：PASS
===== 结论：可以部署 =====
```

任一缺失就别部署。`00-build.sh` 的退出码含义：2 包哈希不符 / 3 静态红线不过 /
4 构建失败 / **7 缺 _kmod_info** / 5 结构检查失败 / **8 KC 预检失败** / 6 两项符号判决都不可用。

## 11. 采集结果的判据（按源码真实类型）

`IGPUProbe.cpp` 实际发布：

| 属性 | 类型 | 正常值 |
|---|---|---|
| `PhysicalIdentityVerified` | bool | `Yes` |
| `GPUAccess` | **字符串** | `"none: MMIO reads only"`（失败路径 `"none: no MMIO opened"`） |
| `RegsRead` | 整数 | 190 |
| `RegsSuspect` | 整数 | 0 |
| `ProbeError` | 字符串 | 仅失败时出现 |

`02-collect.sh` 的 `summary.txt` 里看这些键：

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

`oc_log` 的三种取值：`ok` / `mount-failed`（非 root 挂载不了 ESP）/ `not-found`。

## 12. boot-arg 命名（2026-10-20 修正，别写错）

代码用 `PE_parse_boot_argn("igpu-driver", …)`；XNU 把前导 `-` 的参数当布尔开关，
所以**必须**写成：

```
igpu-driver=off
igpu-driver=verbose
（缺省 = normal）
```

写成 `-igpu-driver=off` 会静默回落 normal，而静态门禁仍然全绿——这是 codex 对抗评审抓出来的假绿点。

## 13. 回滚

```sh
sudo sh onsite/03-rollback.sh            # 只还原 kext（从最近的完整备份）
sudo sh onsite/03-rollback.sh --config   # 额外用 ESP 上的基线 config 覆盖
```

只认 `STATE=complete` 且哈希齐全的备份；缺材料一律拒绝，不会"猜"。

## 14. 剩余验收：一次性批处理（4 次重启 + 1 次断电）

Phase-1 已完成：kext 加载、190 项读集、`PhysicalIdentityVerified=Yes`、
`-igpu-driver=off` 下"kmutil 仍有 · ioreg 零实例 · OC 注入 Success"（判据 d 已过）。
剩下这些**必须进 macOS**，按下面一次性跑完，不要再零散切：

### 第 0 步（不重启）：补 off 态全量快照

```sh
# 只需拷这 4 个文件，不必重拷整包
cp /Volumes/CLONEZILLA/igpu-handoff-20261019/onsite/{02-collect.sh,04-state.sh} ~/igpu-build/onsite/
cp /Volumes/CLONEZILLA/igpu-handoff-20261019/tools/set-bootargs.py ~/igpu-build/tools/
cp /Volumes/CLONEZILLA/igpu-handoff-20261019/SHA256SUMS ~/igpu-build/

sudo sh onsite/02-collect.sh        # 当前就在 off 态，直接采
```

期望：`evidence_complete=yes`、`instances=0`、`probe_loaded=yes`，并新增
`ioreg-full.txt` / `ioreg-probe.plist` / `igpu-log.txt` / `MANIFEST.sha256`。

### 第 1 步（重启 1）：normal 全量快照

```sh
sudo sh onsite/04-state.sh normal && sudo reboot
# 回来
sudo sh onsite/02-collect.sh
```

用途：① 与第 0 步做**全量 ioreg 对比**（严格版判据 d：差异应只差 IGPUProbe 节点）；
② 用 `ioreg-probe.plist` 里 base64 的 `<data>` 判定那条被 ioreg 文本渲染成
`<"?","(">` 的寄存器真实值。

### 第 2 步（重启 2）：断电冷启动（判据 b）

在第 1 步的 normal 桌面下**直接断电**（长按电源 5 秒或拔插头），再开机：

```sh
sudo sh onsite/02-collect.sh
```

期望：`safeboot=0`、`shutdown_cause=ok/N`（N≥1，记录里能看到上次非正常关机），
`evidence_complete=yes`。这一步同时把冷启动计数 +1。

### 第 3 步（重启 3）：安全模式（判据 e）

```sh
sudo sh onsite/04-state.sh safe-on && sudo reboot
# 回来
sysctl -n kern.safeboot        # 必须为 1
sudo sh onsite/02-collect.sh
```

期望：`safeboot=1`、`probe_loaded=yes`（kext 仍加载）、`igpu-driver` 保持切换前状态。
这一步同时回答"入口行为"。

### 第 4 步（重启 4）：Phase-1 退出证据（判据 f）

```sh
sudo sh onsite/04-state.sh safe-off
sudo sh onsite/03-rollback.sh --config
sudo reboot
# 回来
sudo sh onsite/02-collect.sh
```

期望：`probe_loaded=no`、`instances=0`、`manifest=ok`；脚本会因
"探针未加载"返回 **非零**——这是**正确**的，正是判据 f 要的证据（此时不要重跑采集）。

### 冷启动次数账

已有 3 次（20/10 两次 normal + 一次 off）+ 第 1/2/3/4 步共 4 次 = **7 次**，其中 1 次断电冷启，
满足判据 b 的"≥5 次且含断电冷启"。每步都把 `results-collect-*` 目录带回来即可。