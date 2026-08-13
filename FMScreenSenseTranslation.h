#ifndef FLM_SCREEN_SENSE_TRANSLATION_H
#define FLM_SCREEN_SENSE_TRANSLATION_H

#import <Foundation/Foundation.h>

// These keys are shared by the SpringBoard tweak and the PreferenceBundle.
// Keep them as macros because the two targets are linked independently.
#define FLM_TRANSLATION_PROVIDER_KEY @"screenSenseTranslationProvider"
#define FLM_TRANSLATION_TARGET_LANGUAGE_KEY @"screenSenseTranslationTargetLanguage"
#define FLM_TRANSLATION_API_URL_KEY @"screenSenseTranslationAPIURL"
#define FLM_TRANSLATION_API_KEY_KEY @"screenSenseTranslationAPIKey"

#define FLM_TRANSLATION_PROVIDER_WEB @"web"
#define FLM_TRANSLATION_PROVIDER_CUSTOM @"custom"

NS_ASSUME_NONNULL_BEGIN

/// The translation service is intentionally independent from Live Text. Live
/// Text remains responsible for OCR, selection, and Copy; this service only
/// consumes the resulting text and executes the configured translation route.
@interface FMScreenSenseTranslation : NSObject

+ (instancetype)sharedService;

/// Returns a Google Translate URL containing the supplied text. This route is
/// the default and does not perform a request from SpringBoard.
- (nullable NSURL *)webURLForText:(NSString *)text;

/// Sends a Google Cloud Translation v2-compatible JSON request to the custom
/// endpoint configured in Preferences. The completion is delivered on main.
- (void)translateText:(NSString *)text
           completion:(void (^)(NSString *_Nullable translatedText,
                                NSError *_Nullable error))completion;

/// Human-readable provider identifier used for diagnostics and UI state.
- (NSString *)providerIdentifier;

/// The configured target language, defaulting to zh-CN.
- (NSString *)targetLanguage;

@end

NS_ASSUME_NONNULL_END

#endif
