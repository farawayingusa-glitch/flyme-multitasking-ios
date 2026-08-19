#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>

static NSString *const FLMLandscapePreferencesDomain =
    @"com.codex.flymelandscape";
static NSString *const FLMLandscapeLegacyPreferencesDomain =
    @"com.codex.flymemultitasking";
static NSString *const FLMLandscapePreferencesNotification =
    @"com.codex.flymelandscape.preferences-changed";
static NSString *const FLMLandscapeLegacyLockScreenItem =
    @"com.codex.flymemultitasking.lockscreen";

@interface NSObject (FLMLandscapePreferencesPrivate)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSString *)applicationIdentifier;
- (NSString *)applicationType;
- (NSString *)localizedName;
- (BOOL)isLaunchProhibited;
- (BOOL)isPlaceholder;
@end

static id FLMLandscapeCopyPreferenceFromDomain(NSString *domain,
                                                NSString *key) {
    CFPreferencesSynchronize((__bridge CFStringRef)domain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    return CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)domain));
}

static id FLMLandscapeCopyPreference(NSString *key) {
    id value = FLMLandscapeCopyPreferenceFromDomain(
        FLMLandscapePreferencesDomain, key);
    if (value != nil) {
        return value;
    }
    return FLMLandscapeCopyPreferenceFromDomain(
        FLMLandscapeLegacyPreferencesDomain, key);
}

static void FLMLandscapeSetPreference(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          (__bridge CFStringRef)FLMLandscapePreferencesDomain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)FLMLandscapePreferencesDomain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    notify_post(FLMLandscapePreferencesNotification.UTF8String);
}

static NSArray<NSString *> *FLMLandscapeWheelItems(void) {
    id value = FLMLandscapeCopyPreference(@"wheelItems");
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id candidate in (NSArray *)value) {
        if (![candidate isKindOfClass:[NSString class]] ||
            [(NSString *)candidate length] == 0 ||
            [(NSString *)candidate isEqualToString:
                FLMLandscapeLegacyLockScreenItem]) {
            continue;
        }
        [items addObject:candidate];
    }
    return [items copy];
}

static NSArray<NSDictionary<NSString *, id> *> *FLMLandscapeInstalledApplications(void) {
    id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
    NSArray *proxies = [workspace allInstalledApplications];
    NSMutableArray<NSDictionary<NSString *, id> *> *applications =
        [NSMutableArray array];
    for (id proxy in proxies) {
        NSString *identifier = [proxy applicationIdentifier];
        NSString *name = [proxy localizedName];
        NSString *type = [proxy applicationType];
        if (identifier.length == 0 || name.length == 0) {
            continue;
        }
        if ([proxy respondsToSelector:@selector(isPlaceholder)] &&
            [proxy isPlaceholder]) {
            continue;
        }
        if ([proxy respondsToSelector:@selector(isLaunchProhibited)] &&
            [proxy isLaunchProhibited]) {
            continue;
        }
        if (type.length > 0 && ![type isEqualToString:@"User"] &&
            ![type isEqualToString:@"System"]) {
            continue;
        }
        [applications addObject:@{
            @"identifier" : identifier,
            @"name" : name,
        }];
    }
    [applications sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                           NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    return [applications copy];
}

@interface FLMLandscapeRootListController : PSListController
@end

@interface FLMLandscapeAppListController : PSListController
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *applications;
@end

@implementation FLMLandscapeRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (NSNumber *)landscapeEnabled:(PSSpecifier *)specifier {
    (void)specifier;
    id value = FLMLandscapeCopyPreference(@"enabled");
    return @(![value isKindOfClass:[NSNumber class]] || [value boolValue]);
}

- (void)setLandscapeEnabled:(NSNumber *)value
                   specifier:(PSSpecifier *)specifier {
    (void)specifier;
    FLMLandscapeSetPreference(@"enabled", @([value boolValue]));
}

@end

@implementation FLMLandscapeAppListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"应用管理";
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.applications = FLMLandscapeInstalledApplications();
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) {
        return _specifiers;
    }
    self.applications = FLMLandscapeInstalledApplications();
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"横屏轮盘应用"];
    [group setProperty:@"勾选后应用会加入横屏轮盘。"
               forKey:@"footerText"];
    [specifiers addObject:group];
    for (NSDictionary *application in self.applications) {
        NSString *identifier = application[@"identifier"];
        PSSpecifier *specifier =
            [PSSpecifier preferenceSpecifierNamed:application[@"name"]
                                           target:self
                                              set:@selector(setItemEnabled:specifier:)
                                              get:@selector(itemEnabled:)
                                           detail:nil
                                             cell:PSSwitchCell
                                             edit:nil];
        [specifier setProperty:identifier forKey:@"itemIdentifier"];
        [specifiers addObject:specifier];
    }
    _specifiers = [specifiers copy];
    return _specifiers;
}

- (NSNumber *)itemEnabled:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"itemIdentifier"];
    return @([FLMLandscapeWheelItems() containsObject:identifier]);
}

- (void)setItemEnabled:(NSNumber *)value
             specifier:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"itemIdentifier"];
    if (identifier.length == 0) {
        return;
    }
    NSMutableArray<NSString *> *items =
        [FLMLandscapeWheelItems() mutableCopy];
    if ([value boolValue]) {
        if (![items containsObject:identifier]) {
            [items addObject:identifier];
        }
    } else {
        [items removeObject:identifier];
    }
    FLMLandscapeSetPreference(@"wheelItems", items);
}

@end
