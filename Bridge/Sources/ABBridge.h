#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ABRecoveredInterfaces.h"
#import "ABLoginResult.h"

typedef struct {
    BOOL loaded;
    uint8_t unityUUID[16];
    BOOL hasUnityUUID;
    uint64_t unityTextSize;
    char unityTextSHA256[65];

    uint64_t sdkInterfaceClassSlot;
    uint64_t sdkExternalToolsClassSlot;
    uint64_t sdkMetaClassSlot;
    uint64_t networkerTypeSlot;
    uint64_t networkerExpectedClass;
    uint64_t gameFlowClassSlot;

    uint64_t getNetworkConfigFn;
    uint64_t overrideNetworkOptionsFn;
    uint64_t createStringFn;
    uint64_t internalSDKMetaFn;
    uint64_t sdkMetaCtorFn;
    uint64_t clearAuthStatusFn;
    uint64_t clearLoginStatusFn;
    uint64_t getCurrentSceneFn;
} ABRuntimeOffsetProfile;

extern ABLoginCoordinator *ABCurrent;
extern bool ABUseBili, ABInGame;
extern ABSceneGate ABScene;
extern uintptr_t ABBase;
extern void (*ABHGLogin)(id, SEL), (*ABHGLogout)(id, SEL);
extern void (*ABHGLoginParams)(id, SEL, id);

BOOL ABError(NSError **error, NSString *message);
__attribute__((visibility("default"))) BOOL ABPrepareBLogin(NSDictionary *config, NSError **error);
__attribute__((visibility("default"))) BOOL ABEnableBLoginHooks(NSError **error);
BOOL ABSelectLoginChannel(BOOL bili, NSError **error);
BOOL ABLoginBusy(void);
__attribute__((visibility("default"))) NSString *ABLoginState(void);
__attribute__((visibility("default"))) const char *ABSDKLoadDiagnostic(void);
BOOL ABShouldHideChannelButton(void);
void ABObserveScene(NSString *scene);
BOOL ABConfigureRuntimeRoute(uintptr_t base);
BOOL ABApplyGameRoute(BOOL bili, NSError **error);
BOOL ABApplyRuntimeRoute(NSError **error);
NSString *ABRuntimeScene(void);
NSString *ABRuntimeRouteStatus(void);
NSString *ABIL2CPPExportDiagnostic(void);
const ABRuntimeOffsetProfile *ABActiveRuntimeProfile(void);
NSString *ABExpectedHostVersion(void);
NSString *ABExpectedHostBuild(void);
BOOL ABCheckUnityImage(uintptr_t base);
UIViewController *ABTop(void);
UIWindow *ABCurrentWindow(void);

@protocol ABNativeU8 <NSObject>
+ (id)sharedInstance;
- (NSDictionary *)sdkParams;
- (void)setSdkParams:(NSDictionary *)params;
- (BOOL)isInitCompleted;
@end
