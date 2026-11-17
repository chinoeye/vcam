//
//  VCSubstrateCompat.h
//  用系统自带能力替代 CydiaSubstrate，让 tweak 不再依赖越狱环境。
//
//  为什么需要这个：
//    越狱方案里 MSHookMessageEx / MSHookFunction 由 CydiaSubstrate 提供，
//    TrollStore 环境没有这个框架，dylib 加载会直接失败。
//    而 TrollFools 要求注入的库是「bare」的（不依赖第三方 dylib），
//    所以必须把 hook 能力内建进来。
//
//  怎么实现：
//    MSHookMessageEx  →  method_setImplementation（ObjC runtime 原生 API）
//    MSHookFunction   →  fishhook 重绑定符号表（facebook 开源，单文件）
//

#ifndef VCSubstrateCompat_h
#define VCSubstrateCompat_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------- ObjC 方法

/// 等价于 MSHookMessageEx。
/// Logos(%hook) 生成的代码调用的是这个名字，所以签名必须完全一致。
void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

// ---------------------------------------------------------------- C 函数

/// 等价于 MSHookFunction，但按符号名重绑定（fishhook 的要求）。
/// 返回 YES 表示重绑定成功。
BOOL VCHookSymbol(const char *symbolName, void *newFunc, void **oldFunc);

/// 诊断用：上一次 hook 过程中扫过的 section 列表（"段/节(大小)*" 拼接）。
/// 带 * 的是被认作符号指针表、真正参与重绑定的。
extern char g_vcScannedSections[4096];

/// 批量重绑定。数组格式：{ {name, new, &old}, ..., {NULL, NULL, NULL} }
typedef struct {
    const char *name;
    void       *newFunc;
    void      **oldFunc;
} VCSymbolHook;

void VCHookSymbols(const VCSymbolHook *hooks);

#ifdef __cplusplus
}
#endif

#endif /* VCSubstrateCompat_h */
