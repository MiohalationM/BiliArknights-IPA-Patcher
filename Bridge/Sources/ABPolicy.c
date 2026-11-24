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

static bool ABHasPrefix(const char *s, const char *prefix) {
    size_t len = strlen(prefix);
    return strncmp(s, prefix, len) == 0;
}

bool ABIsPreLoginOrTransitionScene(const char *scene) {
    if (!scene || !scene[0]) return true;
    static const char *const kExact[] = {
        "login", "boot", "init", "splash", "start", "title",
        "update", "hotupdate", "patch", "check", "loading", "load",
        "empty", "blank", "transition", "none", "null"
    };
    for (size_t i = 0; i < sizeof(kExact) / sizeof(kExact[0]); ++i) {
        if (strcmp(scene, kExact[i]) == 0) return true;
    }
    static const char *const kPrefixes[] = {
        "boot_", "init_", "splash_", "login_", "update_",
        "hotupdate_", "loading_", "load_", "transition_"
    };
    for (size_t i = 0; i < sizeof(kPrefixes) / sizeof(kPrefixes[0]); ++i) {
        if (ABHasPrefix(scene, kPrefixes[i])) return true;
    }
    return false;
}

bool ABIsInGameScene(const char *scene, bool sawLogin, bool enteringServer) {
    if (!scene || !scene[0]) return false;
    if (strcmp(scene, "home") == 0 || ABHasPrefix(scene, "home_")) return true;
    if (ABIsPreLoginOrTransitionScene(scene)) return false;
    return sawLogin || enteringServer;
}

bool ABShouldExpireEnteringServer(bool enteringServer, bool inGame,
                                  bool isLoginScene, double elapsedSeconds,
                                  double timeoutSeconds) {
    return enteringServer && !inGame && isLoginScene && elapsedSeconds >= timeoutSeconds;
}

bool ABShouldHideButtonForState(bool inGame, bool loginBusy, bool enteringServer) {
    return inGame || loginBusy || enteringServer;
}
