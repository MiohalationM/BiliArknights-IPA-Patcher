// Partial declarations recovered from Objective-C metadata and call sites.
// This header is documentation of observed interfaces, not a complete SDK header.
#import <Foundation/Foundation.h>
#import "ABPolicy.h"

@protocol ABObservedU8 <NSObject>
- (void)eventUserLogin:(NSDictionary *)result;
- (void)eventUserLoginFailed:(id)message;
- (void)eventUserLogout:(id)result;
@end

@protocol ABObservedGSSDK <NSObject>
+ (id)sharedGSInterface;
- (BOOL)initWithGameId:(NSString *)game
           merchantId:(NSString *)merchant
             serverId:(NSString *)server
               appKey:(NSString *)key
           sandboxKey:(NSString *)sandbox
             delegate:(id)delegate;
- (void)showLogin;
- (void)logout;
- (BOOL)handleOpenURL:(NSURL *)url userActivity:(NSUserActivity *)activity;
@end

@interface ABLoginCoordinator : NSObject {
@public
    ABAttemptGate gate;
}
@property(nonatomic, strong) id<ABObservedGSSDK> sdk;
@property(nonatomic, strong) id<ABObservedU8> receiver;
@property(nonatomic, strong) id<ABObservedU8> pluginReceiver;
@property(nonatomic, strong) id<ABObservedU8> logoutReceiver;
@property(nonatomic, copy) NSString *state;
@property(nonatomic) BOOL hooksEnabled;
@property NSUInteger callbackGeneration;
- (void)failGeneration:(NSUInteger)generation message:(NSString *)message;
- (void)beginLogin:(id)receiver selector:(SEL)selector params:(id)params;
- (void)didLoginSuccessWithUid:(id)uid accessKey:(id)accessKey;
- (void)didLoginFailureWithError:(id)error;
- (void)didLogout;
- (void)requestLogout:(id)receiver;
@end

// Implementations for the complete reconstructed build live in ../bridge/ABRuntime.m.
FOUNDATION_EXPORT BOOL ABApplyChannel(BOOL bili, BOOL clearAuth, NSError **error);
FOUNDATION_EXPORT BOOL ABManagedChannelReady(void);
