//
//  VCSubstrateCompat.m
//
//  内含两部分：
//    1) MSHookMessageEx  —— 用 objc runtime 原生 API 实现
//    2) fishhook 精简实现 —— 按符号名重绑定 C 函数
//
//  fishhook 思路来自 facebook/fishhook (BSD)，做了大幅裁剪：
//    - 处理 __DATA 和 __DATA_CONST 两段的 lazy/non-lazy symbol pointers
//    - 不碰 __AUTH_CONST（那一段的指针确实带认证，且没有我们需要 hook 的符号）
//    - 只保留 rebind 主路径，去掉 image 过滤等用不到的入口
//
//  关于 __DATA_CONST：
//    早先这里只扫 __DATA，注释说 __DATA_CONST 带 PAC 不能改。这个判断是错的 ——
//    iOS 13 之后 __la_symbol_ptr / __got 大多搬到了 __DATA_CONST，
//    byteaudio.framework 这类第三方库的符号指针全在那儿。
//    只扫 __DATA 的结果是：主二进制里残留的少量指针能 hook 上（视频那条链），
//    而 framework 里的全部碰不到（音频走 byteaudio，怎么都拦不住）。
//
//    A11 是 arm64，指针不带 PAC，改完不需要重签名；
//    __DATA_CONST 原本只读，靠 vc_rebind_one 里的 VM_PROT_COPY 做写时复制。
//

#import "VCSubstrateCompat.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#if defined(__LP64__)
typedef struct nlist_64 vc_nlist;
typedef struct mach_header_64 vc_mach_header;
typedef struct segment_command_64 vc_segment_command;
typedef struct section_64 vc_section;
#else
typedef struct nlist vc_nlist;
typedef struct mach_header vc_mach_header;
typedef struct segment_command vc_segment_command;
typedef struct section vc_section;
#endif

#define VC_MAX_REBIND 32

// iOS SDK 的 <mach-o/loader.h> 没有导出 SEG_* / SECT_* 这批宏
// （它们在 macOS SDK 里才有），所以自己定义，避免 use of undeclared identifier。
#ifndef SEG_LINKEDIT
#define SEG_LINKEDIT "__LINKEDIT"
#endif
#ifndef SEG_DATA
#define SEG_DATA "__DATA"
#endif
#ifndef SECT_LAZY_SYMBOL_POINTERS
#define SECT_LAZY_SYMBOL_POINTERS "__la_symbol_ptr"
#endif
#ifndef SECT_NON_LAZY_SYMBOL_POINTERS
#define SECT_NON_LAZY_SYMBOL_POINTERS "__nl_symbol_ptr"
#endif

// 现代 Mach-O 里非懒加载符号指针的 section 实际叫 __got。
// __nl_symbol_ptr 是十几年前的旧名，现在的链接器根本不产这个段 ——
// 之前只认旧名，导致所有 __got 里的导入符号（AudioUnitRender 就在其中）
// 全部漏掉，VCHookSymbol 从来没成功绑上过任何东西。
#ifndef SECT_GOT_POINTERS
#define SECT_GOT_POINTERS "__got"
#endif

// 诊断：记录 scan 过的 section，报告里能直接看到漏了谁
char g_vcScannedSections[4096] = {0};

// 判断一个 section 是不是符号指针表。
//
// 原来是硬匹配 __la_symbol_ptr / __nl_symbol_ptr 两个名字，
// 结果 AudioUnitRender 既不在 __la 也不在 __got（这台机器的
// byteaudio 把它放在别的 section 里），导致怎么都绑不上。
// 现在放宽到名字里带 got / symbol_ptr 的一律处理。
static BOOL vc_isPointerSection(const char *sectname)
{
    if (!sectname || !*sectname) return NO;
    if (strncmp(sectname, SECT_LAZY_SYMBOL_POINTERS, 16) == 0) return YES;
    if (strncmp(sectname, SECT_NON_LAZY_SYMBOL_POINTERS, 16) == 0) return YES;
    if (strncmp(sectname, SECT_GOT_POINTERS, 16) == 0) return YES;
    if (strstr(sectname, "got")) return YES;
    if (strstr(sectname, "symbol_ptr")) return YES;
    return NO;
}
#ifndef INDIRECT_SYMBOL_LOCAL
#define INDIRECT_SYMBOL_LOCAL 0x80000000
#endif
#ifndef INDIRECT_SYMBOL_ABS
#define INDIRECT_SYMBOL_ABS 0x40000000
#endif

