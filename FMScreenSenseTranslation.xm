#import "FMScreenSenseTranslation.h"

#import <UIKit/UIKit.h>

#import "FLMDiagnostics.h"

static CFStringRef const kFLMTranslationPreferencesDomain =
    CFSTR("com.codex.flymemultitasking");
static NSString *const kFLMDefaultTranslationTargetLanguage = @"zh-CN";
static NSString *const kFLMDefaultTranslationAPIURL =
    @"https://translation.googleapis.com/language/translate/v2";

static id FLMCopyTranslationPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue(
        (__bridge CFStringRef)key,
        kFLMTranslationPreferencesDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static NSString *FLMStringTranslationPreference(NSString *key,
                                                 NSString *fallback) {
    id value = FLMCopyTranslationPreference(key);
    if (![value isKindOfClass:[NSString class]]) {
        return fallback;
    }
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
                                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return string.length > 0 ? string : fallback;
}

static NSString *FLMValidatedTranslationLanguage(void) {
    NSString *language = FLMStringTranslationPreference(
        FLM_TRANSLATION_TARGET_LANGUAGE_KEY,
        kFLMDefaultTranslationTargetLanguage);
    if (language.length > 32) {
        return kFLMDefaultTranslationTargetLanguage;
    }
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
                           @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" ];
    if ([language rangeOfCharacterFromSet:[allowed invertedSet]].location !=
        NSNotFound) {
        return kFLMDefaultTranslationTargetLanguage;
    }
    return language;
}

static NSError *FLMTranslationError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"com.codex.flymemultitasking.translation"
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSString *FLMTranslationStringFromJSON(id object) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;

        // Google Cloud Translation v2 response:
        // { data: { translations: [{ translatedText: "..." }] } }
        id data = dictionary[@"data"];
        if ([data isKindOfClass:[NSDictionary class]]) {
            id translations = data[@"translations"];
            if ([translations isKindOfClass:[NSArray class]]) {
                for (id translation in (NSArray *)translations) {
                    NSString *value = FLMTranslationStringFromJSON(translation);
                    if (value.length > 0) {
                        return value;
                    }
                }
            }
            NSString *nested = FLMTranslationStringFromJSON(data);
            if (nested.length > 0) {
                return nested;
            }
        }

        NSArray<NSString *> *preferredKeys = @[
            @"translatedText", @"translation", @"translated", @"result", @"text"
        ];
        for (NSString *key in preferredKeys) {
            id value = dictionary[key];
            if ([value isKindOfClass:[NSString class]]) {
                NSString *text = [(NSString *)value
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (text.length > 0) {
                    return text;
                }
            }
        }

        // Accept common wrappers such as {data: "..."} or {response: {...}}
        // without treating arbitrary diagnostic fields as translation text.
        for (NSString *key in @[@"response", @"output", @"data"]) {
            NSString *nested = FLMTranslationStringFromJSON(dictionary[key]);
            if (nested.length > 0) {
                return nested;
            }
        }
        return nil;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            NSString *text = FLMTranslationStringFromJSON(value);
            if (text.length > 0) {
                return text;
            }
        }
    }

    if ([object isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)object
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return text.length > 0 ? text : nil;
    }
    return nil;
}

static NSURL *FLMAppendAPIKeyToURL(NSURL *url, NSString *apiKey) {
    if (apiKey.length == 0) {
        return url;
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return url;
    }
    NSMutableArray<NSURLQueryItem *> *items =
        [components.queryItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"key" value:apiKey]];
    components.queryItems = items;
    return components.URL ?: url;
}

@interface FMScreenSenseTranslation ()
@end

@implementation FMScreenSenseTranslation

+ (instancetype)sharedService {
    static FMScreenSenseTranslation *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[self alloc] init];
    });
    return service;
}

