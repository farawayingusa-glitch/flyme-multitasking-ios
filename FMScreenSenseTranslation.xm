#import "FMScreenSenseTranslation.h"

#import <UIKit/UIKit.h>

static CFStringRef const kFLMTranslationPreferencesDomain =
    CFSTR("com.codex.flymemultitasking");
static NSString *const kFLMDefaultTranslationTargetLanguage = @"zh-CN";

static id FLMCopyTranslationPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue(
        (__bridge CFStringRef)key,
        kFLMTranslationPreferencesDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static NSString *FLMValidatedTranslationLanguage(void) {
    id value = FLMCopyTranslationPreference(FLM_TRANSLATION_TARGET_LANGUAGE_KEY);
    NSString *language = [value isKindOfClass:[NSString class]]
                             ? [(NSString *)value
                                   stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                             : @"";
    if (language.length == 0 || language.length > 32) {
        return kFLMDefaultTranslationTargetLanguage;
    }

    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
                           @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    if ([language rangeOfCharacterFromSet:[allowed invertedSet]].location !=
        NSNotFound) {
        return kFLMDefaultTranslationTargetLanguage;
    }
    return language;
}

@implementation FMScreenSenseTranslation

+ (instancetype)sharedService {
    static FMScreenSenseTranslation *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[self alloc] init];
    });
    return service;
}

- (NSString *)targetLanguage {
    return FLMValidatedTranslationLanguage();
}

- (NSURL *)webURLForText:(NSString *)text {
    NSString *value = [text stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0) {
        return nil;
    }

    // Keep the URL bounded so a long OCR transcript does not make the browser
    // request unusable. The browser performs the actual translation.
    if (value.length > 8000) {
        value = [value substringToIndex:8000];
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://translate.google.com/"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:self.targetLanguage],
        [NSURLQueryItem queryItemWithName:@"text" value:value],
        [NSURLQueryItem queryItemWithName:@"op" value:@"translate"],
    ];
    return components.URL;
}

@end