// ==================================================================
#pragma mark - MSHookMessageEx
// ==================================================================

void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp)
{
    if (!cls || !sel || !newImp) return;

    Method m = class_getInstanceMethod(cls, sel);

    if (!m) {
        // 方法不存在时把新实现注册成实例方法。
        // 部分系统类是 class method, 这里两种都尝试。
        if (!class_addMethod(cls, sel, newImp, "@@:")) {
            Method cm = class_getClassMethod(cls, sel);
            if (cm) {
                IMP prev = method_setImplementation(cm, newImp);
                if (oldImp) *oldImp = prev;
                return;
            }
            if (oldImp) *oldImp = NULL;
            return;
        }
        if (oldImp) *oldImp = NULL;
        return;
    }

    IMP prev = method_setImplementation(m, newImp);
    if (oldImp) *oldImp = prev;
}

// ==================================================================
#pragma mark - fishhook 核心
// ==================================================================

typedef struct {
    const char *name;
    void       *replacement;
    void      **replaced;
} vc_rebinding_t;

typedef struct vc_entry {
    vc_rebinding_t  rb[VC_MAX_REBIND];
    size_t          nel;
    struct vc_entry *next;
} vc_entry_t;

static vc_entry_t *g_entries = NULL;

static vc_segment_command *vc_find_segment(const vc_mach_header *mh, const char *segname)
{
    const struct load_command *cmd = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64 || cmd->cmd == LC_SEGMENT) {
            vc_segment_command *seg = (vc_segment_command *)cmd;
            if (strncmp(seg->segname, segname, 16) == 0) return seg;
        }
        cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
    }
    return NULL;
}

static void vc_rebind_one(vc_entry_t *e, const char *name, void **indirect)
{
    if (!indirect) return;
    for (size_t i = 0; i < e->nel; i++) {
        if (!e->rb[i].name) continue;
        if (strcmp(name, e->rb[i].name) != 0) continue;

        if (e->rb[i].replaced) *e->rb[i].replaced = *indirect;
        if (!e->rb[i].replacement) continue;

        kern_return_t kr = vm_protect(mach_task_self(),
                                      (vm_address_t)indirect,
                                      sizeof(void *),
                                      false,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) continue;

        *indirect = e->rb[i].replacement;
    }
}

