// Reconstructed from ABLoginBridge.dylib, SHA256 5fe8d0c9...37b16ce.
// Source spelling is new; behavior follows the instruction ranges below.
#ifndef AB_POLICY_H
#define AB_POLICY_H
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint64_t generation; // offset 0
    bool pending;        // offset 8
} ABAttemptGate;
typedef struct { bool sawHome; } ABSceneGate;
uint64_t ABAttemptBegin(ABAttemptGate *gate);
bool ABAttemptFinish(ABAttemptGate *gate, uint64_t generation);
void ABAttemptInvalidate(ABAttemptGate *gate);
bool ABSceneShouldReset(ABSceneGate *gate, bool isHome, bool isLogin,
                        bool isLoggingOut, bool hasPendingAttempt);
bool ABKnownGameHost(const char *host);
#endif
