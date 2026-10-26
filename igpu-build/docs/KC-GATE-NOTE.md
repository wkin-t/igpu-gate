# 为什么本包不带 `BootKernelExtensions.kc`（以及门禁在哪跑）

## 结论

符号层门禁 `tools/kc_gate.py` **在 Windows 侧跑**，本包只负责"编出二进制"。
原因：KC 太大，而且**单独一个 BootKC 会给出误导性的判决**。

## 实测（2026-10-19，对 `samples/fb_lep-signed.bin`）

| KC 集合 | imports | resolved | missing | 判决 |
|---|---|---|---|---|
| 仅 `BootKernelExtensions.kc`（64.5 MB） | 594 | 488 | **106** | GATE-FAIL |
| `Boot` + `SystemKernelExtensions.kc`（345 MB） | 594 | 586 | **8** | GATE-FAIL |
| 参考：`SystemKernelExtensions.kc` sha256 | `c80161fa30658837…`（Boot） | | | |

## 剩下 8 个是什么

```
__ZN17AppleIntelPortHAL13probePortModeEv
__ZN21AppleIntelDisplayPath19DSBEngineBusyStatusE
__ZN31AppleIntelFramebufferController14ReadRegister32Em
__ZN31AppleIntelFramebufferController14ReadRegister64EPvvm
__ZN31AppleIntelFramebufferController15WriteRegister32Emj
__ZN31AppleIntelFramebufferController15WriteRegister64EPvmy
__ZN31AppleIntelFramebufferController16hwSetupDSBMemoryEv
__ZN31AppleIntelFramebufferController9getPMTNowEv
```

全部是 **`AppleIntel*` 驱动家族内部的 C++ 符号**，既不在内核里、也不在 IOFramebuffer 家族里——
它们属于苹果自家 Intel 显示驱动的同一家族，只有那个驱动包自身才能解析。

⇒ 这正是为什么我们的 `IGPUProbe` **绝不能引用 `AppleIntel*` 类**：本机根本没有那个家族，
引用了就必然 8 个以上未解析，注入后只会静默失败（OC 对未解析符号只记日志、照样注入）。
我们的源码静态检查（R8）已确保不出现 `IOFramebuffer` 继承/发布；`kc_gate` 会在 Windows 侧再确认一遍。

## 所以

| 谁 | 做什么 |
|---|---|
| macOS（本包） | 构建 + `kextutil -n`（离线符号检查）+ 产物哈希 |
| Windows（已有） | `kc_gate --kc BootKC --kc SystemKC --kext <binary>`，要求 imports>0 且 missing=0 |

⚠ 注意：`kextutil -n` 能通过、`kc_gate` 仍可能失败（两者查的符号集合不同）；
反过来 `kc_gate` 通过**也不证明**可加载。两道都要过，且都只是"必要条件"。