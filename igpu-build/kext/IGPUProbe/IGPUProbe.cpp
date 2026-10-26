// IGPUProbe —— Phase 1 只读探针 + Phase 2a 只读取证（prep 模式）
//
// 目的：证明"能被 OC 注入并加载 / 能发布可复核的读集 / 零 MMIO 写 / 四状态可判"；
//       prep 模式在此之上做 Phase 2 接管前的**只读取证**：判定活动 pipe、跑 A1–A7 断言、
//       记录 readiness 与显示/GTT/连接标志，**绝不触碰 IONDRV、绝不写任何寄存器**。
// 不做：接管显示、发布 IOFramebuffer、任何寄存器写入。
//
// 红线（评审会逐行查，tools/check-kext-source.py 也会静态扫）：
//   1. 本文件**不得**出现任何 MMIO 写（OSWriteLittleInt32 / outl / 裸指针赋值等）；
//   2. 不读 EDID（GMBUS/AUX 事务需要写总线控制寄存器，属主动操作）；
//   3. 物理身份三元组（vendor 8086 + device 4680 + revision 0C）不全 ⇒ 不碰 MMIO，
//      只发布 PhysicalIdentityVerified=false 与原因；
//   4. 任何异常都 fail-closed：记日志、不写寄存器、不阻塞启动。
//
// 2026-10-20 红军评审 9 条必修（全部落在本文件的 prep 段）：
//   · OSData 取字节统一 getBytesNoCopy + 指针检查 + 引用管理；
//   · 端口字段改 TGL+ 口径 (v>>27)&0xF，TC3 编码 6；并校验 DP SST 与 TRANS_CLK_SEL 的闭合；
//   · A3 增加 render/media decompression 与像素格式合同；
//   · readReg 增加对齐/长度/上界检查，0xFFFFFFFF 记 invalid 且不得被当"使能"；
//   · A5 先取 bits[11:0] 再乘 64，全程 UInt64；
//   · A6 分开 BAR0 / GGTT / GMADR，允许 SURF=0，用 need <= limit-surf 判越界，
//     不能证明扫描面长度时保留 unknown；
//   · readiness 增加 R2（运行时类、持有引用、provider 归属、isInactive），verdict 由完整断言驱动；
//   · display-connect-flags 优先在目标 framebuffer 子树里找，并记录来源与类型；
//   · 发布完整性门：EvidenceComplete / 失败原因 / 读取计数，prep 成功路径也发布 PhysicalIdentityVerified。
//
// 2026-10-20 红军第二轮 8 条（N1–N6 + R1/R2；R3 同文件要求一并修）：
//   · 格式字段按 ICL+ bits[27:23] 整体比较；尺寸按完整 16 位解码并查平台上限；
//   · 枚举栈入栈 retain / 出栈 release，候选持独立引用；
//   · bufferNeed 独立于 A6 计算；SURF 地址取 bits[31:12]、低 12 位单独记标志；
//   · 连接标志按 OSNumber(≤32bit)/OSData(len=4) 合同上报，回退命中不得写成已确认；
//   · 枚举结果改结构化回传（不再 strstr）；顶层标量全部走带返回值 helper 并回读校验。

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IORegistryEntry.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOMemoryMap.h>
#include <pexpert/pexpert.h>
#include <mach/kmod.h>
#include <string.h>

#include "IGPUProbeState.hpp"

#define IGPU_LOG(fmt, ...) IOLog("IGPUProbe: " fmt "\n", ##__VA_ARGS__)

// ADL-S 的 iGPU（spec §1.1：IOPCIPrimaryMatch = 0x46808086）。
// revision 只能靠 configRead 补，personality 的匹配串里没有这一位。
static const UInt16 kIntelVendorID    = 0x8086;
static const UInt16 kIGPUDeviceID     = 0x4680;
static const UInt8  kExpectedRevision = 0x0C;

// 活动 pipe 判定与断言用到的寄存器名（全部已存在于 190 项读集，不新增偏移）。
static const char *kRegTransDDIFuncCtl[2] = { "TRANS_DDI_FUNC_CTL_A", "TRANS_DDI_FUNC_CTL_B" };
static const char *kRegTransClkSel[2]     = { "TRANS_CLK_SEL_A", "TRANS_CLK_SEL_B" };
static const char *kRegPlaneCtl[2]        = { "PLANE_CTL_1_A", "PLANE_CTL_1_B" };
static const char *kRegPipeSrc[2]         = { "PIPESRC_A", "PIPESRC_B" };
static const char *kRegPlaneSize[2]       = { "PLANE_SIZE_1_A", "PLANE_SIZE_1_B" };
static const char *kRegPlaneStride[2]     = { "PLANE_STRIDE_1_A", "PLANE_STRIDE_1_B" };
static const char *kRegPlaneSurf[2]       = { "PLANE_SURF_1_A", "PLANE_SURF_1_B" };

// 期望模式：归档 EDID 的 DP 1080p（assets/06-edid-DP-E2423H.edid）。
static const UInt32 kExpectedWidth  = 1920;
static const UInt32 kExpectedHeight = 1080;

// TGL+ 端口字段口径（assets/02 §... 与 assets/17）：
//   TGL_TRANS_DDI_SELECT_PORT(port) = (port + 1) << 27，掩码 0xF << 27；
//   TC1..TC4 的 port 枚举是 3..6 ⇒ TC3 的字段值 = 5 + 1 = **6**。
// 为什么不能再用 bits[30:28]==3：旧口径把 (port+1) 的第 27 位漏掉了，
// 基线 0xB2030106 恰好在旧算法下也得到 3，掩盖了错误；而 TC4 例 0xBA030106 同样得到 3。
static const UInt32 kTransPortShift      = 27;
static const UInt32 kTransPortMask       = 0xF;
static const UInt32 kTransPortTC3        = 6;
static const UInt32 kTransModeShift      = 24;
static const UInt32 kTransModeMask       = 0x7;
static const UInt32 kTransModeDpSst      = 2;
static const UInt32 kTransClkSelShift    = 28;
static const UInt32 kTransClkSelMask     = 0xF;
static const UInt32 kTransClkSelTC3      = 6;

// PLANE_CTL 位（assets/17 逐字引用 skl_universal_plane_regs.h）：
//   FORMAT 在 ICL+ 是 **bits[27:23]**（5 位）：bit23 属于格式字段。
//   旧写法 bits[27:24] 会把 0x84800008（bit23=1）误判成 XRGB8888——这就是 N1 的反例：
//     0x84800008 的高 4 位 = 4，与 0x04000000 相同；只有把 bit23 一起比（字段值 9≠4）才会 fail。
//   XRGB8888 的字段值是 4 ⇒ 掩码后应等于 0x4 << 23 = 0x04000000。
//   RENDER_DECOMPRESSION = bit15，MEDIA_DECOMPRESSION = bit4（TGL+）；
//   TILED_MASK = bits[12:10]，linear = 0。
static const UInt32 kPlaneFormatMask     = 0x0F800000u;
static const UInt32 kPlaneFormatXrgb8888 = 0x04000000u;
static const UInt32 kPlaneFormatShift    = 23;   // 仅用于把字段值发布成数字
static const UInt32 kPlaneRenderDecomp   = 1u << 15;
static const UInt32 kPlaneMediaDecomp    = 1u << 4;
static const UInt32 kPlaneTileShift      = 10;
static const UInt32 kPlaneTileMask       = 0x7;

// PLANE_STRIDE：低 12 位是 64B 单位（assets/07 S5）；高位纯属异常，单独判。
static const UInt32 kStrideUnitsMask     = 0xFFF;

// PLANE_SURF 的低 12 位不是地址：bits[11:0] 是控制/加密标志，地址字段是 bits[31:12]
// （页对齐）。把整个寄存器当地址会让标志位混进偏移，A6 的越界判断随之假通过或假失败——R3。
static const UInt32 kSurfAddrMask        = 0xFFFFF000u;

// A4 的平台尺寸上限：ADL-S 单平面最大 8192。先按完整 16 位解，再做上限检查；
// 不能像旧写法那样 &0x3FFF / &0xFFF —— 那会把 6016 掩成 1920，让 N2 的反例假通过。
static const UInt32 kMaxPlaneDim         = 8192;

// BAR0 里寄存器窗口之后是 GGTT（gen9+ 约定 0x800000 起）。这只是**窗口**，不是"现有扫描面长度"。
static const UInt64 kGttWindowOffset     = 0x800000ULL;

// 读寄存器的三态：unavailable（没映射/没偏移/越界）、valid、invalid（读到 0xFFFFFFFF）。
enum {
    kPrepRegUnavailable = 0,
    kPrepRegValid       = 1,
    kPrepRegInvalid     = 2,
};

struct PrepRegRead {
    const char *name;
    UInt32      offset;
    UInt32      value;
    UInt8       state;
};

// 发布计数与错误累积：任何一次 setObject/setProperty 失败都必须能被看见，
// 否则"少了几个键"的报告看起来仍然像正常报告。
struct PrepPub {
    UInt32 reads;
    UInt32 invalid;
    UInt32 unavailable;
    UInt32 failures;
    char   errors[192];
};

