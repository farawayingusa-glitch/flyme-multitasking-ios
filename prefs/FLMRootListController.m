#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <math.h>
#import <notify.h>
#import <signal.h>
#import <stdint.h>

#import "../FMScreenSenseTranslation.h"

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION "com.codex.flymemultitasking.preferences-changed"
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"
#define FLYME_SCREEN_SENSE_ITEM @"com.codex.flymemultitasking.screensense"
#define FLYME_SCREEN_SENSE_ENABLED 1

static NSString *const FLMDiagnosticPrimaryPath =
    @"/var/jb/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";
static NSString *const FLMDiagnosticFallbackPath =
    @"/var/mobile/Library/Preferences/FlymeMultitasking-Diagnostic.log";

@interface NSObject (FLMPreferencesPrivate)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSString *)applicationIdentifier;
- (NSString *)applicationType;
- (NSString *)localizedName;
- (BOOL)isLaunchProhibited;
- (BOOL)isPlaceholder;
@end

@interface UIImage (FLMPreferencesPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

static id FLMCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                      FLYME_PREFERENCES_DOMAIN,
                                                      kCFPreferencesCurrentUser,
                                                      kCFPreferencesAnyHost);
    return CFBridgingRelease(value);
}

static void FLMSetPreference(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          FLYME_PREFERENCES_DOMAIN,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(FLYME_PREFERENCES_DOMAIN,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    notify_post(FLYME_PREFERENCES_NOTIFICATION);
}

static NSArray<NSString *> *FLMDiagnosticBasePaths(void) {
    return @[FLMDiagnosticPrimaryPath, FLMDiagnosticFallbackPath];
}

static NSString *FLMActiveDiagnosticPath(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *newestPath = nil;
    NSDate *newestDate = nil;
    for (NSString *path in FLMDiagnosticBasePaths()) {
        NSDictionary *attributes =
            [manager attributesOfItemAtPath:path error:nil];
        NSDate *date = attributes[NSFileModificationDate];
        if (attributes && (!newestDate || [date compare:newestDate] ==
                                           NSOrderedDescending)) {
            newestPath = path;
            newestDate = date;
        }
    }
    return newestPath;
}

static NSData *FLMCompleteDiagnosticData(void) {
    NSString *path = FLMActiveDiagnosticPath();
    if (path.length == 0) {
        return nil;
    }
    NSMutableData *result = [NSMutableData data];
    NSString *previousPath = [path stringByAppendingString:@".previous"];
    NSData *previous = [NSData dataWithContentsOfFile:previousPath];
    if (previous.length > 0) {
        [result appendData:previous];
        const char separator[] = "\n--- current log ---\n";
        [result appendBytes:separator length:sizeof(separator) - 1];
    }
    NSData *current = [NSData dataWithContentsOfFile:path];
    if (current.length > 0) {
        [result appendData:current];
    }
    return result.length > 0 ? result : nil;
}

static NSString *FLMDiagnosticStatusText(void) {
    NSString *path = FLMActiveDiagnosticPath();
    NSData *data = FLMCompleteDiagnosticData();
    if (path.length == 0 || data.length == 0) {
        return @"暂无日志";
    }
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *date = attributes[NSFileModificationDate];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"MM-dd HH:mm";
    NSString *dateText = date ? [formatter stringFromDate:date] : @"未知时间";
    CGFloat kibibytes = (CGFloat)data.length / 1024.0;
    return [NSString stringWithFormat:@"%.1f KB · %@", kibibytes, dateText];
}

@interface FLMDiagnosticLogController : UIViewController
@property(nonatomic, copy) NSString *logText;
@end

@implementation FLMDiagnosticLogController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11.0
                                               weight:UIFontWeightRegular];
    textView.text = self.logText ?: @"暂无诊断日志。";
    [self.view addSubview:textView];
}

@end

