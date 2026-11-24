// Channel controls, application delegate OpenURL integration, and safe SDK loading.
#import "ABBridge.h"
#import <dlfcn.h>
#import <math.h>

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

static UIColor *ABSurfaceColor(CGFloat alpha) {
    return [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:alpha];
}

static UIColor *ABBiliAccentColor(CGFloat alpha) {
    return [UIColor colorWithRed:0.14 green:0.68 blue:0.90 alpha:alpha];
}

static UIColor *ABOfficialAccentColor(CGFloat alpha) {
    return [UIColor colorWithRed:0.92 green:0.95 blue:0.98 alpha:alpha];
}

@interface ABBridgeMenuOptionButton : UIButton
@property(nonatomic) BOOL biliChannel;
@property(nonatomic) BOOL activeChannel;
@property(nonatomic, strong) UIView *dotView;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *checkLabel;
- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title bili:(BOOL)bili active:(BOOL)active;
@end

@implementation ABBridgeMenuOptionButton
- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title bili:(BOOL)bili active:(BOOL)active {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _biliChannel = bili;
    _activeChannel = active;
    self.layer.cornerRadius = 6.0;
    self.layer.borderWidth = active ? 0.75 : 0.0;

    _dotView = [[UIView alloc] initWithFrame:CGRectMake(10.0, (CGRectGetHeight(frame) - 6.0) * 0.5, 6.0, 6.0)];
    _dotView.layer.cornerRadius = 3.0;
    _dotView.userInteractionEnabled = NO;
    [self addSubview:_dotView];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(23.0, 0.0, CGRectGetWidth(frame) - 48.0, CGRectGetHeight(frame))];
    _nameLabel.text = title;
    _nameLabel.font = [UIFont systemFontOfSize:13.5 weight:(active ? UIFontWeightSemibold : UIFontWeightMedium)];
    _nameLabel.userInteractionEnabled = NO;
    [self addSubview:_nameLabel];

    _checkLabel = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetWidth(frame) - 26.0, 0.0, 18.0, CGRectGetHeight(frame))];
    _checkLabel.text = @"✓";
    _checkLabel.textAlignment = NSTextAlignmentRight;
    _checkLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    _checkLabel.hidden = !active;
    _checkLabel.userInteractionEnabled = NO;
    [self addSubview:_checkLabel];

    [self applyAppearance];
    return self;
}

- (void)applyAppearance {
    if (self.biliChannel) {
        self.dotView.backgroundColor = ABBiliAccentColor(self.activeChannel ? 1.0 : 0.55);
        self.checkLabel.textColor = ABBiliAccentColor(1.0);
    } else {
        self.dotView.backgroundColor = ABOfficialAccentColor(self.activeChannel ? 0.96 : 0.42);
        self.checkLabel.textColor = ABOfficialAccentColor(0.96);
    }
    self.nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:(self.activeChannel ? 0.98 : 0.78)];

    if (self.highlighted) {
        self.backgroundColor = self.biliChannel
            ? ABBiliAccentColor(0.24)
            : [UIColor colorWithWhite:1.0 alpha:0.16];
    } else if (self.activeChannel) {
        self.backgroundColor = self.biliChannel
            ? ABBiliAccentColor(0.16)
            : [UIColor colorWithWhite:1.0 alpha:0.10];
    } else {
        self.backgroundColor = UIColor.clearColor;
    }

    if (self.activeChannel) {
        self.layer.borderColor = (self.biliChannel
            ? ABBiliAccentColor(0.36)
            : [UIColor colorWithWhite:1.0 alpha:0.16]).CGColor;
    } else {
        self.layer.borderColor = UIColor.clearColor.CGColor;
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self applyAppearance];
}
@end

@interface ABBootstrap : NSObject
@property(nonatomic) BOOL attemptedPreparation;
@property(nonatomic) BOOL prepared;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) UIView *buttonDot;
@property(nonatomic, strong) UILabel *buttonTitleLabel;
@property(nonatomic, strong) UILabel *buttonChevronLabel;
@property(nonatomic, strong) UIControl *menuBackdrop;
@property(nonatomic, strong) UIView *menuPanel;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic) BOOL hasRenderedButtonStyle;
@property(nonatomic) BOOL lastRenderedBili;
@property(nonatomic) BOOL lastRenderedMenuOpen;
@property(nonatomic) BOOL lastRenderedHighlighted;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) UIWindow *gameWindow;
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
    a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self message:message];
    });
}

