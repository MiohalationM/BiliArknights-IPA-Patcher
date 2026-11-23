// Host verification, dynamic Objective-C hook installation, SDK initialization and logout.
#import "ABBridge.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <CommonCrypto/CommonDigest.h>

ABLoginCoordinator *ABCurrent;
bool ABUseBili = true, ABInGame = false;
ABSceneGate ABScene;
void (*ABHGLogin)(id, SEL), (*ABHGLogout)(id, SEL);
void (*ABHGLoginParams)(id, SEL, id);
static void (*HGResult)(id, SEL, int, id), (*HGLoggedOut)(id, SEL, int);

static BOOL Signature(Method method, const char *ret, NSArray<NSString *> *types);

BOOL ABError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ABLoginHooks" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

// Verifies the UnityFramework image against the active ABRuntimeProfile (UUID and optional __TEXT.__text hash).
BOOL ABCheckUnityImage(uintptr_t base) {
    const ABRuntimeOffsetProfile *profile = ABActiveRuntimeProfile();
    const struct mach_header_64 *h = (void *)base;
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64) return NO;
    Dl_info image = {0};
    if (!dladdr((void *)base, &image) || !image.dli_fname) return NO;
    NSData *file = [NSData dataWithContentsOfFile:@(image.dli_fname) options:NSDataReadingMappedIfSafe error:nil];
    if (file.length < sizeof(*h)) return NO;
    const struct mach_header_64 *disk = file.bytes;
    if (disk->magic != MH_MAGIC_64 || disk->cputype != CPU_TYPE_ARM64 ||
        disk->sizeofcmds > file.length - sizeof(*disk)) return NO;

    const uint8_t *p = (const uint8_t *)file.bytes + sizeof(*disk), *end = p + disk->sizeofcmds;
    BOOL hasTextSize = (profile->unityTextSize > 0);
    BOOL hasTextHash = (profile->unityTextSHA256[0] != '\0');
    if (hasTextSize != hasTextHash) return NO;
    BOOL needTextHash = (hasTextSize && hasTextHash);
    BOOL uuidOK = !profile->hasUnityUUID;
    BOOL textOK = !needTextHash;
    BOOL foundText = NO;

    for (uint32_t i = 0; i < disk->ncmds; i++) {
        if ((size_t)(end - p) < sizeof(struct load_command)) return NO;
        const struct load_command *lc = (void *)p;
        if (lc->cmdsize < 8 || lc->cmdsize > (size_t)(end - p)) return NO;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command) && profile->hasUnityUUID) {
            uuidOK = (memcmp(((struct uuid_command *)p)->uuid, profile->unityUUID, 16) == 0);
        }
        if (needTextHash && lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (void *)p;
            if (seg->nsects > (lc->cmdsize - sizeof(*seg)) / sizeof(struct section_64)) return NO;
            const struct section_64 *s = (void *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (!strncmp(s[j].sectname, "__text", 16) && !strncmp(s[j].segname, "__TEXT", 16)) {
                    if (foundText || s[j].offset > file.length ||
                        s[j].size > file.length - s[j].offset || s[j].size != profile->unityTextSize) return NO;
                    foundText = YES;
                    unsigned char hash[32];
                    CC_SHA256((const uint8_t *)file.bytes + s[j].offset, (CC_LONG)s[j].size, hash);
                    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
                    for (int k = 0; k < 32; k++) [hex appendFormat:@"%02x", hash[k]];
                    textOK = [hex isEqualToString:@(profile->unityTextSHA256)];
                }
            }
        }
        p += lc->cmdsize;
    }
    return p == end && uuidOK && textOK;
}

@implementation ABLoginCoordinator
// Other recovered login methods live in ABLoginCallbacks.m.
- (void)didLogout {
    NSUInteger generation = self.callbackGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ABUseBili || generation != self.callbackGeneration) return;
        [self failGeneration:generation message:@"本次登录已退出"];
        ABAttemptInvalidate(&self->gate);
        self.callbackGeneration = self->gate.generation;
        self.state = @"ready";
        id<ABObservedU8> target = self.logoutReceiver ?: self.pluginReceiver;
        self.logoutReceiver = nil;
        if (ABUseBili) {
            ABInGame = false;
            [target eventUserLogout:@{}];
        }
    });
}

- (void)requestLogout:(id<ABObservedU8>)receiver {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestLogout:receiver]; });
        return;
    }
    [self failGeneration:self->gate.generation message:@"登录已取消"];
    ABAttemptInvalidate(&self->gate);
    self.callbackGeneration = self->gate.generation;
    self.receiver = nil;
    self.logoutReceiver = receiver;
    self.state = @"logging-out";
    @try {
        if (ABUseBili) [(id<ABObservedGSSDK>)self.sdk logout];
        else ABHGLogout(receiver, NSSelectorFromString(@"logout"));
    } @catch (id exception) {
        self.state = @"ready";
        self.logoutReceiver = nil;
    }
}

