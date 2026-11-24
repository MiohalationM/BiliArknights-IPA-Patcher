// Reconstructed from ABLoginBridge.dylib, SHA256 5fe8d0c9...37b16ce,
// extended with pre-login/gameplay scene gating and server-entry lock policy.
#ifndef AB_POLICY_H
#define AB_POLICY_H
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint64_t generation; // offset 0
    bool pending;        // offset 8
} ABAttemptGate;
typedef struct {
    bool sawHome;
    bool sawLogin;
} ABSceneGate;
uint64_t ABAttemptBegin(ABAttemptGate *gate);
bool ABAttemptFinish(ABAttemptGate *gate, uint64_t generation);
void ABAttemptInvalidate(ABAttemptGate *gate);
bool ABSceneShouldReset(ABSceneGate *gate, bool isHome, bool isLogin,
                        bool isLoggingOut, bool hasPendingAttempt);
bool ABKnownGameHost(const char *host);
bool ABIsPreLoginOrTransitionScene(const char *scene);
bool ABIsInGameScene(const char *scene, bool sawLogin, bool enteringServer);
bool ABShouldExpireEnteringServer(bool enteringServer, bool inGame,
                                  bool isLoginScene, double elapsedSeconds,
                                  double timeoutSeconds);
bool ABShouldHideButtonForState(bool inGame, bool loginBusy, bool enteringServer);
#endif