- (CGRect)targetButtonFrameForWindow:(UIWindow *)window {
    UIEdgeInsets inset = window.safeAreaInsets;
    CGFloat buttonW = 92.0;
    CGFloat buttonH = 34.0;
    // Place in top-right safe area while clearing the far-right 12+ CADPA age badge (~48pt wide).
    CGFloat rightSafe = inset.right > 56.0 ? inset.right : 56.0;
    CGFloat minX = inset.left + 12.0;
    CGFloat maxX = CGRectGetWidth(window.bounds) - rightSafe - buttonW - 12.0;
    CGFloat targetX = maxX >= minX ? maxX : minX;
    CGFloat targetY = inset.top + 12.0;
    return CGRectMake(floor(targetX), floor(targetY), buttonW, buttonH);
}

- (CGRect)targetMenuFrameForWindow:(UIWindow *)window buttonFrame:(CGRect)buttonFrame {
    UIEdgeInsets inset = window.safeAreaInsets;
    CGFloat panelW = 136.0;
    CGFloat panelH = 120.0;
    CGFloat minX = inset.left + 8.0;
    CGFloat maxX = CGRectGetWidth(window.bounds) - inset.right - panelW - 8.0;
    CGFloat panelX = CGRectGetMaxX(buttonFrame) - panelW;
    if (panelX > maxX) panelX = maxX;
    if (panelX < minX) panelX = minX;

    CGFloat panelY = CGRectGetMaxY(buttonFrame) + 6.0;
    CGFloat maxY = CGRectGetHeight(window.bounds) - inset.bottom - panelH - 8.0;
    if (panelY > maxY) {
        CGFloat aboveY = CGRectGetMinY(buttonFrame) - panelH - 6.0;
        panelY = aboveY >= inset.top + 8.0 ? aboveY : (maxY >= inset.top + 8.0 ? maxY : inset.top + 8.0);
    }
    return CGRectMake(floor(panelX), floor(panelY), panelW, panelH);
}

- (void)buildButtonIfNeeded {
    if (self.button) return;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0.0, 0.0, 92.0, 34.0);
    btn.backgroundColor = ABSurfaceColor(0.86);
    btn.layer.cornerRadius = 8.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    btn.layer.shadowColor = UIColor.blackColor.CGColor;
    btn.layer.shadowOpacity = 0.38;
    btn.layer.shadowRadius = 8.0;
    btn.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    btn.clipsToBounds = NO;

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(12.0, 14.0, 6.0, 6.0)];
    dot.layer.cornerRadius = 3.0;
    dot.userInteractionEnabled = NO;
    [btn addSubview:dot];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(24.0, 0.0, 44.0, 34.0)];
    titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor colorWithWhite:0.97 alpha:1.0];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.userInteractionEnabled = NO;
    [btn addSubview:titleLabel];

    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(70.0, 0.0, 14.0, 34.0)];
    chevron.text = @"▾";
    chevron.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    chevron.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    chevron.textAlignment = NSTextAlignmentCenter;
    chevron.userInteractionEnabled = NO;
    [btn addSubview:chevron];

    [btn addTarget:self action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    [btn addTarget:self action:@selector(onButtonHighlightChanged)
      forControlEvents:(UIControlEventTouchDown | UIControlEventTouchDragEnter |
                        UIControlEventTouchDragExit | UIControlEventTouchUpOutside |
                        UIControlEventTouchCancel)];
    [btn addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(diagnostic:)]];

    self.button = btn;
    self.buttonDot = dot;
    self.buttonTitleLabel = titleLabel;
    self.buttonChevronLabel = chevron;
    self.hasRenderedButtonStyle = NO;
}

- (void)onButtonHighlightChanged {
    [self updateButton];
}