static void prepHex8(char *out, UInt32 v)
{
    static const char digits[] = "0123456789abcdef";
    out[0] = '0';
    out[1] = 'x';
    for (int i = 0; i < 8; i++) {
        out[2 + i] = digits[(v >> ((7 - i) * 4)) & 0xF];
    }
    out[10] = 0;
}

static void prepCat(char *dst, size_t cap, const char *src)
{
    if (!dst || cap == 0 || !src) {
        return;
    }
    size_t n = strlen(dst);
    while (*src && n + 1 < cap) {
        dst[n++] = *src++;
    }
    dst[n] = 0;
}

// 把失败键名追加到 errors：只增加计数而不写原因，等于把"哪一项没发布"丢给现场猜，
// 这正是上一轮 R2 的假绿来源。缓冲区满时保留已写内容（截断也比重置成 none 好）。
static void prepNoteErr(PrepPub *p, const char *key)
{
    if (!p) {
        return;
    }
    if (p->errors[0]) {
        prepCat(p->errors, sizeof(p->errors), ";");
    }
    prepCat(p->errors, sizeof(p->errors), key ? key : "?");
}

// 枚举结果用结构体回传：complete / 候选数 / R2 各维必须由 verdict 直接消费。
// 用 detail 字符串 + strstr 反推状态，一旦措辞改动或别的键值里出现同样子串就会假绿——N6。
struct PrepEnum {
    bool    complete;
    UInt32  count;
    bool    runtimeClassOk;
    bool    providerOurs;
    bool    inactiveKnown;
    bool    inactive;
    bool    candidateHeld;
};

static const char *prepStateName(UInt8 state)
{
    if (state == kPrepRegValid) {
        return "valid";
    }
    if (state == kPrepRegInvalid) {
        return "invalid";
    }
    return "unavailable";
}

// 字典填充小工具：全部返回 bool，调用方把失败累加进 PrepPub.failures。
static bool prepPutObj(PrepPub *p, OSDictionary *d, const char *k, const OSObject *o)
{
    if (!d || !k || !o) {
        if (p) { p->failures++; prepNoteErr(p, k ? k : "<?>"); }
        return false;
    }
    if (!d->setObject(k, o)) {
        if (p) { p->failures++; prepNoteErr(p, k); }
        return false;
    }
    return true;
}

static void prepSetStrP(PrepPub *p, OSDictionary *d, const char *k, const char *v)
{
    if (!v) {
        if (p) { p->failures++; prepNoteErr(p, k ? k : "<?>"); }
        return;
    }
    OSString *s = OSString::withCString(v);
    if (!s) {
        if (p) { p->failures++; prepNoteErr(p, k ? k : "<?>"); }
        return;
    }
    prepPutObj(p, d, k, s);
    s->release();
}

static void prepSetNumP(PrepPub *p, OSDictionary *d, const char *k, unsigned long long v, unsigned int bits)
{
    OSNumber *n = OSNumber::withNumber(v, bits);
    if (!n) {
        if (p) { p->failures++; prepNoteErr(p, k ? k : "<?>"); }
        return;
    }
    prepPutObj(p, d, k, n);
    n->release();
}

static void prepSetBoolP(PrepPub *p, OSDictionary *d, const char *k, bool v)
{
    prepPutObj(p, d, k, v ? kOSBooleanTrue : kOSBooleanFalse);
}

// 在子树里找某个属性的来源节点。
//
// 引用契约（R1）：返回**已 retain 的** entry，调用方用完必须 release。
//   · 为什么不能返回裸指针：递归返回后 `it->release()` 已执行，子节点只由 registry 持有；
//     调用方拿它去 copyProperty 时对象可能已被 terminate。
//   · 为什么用 copyProperty 而不是 getProperty：前者返回持有引用，判定存在性后立即 release，
//     不会出现"两次 getProperty 之间属性被移除"的窗口。
//   · 为什么子遍历器不能替代调用方引用：getNextObject 只返回借用指针，迭代器释放后
//     不再保证对象存活；要用就必须自己 retain，而 retain 的责任只能落在返回值上。
//   · getBytesNoCopy 返回的是 OSData 内部指针，**不得**单独 release/free——
//     它不是独立对象，释放它等于释放别人的堆块。
// truncated 用于把"深度截断"与"确实没有"分开——枚举不完整时不得声称唯一。
static IORegistryEntry *prepFindPropInSubtree(IORegistryEntry *root, const char *key,
                                              int depth, int maxDepth, bool *truncated)
{
    if (!root || !key) {
        return 0;
    }
    OSObject *probe = root->copyProperty(key);
    if (probe) {
        probe->release();
        root->retain();          // 交给调用方的独立引用
        return root;
    }
    if (depth >= maxDepth) {
        OSIterator *it = root->getChildIterator(gIOServicePlane);
        if (it) {
            bool hasChild = (it->getNextObject() != 0);
            it->release();
            if (hasChild && truncated) {
                *truncated = true;
            }
        }
        return 0;
    }
    OSIterator *it = root->getChildIterator(gIOServicePlane);
    if (!it) {
        return 0;
    }
    IORegistryEntry *found = 0;
    OSObject *child = 0;
    while (!found && (child = it->getNextObject())) {
        IORegistryEntry *e = OSDynamicCast(IORegistryEntry, child);
        if (e) {
            // 递归返回值已经是持有引用；直接透传，不再二次 retain。
            found = prepFindPropInSubtree(e, key, depth + 1, maxDepth, truncated);
        }
    }
    it->release();
    return found;
}

class IGPUProbe : public IOService
{
    OSDeclareDefaultStructors(IGPUProbe)
    typedef IOService super;

public:
    bool       init(OSDictionary *dictionary = 0) APPLE_KEXT_OVERRIDE;
    IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    bool       start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void       stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void       free() APPLE_KEXT_OVERRIDE;

private:
    enum ProbeMode {
        kModeNormal = 0,
        kModeVerbose,
        kModeOff,
        kModePrep,
    };

    ProbeMode     fMode;
    IOPCIDevice  *fPci;
    IOMemoryMap  *fBarMap;      // BAR0 = GTTMMADR（寄存器窗口，只读使用）
    IOMemoryMap  *fGmadrMap;    // BAR2 = GMADR（可选，只读映射，用于范围核对）
    bool          fIdentityVerified;
    UInt16        fVendorID;
    UInt16        fDeviceID;
    UInt8         fRevision;
    UInt32        fReadCount;
    UInt32        fSuspectCount;
    IORegistryEntry *fPrepCandidate;  // prep 找到的 IONDRVFramebuffer（持引用，stop 释放）

    void parseBootArgs();
    bool verifyIdentity();
    bool openBar();
    void snapshot();
    void publishSummary();
    void publishRegs();
    void publishFailure(const char *reason);
    void closeBar();

    // ---- Phase 2a：prep 只读取证 ----
    bool  findRegOffset(const char *name, UInt32 *outOffset);
    void  prepReadReg(PrepPub *p, const char *name, PrepRegRead *out);
    void  publishPrep();
    bool  prepTop(PrepPub *p, const char *key, OSObject *obj);
    bool  prepTopNum(PrepPub *p, const char *key, unsigned long long v, unsigned int bits);
    bool  prepTopBool(PrepPub *p, const char *key, bool v);
    bool  prepTopStr(PrepPub *p, const char *key, const char *v);
    void  publishConnFlags(PrepPub *p, OSDictionary *d, IORegistryEntry *candidate);
    bool  scanIONDRV(PrepPub *p, PrepEnum *out, char *detail, size_t detailCap);
    void  releasePrepCandidate();
};

OSDefineMetaClassAndStructors(IGPUProbe, IOService)

bool IGPUProbe::init(OSDictionary *dictionary)
{
    if (!super::init(dictionary)) {
        return false;
    }
    fMode = kModeNormal;
    fPci = 0;
    fBarMap = 0;
    fGmadrMap = 0;
    fIdentityVerified = false;
    fVendorID = 0;
    fDeviceID = 0;
    fRevision = 0;
    fReadCount = 0;
    fSuspectCount = 0;
    fPrepCandidate = 0;
    parseBootArgs();
    return true;
}

// boot-arg 名：`igpu-driver`（**不带前导 `-`**），取值 off|verbose|prep，缺省即 normal。
//
// 为什么不能写 `-igpu-driver=off`：XNU 的 boot-args 解析把前导 `-` 的 token 当作布尔开关，
// PE_parse_boot_argn 按名字精确匹配；`-igpu-driver=off` 既匹配不到 `igpu-driver`、
// 也取不到 "off"，会静默回落 normal —— off/verbose/prep 三种状态永远测不出来，而静态门禁仍全绿。
// 所以状态部署时，config.plist 的 boot-args 必须写 `igpu-driver=off` / `igpu-driver=verbose` / `igpu-driver=prep`。
//
// off 的语义是"行为 ≡ 无 kext"（spec §1.3-d）：probe 阶段直接不匹配，
// 因而 ioreg 里既没有实例也没有属性 —— 与采集器对 off 的期望（loaded>0, inst=0, prop=0）一致。
//
// prep 的语义是"只读取证"（Phase 2a）：照常匹配并发布属性，但只做 MMIO 读与 IORegistry 遍历，
// 不发退役消息、不 terminate、不切 SURF、不写任何寄存器。
void IGPUProbe::parseBootArgs()
{
    char value[64];
    bzero(value, sizeof(value));
    if (!PE_parse_boot_argn("igpu-driver", value, sizeof(value))) {
        fMode = kModeNormal;
        return;
    }
    if (strcmp(value, "off") == 0) {
        fMode = kModeOff;
    } else if (strcmp(value, "verbose") == 0) {
        fMode = kModeVerbose;
    } else if (strcmp(value, "prep") == 0) {
        fMode = kModePrep;
    } else {
        if (strcmp(value, "normal") != 0) {
            IGPU_LOG("unknown igpu-driver value '%s', falling back to normal", value);
        }
        fMode = kModeNormal;
    }
}