static NSArray<NSString *> *FLMWheelItems(void) {
    id value = FLMCopyPreference(@"wheelItems");
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static BOOL FlymeRuntimeIsConnected(void) {
    int token = -1;
    uint64_t state = 0;
    if (notify_register_check(FLYME_RUNTIME_NOTIFICATION, &token) != NOTIFY_STATUS_OK) {
        return NO;
    }

    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    if (status != NOTIFY_STATUS_OK || (state >> 32) != FLYME_RUNTIME_MAGIC) {
        return NO;
    }

    pid_t processIdentifier = (pid_t)(state & 0xffffffffULL);
    if (processIdentifier <= 1) {
        return NO;
    }
    if (kill(processIdentifier, 0) == 0) {
        return YES;
    }
    return errno == EPERM;
}

static NSArray<NSDictionary<NSString *, id> *> *FLMInstalledApplications(void) {
    id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
    NSArray *proxies = [workspace allInstalledApplications];
    NSMutableArray<NSDictionary<NSString *, id> *> *applications = [NSMutableArray array];
    for (id proxy in proxies) {
        NSString *identifier = [proxy applicationIdentifier];
        NSString *name = [proxy localizedName];
        NSString *type = [proxy applicationType];
        if (identifier.length == 0 || name.length == 0) {
            continue;
        }
        if ([proxy respondsToSelector:@selector(isPlaceholder)] && [proxy isPlaceholder]) {
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
    return applications;
}

static UIImage *FLMIconForIdentifier(NSString *identifier) {
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return [UIImage systemImageNamed:@"lock.fill"];
    }
    if ([identifier isEqualToString:FLYME_SCREEN_SENSE_ITEM]) {
        UIImage *image = [UIImage systemImageNamed:@"text.viewfinder"];
        if (!image) {
            image = [UIImage systemImageNamed:@"viewfinder"];
        }
        return [image imageWithTintColor:[UIColor labelColor]
                            renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    if ([UIImage respondsToSelector:
                     @selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return [UIImage _applicationIconImageForBundleIdentifier:identifier
                                                          format:1
                                                           scale:[UIScreen mainScreen].scale];
    }
    return nil;
}

static NSString *FLMNameForIdentifier(
    NSString *identifier,
    NSArray<NSDictionary<NSString *, id> *> *applications) {
    if ([identifier isEqualToString:FLYME_LOCK_SCREEN_ITEM]) {
        return @"锁屏";
    }
    if ([identifier isEqualToString:FLYME_SCREEN_SENSE_ITEM]) {
        return @"识屏";
    }
    for (NSDictionary *application in applications) {
        if ([application[@"identifier"] isEqualToString:identifier]) {
            return application[@"name"];
        }
    }
    return identifier.length > 0 ? identifier : @"未知项目";
}

@interface FLMWheelSliderCell : PSTableCell
@property(nonatomic, strong) UILabel *settingTitleLabel;
@property(nonatomic, strong) UIButton *valueButton;
@property(nonatomic, strong) UIButton *defaultButton;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy) NSString *preferenceKey;
@property(nonatomic, assign) CGFloat minimumValue;
@property(nonatomic, assign) CGFloat maximumValue;
@property(nonatomic, assign) CGFloat defaultValue;
@property(nonatomic, assign) CGFloat inputStep;
@property(nonatomic, assign) CGFloat valueBeforeEditing;
@end

@implementation FLMWheelSliderCell

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 92.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // PSTableCell may also render the specifier label through its
        // inherited textLabel. The custom slider layout owns the title, so
        // hide the inherited label to avoid the duplicated bottom captions
        // shown for card size, wheel radius, and icon size.
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];
        _minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
        _maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
        _defaultValue = [[specifier propertyForKey:@"defaultValue"] doubleValue];
        _inputStep = [[specifier propertyForKey:@"inputStep"] doubleValue];
        if (_inputStep <= 0.0 || !isfinite(_inputStep)) {
            _inputStep = 1.0;
        }

        _settingTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _settingTitleLabel.text = specifier.name;
        _settingTitleLabel.font = [UIFont systemFontOfSize:16.0];
        [self.contentView addSubview:_settingTitleLabel];

        _valueButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _valueButton.titleLabel.font =
            [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        [_valueButton setTitleColor:[UIColor secondaryLabelColor]
                            forState:UIControlStateNormal];
        _valueButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        [_valueButton addTarget:self
                         action:@selector(valueButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
        _valueButton.accessibilityHint = @"点按后使用数字键盘输入";
        [self.contentView addSubview:_valueButton];

        _defaultButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_defaultButton setTitle:@"默认" forState:UIControlStateNormal];
        _defaultButton.titleLabel.font =
            [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        _defaultButton.backgroundColor = [UIColor tertiarySystemFillColor];
        _defaultButton.layer.cornerRadius = 12.0;
        [_defaultButton addTarget:self
                           action:@selector(resetToDefault)
                 forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_defaultButton];

        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        _slider.minimumValue = (float)_minimumValue;
        _slider.maximumValue = (float)_maximumValue;
        _slider.continuous = YES;
        [_slider addTarget:self
                    action:@selector(sliderValueChanged:)
          forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self
                    action:@selector(commitSliderValue)
          forControlEvents:UIControlEventTouchUpInside |
                           UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel];
        [self.contentView addSubview:_slider];

        id storedValue = FLMCopyPreference(_preferenceKey);
        CGFloat value = [storedValue isKindOfClass:[NSNumber class]]
                            ? [storedValue doubleValue]
                            : _defaultValue;
        _slider.value = (float)[self normalizedValue:value];
        [self updateValueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat valueWidth = 86.0;
    CGFloat valueRightInset = 154.0;
    CGFloat titleRightInset = 174.0;
    self.settingTitleLabel.frame = CGRectMake(16.0,
                                               9.0,
                                               width - titleRightInset,
                                               24.0);
    self.defaultButton.frame = CGRectMake(width - 66.0, 8.0, 50.0, 25.0);
    self.valueButton.frame = CGRectMake(width - valueRightInset,
                                         6.0,
                                         valueWidth,
                                         30.0);
    self.slider.frame = CGRectMake(16.0, 41.0, width - 32.0, 42.0);
}

- (void)sliderValueChanged:(UISlider *)slider {
    slider.value = (float)[self normalizedValue:slider.value];
    [self updateValueLabel];
}

- (void)commitSliderValue {
    [self commitCurrentValue];
}

- (void)resetToDefault {
    [self.slider setValue:(float)[self normalizedValue:self.defaultValue]
                animated:YES];
    [self updateValueLabel];
    [self commitCurrentValue];
}

- (void)updateValueLabel {
    NSString *text = [NSString stringWithFormat:@"%ld pt",
                      (long)lround([self normalizedValue:self.slider.value])];
    [self.valueButton setTitle:text forState:UIControlStateNormal];
}

- (CGFloat)normalizedValue:(CGFloat)value {
    if (!isfinite(value)) {
        value = self.defaultValue;
    }
    value = MAX(self.minimumValue, MIN(self.maximumValue, value));
    value = round(value / self.inputStep) * self.inputStep;
    return MAX(self.minimumValue, MIN(self.maximumValue, value));
}

- (void)commitCurrentValue {
    if (self.preferenceKey.length == 0) {
        return;
    }
    self.slider.value = (float)[self normalizedValue:self.slider.value];
    FLMSetPreference(self.preferenceKey, @(self.slider.value));
}

- (UIViewController *)owningViewController {
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

- (void)restoreValueBeforeEditing {
    self.slider.value = (float)[self normalizedValue:self.valueBeforeEditing];
    [self updateValueLabel];
    [self commitCurrentValue];
}

- (void)showInvalidValueAlertForText:(NSString *)text {
    NSString *message = [NSString stringWithFormat:
        @"请输入 %.0f 至 %.0f 之间的数字。",
        self.minimumValue,
        self.maximumValue];
    if (text.length == 0) {
        message = @"请输入数字，或点击取消保留原值。";
    }
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"数值无效"
                                             message:message
                                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
    [[self owningViewController] presentViewController:alert
                                               animated:YES
                                             completion:nil];
}

- (void)valueButtonTapped {
    UIViewController *controller = [self owningViewController];
    if (!controller) {
        return;
    }

    self.valueBeforeEditing = [self normalizedValue:self.slider.value];
    NSString *initialText =
        [NSString stringWithFormat:@"%ld", (long)lround(self.valueBeforeEditing)];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:self.settingTitleLabel.text
                                             message:@"请输入数值（pt）"
                                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = initialText;
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.accessibilityLabel = self.settingTitleLabel.text;
    }];

    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                               style:UIAlertActionStyleCancel
                                             handler:^(__unused UIAlertAction *action) {
        [weakSelf restoreValueBeforeEditing];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        FLMWheelSliderCell *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSString *text = [[weakAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double parsedValue = 0.0;
        BOOL valid = text.length > 0 && [scanner scanDouble:&parsedValue] &&
                     scanner.isAtEnd && isfinite(parsedValue) &&
                     parsedValue >= strongSelf.minimumValue &&
                     parsedValue <= strongSelf.maximumValue;
        if (!valid) {
            [strongSelf restoreValueBeforeEditing];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showInvalidValueAlertForText:text];
            });
            return;
        }
        strongSelf.slider.value = (float)[strongSelf normalizedValue:parsedValue];
        [strongSelf updateValueLabel];
        [strongSelf commitCurrentValue];
    }]];
    [controller presentViewController:alert animated:YES completion:^{
        [alert.textFields.firstObject becomeFirstResponder];
    }];
}

@end

@interface FLMRootListController : PSListController
@end

@interface FLMAppListController : PSListController
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *applications;
@end

@interface FLMTranslationSettingsController : PSViewController
    <UITextFieldDelegate>
@property(nonatomic, strong) UISegmentedControl *providerControl;
@property(nonatomic, strong) UITextField *targetLanguageField;
@property(nonatomic, strong) UITextField *apiURLField;
@property(nonatomic, strong) UITextField *apiKeyField;
@property(nonatomic, strong) UILabel *providerDescriptionLabel;
@end

@interface FLMAppOrderController
    : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *items;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *applications;
@property(nonatomic, strong) UITableView *tableView;
- (BOOL)removeWheelItemAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation FLMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifierID:@"runtime-status" animated:NO];
    [self reloadSpecifierID:@"diagnostic-status" animated:NO];
}