- (void)closeMenuAnimated:(BOOL)animated state:(NSString *)state {
    ++self.menuRequest;
    BOOL wasOpen = self.menuOpen || self.menuPanel != nil || self.menuBackdrop != nil;
    self.menuOpen = NO;
    UIControl *backdrop = self.menuBackdrop;
    UIView *panel = self.menuPanel;
    self.menuBackdrop = nil;
    self.menuPanel = nil;
    if (wasOpen || state) {
        self.menuState = state ?: @"closed";
    }
    [self updateButton];

    if (!backdrop && !panel) return;
    backdrop.userInteractionEnabled = NO;
    panel.userInteractionEnabled = NO;

    if (!animated) {
        [backdrop removeFromSuperview];
        [panel removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.12
                          delay:0.0
                        options:(UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        panel.alpha = 0.0;
        panel.transform = CGAffineTransformTranslate(CGAffineTransformMakeScale(0.96, 0.96), 0.0, -4.0);
    } completion:^(__unused BOOL finished) {
        [backdrop removeFromSuperview];
        [panel removeFromSuperview];
    }];
}

- (void)closeMenu {
    [self closeMenuAnimated:NO state:@"closed"];
}

- (void)onBackdropTap {
    [self closeMenuAnimated:YES state:@"dismissed-outside"];
}

- (void)onSelectOfficial {
    [self closeMenuAnimated:YES state:@"official-selected"];
    [self selectChannel:NO];
}

- (void)onSelectBili {
    [self closeMenuAnimated:YES state:@"bili-selected"];
    [self selectChannel:YES];
}

- (void)openMenu {
    UIWindow *window = self.gameWindow;
    if (!window || ABLoginBusy() || ABShouldHideChannelButton()) return;

    // Tear down any lingering views before mounting fresh panel.
    [self.menuBackdrop removeFromSuperview];
    [self.menuPanel removeFromSuperview];
    self.menuBackdrop = nil;
    self.menuPanel = nil;

    ++self.menuRequest;

    UIControl *backdrop = [[UIControl alloc] initWithFrame:window.bounds];
    backdrop.backgroundColor = UIColor.clearColor;
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addTarget:self action:@selector(onBackdropTap) forControlEvents:UIControlEventTouchDown];

    CGRect panelFrame = [self targetMenuFrameForWindow:window buttonFrame:self.button.frame];
    UIView *panel = [[UIView alloc] initWithFrame:panelFrame];
    panel.backgroundColor = ABSurfaceColor(0.94);
    panel.layer.cornerRadius = 10.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.45;
    panel.layer.shadowRadius = 14.0;
    panel.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    panel.clipsToBounds = NO;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 0.0, CGRectGetWidth(panelFrame) - 24.0, 28.0)];
    header.text = @"登录渠道";
    header.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    header.textColor = [UIColor colorWithWhite:1.0 alpha:0.50];
    [panel addSubview:header];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(10.0, 28.0, CGRectGetWidth(panelFrame) - 20.0, 0.5)];
    divider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [panel addSubview:divider];

    BOOL isBili = ABUseBili ? YES : NO;
    CGFloat rowW = CGRectGetWidth(panelFrame) - 10.0;
    ABBridgeMenuOptionButton *officialBtn = [[ABBridgeMenuOptionButton alloc] initWithFrame:CGRectMake(5.0, 34.0, rowW, 38.0)
                                                                                      title:@"官服"
                                                                                       bili:NO
                                                                                     active:!isBili];
    [officialBtn addTarget:self action:@selector(onSelectOfficial) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:officialBtn];

    ABBridgeMenuOptionButton *biliBtn = [[ABBridgeMenuOptionButton alloc] initWithFrame:CGRectMake(5.0, 76.0, rowW, 38.0)
                                                                                  title:@"B服"
                                                                                   bili:YES
                                                                                 active:isBili];
    [biliBtn addTarget:self action:@selector(onSelectBili) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:biliBtn];

    [window addSubview:backdrop];
    [window bringSubviewToFront:self.button];
    [window addSubview:panel];

    self.menuBackdrop = backdrop;
    self.menuPanel = panel;
    self.menuOpen = YES;
    self.menuState = @"visible";
    [self updateButton];

    panel.alpha = 0.0;
    panel.transform = CGAffineTransformTranslate(CGAffineTransformMakeScale(0.96, 0.96), 0.0, -4.0);
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)show {
    ++self.menuTapCount;
    [self tick];
    if (ABShouldHideChannelButton()) {
        self.menuState = @"blocked-in-game";
    } else if (self.menuOpen) {
        [self closeMenuAnimated:YES state:@"closed"];
    } else {
        if (![self prepare]) [self message:self.note];
        else if (ABLoginBusy()) [self message:@"请先完成或关闭当前登录窗口"];
        else [self openMenu];
    }
}

- (void)diagnostic:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || ABShouldHideChannelButton()) return;
    if (self.menuOpen) [self closeMenuAnimated:NO state:@"closed"];
    [self message:[NSString stringWithFormat:@"%@\n%@\nSDK: %s\n%@\n%@",
                   self.note ?: ABLoginState(),
                   ABChannelStateDiagnostic(),
                   ABSDKLoadDiagnostic(),
                   ABIL2CPPExportDiagnostic(),
                   ABRuntimeRouteStatus()]];
}