- (void)didGameExit { [self didLogout]; }
- (void)didCloseAgreement {}
- (void)didGeetestResult:(id)result { (void)result; }
- (void)shareWithPlatform:(NSInteger)platform { (void)platform; }
- (void)didGetUserInfoSuccess:(id)result { (void)result; }
- (void)didGetUserInfoFailed:(id)result { (void)result; }
- (void)didPaySuccessWithPayment:(id)result { (void)result; }
- (void)didPayFailedWithPayment:(id)payment error:(id)error { (void)payment; (void)error; }
@end

BOOL ABPrepareBLogin(NSDictionary *config, NSError **error) {
    if (error) *error = nil;
    if (!NSThread.isMainThread) return ABError(error, @"请在主线程初始化");
    if (ABCurrent) return YES;
    if (!NSClassFromString(@"U8SDK_HGN")) return ABError(error, @"请等待兼容的游戏组件加载");
    for (NSString *k in @[@"gameId", @"merchantId", @"serverId", @"appKey", @"sandboxKey"]) {
        if (![config[k] isKindOfClass:NSString.class] || (![k isEqual:@"sandboxKey"] && ![config[k] length])) {
            return ABError(error, @"B服配置缺失");
        }
    }
    Class<ABObservedGSSDK> sdkClass = NSClassFromString(@"GSSDK");
    if (!sdkClass ||
        !Signature(class_getClassMethod(sdkClass, @selector(sharedGSInterface)), "@", @[@"@", @":"]) ||
        !Signature(class_getInstanceMethod(sdkClass, @selector(initWithGameId:merchantId:serverId:appKey:sandboxKey:delegate:)),
                   "B", @[@"@", @":", @"@", @"@", @"@", @"@", @"@", @"@"]) ||
        !Signature(class_getInstanceMethod(sdkClass, @selector(showLogin)), "v", @[@"@", @":"]) ||
        !Signature(class_getInstanceMethod(sdkClass, @selector(logout)), "v", @[@"@", @":"])) {
        return ABError(error, @"B站 SDK 接口不匹配");
    }
    @try {
        Protocol *delegateProtocol = NSProtocolFromString(@"GSSDKCenterDelegate");
        if (delegateProtocol) class_addProtocol(ABLoginCoordinator.class, delegateProtocol);
        ABLoginCoordinator *coordinator = [ABLoginCoordinator new];
        coordinator.state = @"initializing";
        id<ABObservedGSSDK> sdk = [sdkClass sharedGSInterface];
        coordinator.sdk = sdk;
        if (![sdk respondsToSelector:@selector(initWithGameId:merchantId:serverId:appKey:sandboxKey:delegate:)] ||
            ![sdk respondsToSelector:@selector(showLogin)] || ![sdk respondsToSelector:@selector(logout)]) {
            return ABError(error, @"B站 SDK 接口不匹配");
        }
        if (![sdk initWithGameId:config[@"gameId"] merchantId:config[@"merchantId"]
                        serverId:config[@"serverId"] appKey:config[@"appKey"]
                      sandboxKey:config[@"sandboxKey"] delegate:coordinator]) {
            return ABError(error, @"B站 SDK 初始化未完成，请重试");
        }
        coordinator.state = @"ready";
        ABCurrent = coordinator;
        ABUseBili = ![[NSUserDefaults.standardUserDefaults stringForKey:@"ABLoginChannel"] isEqual:@"official"];
        return YES;
    } @catch (id exception) {
        return ABError(error, @"B站 SDK 初始化失败，请重试");
    }
}