- (NSNumber *)flymeEnabled:(PSSpecifier *)specifier {
    (void)specifier;
    id value = FLMCopyPreference(@"enabled");
    return @([value isKindOfClass:[NSNumber class]] && [value boolValue]);
}

- (void)setFlymeEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    (void)specifier;
    FLMSetPreference(@"enabled", @([value boolValue]));
}

- (NSString *)runtimeStatus:(PSSpecifier *)specifier {
    (void)specifier;
    return FlymeRuntimeIsConnected() ? @"已连接" : @"未连接";
}

- (NSString *)diagnosticStatus:(PSSpecifier *)specifier {
    (void)specifier;
    return FLMDiagnosticStatusText();
}

- (void)showDiagnosticAlertWithTitle:(NSString *)title
                             message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareDiagnosticLog:(PSSpecifier *)specifier {
    (void)specifier;
    NSData *data = FLMCompleteDiagnosticData();
    if (data.length == 0) {
        [self showDiagnosticAlertWithTitle:@"暂无日志"
                                  message:@"请先复现问题，再点击分享诊断日志。"];
        return;
    }
    NSString *snapshotPath =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"FlymeMultitasking-Diagnostic.log"];
    if (![data writeToFile:snapshotPath options:NSDataWritingAtomic error:nil]) {
        [self showDiagnosticAlertWithTitle:@"无法准备日志"
                                  message:@"请稍后重试，或先打开日志确认文件状态。"];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:snapshotPath];
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                          applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                        CGRectGetMidY(self.view.bounds),
                                        1.0,
                                        1.0);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)openDiagnosticLog:(PSSpecifier *)specifier {
    (void)specifier;
    NSData *data = FLMCompleteDiagnosticData();
    NSString *text = data.length > 0
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"暂无诊断日志。请先复现问题，再返回此页面查看或分享。";
    FLMDiagnosticLogController *controller =
        [[FLMDiagnosticLogController alloc] init];
    controller.logText = text ?: @"日志不是有效的 UTF-8 文本。";
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)clearDiagnosticLog:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"清除诊断日志？"
                                            message:@"清除后不可恢复，之后的新操作仍会继续记录。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清除"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *path in FLMDiagnosticBasePaths()) {
            [manager removeItemAtPath:path error:nil];
            [manager removeItemAtPath:[path stringByAppendingString:@".previous"]
                                error:nil];
        }
        [weakSelf reloadSpecifierID:@"diagnostic-status" animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation FLMTranslationSettingsController

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder
                         secureEntry:(BOOL)secureEntry {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.secureTextEntry = secureEntry;
    field.delegate = self;
    field.returnKeyType = UIReturnKeyDone;
    [field addTarget:self
              action:@selector(textFieldEditingDidEnd:)
    forControlEvents:UIControlEventEditingDidEndOnExit |
                     UIControlEventEditingDidEnd];
    [field.heightAnchor constraintEqualToConstant:44.0].active = YES;
    return field;
}

- (UILabel *)labelWithText:(NSString *)text fontSize:(CGFloat)fontSize {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:fontSize];
    label.textColor = [UIColor labelColor];
    label.numberOfLines = 0;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"翻译设置";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10.0;
    stack.layoutMargins = UIEdgeInsetsMake(20.0, 16.0, 28.0, 16.0);
    stack.layoutMarginsRelativeArrangement = YES;
    [scrollView addSubview:stack];

    UILabel *intro = [self labelWithText:
        @"识屏后点击“翻译”即可执行。默认使用 Google 翻译网页跳转；如果以后配置 API，可切换到自定义 API，并在当前识屏窗口显示返回结果。"
                              fontSize:15.0];
    intro.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:intro];

    UILabel *providerTitle = [self labelWithText:@"翻译方式" fontSize:17.0];
    [stack addArrangedSubview:providerTitle];

    self.providerControl = [[UISegmentedControl alloc]
        initWithItems:@[@"网页跳转", @"自定义 API"]];
    self.providerControl.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *provider = FLMCopyPreference(FLM_TRANSLATION_PROVIDER_KEY);
    self.providerControl.selectedSegmentIndex =
        [provider isKindOfClass:[NSString class]] &&
                [provider isEqualToString:FLM_TRANSLATION_PROVIDER_CUSTOM]
            ? 1
            : 0;
    [self.providerControl addTarget:self
                             action:@selector(providerChanged:)
                   forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.providerControl];

    UILabel *targetTitle = [self labelWithText:@"目标语言" fontSize:17.0];
    [stack addArrangedSubview:targetTitle];
    self.targetLanguageField = [self fieldWithPlaceholder:@"例如 zh-CN、en、ja"
                                              secureEntry:NO];
    NSString *targetLanguage = FLMCopyPreference(FLM_TRANSLATION_TARGET_LANGUAGE_KEY);
    self.targetLanguageField.text =
        [targetLanguage isKindOfClass:[NSString class]] && targetLanguage.length > 0
            ? targetLanguage
            : @"zh-CN";
    self.targetLanguageField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [stack addArrangedSubview:self.targetLanguageField];

    UILabel *apiGroupTitle = [self labelWithText:@"自定义 API" fontSize:17.0];
    [stack addArrangedSubview:apiGroupTitle];

    self.apiURLField = [self fieldWithPlaceholder:
        @"API 地址（默认 Google Cloud v2）" secureEntry:NO];
    self.apiURLField.keyboardType = UIKeyboardTypeURL;
    self.apiURLField.textContentType = UITextContentTypeURL;
    NSString *apiURL = FLMCopyPreference(FLM_TRANSLATION_API_URL_KEY);
    self.apiURLField.text =
        [apiURL isKindOfClass:[NSString class]] && apiURL.length > 0
            ? apiURL
            : @"https://translation.googleapis.com/language/translate/v2";
    self.apiURLField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [stack addArrangedSubview:self.apiURLField];

    self.apiKeyField = [self fieldWithPlaceholder:@"API Key（可留空）"
                                       secureEntry:YES];
    self.apiKeyField.textContentType = UITextContentTypePassword;
    NSString *apiKey = FLMCopyPreference(FLM_TRANSLATION_API_KEY_KEY);
    self.apiKeyField.text = [apiKey isKindOfClass:[NSString class]] ? apiKey : @"";
    self.apiKeyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [stack addArrangedSubview:self.apiKeyField];

    self.providerDescriptionLabel = [self labelWithText:@"" fontSize:13.0];
    self.providerDescriptionLabel.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:self.providerDescriptionLabel];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [saveButton setTitle:@"保存设置" forState:UIControlStateNormal];
    saveButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    saveButton.backgroundColor = [UIColor systemBlueColor];
    [saveButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveButton.layer.cornerRadius = 11.0;
    [saveButton addTarget:self
                   action:@selector(saveButtonTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [saveButton.heightAnchor constraintEqualToConstant:46.0].active = YES;
    [stack addArrangedSubview:saveButton];

    UILabel *formatNote = [self labelWithText:
        @"自定义 API 按 Google Cloud Translation v2 的 JSON 格式发送：请求字段为 q、target、format，结果读取 data.translations[0].translatedText。网页跳转模式不需要 API Key。"
                                  fontSize:12.0];
    formatNote.textColor = [UIColor tertiaryLabelColor];
    [stack addArrangedSubview:formatNote];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];

    [self updateProviderDescriptionAndFields];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self saveSettings];
}