- (void)updateButton {
    if (!self.button) return;
    BOOL shouldHide = ABShouldHideChannelButton();
    BOOL shouldEnable = !ABLoginBusy();
    BOOL isBili = ABUseBili ? YES : NO;
    BOOL isOpen = self.menuOpen;
    BOOL isHighlighted = self.button.highlighted;

    if (self.button.hidden != shouldHide) self.button.hidden = shouldHide;
    if (self.button.enabled != shouldEnable) {
        self.button.enabled = shouldEnable;
        self.button.alpha = shouldEnable ? 1.0 : 0.50;
    }

    if (!self.hasRenderedButtonStyle ||
        self.lastRenderedBili != isBili ||
        self.lastRenderedMenuOpen != isOpen ||
        self.lastRenderedHighlighted != isHighlighted) {
        self.hasRenderedButtonStyle = YES;
        self.lastRenderedBili = isBili;
        self.lastRenderedMenuOpen = isOpen;
        self.lastRenderedHighlighted = isHighlighted;

        self.buttonTitleLabel.text = isBili ? @"B服" : @"官服";
        self.buttonDot.backgroundColor = isBili ? ABBiliAccentColor(1.0) : ABOfficialAccentColor(0.95);
        self.button.backgroundColor = (isOpen || isHighlighted)
            ? [UIColor colorWithRed:0.13 green:0.15 blue:0.20 alpha:0.94]
            : ABSurfaceColor(0.86);
        self.button.layer.borderColor = (isOpen
            ? (isBili ? ABBiliAccentColor(0.55) : [UIColor colorWithWhite:1.0 alpha:0.32])
            : [UIColor colorWithWhite:1.0 alpha:0.18]).CGColor;
        self.buttonChevronLabel.textColor = [UIColor colorWithWhite:1.0 alpha:(isOpen ? 0.90 : 0.65)];

        CGAffineTransform chevronTransform = isOpen
            ? CGAffineTransformMakeRotation((CGFloat)M_PI)
            : CGAffineTransformIdentity;
        [UIView animateWithDuration:0.15
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            self.buttonChevronLabel.transform = chevronTransform;
        } completion:nil];
    }
}

- (void)ensureFloatingZOrderInWindow:(UIWindow *)window {
    if (!self.button || self.button.hidden) return;
    NSArray<UIView *> *subviews = window.subviews;
    if (self.menuOpen && self.menuBackdrop && self.menuPanel) {
        NSUInteger count = subviews.count;
        BOOL ordered = (count >= 3 &&
                        subviews[count - 3] == self.menuBackdrop &&
                        subviews[count - 2] == self.button &&
                        subviews[count - 1] == self.menuPanel);
        if (!ordered) {
            [window bringSubviewToFront:self.menuBackdrop];
            [window bringSubviewToFront:self.button];
            [window bringSubviewToFront:self.menuPanel];
        }
    } else if (subviews.lastObject != self.button) {
        [window bringSubviewToFront:self.button];
    }
}

- (void)syncButtonVisibilityNow {
    if (!self.button) return;
    [self updateButton];
    if (self.button.hidden || ABLoginBusy()) [self closeMenu];
    if (self.gameWindow && !self.button.hidden) {
        [self ensureFloatingZOrderInWindow:self.gameWindow];
    }
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
            [self buildButtonIfNeeded];
            InstallOpenURLCallback();
        }
        [window addSubview:self.button];
    }
    if (self.button.superview != window) {
        [window addSubview:self.button];
    }
    CGRect targetFrame = [self targetButtonFrameForWindow:window];
    if (!CGRectEqualToRect(self.button.frame, targetFrame)) {
        self.button.frame = targetFrame;
    }
    if (self.menuOpen && self.menuBackdrop && self.menuPanel) {
        if (self.menuBackdrop.superview != window) [window addSubview:self.menuBackdrop];
        if (self.menuPanel.superview != window) [window addSubview:self.menuPanel];
        if (!CGRectEqualToRect(self.menuBackdrop.frame, window.bounds)) {
            self.menuBackdrop.frame = window.bounds;
        }
        CGRect targetPanelFrame = [self targetMenuFrameForWindow:window buttonFrame:targetFrame];
        if (CGAffineTransformIsIdentity(self.menuPanel.transform) &&
            !CGRectEqualToRect(self.menuPanel.frame, targetPanelFrame)) {
            self.menuPanel.frame = targetPanelFrame;
        }
    }
    if (!self.attemptedPreparation) {
        Class<ABNativeU8> cls = NSClassFromString(@"U8SDK");
        id<ABNativeU8> native = [cls respondsToSelector:@selector(sharedInstance)] ? [cls sharedInstance] : nil;
        if ([native respondsToSelector:@selector(isInitCompleted)] && [native isInitCompleted]) [self prepare];
    }
    if (self.prepared) {
        ABObserveScene(ABRuntimeScene());
    }
    [self syncButtonVisibilityNow];
}
@end

static __weak ABBootstrap *activeBootstrap;

static void ABHandleUIStateChanged(void) {
    ABBootstrap *b = activeBootstrap;
    if (!b) return;
    [b syncButtonVisibilityNow];
}

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
            ABLoadSavedChannelPreference();
            LoadSDK();
            if (!NSClassFromString(@"GSSDK")) {
                NSLog(@"[ABLoginBridge] SDK load failed: %@", ABLoadDiagnostic);
            }
            static ABBootstrap *bootstrap;
            bootstrap = [ABBootstrap new];
            activeBootstrap = bootstrap;
            ABSetUIStateChangeHandler(ABHandleUIStateChanged);
            bootstrap.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                               target:bootstrap
                                                             selector:@selector(tick)
                                                             userInfo:nil
                                                              repeats:YES];
        });
    }
}
