// Data-driven Unity IL2CPP runtime route & channel configuration.
// Reads host-specific offsets from `ABRuntimeProfile.plist` when bundled,
// falling back to verified 2.7.91 / build 76 defaults.
#import "ABBridge.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <stddef.h>

typedef struct ABManagedObject ABManagedObject;
typedef struct ABManagedMethodInfo ABManagedMethodInfo;
typedef struct {
    uintptr_t klass;
    uintptr_t monitor;
    int32_t length;
    unichar characters[];
} ABManagedStringLayout;

typedef struct {
    uintptr_t klass;
    uintptr_t monitor;
    uintptr_t fields[6];
} ABSDKMetaLayout;

_Static_assert(offsetof(ABManagedStringLayout, length) == 0x10, "IL2CPP string length");
_Static_assert(offsetof(ABManagedStringLayout, characters) == 0x14, "IL2CPP UTF-16 data");
_Static_assert(offsetof(ABSDKMetaLayout, fields) == 0x10, "SDKMeta string fields");

typedef uintptr_t (*ABNewStringFn)(const void *utf8, size_t length, const ABManagedMethodInfo *method);
typedef uintptr_t (*ABGetMetaFn)(ABManagedObject *sdk, const ABManagedMethodInfo *method);
typedef void (*ABSetMetaFn)(ABManagedObject *meta, uintptr_t json, const ABManagedMethodInfo *method);
typedef void (*ABClearStatusFn)(ABManagedObject *sdk, const ABManagedMethodInfo *method);
typedef uintptr_t (*ABGetSceneFn)(const ABManagedMethodInfo *method);

// Exact observed aggregate sizes: getter returns 104 bytes through ARM64 x8;
// override argument is 112 bytes, with the config starting at offset 8.
typedef struct { uintptr_t strings[12]; uint8_t dev; uint8_t padding[7]; } ABNetworkConfig;
typedef struct { uint8_t enabled; uint8_t padding[7]; ABNetworkConfig config; } ABNetworkOverride;
_Static_assert(sizeof(ABNetworkConfig) == 104, "getter ABI");
_Static_assert(sizeof(ABNetworkOverride) == 112, "override ABI");
_Static_assert(offsetof(ABNetworkConfig, dev) == 96, "network development flag");
_Static_assert(offsetof(ABNetworkOverride, config) == 8, "nested configuration");

typedef ABNetworkConfig (*ABGetConfigFn)(ABManagedObject *, const ABManagedMethodInfo *);
typedef void (*ABOverrideFn)(ABManagedObject *, ABNetworkOverride *, int32_t, const ABManagedMethodInfo *);

uintptr_t ABBase;
static NSString *routeStatus, *previousHost;
static bool routeApplied;
static ABRuntimeOffsetProfile runtimeProfile;
static NSString *expectedVersion = @"2.7.91";
static NSString *expectedBuild = @"76";

static BOOL ParseUUIDBytes(NSString *uuidString, uint8_t outBytes[16]) {
    if (![uuidString isKindOfClass:NSString.class]) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    if (!uuid) return NO;
    [uuid getUUIDBytes:outBytes];
    return YES;
}

static uint64_t ReadU64(NSDictionary *dict, NSString *key, uint64_t fallback) {
    id val = dict[key];
    if ([val isKindOfClass:NSNumber.class]) return [(NSNumber *)val unsignedLongLongValue];
    if ([val isKindOfClass:NSString.class]) {
        unsigned long long parsed = 0;
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)val];
        if ([(NSString *)val hasPrefix:@"0x"] || [(NSString *)val hasPrefix:@"0X"]) {
            if ([scanner scanHexLongLong:&parsed]) return (uint64_t)parsed;
        } else if ([scanner scanUnsignedLongLong:&parsed]) {
            return (uint64_t)parsed;
        }
    }
    return fallback;
}