- (void)providerChanged:(UISegmentedControl *)control {
    FLMSetPreference(FLM_TRANSLATION_PROVIDER_KEY,
                     control.selectedSegmentIndex == 1
                         ? FLM_TRANSLATION_PROVIDER_CUSTOM
                         : FLM_TRANSLATION_PROVIDER_WEB);
    [self updateProviderDescriptionAndFields];
}

- (void)updateProviderDescriptionAndFields {
    BOOL custom = self.providerControl.selectedSegmentIndex == 1;
    self.apiURLField.enabled = custom;
    self.apiKeyField.enabled = custom;
    self.apiURLField.alpha = custom ? 1.0 : 0.45;
    self.apiKeyField.alpha = custom ? 1.0 : 0.45;
    self.providerDescriptionLabel.text = custom
        ? @"当前使用自定义 API。Google Cloud Translation v2 可直接使用默认地址，填入 API Key 后保存即可。"
        : @"当前使用网页跳转。翻译文字会带入 Google 翻译网页，不会在插件内发起网络请求。";
}

- (void)textFieldEditingDidEnd:(UITextField *)field {
    (void)field;
    [self saveSettings];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self saveSettings];
    return YES;
}

- (void)saveButtonTapped:(UIButton *)sender {
    (void)sender;
    [self saveSettings];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"已保存"
                                             message:@"下次打开识屏后即可使用新的翻译方式。"
                                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveSettings {
    if (!self.targetLanguageField) {
        return;
    }
    NSString *target = [self.targetLanguageField.text
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *apiURL = [self.apiURLField.text
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *apiKey = self.apiKeyField.text ?: @"";
    FLMSetPreference(FLM_TRANSLATION_TARGET_LANGUAGE_KEY,
                     target.length > 0 ? target : @"zh-CN");
    FLMSetPreference(FLM_TRANSLATION_API_URL_KEY,
                     apiURL.length > 0
                         ? apiURL
                         : @"https://translation.googleapis.com/language/translate/v2");
    FLMSetPreference(FLM_TRANSLATION_API_KEY_KEY, apiKey);
}

@end

@implementation FLMAppListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"应用管理";
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.applications = FLMInstalledApplications();
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) {
        return _specifiers;
    }

    self.applications = FLMInstalledApplications();
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];

    PSSpecifier *sortGroup = [PSSpecifier groupSpecifierWithName:nil];
    [sortGroup setProperty:@"拖动已加入的项目，调整它们在轮盘中的位置。"
                    forKey:@"footerText"];
    [specifiers addObject:sortGroup];

    PSSpecifier *sortSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"应用排序"
                                       target:self
                                          set:NULL
                                          get:NULL
                                       detail:[FLMAppOrderController class]
                                         cell:PSLinkCell
                                         edit:nil];
    [sortSpecifier setProperty:[UIImage systemImageNamed:@"line.3.horizontal"]
                        forKey:@"iconImage"];
    [specifiers addObject:sortSpecifier];

    PSSpecifier *translationSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"翻译设置"
                                       target:self
                                          set:NULL
                                          get:NULL
                                       detail:[FLMTranslationSettingsController class]
                                         cell:PSLinkCell
                                         edit:nil];
    UIImage *translationIcon = [UIImage systemImageNamed:@"character.bubble"];
    if (!translationIcon) {
        translationIcon = [UIImage systemImageNamed:@"globe"];
    }
    if (translationIcon) {
        [translationSpecifier setProperty:translationIcon forKey:@"iconImage"];
    }
    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"识屏翻译"]];
    [specifiers addObject:translationSpecifier];

    PSSpecifier *wheelGroup = [PSSpecifier groupSpecifierWithName:@"轮盘项目"];
    [wheelGroup setProperty:@"打开开关即可加入轮盘；关闭后会从轮盘和排序列表中移除。"
                     forKey:@"footerText"];
    [specifiers addObject:wheelGroup];

    [specifiers addObject:[self itemSpecifierWithName:@"锁屏"
                                           identifier:FLYME_LOCK_SCREEN_ITEM
                                                image:FLMIconForIdentifier(
                                                          FLYME_LOCK_SCREEN_ITEM)]];

    [specifiers addObject:[self itemSpecifierWithName:@"识屏"
                                           identifier:FLYME_SCREEN_SENSE_ITEM
                                                image:FLMIconForIdentifier(
                                                          FLYME_SCREEN_SENSE_ITEM)]];

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"应用"]];
    for (NSDictionary *application in self.applications) {
        NSString *identifier = application[@"identifier"];
        [specifiers addObject:[self itemSpecifierWithName:application[@"name"]
                                               identifier:identifier
                                                    image:FLMIconForIdentifier(identifier)]];
    }

    _specifiers = [specifiers copy];
    return _specifiers;
}

