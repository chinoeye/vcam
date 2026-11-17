//
//  VCSubstrateCompat.m
//
//  内含两部分：
//    1) MSHookMessageEx  —— 用 objc runtime 原生 API 实现
//    2) fishhook 精简实现 —— 按符号名重绑定 C 函数
//
//  fishhook 思路来自 facebook/fishhook (BSD)，做了大幅裁剪：
//    - 只处理 __DATA 段的 lazy/non-lazy symbol pointers
//    - 不碰 __DATA_CONST / __AUTH_CONST —— iOS 15+ 这两处带指针认证(PAC)，
//      直接改写会让内核在下次校验时踢掉进程，得不偿失。
//    - 只保留 rebind 主路径，去掉 image 过滤等用不到的入口
//

#import "VCSubstrateCompat.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
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

    // 只处理 __DATA。__DATA_CONST / __AUTH_CONST 带 PAC，改了会触发内核保护。
    vc_segment_command *dataSeg = vc_find_segment(header, SEG_DATA);
    if (!dataSeg) return;

    const vc_section *sec = (const vc_section *)(dataSeg + 1);
    for (uint32_t k = 0; k < dataSeg->nsects; k++) {
        const vc_section *cs = &sec[k];

        BOOL isLazy = (strncmp(cs->sectname, SECT_LAZY_SYMBOL_POINTERS, 16) == 0);
        BOOL isNL   = (strncmp(cs->sectname, SECT_NON_LAZY_SYMBOL_POINTERS, 16) == 0);
        if (!isLazy && !isNL) continue;

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
