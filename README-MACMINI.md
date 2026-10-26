# Mac mini 自检套件（igpu，0 次重启）

用途：在家里 Apple Silicon Mac mini 上，提前验证**编译 + 全部离线测试**，
把"编译不过 / 脚本在 macOS 上炸"消掉，这样 Dell 上只需做必须实机的事。

## 一条命令

```sh
cd igpu-macmini-20261021
sh macmini-run.sh
```

结果同时写进 `report-macmini.txt`，末尾是 `RESULT: PASS` 或 `RESULT: FAIL` 与 `PASS=n FAIL=m`。
退出码：全过 0，任一硬门禁失败非 0。

## 目录

```
igpu-build/          部署包副本（kext 源码、onsite、tools、docs、regs.txt、run-build.sh、SHA256SUMS）
testkit/
  harness/           桩件仿真（run.sh / run-state.sh / run-collect.sh + stubs + bundle + tpl）
  bin/python         shim：exec ${IGPU_PYTHON:-python3} "$@"
  cases.py cases2.py cases3.py   可移植版（不再有 Windows 硬路径）
  scan-var.py
  live-config.plist  真实配置快照（cases 的输入）
macmini-run.sh
report-macmini.txt   ← 运行时生成
```

## 硬门禁（任一失败即 FAIL）

1. kext 构建成功（`kext/IGPUProbe/build.sh`）
2. 产物存在（`Contents/MacOS/IGPUProbe`）
3. `nm -arch x86_64 -gU` 里 `_kmod_info` 是**已定义**符号
4. `file` 显示 `x86_64`
5. 五套桩件仿真 0 FAIL
6. 三个 cases 0 FAIL
7. `plutil -lint Info.plist`
8. `shasum -a 256 -c SHA256SUMS`（`igpu-build/` 内部清单）
9. `check-kext-source.py` 的 R1–R8 源码红线
10. `dist/` 产物生成（`dist/SHA256SUMS` + `BUILD-REPORT.txt`，记录 binary_sha256/字节数/clang/SDK）
11. kit 顶层 `SHA256SUMS` 校验（条数以该文件为准；已排除 harness 生成目录）

> 注意：本轮恢复了 normal 模式的 `IGPUProbeState` 逐项发布（F6），**二进制身份会变**。
> 旧的 `199772b7…` 作废，以本次 `dist/BUILD-REPORT.txt` 里的 `binary_sha256` 为准。
> 预期 `PASS` 数会从 12 增加到 15 左右（多出 R1–R8、dist、顶层清单三项）。

## 软门禁（只 WARN）

- `kextutil -n`：Apple Silicon 上对 x86_64 kext 可能只做有限检查（甚至报架构不匹配），
  这不代表包有问题；硬门禁里的 `nm`/`file` 才是架构与符号的判物。

## 需要什么

- Xcode Command Line Tools（`xcode-select --install`），clang 能用
- 系统自带 python3、`shasum`、`plutil`、`otool`、`nm`
- 网络不需要

## 常见失败

| 现象 | 处理 |
|---|---|
| `xcrun: error: invalid active developer path` | `sudo xcode-select --switch /Library/Developer/CommandLineTools` |
| `SHASUMS` 校验失败 | 包在拷贝中损坏，重新从 U 盘/共享盘拷一次 |
| `nm` 找不到 `_kmod_info` | 源码末尾 `KMOD_EXPLICIT_DECL` 丢了，或编译用了错误架构 |
| harness 报 `python: not found` | 确认 `testkit/bin` 在 PATH 最前（`macmini-run.sh` 会自动加） |
| cases 报 `IGPU_HANDOFF` 相关 | 若移动了目录，显式传 `IGPU_HANDOFF=/path/to/igpu-build` |

## 带回来什么

- `report-macmini.txt`（完整日志）
- `shasum -a 256 igpu-build/kext/IGPUProbe/IGPUProbe.kext/Contents/MacOS/IGPUProbe`
- `file` 那一行

> 这个套件**不**加载 kext、**不**读寄存器、**不**碰启动项——真正的实机验证仍在 Dell 上做。
## dist 与产物身份

- 构建成功后 `igpu-build/dist/` 是**唯一待部署产物**：`IGPUProbe.kext/` + `dist/SHA256SUMS` + `BUILD-REPORT.txt`。
- `BUILD-REPORT.txt` 记录 `binary_sha256` / `binary_bytes` / `source_*_sha256`；`BUILD-REPORT.mac-original.txt` 保留旧版脚本的原样输出（4 字段为空，作审计证据）。
- `igpu-build/EXPECTED_BIN_SHA` 是部署白名单：Dell 上 `01-deploy.sh` 会强制二进制哈希匹配。
  当前值：`2f0d35595c0d6c5e38d95ee4e5c9468ba647a0165b108f34df49336b2e928d84`（79976 B）。
- 任何重编都会改变身份：更新 `dist/`、`EXPECTED_BIN_SHA`，并重封两份清单。