- (PSSpecifier *)itemSpecifierWithName:(NSString *)name
                            identifier:(NSString *)identifier
                                 image:(UIImage *)image {
    PSSpecifier *specifier =
        [PSSpecifier preferenceSpecifierNamed:name
                                       target:self
                                          set:@selector(setItemEnabled:specifier:)
                                          get:@selector(itemEnabled:)
                                       detail:nil
                                         cell:PSSwitchCell
                                         edit:nil];
    [specifier setProperty:identifier forKey:@"itemIdentifier"];
    if (image) {
        [specifier setProperty:image forKey:@"iconImage"];
    }
    return specifier;
}

- (NSNumber *)itemEnabled:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"itemIdentifier"];
    return @([FLMWheelItems() containsObject:identifier]);
}

- (void)setItemEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"itemIdentifier"];
    NSMutableArray<NSString *> *items = [FLMWheelItems() mutableCopy];
    if ([value boolValue]) {
        if (![items containsObject:identifier]) {
            [items addObject:identifier];
        }
    } else {
        [items removeObject:identifier];
    }
    FLMSetPreference(@"wheelItems", items);
}

@end

@implementation FLMAppOrderController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"应用排序";
        self.items = [FLMWheelItems() mutableCopy];
        self.applications = FLMInstalledApplications();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.items = [FLMWheelItems() mutableCopy];
    self.applications = FLMInstalledApplications();
    [self setEditing:NO animated:NO];
    [self.tableView reloadData];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.items.count == 0 ? @"请先在应用管理中加入项目。"
                                 : @"左滑项目可删除；点击右上角“排序”后可拖动调整轮盘顺序。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseIdentifier = @"FLMOrderCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:reuseIdentifier];
    }
    NSString *identifier = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = FLMNameForIdentifier(identifier, self.applications);
    cell.imageView.image = FLMIconForIdentifier(identifier);
    cell.showsReorderControl = tableView.isEditing;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView
    canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    return tableView.isEditing;
}

