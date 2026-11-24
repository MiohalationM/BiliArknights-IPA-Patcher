#import <Foundation/Foundation.h>
#import "../Sources/ABPolicy.h"
#import "../Sources/ABLoginResult.h"
#include <assert.h>
#include <stdio.h>

static void test_attempt_gate(void) {
    ABAttemptGate gate = {0};
    assert(ABAttemptBegin(&gate) == 1);
    assert(gate.pending == true);
    assert(ABAttemptBegin(&gate) == 0); // re-entrancy blocked
    assert(ABAttemptFinish(&gate, 2) == false); // wrong generation
    assert(ABAttemptFinish(&gate, 1) == true);
    assert(gate.pending == false);
    assert(ABAttemptFinish(&gate, 1) == false); // already finished

    assert(ABAttemptBegin(&gate) == 2);
    ABAttemptInvalidate(&gate);
    assert(gate.pending == false);
    assert(gate.generation == 3);
    assert(ABAttemptFinish(&gate, 2) == false);
}

static void test_scene_gate_and_hosts(void) {
    ABSceneGate scene = {0};
    assert(ABSceneShouldReset(&scene, false, true, false, false) == false);
    assert(ABSceneShouldReset(&scene, true, false, false, false) == false);
    assert(scene.sawHome == true);
    assert(ABSceneShouldReset(&scene, false, true, false, false) == true);
    assert(scene.sawHome == false);
    assert(ABSceneShouldReset(&scene, false, true, true, false) == true);
    assert(ABSceneShouldReset(&scene, false, true, true, true) == false);

    assert(ABKnownGameHost("https://ak-gs-b.hypergryph.com") == true);
    assert(ABKnownGameHost("https://ak-gs-gf.hypergryph.com") == true);
    assert(ABKnownGameHost("https://evil.example.com") == false);
    assert(ABKnownGameHost(NULL) == false);
}

static void test_scene_classification_and_button_visibility(void) {
    // Boot/splash/loading scenes must NEVER be treated as in-game.
    assert(ABIsPreLoginOrTransitionScene(NULL) == true);
    assert(ABIsPreLoginOrTransitionScene("") == true);
    assert(ABIsPreLoginOrTransitionScene("boot") == true);
    assert(ABIsPreLoginOrTransitionScene("splash") == true);
    assert(ABIsPreLoginOrTransitionScene("hotupdate") == true);
    assert(ABIsPreLoginOrTransitionScene("loading") == true);
    assert(ABIsPreLoginOrTransitionScene("loading_next") == true);
    assert(ABIsPreLoginOrTransitionScene("login") == true);
    assert(ABIsPreLoginOrTransitionScene("login_entry") == true);

    // Before login has been seen or server entry started, unknown boot scene names must NOT falsely hide button.
    assert(ABIsInGameScene("custom_boot_logo", false, false) == false);
    assert(ABIsInGameScene("loading", false, false) == false);
    assert(ABIsInGameScene("login", false, false) == false);
    // "home" / "home_*" ALWAYS marks in-game immediately.
    assert(ABIsInGameScene("home", false, false) == true);
    assert(ABIsInGameScene("home_main", false, false) == true);

    // Once login has been seen or server entry started, entering story/battle/stage/building immediately marks in-game,
    // while transition/loading/login scenes do NOT falsely trigger in-game.
    assert(ABIsInGameScene("story", true, false) == true);
    assert(ABIsInGameScene("battle", true, false) == true);
    assert(ABIsInGameScene("stage", false, true) == true);
    assert(ABIsInGameScene("building", true, true) == true);
    assert(ABIsInGameScene("loading", true, true) == false);
    assert(ABIsInGameScene("login", true, true) == false);
    assert(ABIsInGameScene("", true, true) == false);

    // Entering-server watchdog only expires when stuck on login scene past timeout.
    assert(ABShouldExpireEnteringServer(true, false, true, 5.0, 15.0) == false);
    assert(ABShouldExpireEnteringServer(true, false, true, 15.0, 15.0) == true);
    assert(ABShouldExpireEnteringServer(true, true, true, 20.0, 15.0) == false);
    assert(ABShouldExpireEnteringServer(true, false, false, 20.0, 15.0) == false);
    assert(ABShouldExpireEnteringServer(false, false, true, 20.0, 15.0) == false);

    // Button visibility: hidden during login modal, entering-server handoff, or in-game.
    assert(ABShouldHideButtonForState(false, false, false) == false);
    assert(ABShouldHideButtonForState(false, true, false) == true);
    assert(ABShouldHideButtonForState(false, false, true) == true);
    assert(ABShouldHideButtonForState(true, false, false) == true);
    assert(ABShouldHideButtonForState(true, true, true) == true);
}

static void test_login_result(void) {
    NSError *err = nil;
    NSDictionary *ok1 = ABMakeU8LoginResult(@{@"uid": @"123456", @"access_key": @"tok-abc"}, &err);
    assert(ok1 != nil && err == nil);
    assert([ok1[@"uid"] isEqualToString:@"123456"]);
    assert([ok1[@"access_token"] isEqualToString:@"tok-abc"]);
    assert([ok1[@"isSuc"] boolValue] == YES);

    NSDictionary *ok2 = ABMakeU8LoginResult(@{@"uid": @987654321ULL, @"access_key": @"  tok  "}, &err);
    assert(ok2 != nil && err == nil);
    assert([ok2[@"uid"] isEqualToString:@"987654321"]);
    assert([ok2[@"access_token"] isEqualToString:@"  tok  "]);

    // Reject boolean / float / decimal / zero / non-digit UIDs and blank access keys.
    assert(ABMakeU8LoginResult(@{@"uid": @YES, @"access_key": @"tok"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@{@"uid": @1.5, @"access_key": @"tok"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@{@"uid": [NSDecimalNumber decimalNumberWithString:@"42"], @"access_key": @"tok"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@{@"uid": @"0000", @"access_key": @"tok"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@{@"uid": @"12a4", @"access_key": @"tok"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@{@"uid": @"123", @"access_key": @"   \n"}, &err) == nil && err != nil);
    assert(ABMakeU8LoginResult(@"not-a-dict", &err) == nil);
}

int main(void) {
    @autoreleasepool {
        test_attempt_gate();
        test_scene_gate_and_hosts();
        test_scene_classification_and_button_visibility();
        test_login_result();
        printf("OK: Bridge core unit tests passed (ABPolicy + ABLoginResult)\n");
    }
    return 0;
}
