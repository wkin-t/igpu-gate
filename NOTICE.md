# NOTICE —— 第三方来源与适用范围

本项目自有代码（kext 源码、onsite 脚本、testkit、CI 配置）的许可见 `LICENSE`（GPL-3.0-only）。

## 参考 / 引用的第三方资料

| 来源 | 用途 | 许可 |
|---|---|---|
| Linux 内核 i915 驱动（v6.12） | 寄存器名称、偏移与位字段定义的事实性参考；`drivers/gpu/drm/i915/display/skl_universal_plane_regs.h` 在该版本标注为 MIT（Intel 版权） | MIT |
| OpenCorePkg（Acidanthera） | `config.plist` 结构与注释风格参照其 Sample 配置 | BSD-3-Clause |
| Apple 公开文档与头文件名称 | 仅提及 API/头文件名（如 `IOKit/IOBufferMemoryDescriptor.h`），**不分发其实现** | 不适用 |

本仓库**不包含**：Apple 操作系统镜像、Apple 固件、SDK、KDK、KernelCollection 文件或其内容，
也不包含 OpenCore 的可执行文件。`compat-include/` 下是本项目自行编写的转发头文件。

寄存器名称与偏移属于接口事实；若认为某处使用了超出事实引用的受版权材料，请提 issue 指出具体位置。