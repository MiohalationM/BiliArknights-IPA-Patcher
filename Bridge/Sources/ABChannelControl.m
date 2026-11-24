// Channel state, safe pre-selection, scene transitions, and server-entry hide lock.
#import "ABBridge.h"
#import <QuartzCore/QuartzCore.h>

static const CFTimeInterval kEnteringServerWatchdogSeconds = 15.0;

static bool ABInitializedLaunchPref = false;
static CFTimeInterval ABEnteringServerSince = 0;
static void (*ABUIStateChangeHandler)(void) = NULL;
static NSString *ABLastObservedScene = @"";

void ABSetUIStateChangeHandler(void (*handler)(void)) {
    ABUIStateChangeHandler = handler;
}

// Always hop onto the next main-queue turn so UIKit updates never run re-entrantly
// inside Unity or third-party SDK callback frames.
void ABNotifyUIStateChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ABUIStateChangeHandler) ABUIStateChangeHandler();
    });
}

void ABLoadSavedChannelPreference(void) {
    if (ABInitializedLaunchPref) return;
    ABInitializedLaunchPref = true;
    ABUseBili = ![[NSUserDefaults.standardUserDefaults stringForKey:@"ABLoginChannel"] isEqual:@"official"];
}

void ABMarkEnteringServer(void) {
    ABEnteringServer = true;
    ABEnteringServerSince = CACurrentMediaTime();
    ABNotifyUIStateChanged();
}

void ABClearEnteringServer(void) {
    if (!ABEnteringServer) return;
    ABEnteringServer = false;
    ABEnteringServerSince = 0;
    ABNotifyUIStateChanged();
}

// 0x88f4..0x8904
BOOL ABIsBiliChannel(void) { return ABUseBili; }

// 0x8810. Coordinator state is read on the main thread.
__attribute__((visibility("default"))) NSString *ABLoginState(void) {
    if (!NSThread.isMainThread) return @"query-on-main-thread";
    return ABCurrent.state ?: @"not-prepared";
}

// 0x8904..0x89ec
BOOL ABLoginBusy(void) {
    return ABCurrent && (ABCurrent->gate.pending || [ABCurrent.state isEqualToString:@"logging-out"]);
}

BOOL ABIsOnReadyLoginScreen(void) {
    return [ABLastObservedScene isEqualToString:@"login"] && ABChannelPreconditionsReady();
}

static BOOL ABIsTransientNotReadyError(NSError *error) {
    NSString *msg = error.localizedDescription;
    if (!msg.length) return NO;
    return [msg containsString:@"尚未就绪"] ||
           [msg containsString:@"未就绪"] ||
           [msg containsString:@"未找到"] ||
           [msg containsString:@"未完整加载"] ||
           [msg containsString:@"请等待"];
}

// 0x89ec..0x8bf0 + Scheme 2 pre-selection before the login screen & network config are ready.
BOOL ABSelectLoginChannel(BOOL bili, NSError **error) {
    if (!NSThread.isMainThread || !ABCurrent.hooksEnabled)
        return ABError(error, @"登录组件正在准备，请稍后重试");
    if (ABInGame || ABLoginBusy() || ABEnteringServer)
        return ABError(error, @"当前正在登录或已进入游戏，如需换服请先退出登录");

    BOOL appliedImmediately = NO;
    if (ABIsOnReadyLoginScreen()) {
        NSError *applyError = nil;
        if (ABApplyChannel(bili, bili != ABUseBili, &applyError)) {
            appliedImmediately = YES;
        } else if (!ABIsTransientNotReadyError(applyError)) {
            if (error) *error = applyError;
            return NO;
        }
    }

    ABAttemptInvalidate(&ABCurrent->gate);
    ABCurrent.callbackGeneration = ABCurrent->gate.generation;
    ABCurrent.receiver = nil;
    ABCurrent.state = appliedImmediately ? @"ready" : @"channel-selected-awaiting-game-init";
    ABUseBili = bili;
    [NSUserDefaults.standardUserDefaults setObject:bili ? @"bilibili" : @"official"
                                           forKey:@"ABLoginChannel"];
    ABNotifyUIStateChanged();
    return YES;
}

// 0x8bf0..0x8de8 + gameplay scene detection & entering-server watchdog.
void ABObserveScene(NSString *scene) {
    NSString *normalized = scene ?: @"";
    ABLastObservedScene = normalized;
    const char *sceneCStr = normalized.UTF8String ?: "";
    BOOL login = [normalized isEqualToString:@"login"];
    BOOL inGameScene = ABIsInGameScene(sceneCStr, ABScene.sawLogin, ABEnteringServer);
    BOOL reset = ABSceneShouldReset(&ABScene, inGameScene, login,
        [ABCurrent.state isEqualToString:@"logging-out"], ABCurrent ? ABCurrent->gate.pending : NO);

    if (inGameScene) {
        ABInGame = true;
        ABEnteringServer = false;
        ABEnteringServerSince = 0;
    } else if (login) {
        ABScene.sawLogin = true;
        if (reset && ABCurrent) {
            ABAttemptInvalidate(&ABCurrent->gate);
            ABCurrent.callbackGeneration = ABCurrent->gate.generation;
            ABCurrent.receiver = nil;
            ABCurrent.logoutReceiver = nil;
            ABCurrent.pluginReceiver = nil;
            ABCurrent.state = @"ready-after-return-to-login";
            ABEnteringServer = false;
            ABEnteringServerSince = 0;
        }
        ABInGame = false;

        if (ABEnteringServer) {
            double elapsed = CACurrentMediaTime() - ABEnteringServerSince;
            if (ABShouldExpireEnteringServer(true, false, true, elapsed, kEnteringServerWatchdogSeconds)) {
                ABEnteringServer = false;
                ABEnteringServerSince = 0;
            }
        }
    }
}

// 0x8ec0..0x8ed0 + hide immediately during login modal or server-entry handoff.
BOOL ABShouldHideChannelButton(void) {
    return ABShouldHideButtonForState(ABInGame, ABLoginBusy(), ABEnteringServer);
}

NSString *ABChannelStateDiagnostic(void) {
    return [NSString stringWithFormat:@"场景: %@ | 就绪: %@ | 进服中: %@ | 局内: %@",
            ABLastObservedScene.length ? ABLastObservedScene : @"(空)",
            ABIsOnReadyLoginScreen() ? @"是" : @"否",
            ABEnteringServer ? @"是" : @"否",
            ABInGame ? @"是" : @"否"];
}