IOService *IGPUProbe::probe(IOService *provider, SInt32 *score)
{
    if (fMode == kModeOff) {
        // 不匹配 ⇒ 无实例、无属性；kext 本身仍会被 kmutil 记为已加载。
        IGPU_LOG("off: skipping match (no instance, no properties)");
        return 0;
    }
    if (!OSDynamicCast(IOPCIDevice, provider)) {
        return 0;
    }
    return this;
}

bool IGPUProbe::start(IOService *provider)
{
    fPci = OSDynamicCast(IOPCIDevice, provider);
    if (!fPci) {
        IGPU_LOG("provider is not IOPCIDevice, fail-closed");
        return false;
    }

    fVendorID = fPci->configRead16(kIOPCIConfigVendorID);
    fDeviceID = fPci->configRead16(kIOPCIConfigDeviceID);
    fRevision = fPci->configRead8(kIOPCIConfigRevisionID);
    fIdentityVerified = verifyIdentity();

    IGPU_LOG("vendor=0x%04x device=0x%04x revision=0x%02x identity_verified=%d mode=%d",
             fVendorID, fDeviceID, fRevision, (int)fIdentityVerified, (int)fMode);

    if (!fIdentityVerified) {
        publishFailure("physical identity mismatch");
        registerService();
        return super::start(provider);
    }
    if (!openBar()) {
        publishFailure("BAR0 map failed");
        registerService();
        return super::start(provider);
    }

    if (fMode == kModePrep) {
        publishPrep();
        registerService();
        return super::start(provider);
    }

    snapshot();
    publishSummary();
    publishRegs();
    registerService();
    if (fMode == kModeVerbose) {
        for (UInt32 i = 0; i < kIGPUProbeRegCount; i++) {
            IGPU_LOG("  %-28s [0x%06X] = 0x%08X", kIGPUProbeRegs[i].name,
                     kIGPUProbeRegs[i].offset, kIGPUProbeRegs[i].value);
        }
    }
    return super::start(provider);
}

bool IGPUProbe::verifyIdentity()
{
    return fVendorID == kIntelVendorID && fDeviceID == kIGPUDeviceID && fRevision == kExpectedRevision;
}

bool IGPUProbe::openBar()
{
    fBarMap = fPci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    if (!fBarMap || !fBarMap->getVirtualAddress() || fBarMap->getLength() == 0) {
        return false;
    }
    fGmadrMap = fPci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress2);
    return true;
}

void IGPUProbe::snapshot()
{
    UInt32 read = 0;
    UInt32 suspect = 0;
    for (UInt32 i = 0; i < kIGPUProbeRegCount; i++) {
        PrepRegRead r;
        PrepPub p;
        bzero(&p, sizeof(p));
        prepReadReg(&p, kIGPUProbeRegs[i].name, &r);
        if (r.state == kPrepRegValid) {
            kIGPUProbeRegs[i].value = r.value;
            read++;
        } else {
            kIGPUProbeRegs[i].value = 0xFFFFFFFF;
            suspect++;
        }
    }
    fReadCount = read;
    fSuspectCount = suspect;
}

void IGPUProbe::publishSummary()
{
    setProperty("GPUAccess", "none: MMIO reads only");
    setProperty("PhysicalIdentityVerified", fIdentityVerified);
    setProperty("RegsRead", (unsigned long long)fReadCount, 32);
    setProperty("RegsSuspect", (unsigned long long)fSuspectCount, 32);
    setProperty("VendorID", (unsigned long long)fVendorID, 16);
    setProperty("DeviceID", (unsigned long long)fDeviceID, 16);
    setProperty("RevisionID", (unsigned long long)fRevision, 8);
    if (fSuspectCount > 0) {
        setProperty("ProbeError", "some registers read as 0xFFFFFFFF (see RegsSuspect)");
    }
}

// F6 回归修复：Phase 1 的 normal/verbose 会发布逐项读数（IGPUProbeState 字典），
// prep 重写时 publishSummary() 只剩计数，导致采集器拿不到 190 个原始值。
// 这里恢复"计数 + 逐项值"的交付通道：键=寄存器名，值=OSData(4 字节小端)。
// 为什么用 OSData 而不是 OSNumber：Phase 1 的采集器就是按 OSData 解析的，
// 保持一致才能与历史 ioreg 快照逐项对照；同时避免把 32 位值发布成十进制怪值。
void IGPUProbe::publishRegs()
{
    OSDictionary *table = OSDictionary::withCapacity(kIGPUProbeRegCount);
    if (!table) {
        setProperty("ProbeError", "RegsTable allocation failed");
        return;
    }
    UInt32 published = 0;
    for (UInt32 i = 0; i < kIGPUProbeRegCount; i++) {
        UInt32 raw = kIGPUProbeRegs[i].value;
        OSData *item = OSData::withBytes(&raw, sizeof(raw));
        if (!item) {
            continue;
        }
        // setObject 会 retain；这里立刻 release，最终由 table 持有。
        if (table->setObject(kIGPUProbeRegs[i].name, item)) {
            published++;
        }
        item->release();
    }
    setProperty("IGPUProbeState", table);
    setProperty("RegsTable", (unsigned long long)published, 32);
    setProperty("RegsTableFormat", "name -> OSData(4B LE)");
    if (published != kIGPUProbeRegCount) {
        setProperty("ProbeError", "RegsTable incomplete (published != 190)");
    }
    table->release();
}

void IGPUProbe::publishFailure(const char *reason)
{
    setProperty("PhysicalIdentityVerified", false);
    setProperty("ProbeError", reason);
    setProperty("GPUAccess", "none: no MMIO opened");
    setProperty("VendorID", (unsigned long long)fVendorID, 16);
    setProperty("DeviceID", (unsigned long long)fDeviceID, 16);
    setProperty("RevisionID", (unsigned long long)fRevision, 8);
    IGPU_LOG("fail-closed: %s", reason);
}

// ---------------------------------------------------------------------------
// Phase 2a：prep 只读取证
// ---------------------------------------------------------------------------

bool IGPUProbe::findRegOffset(const char *name, UInt32 *outOffset)
{
    if (!name || !outOffset) {
        return false;
    }
    for (UInt32 i = 0; i < kIGPUProbeRegCount; i++) {
        if (strcmp(kIGPUProbeRegs[i].name, name) == 0) {
            *outOffset = kIGPUProbeRegs[i].offset;
            return true;
        }
    }
    return false;
}

// 读一个寄存器，三态明确：
//   unavailable —— 没映射 / 表里没这个偏移 / 偏移未对齐 / 超出映射长度；
//   invalid     —— 读回 0xFFFFFFFF（总线无响应/块未上电的典型值）；
//   valid       —— 其余值（含 0：0 是合法值，不能一律拒绝）。
//
// 边界检查为什么用减法：`off + 4 <= len` 在 off 接近 UInt32 上限时会溢出。
// 这里先要求 off <= len，再用 `len - off >= 4` 判剩余长度，UInt64 计算，永不溢出。
void IGPUProbe::prepReadReg(PrepPub *p, const char *name, PrepRegRead *out)
{
    out->name = name;
    out->offset = 0;
    out->value = 0;
    out->state = kPrepRegUnavailable;
    if (!fBarMap) {
        if (p) { p->unavailable++; }
        return;
    }
    UInt32 off = 0;
    if (!findRegOffset(name, &off)) {
        if (p) { p->unavailable++; }
        return;
    }
    out->offset = off;
    if ((off & 3) != 0) {
        if (p) { p->unavailable++; }
        return;
    }
    volatile const void *base = (volatile const void *)fBarMap->getVirtualAddress();
    if (!base) {
        if (p) { p->unavailable++; }
        return;
    }
    UInt64 len = (UInt64)fBarMap->getLength();
    if ((UInt64)off > len || (len - (UInt64)off) < 4) {
        if (p) { p->unavailable++; }
        return;
    }
    UInt32 v = (UInt32)OSReadLittleInt32(base, off);
    out->value = v;
    if (v == 0xFFFFFFFFu) {
        out->state = kPrepRegInvalid;
        if (p) { p->reads++; p->invalid++; }
        return;
    }
    out->state = kPrepRegValid;
    if (p) { p->reads++; }
}

