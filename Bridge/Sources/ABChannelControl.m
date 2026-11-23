// Channel state and scene transitions recovered from the 2.7.91 bridge.
#import "ABRecoveredInterfaces.h"

// These are external in this reconstruction so the original module's shared
// state is explicit. In the original image the corresponding symbols are local.
extern ABLoginCoordinator *ABCurrent;
extern bool ABUseBili;
extern bool ABInGame;
extern ABSceneGate ABScene;

// The shared error constructor is implemented in ABHooks.m.
extern BOOL ABError(NSError **error, NSString *message);

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

// 0x89ec..0x8bf0
BOOL ABSelectLoginChannel(BOOL bili, NSError **error) {
    if (!NSThread.isMainThread || !ABCurrent.hooksEnabled)
        return ABError(error, @"登录组件正在准备，请稍后重试");
    if (ABInGame || ABLoginBusy())
        return ABError(error, @"请先返回登录页并完成或关闭当前登录窗口");
    BOOL ready = ABManagedChannelReady();
    if (ready && !ABApplyChannel(bili, bili != ABUseBili, error)) return NO;
    ABAttemptInvalidate(&ABCurrent->gate);
    ABCurrent.callbackGeneration = ABCurrent->gate.generation;
    ABCurrent.receiver = nil;
    ABCurrent.state = ready ? @"ready" : @"channel-selected-awaiting-game-init";
    ABUseBili = bili;
    [NSUserDefaults.standardUserDefaults setObject:bili ? @"bilibili" : @"official"
                                           forKey:@"ABLoginChannel"];
    return YES;
}

// 0x8bf0..0x8de8
void ABObserveScene(NSString *scene) {
    BOOL home = [scene isEqualToString:@"home"];
    BOOL login = [scene isEqualToString:@"login"];
    BOOL reset = ABSceneShouldReset(&ABScene, home, login,
        [ABCurrent.state isEqualToString:@"logging-out"], ABCurrent ? ABCurrent->gate.pending : NO);
    if (home) {
        ABInGame = true;
    } else if (login) {
        if (reset && ABCurrent) {
            ABAttemptInvalidate(&ABCurrent->gate);
            ABCurrent.callbackGeneration = ABCurrent->gate.generation;
            ABCurrent.receiver = nil;
            ABCurrent.logoutReceiver = nil;
            ABCurrent.pluginReceiver = nil;
            ABCurrent.state = @"ready-after-return-to-login";
        }
        ABInGame = false;
    }
}

// 0x8ec0..0x8ed0
BOOL ABShouldHideChannelButton(void) { return ABInGame; }