static void EnsureProfileLoaded(void) {
    if (runtimeProfile.loaded) return;

    // Built-in verified defaults for Arknights 2.7.91 / build 76.
    static const uint8_t kDefaultUUID[16] = {
        0x38, 0x6e, 0x1e, 0x29, 0xf5, 0x38, 0x38, 0xc5,
        0x84, 0xd3, 0x40, 0x42, 0x7d, 0x3e, 0x6e, 0xb1
    };
    memcpy(runtimeProfile.unityUUID, kDefaultUUID, 16);
    runtimeProfile.hasUnityUUID = YES;
    runtimeProfile.unityTextSize = 0x99f7a28ULL;
    strlcpy(runtimeProfile.unityTextSHA256,
            "ef43071f7010d6c429f34bd4b9dd3e347941db43dfd3b47913e146fe98f67443",
            sizeof(runtimeProfile.unityTextSHA256));

    runtimeProfile.sdkInterfaceClassSlot = 0xb9a5e38ULL;
    runtimeProfile.sdkExternalToolsClassSlot = 0xb99d618ULL;
    runtimeProfile.sdkMetaClassSlot = 0xb99d6c0ULL;
    runtimeProfile.networkerTypeSlot = 0xba1cc48ULL;
    runtimeProfile.networkerExpectedClass = 0x6049b80ULL;
    runtimeProfile.gameFlowClassSlot = 0xb98f408ULL;

    runtimeProfile.getNetworkConfigFn = 0x77ad3acULL;
    runtimeProfile.overrideNetworkOptionsFn = 0x77ad968ULL;
    runtimeProfile.createStringFn = 0x7dcaf48ULL;
    runtimeProfile.internalSDKMetaFn = 0x6c5aff4ULL;
    runtimeProfile.sdkMetaCtorFn = 0x6c62a84ULL;
    runtimeProfile.clearAuthStatusFn = 0x6c5c478ULL;
    runtimeProfile.clearLoginStatusFn = 0x6c5c53cULL;
    runtimeProfile.getCurrentSceneFn = 0x18178d4ULL;

    NSString *plistPath = [NSBundle.mainBundle pathForResource:@"ABRuntimeProfile" ofType:@"plist"];
    NSDictionary *plist = plistPath ? [NSDictionary dictionaryWithContentsOfFile:plistPath] : nil;
    if ([plist isKindOfClass:NSDictionary.class]) {
        if ([plist[@"version"] isKindOfClass:NSString.class] && [plist[@"version"] length] > 0) {
            expectedVersion = [plist[@"version"] copy];
        }
        if (plist[@"build"]) {
            expectedBuild = [[plist[@"build"] description] copy];
        }
        uint8_t parsedUUID[16];
        if (ParseUUIDBytes(plist[@"unityUUID"], parsedUUID)) {
            memcpy(runtimeProfile.unityUUID, parsedUUID, 16);
            runtimeProfile.hasUnityUUID = YES;
        }
        // Never inherit 2.7.91 __text digest defaults when an explicit ABRuntimeProfile.plist is present.
        runtimeProfile.unityTextSize = ReadU64(plist, @"unityTextSize", 0);
        runtimeProfile.unityTextSHA256[0] = '\0';
        if ([plist[@"unityTextSHA256"] isKindOfClass:NSString.class]) {
            strlcpy(runtimeProfile.unityTextSHA256,
                    [(NSString *)plist[@"unityTextSHA256"] UTF8String],
                    sizeof(runtimeProfile.unityTextSHA256));
        }

        NSDictionary *offsets = [plist[@"il2cppOffsets"] isKindOfClass:NSDictionary.class] ? plist[@"il2cppOffsets"] : nil;
        if (offsets) {
            runtimeProfile.sdkInterfaceClassSlot = ReadU64(offsets, @"sdkInterfaceClassSlot", runtimeProfile.sdkInterfaceClassSlot);
            runtimeProfile.sdkExternalToolsClassSlot = ReadU64(offsets, @"sdkExternalToolsClassSlot", runtimeProfile.sdkExternalToolsClassSlot);
            runtimeProfile.sdkMetaClassSlot = ReadU64(offsets, @"sdkMetaClassSlot", runtimeProfile.sdkMetaClassSlot);
            runtimeProfile.networkerTypeSlot = ReadU64(offsets, @"networkerTypeSlot", runtimeProfile.networkerTypeSlot);
            // Optional secondary pointer check defaults to 0 (skip) instead of inheriting 2.7.91's address.
            runtimeProfile.networkerExpectedClass = ReadU64(offsets, @"networkerExpectedClass", 0);
            runtimeProfile.gameFlowClassSlot = ReadU64(offsets, @"gameFlowClassSlot", runtimeProfile.gameFlowClassSlot);

            runtimeProfile.getNetworkConfigFn = ReadU64(offsets, @"getNetworkConfigFn", runtimeProfile.getNetworkConfigFn);
            runtimeProfile.overrideNetworkOptionsFn = ReadU64(offsets, @"overrideNetworkOptionsFn", runtimeProfile.overrideNetworkOptionsFn);
            runtimeProfile.createStringFn = ReadU64(offsets, @"createStringFn", runtimeProfile.createStringFn);
            runtimeProfile.internalSDKMetaFn = ReadU64(offsets, @"internalSDKMetaFn", runtimeProfile.internalSDKMetaFn);
            runtimeProfile.sdkMetaCtorFn = ReadU64(offsets, @"sdkMetaCtorFn", runtimeProfile.sdkMetaCtorFn);
            runtimeProfile.clearAuthStatusFn = ReadU64(offsets, @"clearAuthStatusFn", runtimeProfile.clearAuthStatusFn);
            runtimeProfile.clearLoginStatusFn = ReadU64(offsets, @"clearLoginStatusFn", runtimeProfile.clearLoginStatusFn);
            runtimeProfile.getCurrentSceneFn = ReadU64(offsets, @"getCurrentSceneFn", runtimeProfile.getCurrentSceneFn);
        }
    }

    runtimeProfile.loaded = YES;
}