bool IGPUProbe::prepTop(PrepPub *p, const char *key, OSObject *obj)
{
    if (!key || !obj) {
        if (p) { p->failures++; prepNoteErr(p, key ? key : "<?>"); }
        return false;
    }
    if (!setProperty(key, obj)) {
        if (p) { p->failures++; prepNoteErr(p, key); }
        return false;
    }
    return true;
}

// 顶层标量统一走带返回值的 helper（R2）：setProperty 的返回值被平台钩子否决时是 false，
// 旧代码把它丢掉 ⇒ 键其实没发布，EvidenceComplete 仍然可能为真。
// 所有失败路径都记进 pub.errors，报告里能直接看到"是哪个键没写成"。
bool IGPUProbe::prepTopNum(PrepPub *p, const char *key, unsigned long long v, unsigned int bits)
{
    OSNumber *n = OSNumber::withNumber(v, bits);
    if (!n) {
        if (p) { p->failures++; prepNoteErr(p, key ? key : "<?>"); }
        return false;
    }
    bool ok = prepTop(p, key, n);
    n->release();
    return ok;
}

bool IGPUProbe::prepTopBool(PrepPub *p, const char *key, bool v)
{
    return prepTop(p, key, v ? kOSBooleanTrue : kOSBooleanFalse);
}

bool IGPUProbe::prepTopStr(PrepPub *p, const char *key, const char *v)
{
    OSString *s = OSString::withCString(v ? v : "");
    if (!s) {
        if (p) { p->failures++; prepNoteErr(p, key ? key : "<?>"); }
        return false;
    }
    bool ok = prepTop(p, key, s);
    s->release();
    return ok;
}

// 数值 → 固定宽度 hex 字符串。OSNumber 在 ioreg 里显示十进制，
// 复核时容易把 14085 当成宽度；hex 字符串可读性更好，也便于与台账逐字比对。
static void prepSetHexP(PrepPub *p, OSDictionary *d, const char *k, UInt32 v)
{
    char buf[11];
    prepHex8(buf, v);
    prepSetStrP(p, d, k, buf);
}

// 递归扫描 IONDRVFramebuffer，返回"是否完整枚举"。
// R2 要求的是运行时类匹配（metaCast），不是只看 IOClass 属性字符串：
//   IOClass 属性可以被 provider 改写/伪装，metaCast 走 OSMetaClass 继承链；
//   同时持有引用后再读 provider 归属与 isInactive，避免对象在扫描与使用之间被释放。
bool IGPUProbe::scanIONDRV(PrepPub *p, PrepEnum *out, char *detail, size_t detailCap)
{
    if (!out) {
        return false;
    }
    bzero(out, sizeof(*out));
    releasePrepCandidate();

    if (!fPci) {
        prepCat(detail, detailCap, "no-provider");
        return false;
    }
    bool complete = true;
    UInt32 count = 0;
    char firstProvider[64];
    bzero(firstProvider, sizeof(firstProvider));
    bool inactiveKnown = false;
    bool inactive = false;
    bool providerIsOurs = false;
    bool runtimeClassOk = false;

    // 引用契约（N3）：**入栈即 retain，出栈处理完再 release**。
    //   · 旧实现把 getNextObject 的借用指针直接入栈：迭代器 release 后、或对象被 terminate 后，
    //     出栈时就是悬垂指针；后续 metaCast/getParentEntry 都在读已释放内存。
    //   · 首个候选取**独立引用**（再 retain 一次）：栈里的那份退出循环就释放，
    //     不能让它顺带把 fPrepCandidate 也一起释放。
    //   · 栈满只放弃尚未入栈的兄弟节点（不计引用），已入栈的仍会逐个弹出释放；
    //     所以"截断"路径不会漏引用。
    //   · 为什么子遍历器不能替代调用方引用：getNextObject 不 retain，迭代器释放后
    //     对象存活不受调用方控制；要跨函数使用就必须自己持有。
    IORegistryEntry *stack[64];
    int sp = 0;
    fPci->retain();
    stack[sp++] = fPci;
    while (sp > 0) {
        IORegistryEntry *e = stack[--sp];        // e 由栈持有一份引用
        if (e->metaCast("IONDRVFramebuffer")) {
            count++;
            runtimeClassOk = true;
            if (count == 1) {
                e->retain();                     // fPrepCandidate 的独立引用
                fPrepCandidate = e;
                // 父节点同样是借用指针：先 retain 再解引用，用完 release（R1 残留项）。
                IORegistryEntry *prov = e->getParentEntry(gIOServicePlane);
                if (prov) { prov->retain(); }
                providerIsOurs = (prov == fPci);
                OSObject *pnObj = prov ? prov->copyProperty("IOName") : 0;
                OSString *pn = OSDynamicCast(OSString, pnObj);
                if (pn) {
                    const char *src = pn->getCStringNoCopy();
                    size_t n = 0;
                    while (src && src[n] && n + 1 < sizeof(firstProvider)) {
                        firstProvider[n] = src[n];
                        n++;
                    }
                    firstProvider[n] = 0;
                }
                if (pnObj) {
                    pnObj->release();            // copyProperty 的持有引用
                }
                if (prov) { prov->release(); }   // 与上面的 retain 配平
                IOService *svc = OSDynamicCast(IOService, e);
                if (svc) {
                    inactiveKnown = true;
                    inactive = svc->isInactive();
                }
            }
        }
        OSIterator *it = e->getChildIterator(gIOServicePlane);
        if (!it) {
            complete = false;
            e->release();
            continue;
        }
        OSObject *child = 0;
        while ((child = it->getNextObject())) {
            IORegistryEntry *c = OSDynamicCast(IORegistryEntry, child);
            if (!c) {
                continue;
            }
            if (sp >= (int)(sizeof(stack) / sizeof(stack[0]))) {
                complete = false;
                break;                       // 未入栈的兄弟不 retain，无需释放
            }
            c->retain();                     // 入栈即持有
            stack[sp++] = c;
        }
        it->release();
        e->release();                        // 出栈引用在这里释放
    }

    out->complete = complete;
    out->count = count;
    out->runtimeClassOk = runtimeClassOk;
    out->providerOurs = providerIsOurs;
    out->inactiveKnown = inactiveKnown;
    out->inactive = inactive;
    out->candidateHeld = (fPrepCandidate != 0);
    if (count == 0) {
        prepCat(detail, detailCap, "count=0");
    } else if (count > 1) {
        prepCat(detail, detailCap, "count>1");
    }
    if (!complete) {
        prepCat(detail, detailCap, ";enum-truncated");
    }
    if (count == 1) {
        // 记录 provider 归属（名字 + 是否就是本 kext 的 PCI provider）与运行时活跃状态，
        // 这样"候选对象属于别的设备"或"对象已 inactive"都能在报告里直接看出来。
        prepCat(detail, detailCap, ";provider=");
        prepCat(detail, detailCap, firstProvider[0] ? firstProvider : "unknown");
        if (!providerIsOurs) {
            prepCat(detail, detailCap, ";provider-not-our-pci");
        }
        if (!inactiveKnown) {
            prepCat(detail, detailCap, ";inactive-unknown");
        } else if (inactive) {
            prepCat(detail, detailCap, ";inactive=1");
        } else {
            prepCat(detail, detailCap, ";inactive=0");
        }
    }

    // 细节通过 detail 字符串回传给调用方，由 publishPrep 组装进 PrepReadiness。
    return complete && count == 1 && runtimeClassOk && providerIsOurs && inactiveKnown && !inactive;
}