- (void)tableView:(UITableView *)tableView
    moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
           toIndexPath:(NSIndexPath *)destinationIndexPath {
    (void)tableView;
    NSString *identifier = self.items[(NSUInteger)sourceIndexPath.row];
    [self.items removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [self.items insertObject:identifier atIndex:(NSUInteger)destinationIndexPath.row];
    FLMSetPreference(@"wheelItems", self.items);
}

- (BOOL)removeWheelItemAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger row = (NSUInteger)indexPath.row;
    if (indexPath.section != 0 || row >= self.items.count) {
        return NO;
    }

    NSString *identifier = self.items[row];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return NO;
    }

    // Persist the removal before updating the visible row so the settings
    // screen, runtime wheel, and later resprings share one source of truth.
    [self.items removeObjectAtIndex:row];
    NSArray<NSString *> *expectedItems = [self.items copy];
    FLMSetPreference(@"wheelItems", expectedItems);
    NSArray<NSString *> *persistedItems = FLMWheelItems();
    BOOL persisted = [persistedItems isEqualToArray:expectedItems];
    if (!persisted) {
        [self.items insertObject:identifier atIndex:row];
        return NO;
    }
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 0 &&
           (NSUInteger)indexPath.row < self.items.count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return [self tableView:tableView canEditRowAtIndexPath:indexPath]
               ? UITableViewCellEditingStyleDelete
               : UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 ||
        (NSUInteger)indexPath.row >= self.items.count) {
        return nil;
    }

    __weak FLMAppOrderController *weakSelf = self;
    __weak UITableView *weakTableView = tableView;
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                 title:@"删除"
                                               handler:^(UIContextualAction *action,
                                                         UIView *sourceView,
                                                         void (^completionHandler)(BOOL)) {
        (void)action;
        (void)sourceView;
        FLMAppOrderController *strongSelf = weakSelf;
        UITableView *strongTableView = weakTableView;
        BOOL removed = [strongSelf removeWheelItemAtIndexPath:indexPath];
        if (removed && strongTableView) {
            [strongTableView deleteRowsAtIndexPaths:@[indexPath]
                                   withRowAnimation:UITableViewRowAnimationAutomatic];
        }
        completionHandler(removed);
    }];
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }

    BOOL removed = [self removeWheelItemAtIndexPath:indexPath];
    if (removed) {
        [tableView deleteRowsAtIndexPaths:@[indexPath]
                         withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (BOOL)tableView:(UITableView *)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return NO;
}

@end