static void Login(id obj, SEL sel) { [ABCurrent beginLogin:obj selector:sel params:nil]; }
static void LoginParams(id obj, SEL sel, id params) { [ABCurrent beginLogin:obj selector:sel params:params]; }
static void Logout(id obj, SEL sel) { (void)sel; [ABCurrent requestLogout:obj]; }
static void Result(id obj, SEL sel, int code, id data) {
    if (ABUseBili) return;
    if (ABCurrent->gate.pending) {
        ABAttemptFinish(&ABCurrent->gate, ABCurrent->gate.generation);
        ABCurrent.receiver = nil;
        ABCurrent.state = @"official-result-forwarded";
    }
    HGResult(obj, sel, code, data);
}
static void LoggedOut(id obj, SEL sel, int code) {
    if (ABUseBili) return;
    ABAttemptInvalidate(&ABCurrent->gate);
    ABCurrent.callbackGeneration = ABCurrent->gate.generation;
    ABCurrent.receiver = nil;
    ABCurrent.logoutReceiver = nil;
    ABCurrent.state = @"ready";
    ABInGame = false;
    HGLoggedOut(obj, sel, code);
}
static void Pay(id obj, SEL sel, id params) {
    (void)sel;
    (void)params;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(
            obj, NSSelectorFromString(@"eventPayFailed:"),
            @{@"status": @1, @"message": @"商品下架", @"extension": @""});
        UIViewController *top = ABTop();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"商品下架"
                                                                       message:@"当前客户端不提供充值购买。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

// Dynamically resolves the UnityFramework image base from ObjC IMPs without requiring hardcoded ObjC offsets.
static BOOL SameHostImage(Method method, uintptr_t *base) {
    if (!method) return NO;
    Dl_info info = {0};
    IMP imp = method_getImplementation(method);
    if (!imp || !dladdr((void *)imp, &info) || !info.dli_fbase) return NO;
    if (*base && *base != (uintptr_t)info.dli_fbase) return NO;
    *base = (uintptr_t)info.dli_fbase;
    return YES;
}

static BOOL Signature(Method method, const char *ret, NSArray<NSString *> *types) {
    if (!method || method_getNumberOfArguments(method) != types.count) return NO;
    char *r = method_copyReturnType(method);
    BOOL ok = r && !strcmp(r, ret);
    free(r);
    for (unsigned i = 0; i < types.count; i++) {
        char *t = method_copyArgumentType(method, i);
        ok &= t && !strcmp(t, types[i].UTF8String);
        free(t);
    }
    return ok;
}

BOOL ABEnableBLoginHooks(NSError **error) {
    if (!NSThread.isMainThread || !ABCurrent) return ABError(error, @"登录组件尚未准备");
    if (ABCurrent.hooksEnabled) return YES;

    NSString *expectedVer = ABExpectedHostVersion();
    NSString *expectedBld = ABExpectedHostBuild();
    NSString *actualVer = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *actualBld = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] description];
    if (![actualVer isEqual:expectedVer] || ![actualBld isEqual:expectedBld]) {
        return ABError(error, [NSString stringWithFormat:@"此配置仅适配明日方舟 %@（%@），当前为 %@（%@）",
                               expectedVer, expectedBld, actualVer ?: @"?", actualBld ?: @"?"]);
    }

    Class host = NSClassFromString(@"U8SDK_HGN");
    NSArray *selectors = @[@"login", @"login:", @"logout", @"onHGSDKLoginResult:withLoginCode:", @"onHGSDKLogout:", @"pay:"];
    NSArray *args = @[
        @[@"@", @":"],
        @[@"@", @":", @"@"],
        @[@"@", @":"],
        @[@"@", @":", @"i", @"@"],
        @[@"@", @":", @"i"],
        @[@"@", @":", @"@"]
    ];
    Method methods[6];
    uintptr_t base = 0;
    for (unsigned i = 0; i < 6; i++) {
        methods[i] = class_getInstanceMethod(host, NSSelectorFromString(selectors[i]));
        if (!Signature(methods[i], "v", args[i]) || !SameHostImage(methods[i], &base)) {
            return ABError(error, @"游戏登录接口签名不匹配，已停止接管");
        }
    }

    Class native = NSClassFromString(@"U8SDK");
    Method u8Shared = class_getClassMethod(native, @selector(sharedInstance));
    Method u8GetParams = class_getInstanceMethod(native, @selector(sdkParams));
    Method u8SetParams = class_getInstanceMethod(native, @selector(setSdkParams:));
    if (!Signature(u8Shared, "@", @[@"@", @":"]) ||
        !Signature(u8GetParams, "@", @[@"@", @":"]) ||
        !Signature(u8SetParams, "v", @[@"@", @":", @"@"]) ||
        !SameHostImage(u8Shared, &base) ||
        !SameHostImage(u8GetParams, &base) ||
        !SameHostImage(u8SetParams, &base) ||
        !ABCheckUnityImage(base)) {
        return ABError(error, @"渠道配置接口或 UnityFramework 镜像校验不匹配");
    }

    for (NSString *s in @[@"eventUserLogin:", @"eventUserLoginFailed:", @"eventUserLogout:", @"eventPayFailed:"]) {
        if (!Signature(class_getInstanceMethod(host, NSSelectorFromString(s)), "v", @[@"@", @":", @"@"])) {
            return ABError(error, @"游戏回调接口不匹配");
        }
    }

    if (!ABConfigureRuntimeRoute(base)) return ABError(error, @"运行时配置入口不可用");

    ABHGLogin = (void *)method_getImplementation(methods[0]);
    ABHGLoginParams = (void *)method_getImplementation(methods[1]);
    ABHGLogout = (void *)method_getImplementation(methods[2]);
    HGResult = (void *)method_getImplementation(methods[3]);
    HGLoggedOut = (void *)method_getImplementation(methods[4]);

    IMP replacements[] = {(IMP)Login, (IMP)LoginParams, (IMP)Logout, (IMP)Result, (IMP)LoggedOut, (IMP)Pay};
    for (unsigned i = 0; i < 6; i++) method_setImplementation(methods[i], replacements[i]);
    ABCurrent.hooksEnabled = YES;
    return YES;
}