void IGPUProbe::publishConnFlags(PrepPub *p, OSDictionary *d, IORegistryEntry *candidate)
{
    const char *key = "display-connect-flags";
    bool truncated = false;
    IORegistryEntry *found = 0;          // 持有引用（prepFindPropInSubtree 的契约）
    const char *source = "unknown";
    bool belongs = false;                // 只有"目标 framebuffer 子树"才算确认归属

    // 方向修正：该属性通常挂在 framebuffer/显示节点上，而不是 PCI 自身的祖先链。
    if (candidate) {
        found = prepFindPropInSubtree(candidate, key, 0, 3, &truncated);
        if (found) {
            source = "candidate-subtree";
            belongs = true;
        }
    }
    if (!found && fPci) {
        // PCI 子树是回退命中：它可能来自别的显示设备，**不能**写成"已确认 flags"。
        found = prepFindPropInSubtree(fPci, key, 0, 3, &truncated);
        if (found) {
            source = "pci-subtree";
            belongs = false;
        }
    }
    if (!found && fPci) {
        fPci->retain();
        found = fPci;
        source = "pci-self";
        belongs = false;
    }

    prepSetStrP(p, d, "Source", source);
    if (!found) {
        prepSetStrP(p, d, "Status", truncated ? "unknown:not-found-truncated" : "unknown:not-found");
        return;
    }
    prepSetNumP(p, d, "SourceEntryID", (unsigned long long)found->getRegistryEntryID(), 64);
    prepSetBoolP(p, d, "BelongsToTarget", belongs);

    OSObject *v = found->copyProperty(key);   // 持有引用
    if (!v) {
        prepSetStrP(p, d, "Source", truncated ? "not-found:truncated" : "not-found");
        prepSetStrP(p, d, "Status", "unknown:not-found");
        found->release();
        return;
    }

    OSData *data = OSDynamicCast(OSData, v);
    OSNumber *num = OSDynamicCast(OSNumber, v);
    if (num) {
        // OSNumber 的合同是 32 位 flags：numberOfBits > 32 或值 > 0xFFFFFFFF 都超出合同，
        // 必须报 unknown/invalid 并保留原始宽度与 64 位值，不能静默截成 UInt32（N5 反例 0x1_0000_0000）。
        UInt64 nv = num->unsigned64BitValue();
        UInt32 bits = (UInt32)num->numberOfBits();
        prepSetStrP(p, d, "Type", "OSNumber");
        prepSetNumP(p, d, "RawBits", bits, 32);
        prepSetNumP(p, d, "Raw64", nv, 64);
        if (bits > 32 || nv > 0xFFFFFFFFULL) {
            prepSetStrP(p, d, "Status", "unknown:exceeds-32bit-contract");
        } else {
            prepSetHexP(p, d, "Raw", (UInt32)nv);
            prepSetStrP(p, d, "Status", belongs ? "ok" : "unknown:not-target-display");
        }
    } else if (data) {
        UInt32 len = data->getLength();
        prepSetStrP(p, d, "Type", "OSData");
        prepSetNumP(p, d, "Length", len, 32);
        if (len == 4) {
            // getBytesNoCopy 返回内部指针：只读复制，不 release/free（它不是独立对象）。
            const void *bytes = data->getBytesNoCopy(0, 4);
            if (bytes) {
                UInt32 raw = 0;
                memcpy(&raw, bytes, sizeof(raw));
                prepSetHexP(p, d, "Raw", raw);
                prepSetStrP(p, d, "Status", belongs ? "ok" : "unknown:not-target-display");
            } else {
                prepSetStrP(p, d, "Status", "unknown:data-pointer-null");
            }
        } else if (len > 4) {
            const void *bytes = data->getBytesNoCopy(0, 4);
            if (bytes) {
                UInt32 raw = 0;
                memcpy(&raw, bytes, sizeof(raw));
                prepSetHexP(p, d, "Raw", raw);
            }
            // 长度 >4 不在 32 位合同内：保留长度与前 4 字节，但状态明确 unknown。
            prepSetStrP(p, d, "Status", "unknown:data-length-contract");
        } else {
            prepSetStrP(p, d, "Status", "unknown:data-short");
        }
    } else {
        prepSetStrP(p, d, "Type", "other");
        prepSetStrP(p, d, "Status", "unknown:type");
    }
    v->release();
    found->release();
}

void IGPUProbe::releasePrepCandidate()
{
    if (fPrepCandidate) {
        fPrepCandidate->release();
        fPrepCandidate = 0;
    }
}