const ABRuntimeOffsetProfile *ABActiveRuntimeProfile(void) {
    EnsureProfileLoaded();
    return &runtimeProfile;
}

NSString *ABExpectedHostVersion(void) {
    EnsureProfileLoaded();
    return expectedVersion;
}

NSString *ABExpectedHostBuild(void) {
    EnsureProfileLoaded();
    return expectedBuild;
}

NSString *ABIL2CPPExportDiagnostic(void) {
    void *domainGet = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    void *classFromName = dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    void *stringNew = dlsym(RTLD_DEFAULT, "il2cpp_string_new_len");
    return [NSString stringWithFormat:@"il2cpp符号: domain=%@ class=%@ str=%@",
            domainGet ? @"有" : @"无",
            classFromName ? @"有" : @"无",
            stringNew ? @"有" : @"无"];
}

static BOOL Read(uintptr_t p, void *out, size_t size) {
    if (p < 0x100000000ULL || size > 8192 || p > UINTPTR_MAX - size) return NO;
    vm_size_t read = 0;
    return vm_read_overwrite(mach_task_self(), p, size, (vm_address_t)out, &read) == KERN_SUCCESS && read == size;
}
static uintptr_t Pointer(uintptr_t p) { uintptr_t v = 0; return Read(p, &v, 8) ? v : 0; }
static BOOL Initialized(uintptr_t p) { uint16_t v = 0; return p && Read(p + 0x136, &v, 2) && (v & 1); }

static NSString *ManagedString(uintptr_t p) {
    int32_t length = 0;
    unichar chars[2048];
    if (!p || !Read(p + offsetof(ABManagedStringLayout, length), &length, sizeof(length)) ||
        length < 0 || length > 2048) return nil;
    if (!length) return @"";
    if (!Read(p + offsetof(ABManagedStringLayout, characters), chars, (size_t)length * sizeof(*chars))) return nil;
    return [[NSString alloc] initWithCharacters:chars length:(NSUInteger)length];
}

static uintptr_t ExistingSDK(void) {
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    uintptr_t k = Pointer(ABBase + (uintptr_t)p->sdkInterfaceClassSlot);
    return Initialized(k) ? Pointer(Pointer(k + 0xb8)) : 0;
}

static uintptr_t ExistingNetworker(void) {
    if (!ABBase) return 0;
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    uintptr_t type = Pointer(ABBase + (uintptr_t)p->networkerTypeSlot);
    if (p->networkerExpectedClass != 0 && Pointer(type) != ABBase + (uintptr_t)p->networkerExpectedClass) return 0;
    uintptr_t k = Pointer(type + 0x20);
    if (!Initialized(k)) return 0;
    k = Pointer(Pointer(k + 0xc0));
    if (!Initialized(k)) return 0;
    uintptr_t obj = Pointer(Pointer(k + 0xb8));
    if (!Pointer(obj) || !Pointer(obj + 0x10) || !Pointer(obj + 0x48)) return 0;
    return obj;
}

BOOL ABConfigureRuntimeRoute(uintptr_t base) {
    if (!NSThread.isMainThread || !base) return NO;
    EnsureProfileLoaded();
    ABBase = base;
    routeStatus = @"等待游戏加载原版 iOS 配置";
    return YES;
}

BOOL ABManagedChannelReady(void) {
    if (!NSThread.isMainThread || !ABBase) return NO;
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    uintptr_t sdk = ExistingSDK();
    uintptr_t k = Pointer(ABBase + (uintptr_t)p->sdkExternalToolsClassSlot);
    if (!sdk || !Pointer(sdk + 0xc0) || !Initialized(k)) return NO;
    uintptr_t x = Pointer(Pointer(k + 0xb8) + 0x10);
    return x && Pointer(x);
}

