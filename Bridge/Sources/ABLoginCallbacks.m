// Recovered methods in a category; the reconstructed primary class and logout
// methods are provided by ../bridge/ABHooks.m.
#import "ABRecoveredInterfaces.h"
#import "ABLoginResult.h"
extern bool ABUseBili;
extern bool ABInGame;
extern void (*ABHGLogin)(id, SEL);
extern void (*ABHGLoginParams)(id, SEL, id);


@interface ABLoginCoordinator (RecoveredCallbacks)
@end
@implementation ABLoginCoordinator (RecoveredCallbacks)

// 0x48b4..0x4e98, with compiler-generated ARC and exception cleanup removed.
- (void)beginLogin:(id<ABObservedU8>)receiver selector:(SEL)selector params:(id)params {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self beginLogin:receiver selector:selector params:params];
        });
        return;
    }
    if (self->gate.pending) return;
    if (!self.hooksEnabled || [self.state isEqualToString:@"logging-out"]) {
        [receiver eventUserLoginFailed:@"登录组件正在准备，请稍后再试"];
        return;
    }
    NSError *error = nil;
    if (!ABApplyChannel(ABUseBili, NO, &error)) {
        [receiver eventUserLoginFailed:error.localizedDescription ?: @"渠道未就绪"];
        return;
    }
    ABInGame = false;
    NSUInteger generation = ABAttemptBegin(&self->gate);
    self.callbackGeneration = generation;
    self.receiver = receiver;
    self.pluginReceiver = receiver;
    self.state = ABUseBili ? @"bili-login-pending" : @"official-login-pending";
    @try {
        if (ABUseBili) {
            [self.sdk showLogin];
        } else if (selector == NSSelectorFromString(@"login:")) {
            ABHGLoginParams(receiver, selector, params);
        } else {
            ABHGLogin(receiver, selector);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300LL * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self failGeneration:generation message:@"登录超时，请重新登录"];
        });
    } @catch (id exception) {
        [self failGeneration:generation message:@"登录窗口打开失败，请重试"];
    }
}

// 0x476c..0x4840
- (void)failGeneration:(NSUInteger)generation message:(NSString *)message {
    if (!ABAttemptFinish(&self->gate, generation)) return;
    id<ABObservedU8> target = self.receiver;
    self.receiver = nil;
    self.state = @"ready";
    [target eventUserLoginFailed:message];
}

// 0x5090..0x53a8 + block 0x53a8..0x554c. The initial copy/nil checks
// correspond to construction of the callback dictionary in the original.
- (void)didLoginSuccessWithUid:(id)uid accessKey:(id)accessKey {
    NSUInteger generation = self.callbackGeneration;
    NSDictionary *data = (uid && accessKey) ? @{@"uid": [uid copy], @"access_key": [accessKey copy]} : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ABUseBili || !self->gate.pending || self->gate.generation != generation) return;
        NSError *error = nil;
        NSDictionary *result = ABMakeU8LoginResult(data, &error);
        if (!result) {
            [self failGeneration:generation message:@"登录结果不完整，请重试"];
            return;
        }
        if (!ABAttemptFinish(&self->gate, generation)) return;
        id<ABObservedU8> target = self.receiver;
        self.receiver = nil;
        self.state = @"sdk-result-forwarded";
        [target eventUserLogin:result];
    });
}

// 0x55e8..0x5744. The error argument is retained/released by generated ARC
// code but is not used for the user-facing failure message.
- (void)didLoginFailureWithError:(id)error {
    (void)error;
    NSUInteger generation = self.callbackGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ABUseBili) [self failGeneration:generation message:@"登录未完成，可重新登录"];
    });
}
@end