void IGPUProbe::publishPrep()
{
    PrepPub pub;
    bzero(&pub, sizeof(pub));

    // ---- 读全部相关寄存器（A/B 两路都读，便于离线复核）----
    PrepRegRead tddi[2], tclk[2], pctl[2], psrc[2], psize[2], pstride[2], psurf[2];
    PrepRegRead ddiBuf;
    prepReadReg(&pub, kRegTransDDIFuncCtl[0], &tddi[0]);
    prepReadReg(&pub, kRegTransDDIFuncCtl[1], &tddi[1]);
    prepReadReg(&pub, kRegTransClkSel[0], &tclk[0]);
    prepReadReg(&pub, kRegTransClkSel[1], &tclk[1]);
    prepReadReg(&pub, kRegPlaneCtl[0], &pctl[0]);
    prepReadReg(&pub, kRegPlaneCtl[1], &pctl[1]);
    prepReadReg(&pub, kRegPipeSrc[0], &psrc[0]);
    prepReadReg(&pub, kRegPipeSrc[1], &psrc[1]);
    prepReadReg(&pub, kRegPlaneSize[0], &psize[0]);
    prepReadReg(&pub, kRegPlaneSize[1], &psize[1]);
    prepReadReg(&pub, kRegPlaneStride[0], &pstride[0]);
    prepReadReg(&pub, kRegPlaneStride[1], &pstride[1]);
    prepReadReg(&pub, kRegPlaneSurf[0], &psurf[0]);
    prepReadReg(&pub, kRegPlaneSurf[1], &psurf[1]);
    prepReadReg(&pub, "DDI_BUF_CTL_TC3", &ddiBuf);

    // ---- A1：活动路径闭合（两路 enable 数单独统计）----
    UInt32 enableCount = 0;
    UInt32 targetCount = 0;
    int active = -1;
    char a1[128];
    char routeFail[128];
    bzero(a1, sizeof(a1));
    bzero(routeFail, sizeof(routeFail));
    for (int i = 0; i < 2; i++) {
        if (tddi[i].state == kPrepRegValid && ((tddi[i].value >> 31) & 1) == 1) {
            enableCount++;
        }
        if (tddi[i].state == kPrepRegValid
            && (((tddi[i].value >> kTransPortShift) & kTransPortMask) == kTransPortTC3)) {
            targetCount++;
        }
    }

    if (tddi[0].state != kPrepRegValid || tddi[1].state != kPrepRegValid) {
        prepCat(a1, sizeof(a1), "fail:trans-reading-not-valid");
        prepCat(routeFail, sizeof(routeFail), "trans-reading-not-valid");
    } else if (enableCount == 0) {
        prepCat(a1, sizeof(a1), "fail:no-enabled-transcoder");
        prepCat(routeFail, sizeof(routeFail), "no-enabled-transcoder");
    } else if (enableCount > 1) {
        // spec 字面：两路都 enable ⇒ 拒绝。不能用"目标端口命中数"替代 enable 计数：
        // 两路都 enable、只有一路端口字段=6 时，旧实现会选出一路并判 pass。
        prepCat(a1, sizeof(a1), "fail:multiple-enabled-transcoders");
        prepCat(routeFail, sizeof(routeFail), "multiple-enabled-transcoders");
    } else {
        active = (tddi[0].state == kPrepRegValid && ((tddi[0].value >> 31) & 1) == 1) ? 0 : 1;
        UInt32 port = (tddi[active].value >> kTransPortShift) & kTransPortMask;
        UInt32 mode = (tddi[active].value >> kTransModeShift) & kTransModeMask;
        bool clkOk = (tclk[active].state == kPrepRegValid)
                     && (((tclk[active].value >> kTransClkSelShift) & kTransClkSelMask) == kTransClkSelTC3);
        if (port != kTransPortTC3) {
            prepCat(a1, sizeof(a1), "fail:port-field-not-TC3");
            prepCat(routeFail, sizeof(routeFail), "port-field-not-TC3");
        } else if (mode != kTransModeDpSst) {
            prepCat(a1, sizeof(a1), "fail:mode-not-dp-sst");
            prepCat(routeFail, sizeof(routeFail), "mode-not-dp-sst");
        } else if (!clkOk) {
            prepCat(a1, sizeof(a1), "fail:clock-sel-not-TC3");
            prepCat(routeFail, sizeof(routeFail), "clock-sel-not-TC3");
        } else {
            prepCat(a1, sizeof(a1), "pass");
        }
    }

    // ---- 取活动 pipe 的显示寄存器；没有唯一 pipe 时全部按 unavailable 处理 ----
    PrepRegRead ctl, src, size, stride, surf;
    bzero(&ctl, sizeof(ctl));
    bzero(&src, sizeof(src));
    bzero(&size, sizeof(size));
    bzero(&stride, sizeof(stride));
    bzero(&surf, sizeof(surf));
    ctl.name = "PLANE_CTL_1_?"; ctl.state = kPrepRegUnavailable;
    src.name = "PIPESRC_?"; src.state = kPrepRegUnavailable;
    size.name = "PLANE_SIZE_1_?"; size.state = kPrepRegUnavailable;
    stride.name = "PLANE_STRIDE_1_?"; stride.state = kPrepRegUnavailable;
    surf.name = "PLANE_SURF_1_?"; surf.state = kPrepRegUnavailable;
    if (active >= 0) {
        ctl = pctl[active];
        src = psrc[active];
        size = psize[active];
        stride = pstride[active];
        surf = psurf[active];
    }

    // ---- A2：使能（invalid 读数不得当"使能"）----
    char a2[160];
    bzero(a2, sizeof(a2));
    if (ctl.state != kPrepRegValid) {
        prepCat(a2, sizeof(a2), ctl.state == kPrepRegInvalid ? "fail:plane-ctl-invalid" : "fail:plane-ctl-unavailable");
    } else if (ddiBuf.state != kPrepRegValid) {
        prepCat(a2, sizeof(a2), ddiBuf.state == kPrepRegInvalid ? "fail:ddi-buf-invalid" : "fail:ddi-buf-unavailable");
    } else if (((ctl.value >> 31) & 1) == 0) {
        prepCat(a2, sizeof(a2), "fail:plane-disabled");
    } else if (((ddiBuf.value >> 31) & 1) == 0) {
        prepCat(a2, sizeof(a2), "fail:ddi-buf-disabled");
    } else {
        prepCat(a2, sizeof(a2), "pass");
    }

    // ---- A3：线性 + 未压缩 + 32bpp XRGB8888 合同 ----
    // 反例：PLANE_CTL=0x84008000 只置了 render decompression(bit15)，
    // 旧实现只看 tile 字段，仍然 pass；这里三个条件分别判，任一命中即 fail。
    char a3[160];
    bzero(a3, sizeof(a3));
    if (ctl.state != kPrepRegValid) {
        prepCat(a3, sizeof(a3), ctl.state == kPrepRegInvalid ? "fail:plane-ctl-invalid" : "fail:plane-ctl-unavailable");
    } else {
        UInt32 tile = (ctl.value >> kPlaneTileShift) & kPlaneTileMask;
        // 5 位字段整体比较：0x84800008 的 bit23=1 ⇒ 字段值 9 ≠ 4，必须 fail。
        // 若只取高 4 位（旧写法），0x84800008 与 0x04000000 都被看成 4，反例会被放行。
        UInt32 fmtField = ctl.value & kPlaneFormatMask;
        if (tile != 0) {
            prepCat(a3, sizeof(a3), "fail:tiled-nonzero");
        } else if ((ctl.value & kPlaneRenderDecomp) != 0) {
            prepCat(a3, sizeof(a3), "fail:render-decompression");
        } else if ((ctl.value & kPlaneMediaDecomp) != 0) {
            prepCat(a3, sizeof(a3), "fail:media-decompression");
        } else if (fmtField != kPlaneFormatXrgb8888) {
            prepCat(a3, sizeof(a3), "fail:format-not-xrgb8888");
        } else {
            prepCat(a3, sizeof(a3), "pass");
        }
    }

    // ---- A4：尺寸（两个寄存器的字段序**相反**，实测锚点见下）----
    // 实测（2026-10-20，ioreg -a plist，normal 态）：
    //   PIPESRC_A      = 0x077F0437 ⇒ 高 16 = 0x077F = 1919 ⇒ 宽 1920；低 16 = 0x0437 = 1079 ⇒ 高 1080
    //   PLANE_SIZE_1_A = 0x0437077F ⇒ 低 16 = 0x077F = 1919 ⇒ 宽 1920；高 16 = 0x0437 = 1079 ⇒ 高 1080
    // ⇒ PIPESRC 宽在高 16、PLANE_SIZE 宽在低 16；两者按各自方向解出后必须相等（A4 的"一致"判据）。
    // 为什么不能套同一个方向：会把 1920×1080 解成 1080×1920，真机上 A4 必假失败。
    // N2：必须按完整 16 位解。旧写法 &0x3FFF / &0xFFF 会把 6016 掩成 1920，
    //      让 PLANE_SIZE=0x0437177F（宽 6016）在"A4 == 1920×1080"下假通过。
    //      完整解码后再单独做平台上限检查：超过 8192 说明字段解错，不能继续拿"看起来 1920"当证据。
    UInt32 srcW = 0, srcH = 0, sizeW = 0, sizeH = 0;
    if (src.state == kPrepRegValid) {
        srcW = ((src.value >> 16) & 0xFFFFu) + 1;   // PIPESRC：宽在高 16
        srcH = (src.value & 0xFFFFu) + 1;           // PIPESRC：高在低 16
    }
    if (size.state == kPrepRegValid) {
        sizeW = (size.value & 0xFFFFu) + 1;
        sizeH = ((size.value >> 16) & 0xFFFFu) + 1;
    }
    char a4[160];
    bzero(a4, sizeof(a4));
    if (src.state != kPrepRegValid || size.state != kPrepRegValid) {
        prepCat(a4, sizeof(a4), "fail:size-reading-not-valid");
    } else if (srcW > kMaxPlaneDim || srcH > kMaxPlaneDim
               || sizeW > kMaxPlaneDim || sizeH > kMaxPlaneDim) {
        prepCat(a4, sizeof(a4), "fail:size-exceeds-platform-limit");
    } else if (srcW != sizeW || srcH != sizeH) {
        prepCat(a4, sizeof(a4), "fail:pipesrc-plane-size-disagree");
    } else if (srcW != kExpectedWidth || srcH != kExpectedHeight) {
        prepCat(a4, sizeof(a4), "fail:not-1920x1080");
    } else {
        prepCat(a4, sizeof(a4), "pass");
    }

    // ---- A5：stride，先取 bits[11:0] 再乘 64，全程 UInt64 ----
    // 反例：0x04000078 用 32 位整体乘 64 会回绕成 7680（假绿）；这里高位单独判。
    UInt64 strideBytes = 0;
    UInt64 bufferNeed = 0;
    char a5[160];
    bzero(a5, sizeof(a5));
    if (stride.state != kPrepRegValid) {
        prepCat(a5, sizeof(a5), stride.state == kPrepRegInvalid ? "fail:stride-invalid" : "fail:stride-unavailable");
    } else if (sizeW == 0 || sizeH == 0) {
        prepCat(a5, sizeof(a5), "fail:size-unknown");
    } else if ((stride.value & ~kStrideUnitsMask) != 0) {
        prepCat(a5, sizeof(a5), "fail:stride-high-bits");
    } else {
        UInt64 units = (UInt64)(stride.value & kStrideUnitsMask);
        strideBytes = units * 64ULL;
        UInt64 expected = (UInt64)sizeW * 4ULL;
        if (strideBytes != expected) {
            prepCat(a5, sizeof(a5), "fail:stride-mismatch");
        } else {
            prepCat(a5, sizeof(a5), "pass");
        }
    }

    // ---- N4：bufferNeed 独立计算，A6 只消费 ----
    // A6 可能因"BAR2 未映射/孔径未知"给 unknown；若把需求算在 A6 的成功分支里，
    // 这种会话下 PrepRequiredBytes 会变成 0/unknown，离线判据就丢了"需要多少字节"。
    // 只要宽高与 stride 有效，就先独立算出需求（1080p/32bpp = 8,294,400）。
    if (sizeW > 0 && sizeH > 0 && strideBytes > 0) {
        bufferNeed = strideBytes * (UInt64)sizeH;
    }

    // ---- A6：范围（三个空间分开，允许 SURF=0）----
    // 评审要点：BAR0 长度是寄存器窗口，GGTT 数组窗口（BAR0+0x800000）又是另一回事，
    // 而 PLANE_SURF 用的是 **GMA 地址**（在 GMADR 孔径内）。把三者混成一个上界是错的：
    //   实测 BAR0 = 16 MiB、GMADR = 256 MiB，1080p 32bpp 需要 8.29 MiB，
    //   若拿 BAR0-8MiB 当上界会得到"越界"的假失败。
    // 同时：不能证明"现有扫描面长度"时 A6 只能是 unknown —— 用窗口长度当 pass 是评审明确禁止的。
    UInt64 barLen = fBarMap ? (UInt64)fBarMap->getLength() : 0;
    UInt64 gttArrayLen = (barLen > kGttWindowOffset) ? (barLen - kGttWindowOffset) : 0;
    UInt64 apertureLen = fGmadrMap ? (UInt64)fGmadrMap->getLength() : 0;
    // SURF 的 bits[31:12] 才是地址，低 12 位是标志（R3）。混用会把标志算进偏移。
    UInt64 surfOffset = (surf.state == kPrepRegValid) ? (UInt64)(surf.value & kSurfAddrMask) : 0;
    UInt32 surfFlags = (surf.state == kPrepRegValid) ? (surf.value & ~kSurfAddrMask) : 0;
    bool surfInAperture = false;
    bool needFits = false;
    char a6[192];
    bzero(a6, sizeof(a6));
    if (surf.state != kPrepRegValid) {
        prepCat(a6, sizeof(a6), surf.state == kPrepRegInvalid ? "fail:surf-invalid" : "fail:surf-unavailable");
    } else if (apertureLen == 0) {
        prepCat(a6, sizeof(a6), "unknown:gmadr-aperture-unknown");
    } else if (surfOffset >= apertureLen) {
        prepCat(a6, sizeof(a6), "fail:surf-outside-gmadr-aperture");
    } else if (bufferNeed == 0) {
        prepCat(a6, sizeof(a6), "unknown:buffer-need-unknown");
    } else {
        surfInAperture = true;
        // 用 limit - offset 判，避免 offset + need 溢出
        needFits = (bufferNeed <= (apertureLen - surfOffset));
        if (!needFits) {
            prepCat(a6, sizeof(a6), "fail:buffer-crosses-aperture-end");
        } else if (surfFlags != 0) {
            // 低 12 位标志在本阶段没有"支持"的定义：不解释也不当 pass。
            prepCat(a6, sizeof(a6), "unknown:surf-flags-present");
        } else {
            // 孔径内只证明"不越孔径"；现有扫描面的真实长度没有取证 ⇒ 诚实记 unknown。
            prepCat(a6, sizeof(a6), "unknown:surface-length-unproven");
        }
    }

    // ---- A7：只发布需求，不分配 buffer ----
    char a7[96];
    bzero(a7, sizeof(a7));
    if (bufferNeed > 0) {
        prepCat(a7, sizeof(a7), "recorded");
    } else {
        prepCat(a7, sizeof(a7), "unknown:buffer-need-unknown");
    }

    // ---- readiness / R1 / R2 ----
    char rDetail[160];
    bzero(rDetail, sizeof(rDetail));
    PrepEnum enumRes;
    bzero(&enumRes, sizeof(enumRes));
    bool rOk = scanIONDRV(&pub, &enumRes, rDetail, sizeof(rDetail));
    bool enumComplete = enumRes.complete;
    UInt32 iondrvCount = enumRes.count;

    // ---- verdict：必须由完整断言结果驱动（任一 fail/unknown ⇒ 不得 ready）----
    char verdictDetail[256];
    bzero(verdictDetail, sizeof(verdictDetail));
    bool allPass = (strcmp(a1, "pass") == 0) && (strcmp(a2, "pass") == 0)
                   && (strcmp(a3, "pass") == 0) && (strcmp(a4, "pass") == 0)
                   && (strcmp(a5, "pass") == 0) && (strcmp(a6, "pass") == 0);
    if (allPass && rOk && enumComplete && pub.invalid == 0 && pub.unavailable == 0) {
        prepCat(verdictDetail, sizeof(verdictDetail), "ready");
    } else {
        prepCat(verdictDetail, sizeof(verdictDetail), "not-ready");
        if (!allPass) {
            prepCat(verdictDetail, sizeof(verdictDetail), ":assert");
        }
        if (!rOk) {
            prepCat(verdictDetail, sizeof(verdictDetail), ":readiness");
        }
        if (!enumComplete) {
            prepCat(verdictDetail, sizeof(verdictDetail), ":enum-incomplete");
        }
        if (pub.invalid > 0) {
            prepCat(verdictDetail, sizeof(verdictDetail), ":invalid-readings");
        }
        if (pub.unavailable > 0) {
            prepCat(verdictDetail, sizeof(verdictDetail), ":unavailable-readings");
        }
    }

    // ---- 组装发布 ----
    OSDictionary *route = OSDictionary::withCapacity(16);
    OSDictionary *asserts = OSDictionary::withCapacity(8);
    OSDictionary *display = OSDictionary::withCapacity(16);
    OSDictionary *gtt = OSDictionary::withCapacity(12);
    OSDictionary *readiness = OSDictionary::withCapacity(12);
    OSDictionary *regs = OSDictionary::withCapacity(20);
    OSDictionary *regState = OSDictionary::withCapacity(20);
    OSDictionary *conn = OSDictionary::withCapacity(6);

    if (route && asserts && display && gtt && readiness && regs && regState && conn) {
        // PrepRoute：A/B 两路原始值 + 字段解码 + 计数
        for (int i = 0; i < 2; i++) {
            const char *suffix = (i == 0) ? "A" : "B";
            char key[64];
            key[0] = 0;
            prepCat(key, sizeof(key), "TransDDIFuncCtl_");
            prepCat(key, sizeof(key), suffix);
            prepSetHexP(&pub, route, key, tddi[i].value);
            key[0] = 0;
            prepCat(key, sizeof(key), "TransDDIFuncCtlState_");
            prepCat(key, sizeof(key), suffix);
            prepSetStrP(&pub, route, key, prepStateName(tddi[i].state));
            key[0] = 0;
            prepCat(key, sizeof(key), "TransClkSel_");
            prepCat(key, sizeof(key), suffix);
            prepSetHexP(&pub, route, key, tclk[i].value);
            key[0] = 0;
            prepCat(key, sizeof(key), "PortField_");
            prepCat(key, sizeof(key), suffix);
            prepSetNumP(&pub, route, key, (tddi[i].value >> kTransPortShift) & kTransPortMask, 32);
            key[0] = 0;
            prepCat(key, sizeof(key), "ModeField_");
            prepCat(key, sizeof(key), suffix);
            prepSetNumP(&pub, route, key, (tddi[i].value >> kTransModeShift) & kTransModeMask, 32);
            key[0] = 0;
            prepCat(key, sizeof(key), "ClkSelField_");
            prepCat(key, sizeof(key), suffix);
            prepSetNumP(&pub, route, key, (tclk[i].value >> kTransClkSelShift) & kTransClkSelMask, 32);
        }
        prepSetNumP(&pub, route, "EnableCount", enableCount, 32);
        prepSetNumP(&pub, route, "TargetPortCount", targetCount, 32);
        prepSetNumP(&pub, route, "TC3PortField", kTransPortTC3, 32);
        prepSetStrP(&pub, route, "ActivePipe", (active == 0) ? "A" : (active == 1) ? "B" : "none");
        prepSetStrP(&pub, route, "Failure", routeFail[0] ? routeFail : "none");

        prepSetStrP(&pub, asserts, "A1", a1);
        prepSetStrP(&pub, asserts, "A2", a2);
        prepSetStrP(&pub, asserts, "A3", a3);
        prepSetStrP(&pub, asserts, "A4", a4);
        prepSetStrP(&pub, asserts, "A5", a5);
        prepSetStrP(&pub, asserts, "A6", a6);
        prepSetStrP(&pub, asserts, "A7", a7);

        // PrepDisplay：原始值用 hex 字符串，另附解码
        prepSetHexP(&pub, display, "PIPESRC_Raw", src.value);
        prepSetHexP(&pub, display, "PLANE_SIZE_Raw", size.value);
        prepSetHexP(&pub, display, "PLANE_STRIDE_Raw", stride.value);
        prepSetHexP(&pub, display, "PLANE_SURF_Raw", surf.value);
        prepSetHexP(&pub, display, "PlaneCtlRaw", ctl.value);
        prepSetNumP(&pub, display, "Width", sizeW, 32);
        prepSetNumP(&pub, display, "Height", sizeH, 32);
        prepSetNumP(&pub, display, "SrcWidth", srcW, 32);
        prepSetNumP(&pub, display, "SrcHeight", srcH, 32);
        prepSetNumP(&pub, display, "StrideUnits", (UInt32)(stride.value & kStrideUnitsMask), 32);
        prepSetNumP(&pub, display, "StrideBytes", strideBytes, 64);
        // 发布的是字段值（5 位）本身：先掩再右移，不能写成 (v >> shift) & mask（那会恒为 0）。
        prepSetNumP(&pub, display, "PlaneFormat",
                    (ctl.value & kPlaneFormatMask) >> kPlaneFormatShift, 32);
        prepSetBoolP(&pub, display, "MatchesEdid1080p", sizeW == kExpectedWidth && sizeH == kExpectedHeight);
        prepSetStrP(&pub, display, "PixelFormatContract", "XRGB8888 / 32bpp / linear / no compression");

        // PrepGTT：BAR0 长度、GGTT 窗口（单独字段＋来源）、GMADR、SURF 与需求
        prepSetNumP(&pub, gtt, "Bar0Length", barLen, 64);
        prepSetNumP(&pub, gtt, "GttArrayOffset", kGttWindowOffset, 64);
        prepSetNumP(&pub, gtt, "GttArrayLength", gttArrayLen, 64);
        prepSetStrP(&pub, gtt, "GttArraySource",
                    gttArrayLen ? "BAR0 length - 0x800000 (gen9+ MMIO layout)" : "unknown");
        prepSetNumP(&pub, gtt, "GmadrApertureLength", apertureLen, 64);
        prepSetStrP(&pub, gtt, "GmadrSource", apertureLen ? "BAR2 map length" : "unknown");
        prepSetHexP(&pub, gtt, "SurfRaw", surf.value);
        prepSetNumP(&pub, gtt, "SurfOffset", surfOffset, 64);
        prepSetHexP(&pub, gtt, "SurfFlags", surfFlags);
        prepSetNumP(&pub, gtt, "BufferNeed", bufferNeed, 64);
        prepSetBoolP(&pub, gtt, "SurfInAperture", surfInAperture);
        prepSetBoolP(&pub, gtt, "NeedFitsAperture", needFits);
        prepSetStrP(&pub, gtt, "SurfaceLengthProven", "no");

        // PrepReadiness：R1 计数 + R2 证据 + R3 opened=unknown + verdict
        prepSetNumP(&pub, readiness, "IONDRVCount", iondrvCount, 32);
        prepSetBoolP(&pub, readiness, "EnumComplete", enumComplete);
        prepSetStrP(&pub, readiness, "R2Detail", rDetail[0] ? rDetail : "ok");
        prepSetBoolP(&pub, readiness, "HolderAlive", enumRes.candidateHeld);
        prepSetStrP(&pub, readiness, "opened", "unknown");
        prepSetStrP(&pub, readiness, "verdict", verdictDetail);

        // PrepRegs / PrepRegState：所有读数（含 unavailable），便于离线复核
        struct { const char *label; const PrepRegRead *r; } allRegs[] = {
            { "TRANS_DDI_FUNC_CTL_A", &tddi[0] }, { "TRANS_DDI_FUNC_CTL_B", &tddi[1] },
            { "TRANS_CLK_SEL_A", &tclk[0] }, { "TRANS_CLK_SEL_B", &tclk[1] },
            { "PLANE_CTL_1_A", &pctl[0] }, { "PLANE_CTL_1_B", &pctl[1] },
            { "PIPESRC_A", &psrc[0] }, { "PIPESRC_B", &psrc[1] },
            { "PLANE_SIZE_1_A", &psize[0] }, { "PLANE_SIZE_1_B", &psize[1] },
            { "PLANE_STRIDE_1_A", &pstride[0] }, { "PLANE_STRIDE_1_B", &pstride[1] },
            { "PLANE_SURF_1_A", &psurf[0] }, { "PLANE_SURF_1_B", &psurf[1] },
            { "DDI_BUF_CTL_TC3", &ddiBuf },
        };
        for (UInt32 i = 0; i < sizeof(allRegs) / sizeof(allRegs[0]); i++) {
            if (allRegs[i].r->state == kPrepRegValid) {
                prepSetHexP(&pub, regs, allRegs[i].label, allRegs[i].r->value);
            } else {
                prepSetStrP(&pub, regs, allRegs[i].label, "n/a");
            }
            prepSetStrP(&pub, regState, allRegs[i].label, prepStateName(allRegs[i].r->state));
        }

        publishConnFlags(&pub, conn, fPrepCandidate);

        // 发布（顶层失败也要计数）
        prepTopStr(&pub, "PrepMode", "prep: read-only evidence");
        prepTop(&pub, "PrepRoute", route);
        prepTop(&pub, "PrepAssert", asserts);
        prepTop(&pub, "PrepDisplay", display);
        prepTop(&pub, "PrepGTT", gtt);
        prepTop(&pub, "PrepReadiness", readiness);
        prepTop(&pub, "PrepRegs", regs);
        prepTop(&pub, "PrepRegState", regState);
        prepTop(&pub, "PrepConnFlags", conn);

        route->release();
        asserts->release();
        display->release();
        gtt->release();
        readiness->release();
        regs->release();
        regState->release();
        conn->release();
    } else {
        pub.failures++;
        if (route) { route->release(); }
        if (asserts) { asserts->release(); }
        if (display) { display->release(); }
        if (gtt) { gtt->release(); }
        if (readiness) { readiness->release(); }
        if (regs) { regs->release(); }
        if (regState) { regState->release(); }
        if (conn) { conn->release(); }
    }

    // 顶层标量：身份、计数、完整性门。全部走带返回值的 helper（R2）：
    // 旧代码用 setProperty 且丢弃返回值 ⇒ 键没写成也当成功，errors 永远是 none。
    prepTopBool(&pub, "PhysicalIdentityVerified", fIdentityVerified);
    prepTopStr(&pub, "GPUAccess", "none: MMIO reads only");
    prepTopNum(&pub, "VendorID", (unsigned long long)fVendorID, 16);
    prepTopNum(&pub, "DeviceID", (unsigned long long)fDeviceID, 16);
    prepTopNum(&pub, "RevisionID", (unsigned long long)fRevision, 8);
    prepTopNum(&pub, "PrepReadCount", (unsigned long long)pub.reads, 32);
    prepTopNum(&pub, "PrepInvalidCount", (unsigned long long)pub.invalid, 32);
    prepTopNum(&pub, "PrepUnavailableCount", (unsigned long long)pub.unavailable, 32);
    prepTopNum(&pub, "PrepPublishFailures", (unsigned long long)pub.failures, 32);
    prepTopNum(&pub, "PrepRequiredBytes", bufferNeed, 64);

    // 必需键/类型回读校验：发布成功 ≠ 键真的在（平台钩子可能在 setProperty 里否决）。
    // 缺一即记 error 并阻止 EvidenceComplete——这就是"顶层标量也算进完整性门"的落点。
    bool requiredOk = true;
    const char *reqNums[] = { "VendorID", "DeviceID", "RevisionID",
                              "PrepReadCount", "PrepInvalidCount", "PrepUnavailableCount",
                              "PrepPublishFailures", "PrepRequiredBytes" };
    for (UInt32 i = 0; i < sizeof(reqNums) / sizeof(reqNums[0]); i++) {
        OSObject *o = copyProperty(reqNums[i]);
        if (!o || !OSDynamicCast(OSNumber, o)) {
            requiredOk = false;
            prepNoteErr(&pub, reqNums[i]);
        }
        if (o) { o->release(); }
    }
    const char *reqDicts[] = { "PrepRoute", "PrepAssert", "PrepDisplay", "PrepGTT",
                               "PrepReadiness", "PrepRegs", "PrepRegState", "PrepConnFlags" };
    for (UInt32 i = 0; i < sizeof(reqDicts) / sizeof(reqDicts[0]); i++) {
        OSObject *o = copyProperty(reqDicts[i]);
        if (!o || !OSDynamicCast(OSDictionary, o)) {
            requiredOk = false;
            prepNoteErr(&pub, reqDicts[i]);
        }
        if (o) { o->release(); }
    }
    {
        OSObject *o = copyProperty("PhysicalIdentityVerified");
        if (!o || !OSDynamicCast(OSBoolean, o)) {
            requiredOk = false;
            prepNoteErr(&pub, "PhysicalIdentityVerified");
        }
        if (o) { o->release(); }
        o = copyProperty("PrepMode");
        if (!o || !OSDynamicCast(OSString, o)) {
            requiredOk = false;
            prepNoteErr(&pub, "PrepMode");
        }
        if (o) { o->release(); }
    }

    // EvidenceComplete：只有"必需证据齐全 + 无发布失败 + 无无效/缺失读数 + 枚举完整
    // + 必需键回读通过"才为真。A6 在 prep 阶段必然 unknown，只影响 verdict，不影响证据齐全。
    bool evidenceComplete = fIdentityVerified && (pub.failures == 0) && (pub.invalid == 0)
                            && (pub.unavailable == 0) && enumRes.complete
                            && enumRes.candidateHeld && (bufferNeed > 0) && requiredOk;
    // 顺序要求（R2）：先发 EvidenceErrors，再发 EvidenceComplete。
    // 若反过来，EvidenceComplete 失败时消费者看不到原因（errors 还没写）。
    if (!prepTopStr(&pub, "EvidenceErrors", pub.errors[0] ? pub.errors : "none")) {
        IGPU_LOG("prep: failed to publish EvidenceErrors: %s", pub.errors[0] ? pub.errors : "none");
        // 发布失败本身也必须让证据判为不完整：否则消费者既看不到 errors、
        // 又可能拿到 EvidenceComplete=true（review 第四轮唯一必修项）。
        evidenceComplete = false;
    }
    // 最终状态发布失败必须能被看到：此时没有别的键可用，只能打日志。
    if (!prepTopBool(&pub, "EvidenceComplete", evidenceComplete)) {
        IGPU_LOG("prep: failed to publish EvidenceComplete (value=%d)", (int)evidenceComplete);
    }

    IGPU_LOG("prep: pipe=%s enables=%u targets=%u surf=0x%08X stride=%llu need=%llu verdict=%s evidence=%d",
             (active == 0) ? "A" : (active == 1) ? "B" : "none",
             (unsigned)enableCount, (unsigned)targetCount, (unsigned)surf.value,
             strideBytes, bufferNeed, verdictDetail, (int)evidenceComplete);
}

