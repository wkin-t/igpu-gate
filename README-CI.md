# igpu CI —— 在真 macOS 上跑离线门禁

只包含**离线门禁所需的最小集合**（主工作目录有 33 GB 历史文件，不适合整仓推送）：

```
igpu-build/      kext 源码 + dist 预编译产物 + onsite 脚本 + tools + docs
testkit/         五套仿真 + cases + 夹具（bundle/ 由 sync-bundle.sh 每次重建，不入库）
macmini-run.sh   Mac 侧一键自检（本仓库不使用，随包带上便于核对）
SHA256SUMS       脱敏镜像清单（CI 校验）
LICENSE / NOTICE.md / DISCLAIMER.md
```

## 它验证什么

| 步骤 | 对应风险 |
|---|---|
| 可执行位自检 | 桩件若不是 100755，测试会静默落到真实 `diskutil`/`ioreg`/`log` 上，仿真边界就破了 |
| 三份清单 | 文件内容与本仓库登记的清单一致（**这不能证明来源或未被篡改**——清单与文件可以一起被改） |
| 五套仿真 | 部署/采集/探针/KC 门禁的脚本逻辑 |
| `cases*.py` | plist 解析等纯逻辑 |
| **真 bash 3.2** | 本地 Windows 跑的是 bash 5，`$VAR（` 这类中文邻接坑只有真 macOS 才炸 |

依赖只有：POSIX `sh`、`bash` 3.2、执行 Python 的 `python3`、`shasum`。
**不依赖裸 `python`**（macOS 26 无此命令）；`testkit/bin/python` 是兼容 shim
（优先 `python3`、回退 `python`，并防止递归）。

## 它**不能**做什么

- 没有 Intel UHD 770，不能验证 kext 是否能接管显示；
- 不能嵌套虚拟化，跑不了"模拟的 macOS 机器"；
- 不能替代目标机上的三次启动取证。

## 脱敏说明（本仓库是 public）

测试夹具里的 OpenCore `PlatformInfo` 全部换成明确的占位值：

| 字段 | 本仓库（假值） | 说明 |
|---|---|---|
| `SystemSerialNumber` | `C02IGPU00001` | 12 字符占位 |
| `MLB` | `IGPUMLB0000000001` | 17 字符占位 |
| `SystemUUID` | `00000000-0000-4000-8000-000000000001` | 占位 UUID |
| `ROM` | `02:00:00:00:00:01`（base64 `AgAAAAAB`） | 合成值，**不对应任何真实网卡** |

因此顶层 `SHA256SUMS` 是按脱敏后内容重新生成的镜像清单；
`igpu-build/SHA256SUMS` 与 `igpu-build/dist/SHA256SUMS` 保持原始封存值（`igpu-build` 未脱敏）。

## 换 SMBIOS 序列号后要注意

生产脚本里的基线哈希支持覆盖（`01-deploy.sh` / `03-rollback.sh` / `10-probe.sh` 都用
`${IGPU_BASELINE_SHA:-<默认值>}`）：

```sh
export IGPU_BASELINE_SHA=$(shasum -a 256 /Volumes/OCEFI/EFI/OC/config.plist | awk '{print $1}')
sudo sh onsite/01-deploy.sh --reinject
```

换序列号后 `config.plist` 内容变、哈希变，必须显式传新的基线哈希，否则会被判成 `dirty`。

## 许可与免责

- 自有代码：GPL-3.0-only，见 `LICENSE`。
- 第三方来源与用途：见 `NOTICE.md`（i915 寄存器事实、OpenCore Sample 结构、仅提及 Apple API 名称）。
- 合规与风险：见 `DISCLAIMER.md`（本项目不授予在非 Apple 硬件运行 macOS 的权利）。

## 本地跑同一套

```sh
cd testkit/harness
for f in run-state.sh run.sh run-collect.sh run-probe.sh run-kcgate.sh; do bash "$f"; done
cd ..
python3 cases.py && python3 cases2.py && python3 cases3.py
```