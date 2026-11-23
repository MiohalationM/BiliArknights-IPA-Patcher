// Channel controls, application delegate OpenURL integration, and safe SDK loading.
#import "ABBridge.h"
#import <dlfcn.h>

static __weak UIWindow *gameWindow;
static BOOL (*originalOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *);

static BOOL UsableWindow(UIWindow *window) {
    return window && !window.hidden && window.alpha > 0.01 &&
        window.userInteractionEnabled && window.rootViewController &&
        window.windowLevel == UIWindowLevelNormal &&
        (!window.windowScene || window.windowScene.activationState == UISceneActivationStateForegroundActive);
}

UIWindow *ABCurrentWindow(void) {
    UIWindow *previous = gameWindow;
    if (ABLoginBusy() && UsableWindow(previous)) return previous;
    UIApplication *app = UIApplication.sharedApplication;
    UIWindowScene *previousScene = previous.windowScene;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (previousScene && previousScene.activationState == UISceneActivationStateForegroundActive &&
            previousScene != scene) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && UsableWindow(window)) return window;
        }
    }
    UIWindow *keyWindow = app.keyWindow;
    if (UsableWindow(keyWindow)) return keyWindow;
    return UsableWindow(previous) ? previous : nil;
}

UIViewController *ABTop(void) {
    UIWindow *window = gameWindow;
    UIViewController *controller = window.rootViewController;
    for (NSUInteger depth = 0; controller && depth < 32; ++depth) {
        if (controller.isBeingDismissed || controller.isBeingPresented) return nil;
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)controller).visibleViewController;
        }
        if ((!next || next == controller) && [controller isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next || next == controller) return controller.viewIfLoaded.window == window ? controller : nil;
        controller = next;
    }
    return nil;
}

static BOOL OpenURL(id receiver, SEL selector, UIApplication *app, NSURL *url, NSDictionary *options) {
    BOOL handledBySDK = NO;
    if (ABUseBili) {
        Class<ABObservedGSSDK> sdkClass = NSClassFromString(@"GSSDK");
        id<ABObservedGSSDK> sdk = [sdkClass respondsToSelector:@selector(sharedGSInterface)] ?
            [sdkClass sharedGSInterface] : nil;
        if ([sdk respondsToSelector:@selector(handleOpenURL:userActivity:)]) {
            handledBySDK = [sdk handleOpenURL:url userActivity:nil];
        }
    }
    BOOL handledByHost = originalOpenURL && originalOpenURL(receiver, selector, app, url, options);
    return handledBySDK || handledByHost;
}

static void InstallOpenURLCallback(void) {
    Class cls = object_getClass(UIApplication.sharedApplication.delegate);
    if (!cls) return;
    SEL selector = @selector(application:openURL:options:);
    Method original = class_getInstanceMethod(cls, selector);
    if (!original) {
        class_addMethod(cls, selector, (IMP)OpenURL, "B40@0:8@16@24@32");
    } else if (method_getNumberOfArguments(original) == 5) {
        originalOpenURL = (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSDictionary *))method_getImplementation(original);
        class_replaceMethod(cls, selector, (IMP)OpenURL, method_getTypeEncoding(original));
    }
}

@interface ABBootstrap : NSObject <UIAdaptivePresentationControllerDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic) BOOL attemptedPreparation;
@property(nonatomic) BOOL prepared;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) UIWindow *gameWindow;
@property(nonatomic, strong) UIAlertController *channelMenu;
@property(nonatomic) NSUInteger menuRequest;
@property(nonatomic) NSUInteger menuTapCount;
@property(nonatomic, copy) NSString *menuState;
@property(nonatomic, copy) NSString *note;
@end

@implementation ABBootstrap
- (BOOL)prepare {
    if (self.prepared) return YES;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:
        [NSBundle.mainBundle pathForResource:@"ABGameConfig" ofType:@"plist"]];
    NSError *error = nil;
    self.attemptedPreparation = YES;
    self.prepared = ABPrepareBLogin(config, &error) && ABEnableBLoginHooks(&error);
    self.note = self.prepared ? nil : (error.localizedDescription ?: @"登录组件正在准备");
    return self.prepared;
}

- (void)message:(NSString *)message {
    UIViewController *top = ABTop();
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"渠道切换"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

- (void)selectChannel:(BOOL)bili {
    NSError *error = nil;
    if ([self prepare] && ABSelectLoginChannel(bili, &error)) {
        [self updateButton];
        return;
    }
    NSString *message = error.localizedDescription ?: self.note ?: @"切换未完成，请稍后重试";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self message:message];
    });
}

- (void)closeMenu {
    ++self.menuRequest;
    UIAlertController *menu = self.channelMenu;
    self.channelMenu = nil;
    if (menu.presentingViewController) [menu dismissViewControllerAnimated:NO completion:nil];
    self.menuState = @"closed";
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
    if (controller.presentedViewController != self.channelMenu) return;
    self.channelMenu = nil;
    self.menuState = @"dismissed-outside";
}

- (void)popoverPresentationControllerDidDismissPopover:(UIPopoverPresentationController *)controller {
    [self presentationControllerDidDismiss:controller];
}

