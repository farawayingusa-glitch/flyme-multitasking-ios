#ifndef FLM_SCREEN_SENSE_TRANSLATION_H
#define FLM_SCREEN_SENSE_TRANSLATION_H

#import <Foundation/Foundation.h>

// This key is shared by the SpringBoard tweak and the PreferenceBundle.
// Keep it as a macro because the two targets are linked independently.
#define FLM_TRANSLATION_TARGET_LANGUAGE_KEY @"screenSenseTranslationTargetLanguage"

NS_ASSUME_NONNULL_BEGIN

/// Live Text remains responsible for OCR, selection, and Copy. This service
/// only builds the system-independent Google Translate web URL; it never sends
/// a request, stores credentials, or implements a third-party API client.
@interface FMScreenSenseTranslation : NSObject

+ (instancetype)sharedService;

/// Returns a Google Translate URL containing the supplied text.
- (nullable NSURL *)webURLForText:(NSString *)text;

/// The configured target language, defaulting to zh-CN.
- (NSString *)targetLanguage;

@end

NS_ASSUME_NONNULL_END

#endif
