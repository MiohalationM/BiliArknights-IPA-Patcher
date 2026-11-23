#include "ABPolicy.h"
#include <string.h>

// 0x4f9c..0x4fec
uint64_t ABAttemptBegin(ABAttemptGate *gate) {
    if (gate->pending) return 0;
    gate->pending = true;
    return ++gate->generation;
}

// 0x4840..0x48b4
bool ABAttemptFinish(ABAttemptGate *gate, uint64_t generation) {
    if (!gate->pending || gate->generation != generation) return false;
    gate->pending = false;
    return true;
}

// 0x59f0..0x5a18
void ABAttemptInvalidate(ABAttemptGate *gate) {
    gate->pending = false;
    ++gate->generation;
}

// 0x8de8..0x8ec0. The original clears sawHome whenever isLogin is true,
// even if a pending attempt prevents the logging-out reset branch.
bool ABSceneShouldReset(ABSceneGate *gate, bool isHome, bool isLogin,
                        bool isLoggingOut, bool hasPendingAttempt) {
    if (isHome) gate->sawHome = true;
    if (!isLogin) return false;
    bool reset = gate->sawHome || (isLoggingOut && !hasPendingAttempt);
    gate->sawHome = false;
    return reset;
}

// 0xb338..0xb3bc
bool ABKnownGameHost(const char *host) {
    return host && (!strcmp(host, "https://ak-gs-b.hypergryph.com") ||
                    !strcmp(host, "https://ak-gs-gf.hypergryph.com"));
}
