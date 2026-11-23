#import "ABLoginResult.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

// 0x465c..0x476c
static id ABInvalid(NSError **error, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"ABLoginAdapter" code:1
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return nil;
}

// 0x4000..0x465c. Validation and output keys recovered instruction by
// instruction, including rejection of Boolean/float/decimal UID objects.
NSDictionary *ABMakeU8LoginResult(id result, NSError **error) {
    if (error) *error = nil;
    if (![result isKindOfClass:NSDictionary.class])
        return ABInvalid(error, @"SDK result must be a dictionary");
    id rawUID = result[@"uid"];
    NSString *uid = nil;
    if ([rawUID isKindOfClass:NSString.class]) {
        uid = [rawUID copy];
    } else if ([rawUID isKindOfClass:NSNumber.class]) {
        const char *type = [rawUID objCType];
        if (CFGetTypeID((__bridge CFTypeRef)rawUID) == CFBooleanGetTypeID() ||
            [rawUID isKindOfClass:NSDecimalNumber.class] ||
            strlen(type) != 1 || !strchr("cCsSiIlLqQ", type[0]))
            return ABInvalid(error, @"UID must be an exact positive integer or decimal string");
        uid = [rawUID stringValue];
    }
    if (uid.length == 0)
        return ABInvalid(error, @"SDK result has no UID; game_open_id is not a substitute");
    bool positive = false;
    for (NSUInteger i = 0; i < uid.length; ++i) {
        unichar c = [uid characterAtIndex:i];
        if (c < '0' || c > '9')
            return ABInvalid(error, @"UID contains non-decimal characters");
        positive |= c != '0';
    }
    if (!positive) return ABInvalid(error, @"UID must be positive");
    id key = result[@"access_key"];
    if (![key isKindOfClass:NSString.class] || [key length] == 0 ||
        [[key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0)
        return ABInvalid(error, @"SDK result has no nonempty access_key");
    // Whitespace is checked but the original untrimmed key is forwarded.
    return @{@"uid": uid, @"access_token": [key copy], @"isSuc": @YES};
}
