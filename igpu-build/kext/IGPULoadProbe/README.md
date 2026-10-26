# IGPULoadProbe —— Phase 2b-A0：只验证"加载路径"

## 它回答的问题

> OpenCore 注入到 **Boot/Aux KC** 的 kext，能否满足对 **System KC** 里
> `com.apple.iokit.IOGraphicsFamily`（`IOFramebuffer` 的父类）的依赖？

这是 2b 的第一个未知（评审指出的硬阻塞点）。在它被证明之前，写接管逻辑没有意义。

## 它故意不做什么

- **没有 `IOKitPersonalities`** → 永远不会被实例化 → `start()` 不会跑；
- 8 个 `IOFramebuffer` 纯虚方法全部返回"不支持"，即使被误实例化也不写任何 MMIO；
- 不注册 framebuffer、不改显示、不碰寄存器。

## 唯一的可观测输出

`kern_start` 里的一条 `IOLog`：

```
IGPULoadProbe: kern_start —— kext 已加载，IOGraphicsFamily 依赖已满足
```

**依赖不满足时，内核根本不会调用 `kern_start`** —— 所以"日志里有没有这一行"就是判据。

## 构建（Mac 上）

```sh
cd kext/IGPULoadProbe
chmod +x build.sh
./build.sh
```

门禁（build.sh 内置，缺一即失败）：

| 检查 | 含义 |
|---|---|
| `_kmod_info` 已定义 | 否则 OC 注入报 `Invalid Parameter` |
| 二进制里存在对 `IOFramebuffer` 的**未定义引用** | 若被链接优化掉，A0 就失去意义 |

## 部署（目标机上）

```sh
# 1) 拷进去（ESP 已挂成 /Volumes/OCEFI）
cp -R IGPULoadProbe.kext /Volumes/OCEFI/EFI/OC/Kexts/

# 2) 往 config 里加一条 Kernel/Add（幂等，可回退）
python3 tools/add-kext-entry.py --config /Volumes/OCEFI/EFI/OC/config.plist --name IGPULoadProbe
python3 tools/add-kext-entry.py --config /Volumes/OCEFI/EFI/OC/config.plist --name IGPULoadProbe --check

# 3) 重启后判定
sudo sh onsite/12-loadprobe-check.sh
```

## 判定与回退

| `RESULT:` | 含义 | 下一步 |
|---|---|---|
| `LOADED` | A0 通过：注入 kext 能用到 System KC 的 `IOGraphicsFamily` | 可以开始 2b-A1（继承扫描面） |
| `DEPENDENCY_MISSING` | 依赖/加载失败 | 把失败行带回来；考虑改用"不继承 `IOFramebuffer`"的取巧路径（见设计 v0.2 第 1 节） |
| `NOT_INJECTED` | ESP 上没有 kext 或 config 没引用 | 重新部署 |
| `UNKNOWN` | 已在已加载列表但没看到 `kern_start` | 核对日志窗口/谓词，或先确认 KMOD_EXPLICIT_DECL 在产物里 |

回退：`python3 tools/add-kext-entry.py --config ... --name IGPULoadProbe --remove`，再删掉 ESP 上的 kext。