- (NSString *)providerIdentifier {
    NSString *provider = FLMStringTranslationPreference(
        FLM_TRANSLATION_PROVIDER_KEY,
        FLM_TRANSLATION_PROVIDER_WEB);
    if (![provider isEqualToString:FLM_TRANSLATION_PROVIDER_CUSTOM]) {
        return FLM_TRANSLATION_PROVIDER_WEB;
    }
    return FLM_TRANSLATION_PROVIDER_CUSTOM;
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

    // A URL is the transport for the web provider. Keep it bounded so a very
    // large OCR transcript does not create an unusable browser URL.
    NSUInteger maximumLength = 8000;
    if (value.length > maximumLength) {
        value = [value substringToIndex:maximumLength];
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

- (void)translateText:(NSString *)text
           completion:(void (^)(NSString *_Nullable translatedText,
                                NSError *_Nullable error))completion {
    NSString *value = [text stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, FLMTranslationError(1, @"没有可翻译的文字"));
        });
        return;
    }

    NSString *endpointString = FLMStringTranslationPreference(
        FLM_TRANSLATION_API_URL_KEY,
        kFLMDefaultTranslationAPIURL);
    NSURL *endpoint = [NSURL URLWithString:endpointString];
    NSString *scheme = endpoint.scheme.lowercaseString;
    if (!endpoint || !([scheme isEqualToString:@"https"] ||
                       [scheme isEqualToString:@"http"])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, FLMTranslationError(2, @"自定义 API 地址无效"));
        });
        return;
    }

    NSString *apiKey = FLMStringTranslationPreference(
        FLM_TRANSLATION_API_KEY_KEY, @"");
    if (apiKey.length == 0 &&
        [endpoint.host.lowercaseString containsString:@"googleapis.com"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, FLMTranslationError(11, @"请先在翻译设置中填写 Google Cloud API Key"));
        });
        return;
    }
    NSURL *requestURL = FLMAppendAPIKeyToURL(endpoint, apiKey);
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:requestURL
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:20.0];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (apiKey.length > 0 &&
        ![endpoint.host.lowercaseString containsString:@"googleapis.com"]) {
        // Google Cloud v2 consumes the query key. For non-Google custom
        // endpoints, also offer the common bearer-token convention.
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];
    }

    NSDictionary *payload = @{
        @"q" : @[value],
        @"target" : self.targetLanguage,
        @"format" : @"text",
    };
    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload
                                                         options:0
                                                           error:&serializationError];
    if (!request.HTTPBody) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, serializationError ?: FLMTranslationError(3, @"请求无法编码"));
        });
        return;
    }

    NSString *host = endpoint.host ?: @"<custom>";
    FLMEnqueueDiagnosticLine(
        @"[ScreenSense][Translation] provider=custom request host=%@ textLength=%lu",
        host, (unsigned long)value.length);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data,
                                                            NSURLResponse *response,
                                                            NSError *error) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (error) {
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Translation][ERROR] provider=custom network=%@",
                error.localizedDescription ?: @"unknown");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        if (statusCode < 200 || statusCode >= 300) {
            NSString *body = [[NSString alloc] initWithData:data
                                                    encoding:NSUTF8StringEncoding];
            NSString *description = body.length > 0
                ? [NSString stringWithFormat:@"翻译服务返回 HTTP %ld：%@",
                                             (long)statusCode,
                                             [body substringToIndex:MIN(body.length, (NSUInteger)160)]]
                : [NSString stringWithFormat:@"翻译服务返回 HTTP %ld", (long)statusCode];
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Translation][ERROR] provider=custom status=%ld",
                (long)statusCode);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, FLMTranslationError(statusCode, description));
            });
            return;
        }

        NSError *jsonError = nil;
        id json = data.length > 0
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]
            : nil;
        NSString *translatedText = FLMTranslationStringFromJSON(json);
        if (translatedText.length == 0) {
            NSString *description = jsonError
                ? @"翻译服务返回的不是有效 JSON"
                : @"翻译服务返回中没有找到翻译结果";
            FLMEnqueueDiagnosticLine(
                @"[ScreenSense][Translation][ERROR] provider=custom status=%ld parse=failed",
                (long)statusCode);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, FLMTranslationError(4, description));
            });
            return;
        }

        FLMEnqueueDiagnosticLine(
            @"[ScreenSense][Translation] provider=custom status=%ld resultLength=%lu",
            (long)statusCode, (unsigned long)translatedText.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(translatedText, nil);
        });
    }];
    [task resume];
}

@end
