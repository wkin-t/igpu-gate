// macOS 26/27（Tahoe 线）的 SDK 已把 IOMemoryMap 合并进 IOMemoryDescriptor.h，
// `Kernel.framework/Headers/IOKit/` 下不再有独立 IOMemoryMap.h（SDK 26 与 27 均已核实）。
// 这个转发头只为保住源码里的旧式 `#include <IOKit/IOMemoryMap.h>`，
// **不引入任何自定义声明**，净效果为零；类定义仍在 IOMemoryDescriptor.h 里
// （`class IOMemoryMap : public OSObject`，getVirtualAddress/getLength/release 齐全）。
#pragma once
#include <IOKit/IOMemoryDescriptor.h>