static ABNetworkConfig GetConfig(uintptr_t object) {
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    return ((ABGetConfigFn)(ABBase + (uintptr_t)p->getNetworkConfigFn))((ABManagedObject *)object, NULL);
}

static void Override(uintptr_t object, ABNetworkOverride *value) {
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    ((ABOverrideFn)(ABBase + (uintptr_t)p->overrideNetworkOptionsFn))((ABManagedObject *)object, value, 3, NULL);
}

static uintptr_t NewString(const void *bytes, size_t length) {
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    return ((ABNewStringFn)(ABBase + (uintptr_t)p->createStringFn))(bytes, length, NULL);
}

static BOOL Fail(NSError **error, NSString *message) {
    routeStatus = message;
    if (error) *error = [NSError errorWithDomain:@"ABRuntimeRoute" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

BOOL ABApplyGameRoute(BOOL bili, NSError **error) {
    if (error) *error = nil;
    if (!NSThread.isMainThread || !ABBase) return Fail(error, @"路由未就绪：版本检查未完成");
    uintptr_t obj = ExistingNetworker();
    if (!obj) return Fail(error, @"路由未就绪：未找到已初始化的 Networker；请等原版配置加载完成");
    ABNetworkConfig before = GetConfig(obj);
    NSString *host = ManagedString(before.strings[0]);
    if (!ABKnownGameHost(host.UTF8String)) return Fail(error, @"已停止：当前游戏服不属于已验证的官服/B服地址");
    for (unsigned i = 0; i < 12; i++) if (before.strings[i] && !ManagedString(before.strings[i]))
        return Fail(error, @"已停止：网络配置字符串布局不兼容");
    for (unsigned i = 2; i <= 4; i++) if (![ManagedString(before.strings[i]) hasPrefix:@"https://"])
        return Fail(error, @"已停止：鉴权或资源配置尚未就绪");
    if (before.dev) return Fail(error, @"已停止：检测到开发服配置");
    NSString *target = bili ? @"https://ak-gs-b.hypergryph.com" : @"https://ak-gs-gf.hypergryph.com";
    previousHost = host;
    if ([host isEqualToString:target]) { routeApplied = true; routeStatus = @"游戏服地址已匹配所选渠道"; return YES; }
    ABNetworkOverride value = {.enabled = 1, .config = before};
    const char *targetBytes = target.UTF8String;
    value.config.strings[0] = NewString(targetBytes, strlen(targetBytes));
    if (![ManagedString(value.config.strings[0]) isEqualToString:target]) return Fail(error, @"已停止：托管目标地址创建失败");
    Override(obj, &value);
    ABNetworkConfig after = GetConfig(obj);
    BOOL ok = after.dev == before.dev;
    for (unsigned i = 1; i < 12; i++) ok &= after.strings[i] == before.strings[i];
    ok &= [ManagedString(after.strings[0]) isEqualToString:target];
    if (!ok) {
        ABNetworkOverride clear = {0};
        Override(obj, &clear);
        return Fail(error, @"已停止：配置回读不符；已请求移除本次路由覆盖，请重启");
    }
    routeApplied = true;
    routeStatus = @"渠道地址回读通过；其他地址未变";
    return YES;
}

BOOL ABApplyChannel(BOOL bili, BOOL clearAuth, NSError **error) {
    if (error) *error = nil;
    if (!NSThread.isMainThread || !ABBase) return Fail(error, @"请等待登录组件加载完成");
    if (!ABManagedChannelReady()) return Fail(error, @"游戏登录组件尚未就绪，请等到登录页后重试");
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    uintptr_t sdk = ExistingSDK();
    if (!sdk || !Pointer(sdk + 0xc0)) return Fail(error, @"请等待登录组件初始化完成");
    uintptr_t meta = ((ABGetMetaFn)(ABBase + (uintptr_t)p->internalSDKMetaFn))((ABManagedObject *)sdk, NULL);
    uintptr_t expectedClass = Pointer(ABBase + (uintptr_t)p->sdkMetaClassSlot);
    if (!expectedClass || !meta || Pointer(meta) != expectedClass) return Fail(error, @"渠道参数布局不匹配");

    NSArray *keys = @[@"appID", @"appKey", @"channel", @"worldId", @"extension", @"appCode"];
    NSMutableDictionary *previous = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *s = ManagedString(Pointer(meta + offsetof(ABSDKMetaLayout, fields) + i * sizeof(uintptr_t)));
        if (!s) return Fail(error, @"渠道参数未完整加载");
        previous[keys[i]] = s;
    }

    NSDictionary *profiles = [NSDictionary dictionaryWithContentsOfFile:
        [NSBundle.mainBundle pathForResource:@"ABChannelProfiles" ofType:@"plist"]];
    NSDictionary *selected = profiles[bili ? @"bilibili" : @"official"];
    if (![selected isKindOfClass:NSDictionary.class] || ![selected[@"AppKey"] isKindOfClass:NSString.class] ||
        [selected[@"Channel"] intValue] != (bili ? 2 : 1) || [selected[@"World"] intValue] != (bili ? 2 : 1)) {
        return Fail(error, @"所选渠道配置缺失");
    }

    NSMutableDictionary *data = [previous mutableCopy];
    data[@"appKey"] = selected[@"AppKey"];
    data[@"channel"] = [selected[@"Channel"] stringValue];
    data[@"worldId"] = [selected[@"World"] stringValue];
    NSData *json = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    if (!json || json.length > 0x2000) return Fail(error, @"渠道参数无法序列化");
    uintptr_t managed = NewString(json.bytes, json.length);
    if (!managed) return Fail(error, @"渠道参数创建失败");
    if (!ABApplyGameRoute(bili, error)) return NO;

    id<ABNativeU8> native = [(Class<ABNativeU8>)NSClassFromString(@"U8SDK") sharedInstance];
    NSDictionary *old = [native sdkParams];
    if (![old isKindOfClass:NSDictionary.class]) return Fail(error, @"原生渠道配置不可用");
    NSMutableDictionary *updated = [old mutableCopy];
    for (NSString *k in @[@"Channel", @"World", @"AppKey"]) updated[k] = selected[k];
    if (![updated isEqualToDictionary:old]) [native setSdkParams:updated];

    if (![data isEqualToDictionary:previous]) {
        ((ABSetMetaFn)(ABBase + (uintptr_t)p->sdkMetaCtorFn))((ABManagedObject *)meta, managed, NULL);
    }
    for (NSUInteger i = 0; i < keys.count; i++) {
        uintptr_t field = meta + offsetof(ABSDKMetaLayout, fields) + i * sizeof(uintptr_t);
        if (![ManagedString(Pointer(field)) isEqualToString:data[keys[i]]]) {
            return Fail(error, @"渠道参数回读失败，已停止登录");
        }
    }
    if (clearAuth) {
        ((ABClearStatusFn)(ABBase + (uintptr_t)p->clearAuthStatusFn))((ABManagedObject *)sdk, NULL);
        ((ABClearStatusFn)(ABBase + (uintptr_t)p->clearLoginStatusFn))((ABManagedObject *)sdk, NULL);
    }
    return YES;
}

BOOL ABApplyRuntimeRoute(NSError **error) {
    return ABApplyChannel(YES, NO, error);
}

NSString *ABRuntimeScene(void) {
    if (!NSThread.isMainThread || !ABBase) return @"";
    const ABRuntimeOffsetProfile *p = ABActiveRuntimeProfile();
    uintptr_t k = Pointer(ABBase + (uintptr_t)p->gameFlowClassSlot);
    int32_t state = 0;
    if (!Initialized(k) || !Read(k + 0xe0, &state, 4) || !state) return @"";
    uintptr_t s = ((ABGetSceneFn)(ABBase + (uintptr_t)p->getCurrentSceneFn))(NULL);
    NSString *scene = ManagedString(s);
    return scene.length <= 80 ? (scene.lowercaseString ?: @"") : @"";
}

NSString *ABRuntimeRouteStatus(void) {
    if (!NSThread.isMainThread) return @"请在主线程查看路由状态";
    NSString *current = @"尚未切换";
    if (routeApplied) {
        uintptr_t object = ExistingNetworker();
        NSString *host = object ? ManagedString(GetConfig(object).strings[0]) : nil;
        current = object ? (ABKnownGameHost(host.UTF8String) ? host : @"未知地址（未显示原值）") : @"运行时对象不可读";
    }
    return [NSString stringWithFormat:@"%@\n切换前：%@\n当前游戏服：%@",
            routeStatus ?: @"尚未准备路由", previousHost ?: @"尚未读取", current];
}
