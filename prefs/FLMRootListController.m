#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <notify.h>
#import <signal.h>
#import <stdint.h>

#define FLYME_RUNTIME_NOTIFICATION "com.codex.flymemultitasking.runtime"
#define FLYME_PREFERENCES_NOTIFICATION "com.codex.flymemultitasking.preferences-changed"
#define FLYME_PREFERENCES_DOMAIN CFSTR("com.codex.flymemultitasking")
#define FLYME_RUNTIME_MAGIC 0x464C594DULL
#define FLYME_LOCK_SCREEN_ITEM @"com.codex.flymemultitasking.lockscreen"

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
    for (NSDictionary *application in applications) {
        if ([application[@"identifier"] isEqualToString:identifier]) {
            return application[@"name"];
        }
    }
    return identifier;
}

@interface FLMWheelSliderCell : PSTableCell
@property(nonatomic, strong) UILabel *settingTitleLabel;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UIButton *defaultButton;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy) NSString *preferenceKey;
@property(nonatomic, assign) CGFloat minimumValue;
@property(nonatomic, assign) CGFloat maximumValue;
@property(nonatomic, assign) CGFloat defaultValue;
@property(nonatomic, assign) BOOL cardGeometry;
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

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];
        _minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
        _maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
        _defaultValue = [[specifier propertyForKey:@"defaultValue"] doubleValue];
        _cardGeometry = [[specifier propertyForKey:@"cardGeometry"] boolValue];

        _settingTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _settingTitleLabel.text = specifier.name;
        _settingTitleLabel.font = [UIFont systemFontOfSize:16.0];
        [self.contentView addSubview:_settingTitleLabel];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font =
            [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

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
        _slider.value =
            (float)MAX(_minimumValue, MIN(_maximumValue, round(value)));
        [self updateValueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat valueWidth = self.cardGeometry ? 90.0 : 56.0;
    CGFloat valueRightInset = self.cardGeometry ? 160.0 : 128.0;
    CGFloat titleRightInset = self.cardGeometry ? 180.0 : 150.0;
    self.settingTitleLabel.frame = CGRectMake(16.0,
                                               9.0,
                                               width - titleRightInset,
                                               24.0);
    self.defaultButton.frame = CGRectMake(width - 66.0, 8.0, 50.0, 25.0);
    self.valueLabel.frame = CGRectMake(width - valueRightInset,
                                        9.0,
                                        valueWidth,
                                        24.0);
    self.slider.frame = CGRectMake(16.0, 41.0, width - 32.0, 42.0);
}

- (void)sliderValueChanged:(UISlider *)slider {
    slider.value = roundf(slider.value);
    [self updateValueLabel];
}

- (void)commitSliderValue {
    FLMSetPreference(self.preferenceKey, @(lroundf(self.slider.value)));
}

- (void)resetToDefault {
    [self.slider setValue:(float)self.defaultValue animated:YES];
    [self updateValueLabel];
    [self commitSliderValue];
}

- (void)updateValueLabel {
    CGFloat width = (CGFloat)lroundf(self.slider.value);
    if (self.cardGeometry) {
        CGFloat height = width * (844.0 / 390.0);
        self.valueLabel.text =
            [NSString stringWithFormat:@"%.0f×%.1f", width, height];
    } else {
        self.valueLabel.text =
            [NSString stringWithFormat:@"%ld pt", (long)width];
    }
}

@end

@interface FLMRootListController : PSListController
@end

@interface FLMAppListController : PSListController
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *applications;
@end

@interface FLMAppOrderController
    : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *items;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *applications;
@property(nonatomic, strong) UITableView *tableView;
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

    PSSpecifier *wheelGroup = [PSSpecifier groupSpecifierWithName:@"轮盘项目"];
    [wheelGroup setProperty:@"打开开关即可加入轮盘；关闭后会从轮盘和排序列表中移除。"
                     forKey:@"footerText"];
    [specifiers addObject:wheelGroup];

    [specifiers addObject:[self itemSpecifierWithName:@"锁屏"
                                           identifier:FLYME_LOCK_SCREEN_ITEM
                                                image:FLMIconForIdentifier(
                                                          FLYME_LOCK_SCREEN_ITEM)]];

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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.items = [FLMWheelItems() mutableCopy];
    self.applications = FLMInstalledApplications();
    [self.tableView setEditing:YES animated:NO];
    [self.tableView reloadData];
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
                                 : @"按住右侧拖动图标即可调整轮盘顺序。";
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
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView
    canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
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

- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return NO;
}

@end
