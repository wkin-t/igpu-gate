# HANDOFF：在 macOS 上构建 IGPUProbe.kext

> 这是一个**自包含**的构建包：校验清单、源码、工具、一键脚本、报告模板都在里面。
> 目标：在任意一台 macOS 上编出 `IGPUProbe.kext` 并做离线校验；**不加载、不部署、不碰 EFI**。

## 一键跑

```
cd <本目录>
chmod +x run-build.sh
./run-build.sh
```

脚本按顺序做五件事，任何一步失败都会停下并给出非零退出码：

| 步 | 内容 | 失败退出码 |
|---|---|---|
| 1 | `shasum -a 256 -c SHA256SUMS` 校验所有文件未被改动 | 2 |
| 2 | 记录构建机身份（`sw_vers` / `xcode-select -p` / `clang` / SDK / `uname`） | — |
| 3 | 静态红线检查（R1–R8：零 MMIO 写、不读 EDID、off 分支、身份顺序…） | 3 |
| 4 | 构建（`build.sh`：clang `-mkapple-kext` 路线） | 4 |
| 5 | 产物结构检查（`file` / `otool -hv` / `lipo -info` / `sha256` / `nm -u` 计数） | 5 |
| 5b | **_kmod_info 存在性**（缺了 OC 一定注入失败） | 7 |

另外：macOS 26/27 的 `kextutil -n` 已是**假绿**（打印 "not a supported kmutil mode" 但退出码 0）。
脚本会识别这种情况并返回 **6**，明确表示"结构对、但本机无法做符号检查"——符号判决交 Windows 侧 `kc_gate`。

全部输出同时写进 `results-20261019/report.md`，另有一份摘要在 `results-20261019/summary.txt`。

## 目录内容

| 路径 | 说明 |
|---|---|
| `kext/IGPUProbe/IGPUProbe.cpp` | 驱动主体（只读快照、身份三元组、fail-closed） |
| `kext/IGPUProbe/Info.plist` | `dev.igpu.probe`；`OSBundleRequired=Root`；匹配 `IOPCIDevice` + `0x46808086` |
| `kext/IGPUProbe/IGPUProbeState.hpp` | **生成物**（190 项读集），构建时会重算 |
| `kext/IGPUProbe/build.sh` | 构建脚本（**链接参数未经实测**，见下） |
| `kext/IGPUProbe/README.md` | 判物方法、四状态判据、红线、已知未知 |
| `tools/gen-readset-header.py` | `regs.txt` → 头文件（可复算） |
| `tools/check-kext-source.py` | 红线静态门禁（R1–R8） |
| `tools/kc_gate.py` / `kc_imports.py` | 符号层门禁（本包不跑，见 `docs/KC-GATE-NOTE.md`） |
| `regs.txt` | 读集源（195 条 → 190 唯一偏移） |
| `SHA256SUMS` | 上述文件的校验清单 |
| `docs/KC-GATE-NOTE.md` | 为什么包里没有 KC、门禁在哪跑、已测结论 |
| `results-20261019/` | 产物与报告（脚本自动写） |

## 构建成功后要带走什么

`results-20261019/` 整个目录，外加 `kext/IGPUProbe/IGPUProbe.kext/Contents/MacOS/IGPUProbe` 这个二进制。
里面已经有：环境五行、每条命令的退出码、`file` 输出、`kextutil -n` 全文、二进制 sha256。

## 硬约束（违反则这次构建作废）

- **禁止** `-undefined dynamic_lookup`、`-Wl,-undefined,suppress`、删符号、`-fno-*` 掩盖告警
  —— 那会把"未解析符号 = 0"变成假绿，而这正是本项目最忌讳的失败模式。
- **禁止** 改 `IGPUProbe.cpp` 的读写语义（不得新增任何 MMIO 写）、改读集条目、改 `IGPUProbeState.hpp`、
  改 `Info.plist` 的 `OSBundleRequired` / `CFBundleIdentifier` / `IOPCIPrimaryMatch` / `IOMatchCategory`。
- **禁止** `kextutil -load`、`kmutil load`、`sudo`、`csrutil`、任何 `diskutil`/EFI 写入。
- 允许改：`build.sh` 的编译/链接参数；`OSBundleLibraries`（只能用 `kextlibs -xml` 的真实输出替换）。

## 已知未知

`build.sh` 的链接参数（`-mkernel -nostdlib -Wl,-kext`）**没在真机上验证过**，首次跑大概率在
`[3/4] 链接` 处报错（`kmod_info` 或符号导出相关）。这时**把报错原文带回来**，不要硬试第三次，
也不要靠"让它过"的手段糊过去。