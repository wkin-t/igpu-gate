// IGPULoadProbe —— Phase 2b-A0：**只验证加载路径**的最小 kext。
//
// 目的（唯一目的）：回答一个问题 ——
//   「OpenCore 注入到 Boot/Aux KC 的 kext，能不能满足对 System KC 里
//     com.apple.iokit.IOGraphicsFamily（IOFramebuffer 的父类）的依赖？」
//
// 因此本 kext 故意做成"能链接、但不产生任何副作用"：
//   * 继承 IOFramebuffer，从而**必须**解析 IOGraphicsFamily 的符号（这正是被测依赖）；
//   * Info.plist 里**没有 IOKitPersonalities** → 永远不被实例化 → start() 不会跑；
//   * 全部纯虚方法返回"不支持"，即使被误实例化也不会写任何 MMIO；
//   * 唯一的可观测输出在 kern_start/kern_stop 里打一条 IOLog（加载成功才会出现）。
//
// 判定方法（现场）：
//   加载成功      → `log show --last boot` 里有 "IGPULoadProbe: kern_start"，
//                   且 `kmutil showloaded` 能列出 dev.igpu.loadprobe
//   依赖不满足    → 没有 kern_start 行，日志/OC 日志里出现未解析依赖或 load failed
//   根本没注入    → 两者都没有，且 ESP 上没有本 kext
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/graphics/IOFramebuffer.h>

#define LOADPROBE_TAG "IGPULoadProbe"

class IGPULoadProbe : public IOFramebuffer
{
    OSDeclareDefaultStructors(IGPULoadProbe);

public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

    // ---- IOFramebuffer 的 8 个纯虚方法：全部返回"不支持" ----
    // 只在真的被实例化时才会调用；A0 阶段 Info.plist 不含 personality，
    // 所以这些实现是**安全兜底**，不是功能。
    virtual IODeviceMemory * getApertureRange(IOPixelAperture aperture) APPLE_KEXT_OVERRIDE;
    virtual const char * getPixelFormats(void) APPLE_KEXT_OVERRIDE;
    virtual IOItemCount getDisplayModeCount(void) APPLE_KEXT_OVERRIDE;
    virtual IOReturn getDisplayModes(IODisplayModeID *allDisplayModes) APPLE_KEXT_OVERRIDE;
    virtual IOReturn getInformationForDisplayMode(IODisplayModeID displayMode,
                                                  IODisplayModeInformation *info) APPLE_KEXT_OVERRIDE;
    virtual UInt64 getPixelFormatsForDisplayMode(IODisplayModeID displayMode,
                                                 IOIndex depth) APPLE_KEXT_OVERRIDE;
    virtual IOReturn getPixelInformation(IODisplayModeID displayMode, IOIndex depth,
                                         IOPixelAperture aperture,
                                         IOPixelInformation *pixelInfo) APPLE_KEXT_OVERRIDE;
    virtual IOReturn getCurrentDisplayMode(IODisplayModeID *displayMode,
                                          IOIndex *depth) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(IGPULoadProbe, IOFramebuffer);

bool IGPULoadProbe::start(IOService *provider)
{
    IOLog(LOADPROBE_TAG ": start() on provider %s —— A0 不应走到这里\n",
          provider ? provider->getName() : "(null)");
    // 不做任何寄存器/MMIO 操作；也不注册 framebuffer。
    return IOFramebuffer::start(provider);
}

void IGPULoadProbe::stop(IOService *provider)
{
    IOLog(LOADPROBE_TAG ": stop()\n");
    IOFramebuffer::stop(provider);
}

IODeviceMemory * IGPULoadProbe::getApertureRange(IOPixelAperture aperture)
{
    (void)aperture;
    return NULL;
}

const char * IGPULoadProbe::getPixelFormats(void)
{
    return "----";     // 空像素格式集：明确表示"不支持任何格式"
}

IOItemCount IGPULoadProbe::getDisplayModeCount(void)
{
    return 0;
}

IOReturn IGPULoadProbe::getDisplayModes(IODisplayModeID *allDisplayModes)
{
    (void)allDisplayModes;
    return kIOReturnUnsupported;
}

IOReturn IGPULoadProbe::getInformationForDisplayMode(IODisplayModeID displayMode,
                                                     IODisplayModeInformation *info)
{
    (void)displayMode; (void)info;
    return kIOReturnUnsupported;
}

UInt64 IGPULoadProbe::getPixelFormatsForDisplayMode(IODisplayModeID displayMode, IOIndex depth)
{
    (void)displayMode; (void)depth;
    return 0;
}

IOReturn IGPULoadProbe::getPixelInformation(IODisplayModeID displayMode, IOIndex depth,
                                           IOPixelAperture aperture,
                                           IOPixelInformation *pixelInfo)
{
    (void)displayMode; (void)depth; (void)aperture; (void)pixelInfo;
    return kIOReturnUnsupported;
}

IOReturn IGPULoadProbe::getCurrentDisplayMode(IODisplayModeID *displayMode, IOIndex *depth)
{
    (void)displayMode; (void)depth;
    return kIOReturnUnsupported;
}

// ---------------------------------------------------------------------------
// kext 加载/卸载钩子：**这是 A0 唯一的可观测输出**。
// 依赖不满足时内核不会调用这里，所以"日志里有没有这一行"就是加载成败的判据。
// ---------------------------------------------------------------------------
extern "C" kern_return_t IGPULoadProbe_kern_start(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    IOLog(LOADPROBE_TAG ": kern_start —— kext 已加载，IOGraphicsFamily 依赖已满足\n");
    return KERN_SUCCESS;
}

extern "C" kern_return_t IGPULoadProbe_kern_stop(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    IOLog(LOADPROBE_TAG ": kern_stop\n");
    return KERN_SUCCESS;
}

extern "C" {
KMOD_EXPLICIT_DECL(dev.igpu.loadprobe, "0.1.0", IGPULoadProbe_kern_start, IGPULoadProbe_kern_stop)
}