void IGPUProbe::stop(IOService *provider)
{
    releasePrepCandidate();
    closeBar();
    super::stop(provider);
}

void IGPUProbe::free()
{
    releasePrepCandidate();
    closeBar();
    super::free();
}

void IGPUProbe::closeBar()
{
    if (fBarMap) {
        fBarMap->release();
        fBarMap = 0;
    }
    if (fGmadrMap) {
        fGmadrMap->release();
        fGmadrMap = 0;
    }
}

// ---------------------------------------------------------------------------
// kmod_info：OpenCore 注入的硬前提（2026-10-20 上机实测）
//
// OC 的 KextFindKmodAddress() 在符号表里找 `_kmod_info`；找不到时把它置 0，
// 后续链接失败，日志只留一行且无任何附加线索：
//     OC: Prelinked injection IGPUProbe.kext (...) - Invalid Parameter
//
// 注意：libkmod.a 里的 `_kmod_info` 是**未定义引用**（c_start.o 引它），
// 光加 `-l kmod` 不会产生定义；定义必须来自源码，就是下面的 KMOD_EXPLICIT_DECL。
// 这也是 Lilu 的作法（Lilu/Sources/kern_start.cpp + MODULE_* 构建设置）。
//
// start/stop 对 IOKit personality 驱动的 kext 不会被调用（加载由 IOService 匹配完成），
// 这里只返回 KERN_SUCCESS；**绝不做任何寄存器/MMIO 操作**。
// ---------------------------------------------------------------------------
extern "C" kern_return_t IGPUProbe_kern_start(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    return KERN_SUCCESS;
}

extern "C" kern_return_t IGPUProbe_kern_stop(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    return KERN_SUCCESS;
}

extern "C" {
KMOD_EXPLICIT_DECL(dev.igpu.probe, "0.1.0", IGPUProbe_kern_start, IGPUProbe_kern_stop)
}