- (void)presentMenuAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (generation != self.menuRequest) return;
    if (ABLoginBusy() || ABShouldHideChannelButton()) return;
    UIViewController *top = ABTop();
    if (!top || top.transitionCoordinator || [top isKindOfClass:UIAlertController.class]) {
        if (attempt >= 8) { self.menuState = @"blocked-by-modal-or-transition"; return; }
        self.menuState = @"waiting-for-presenter";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self presentMenuAttempt:attempt + 1 generation:generation];
        });
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"选择登录渠道"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak ABBootstrap *weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"官服" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.channelMenu = nil;
        weakSelf.menuState = @"official-selected";
        [weakSelf selectChannel:NO];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"B服" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        weakSelf.channelMenu = nil;
        weakSelf.menuState = @"bili-selected";
        [weakSelf selectChannel:YES];
    }]];
    UIPopoverPresentationController *pop = a.popoverPresentationController;
    pop.sourceView = self.button;
    pop.sourceRect = self.button.bounds;
    pop.delegate = self;
    self.channelMenu = a;
    self.menuState = @"presenting";
    [top presentViewController:a animated:YES completion:^{
        if (weakSelf.channelMenu == a) weakSelf.menuState = @"visible";
    }];
    a.presentationController.delegate = self;
}

- (void)show {
    ++self.menuTapCount;
    [self tick];
    if (ABShouldHideChannelButton()) {
        self.menuState = @"blocked-in-game";
    } else if (self.channelMenu.presentingViewController) {
        [self closeMenu];
    } else {
        self.channelMenu = nil;
        if (![self prepare]) [self message:self.note];
        else if (ABLoginBusy()) [self message:@"请先完成或关闭当前登录窗口"];
        else [self presentMenuAttempt:0 generation:++self.menuRequest];
    }
}

- (void)diagnostic:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || ABShouldHideChannelButton()) return;
    [self message:[NSString stringWithFormat:@"%@\nSDK: %s\n%@\n%@",
                   self.note ?: ABLoginState(),
                   ABSDKLoadDiagnostic(),
                   ABIL2CPPExportDiagnostic(),
                   ABRuntimeRouteStatus()]];
}

- (void)updateButton {
    self.button.hidden = ABShouldHideChannelButton();
    self.button.enabled = !ABLoginBusy();
    [self.button setTitle:ABUseBili ? @"B服 ▾" : @"官服 ▾" forState:UIControlStateNormal];
}

- (void)tick {
    if (!NSClassFromString(@"U8SDK_HGN")) return;
    UIWindow *window = ABCurrentWindow();
    if (!window) return;
    if (window != self.gameWindow) {
        [self closeMenu];
        self.gameWindow = window;
        gameWindow = window;
        if (!self.button) {
            self.button = [UIButton buttonWithType:UIButtonTypeSystem];
            self.button.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
            [self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            self.button.layer.cornerRadius = 8;
            [self.button addTarget:self action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
            [self.button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(diagnostic:)]];
            InstallOpenURLCallback();
        }
        [window addSubview:self.button];
    }
    if (self.button.superview != window) {
        [window addSubview:self.button];
    }
    UIEdgeInsets inset = window.safeAreaInsets;
    self.button.frame = CGRectMake(inset.left + 12, inset.top + 12, 86, 36);
    if (!self.attemptedPreparation) {
        Class<ABNativeU8> cls = NSClassFromString(@"U8SDK");
        id<ABNativeU8> native = [cls respondsToSelector:@selector(sharedInstance)] ? [cls sharedInstance] : nil;
        if ([native respondsToSelector:@selector(isInitCompleted)] && [native isInitCompleted]) [self prepare];
    }
    if (self.prepared) ABObserveScene(ABRuntimeScene());
    [self updateButton];
    if (self.button.hidden || ABLoginBusy()) [self closeMenu];
    if (!self.button.hidden) [window bringSubviewToFront:self.button];
}
@end

static NSString *ABLoadDiagnostic;

// Loads the official Bilibili SDK carrier (`ABSDKCarrier.dylib`) with RTLD_LOCAL so its renamed legacy
// symbols stay isolated while its Objective-C classes register globally for `GSSDK` lookup.
static void LoadSDK(void) {
    if (NSClassFromString(@"GSSDK")) {
        ABLoadDiagnostic = @"SDK already present";
        return;
    }
    Dl_info image = {0};
    if (!dladdr((void *)LoadSDK, &image) || !image.dli_fname) {
        ABLoadDiagnostic = @"cannot resolve bridge image path";
        return;
    }
    NSString *dir = [@(image.dli_fname) stringByDeletingLastPathComponent];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *errors = [NSMutableArray arrayWithCapacity:2];

    for (NSString *name in @[@"ABSDKCarrier.dylib", @"ABSDKRecovered.dylib"]) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:path]) {
            continue;
        }
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (handle && NSClassFromString(@"GSSDK")) {
            ABLoadDiagnostic = [@"loaded " stringByAppendingString:name];
            return;
        }
        const char *error = handle ? NULL : dlerror();
        [errors addObject:[NSString stringWithFormat:@"%@: %s", name,
                           error ? error : "loaded but GSSDK is missing"]];
    }
    ABLoadDiagnostic = errors.count > 0 ? [errors componentsJoinedByString:@"; "] : @"no SDK dylib found next to bridge";
}

__attribute__((visibility("default"))) const char *ABSDKLoadDiagnostic(void) {
    return ABLoadDiagnostic.UTF8String ?: "SDK not loaded yet";
}

__attribute__((constructor)) static void ABInstall(void) {
    @autoreleasepool {
        // Defer dlopen onto the main queue after dyld finishes initializers to avoid constructor-time lock issues.
        dispatch_async(dispatch_get_main_queue(), ^{
            LoadSDK();
            if (!NSClassFromString(@"GSSDK")) {
                NSLog(@"[ABLoginBridge] SDK load failed: %@", ABLoadDiagnostic);
            }
            static ABBootstrap *bootstrap;
            bootstrap = [ABBootstrap new];
            bootstrap.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                               target:bootstrap
                                                             selector:@selector(tick)
                                                             userInfo:nil
                                                              repeats:YES];
        });
    }
}