static void vc_rebind_image(vc_entry_t *e, const vc_mach_header *header, intptr_t slide)
{
    if (!header) return;
    if (header->filetype != MH_EXECUTE && header->filetype != MH_DYLIB) return;

    vc_segment_command *linkedit = vc_find_segment(header, SEG_LINKEDIT);
    if (!linkedit) return;

    intptr_t base = (intptr_t)(linkedit->vmaddr - linkedit->fileoff) + slide;

    const struct symtab_command  *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const struct load_command *cmd = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SYMTAB)        symtab   = (const struct symtab_command *)cmd;
        else if (cmd->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)cmd;
        cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
    }
    if (!symtab || !dysymtab || !symtab->nsyms) return;

    const vc_nlist *syms = (const vc_nlist *)(base + symtab->symoff);
    const char     *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    // 处理 __DATA 和 __DATA_CONST 两段。
    //
    // 之前只处理 __DATA，导致对第三方 framework 的 hook 全部失效：
    // iOS 13 之后 __la_symbol_ptr / __got 大多搬到了 __DATA_CONST，
    // byteaudio.framework、EffectSDKFramework 这类库的符号指针都在那儿。
    // 主二进制 __DATA 里还残留一部分，所以视频那条链能 hook 上、
    // 音频（走 byteaudio）却怎么都碰不到 —— 现在补上。
    //
    // __DATA_CONST 原本是只读的，vc_rebind_one 里的 VM_PROT_COPY 会做
    // 写时复制，把这一页改成私有可写，不影响其它进程。
    // 这台机器是 A11（arm64，非 arm64e），指针不带 PAC，改完不需要重签名。
    static const char *kPointerSegs[] = { SEG_DATA, "__DATA_CONST" };

    for (size_t ds = 0; ds < sizeof(kPointerSegs) / sizeof(kPointerSegs[0]); ds++) {
        vc_segment_command *dataSeg = vc_find_segment(header, kPointerSegs[ds]);
        if (!dataSeg) continue;

        const vc_section *sec = (const vc_section *)(dataSeg + 1);
        for (uint32_t k = 0; k < dataSeg->nsects; k++) {
            const vc_section *cs = &sec[k];

            // 诊断：把每个 section 都记下来，报告里能看出扫了什么
            size_t used = strlen(g_vcScannedSections);
            if (used < sizeof(g_vcScannedSections) - 80) {
                snprintf(g_vcScannedSections + used,
                         sizeof(g_vcScannedSections) - used,
                         "%s/%s(%u)%s ",
                         kPointerSegs[ds], cs->sectname,
                         (unsigned)cs->size,
                         vc_isPointerSection(cs->sectname) ? "*" : "");
            }

            if (!vc_isPointerSection(cs->sectname)) continue;

            uint32_t n = (uint32_t)(cs->size / sizeof(void *));
            for (uint32_t i = 0; i < n; i++) {
                uint32_t idx = cs->reserved1 + i;
                if (idx >= dysymtab->nindirectsyms) break;

                uint32_t symIndex = indirect[idx];
                if (symIndex == INDIRECT_SYMBOL_LOCAL ||
                    symIndex == INDIRECT_SYMBOL_ABS) continue;
                if (symIndex >= symtab->nsyms) continue;

                const vc_nlist *sym = &syms[symIndex];
                if (!sym->n_un.n_strx) continue;

                const char *name = strs + sym->n_un.n_strx;
                if (!name || !*name) continue;

                // 关键：段内地址 = section 虚拟地址 + slide + 表内偏移
                void **slot = (void **)(cs->addr + slide + i * sizeof(void *));
                vc_rebind_one(e, name, slot);
            }
        }
    }
}

static void vc_image_added_cb(const struct mach_header *mh, intptr_t slide)
{
    vc_entry_t *e = g_entries;
    while (e) {
        vc_rebind_image(e, (const vc_mach_header *)mh, slide);
        e = e->next;
    }
}

void VCHookSymbols(const VCSymbolHook *hooks)
{
    if (!hooks) return;

    size_t n = 0;
    while (hooks[n].name) n++;
    if (n == 0) return;
    if (n > VC_MAX_REBIND) n = VC_MAX_REBIND;

    vc_entry_t *e = calloc(1, sizeof(vc_entry_t));
    if (!e) return;

    for (size_t i = 0; i < n; i++) {
        e->rb[i].name        = hooks[i].name;
        e->rb[i].replacement = hooks[i].newFunc;
        e->rb[i].replaced    = hooks[i].oldFunc;
    }
    e->nel  = n;
    e->next = g_entries;
    g_entries = e;

    // 首次注册时挂上 dyld 回调，后续新加载的镜像也会被处理
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _dyld_register_func_for_add_image(vc_image_added_cb);
    });

    // 对当前已加载的镜像立即生效
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        vc_image_added_cb(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
}

BOOL VCHookSymbol(const char *symbolName, void *newFunc, void **oldFunc)
{
    if (!symbolName || !newFunc) return NO;
    VCSymbolHook hooks[2] = {
        { symbolName, newFunc, oldFunc },
        { NULL, NULL, NULL }
    };
    VCHookSymbols(hooks);
    return (oldFunc && *oldFunc) ? YES : NO;
}
