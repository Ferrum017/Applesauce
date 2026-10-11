#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>

typedef int32_t (*TouchHLEIOSRunGameFn)(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);
typedef void (*TouchHLEIOSRequestExitFn)(void);

extern bool touchhle_ios_jit_available(void);
extern void touchhle_ios_log_jit_status(const char *context);
extern int32_t touchhle_ios_launch_game(
    TouchHLEIOSRunGameFn run_game,
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

@class TouchHLENativeHost;

@interface LegacyHostViewController : UIViewController
@property(nonatomic, assign) UIInterfaceOrientationMask orientationMask;
@end

@interface LegacyControlsWindow : UIWindow
@property(nonatomic, weak) UIView *interactiveView;
@end

@implementation LegacyControlsWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil || self.interactiveView == nil) {
        return nil;
    }
    return [hit isDescendantOfView:self.interactiveView] ? hit : nil;
}

@end

@implementation LegacyHostViewController

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.orientationMask ?: UIInterfaceOrientationMaskAll;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    if (self.orientationMask == UIInterfaceOrientationMaskLandscapeRight) {
        return UIInterfaceOrientationLandscapeRight;
    }
    return UIInterfaceOrientationPortrait;
}

@end

@interface TouchHLENativeHost : NSObject <UIDocumentPickerDelegate, UIPickerViewDataSource, UIPickerViewDelegate>
@property(nonatomic, strong) UIWindow *hostWindow;
@property(nonatomic, strong) LegacyControlsWindow *controlsWindow;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *deleteButton;
@property(nonatomic, strong) UIPickerView *gamePicker;
@property(nonatomic, strong) UISegmentedControl *orientationControl;
@property(nonatomic, copy) NSArray<NSURL *> *games;
@property(nonatomic, strong) NSURL *gameURL;
@property(nonatomic, assign) int32_t launchOrientation;
@property(nonatomic, assign) void *coreHandle;
@property(nonatomic, assign) TouchHLEIOSRunGameFn runGame;
@property(nonatomic, assign) TouchHLEIOSRequestExitFn requestExit;
@end

@implementation TouchHLENativeHost

static TouchHLENativeHost *sharedHost;

+ (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sharedHost == nil) {
            sharedHost = [[TouchHLENativeHost alloc] init];
        }
        [sharedHost presentHost];
    });
}

- (NSURL *)appsDirectory {
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [documents URLByAppendingPathComponent:@"touchHLE_apps"
                                                   isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

- (void)presentHost {
    if (self.hostWindow != nil) {
        self.hostWindow.hidden = NO;
        [self.hostWindow makeKeyAndVisible];
        return;
    }

    LegacyHostViewController *controller = [[LegacyHostViewController alloc] init];
    controller.orientationMask = UIInterfaceOrientationMaskAll;
    controller.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.045 blue:0.055 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"APPLESAUCE LEGACY";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.92 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:30.0];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"32-bit iPhone app compatibility host for iOS 12";
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:15.0];
    subtitle.numberOfLines = 0;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:17.0];
    self.statusLabel.numberOfLines = 0;

    self.gamePicker = [[UIPickerView alloc] initWithFrame:CGRectZero];
    self.gamePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.gamePicker.dataSource = self;
    self.gamePicker.delegate = self;

    self.orientationControl = [[UISegmentedControl alloc] initWithItems:@[
        @"Авто", @"Портрет", @"Лево", @"Право"
    ]];
    self.orientationControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.orientationControl.selectedSegmentIndex = 0;

    UIButton *importButton = [self buttonWithTitle:@"Импортировать IPA"
                                           action:@selector(importGame:)];
    self.deleteButton = [self buttonWithTitle:@"Удалить выбранный IPA"
                                       action:@selector(deleteGame:)];
    self.launchButton = [self buttonWithTitle:@"Запустить выбранное приложение"
                                       action:@selector(launchGame:)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        subtitle,
        self.statusLabel,
        self.gamePicker,
        self.orientationControl,
        importButton,
        self.deleteButton,
        self.launchButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 12.0;
    [controller.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:34.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-34.0],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [self.gamePicker.heightAnchor constraintEqualToConstant:110.0],
        [self.orientationControl.heightAnchor constraintEqualToConstant:36.0],
        [importButton.heightAnchor constraintEqualToConstant:52.0],
        [self.deleteButton.heightAnchor constraintEqualToConstant:52.0],
        [self.launchButton.heightAnchor constraintEqualToConstant:52.0]
    ]];

    self.hostWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.hostWindow.rootViewController = controller;
    self.hostWindow.backgroundColor = controller.view.backgroundColor;
    [self.hostWindow makeKeyAndVisible];
    [self refreshGameSelection];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [UIColor colorWithRed:0.08 green:0.30 blue:0.31 alpha:1.0];
    button.tintColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    button.layer.cornerRadius = 8.0;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)refreshGameSelection {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:[self appsDirectory]
        includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles
        error:nil];

    NSMutableArray<NSURL *> *games = [NSMutableArray array];
    for (NSURL *url in files) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"ipa"]) {
            [games addObject:url];
        }
    }
    [games sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedCaseInsensitiveCompare:right.lastPathComponent];
    }];
    self.games = games;
    [self.gamePicker reloadAllComponents];
    self.gameURL = self.games.firstObject;
    if (self.games.count > 0) {
        [self.gamePicker selectRow:0 inComponent:0 animated:NO];
    }

    if (self.gameURL != nil) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"Найдено IPA: %lu\nВыбран: %@",
            (unsigned long)self.games.count,
            self.gameURL.lastPathComponent];
        self.launchButton.enabled = YES;
        self.launchButton.alpha = 1.0;
        self.deleteButton.enabled = YES;
        self.deleteButton.alpha = 1.0;
    } else {
        self.statusLabel.text = @"Импортируй расшифрованный 32-битный ARMv6/ARMv7 IPA.\nARM64 и зашифрованные App Store IPA не поддерживаются.";
        self.launchButton.enabled = NO;
        self.launchButton.alpha = 0.45;
        self.deleteButton.enabled = NO;
        self.deleteButton.alpha = 0.45;
    }
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    (void)pickerView;
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView
numberOfRowsInComponent:(NSInteger)component {
    (void)pickerView;
    (void)component;
    return (NSInteger)self.games.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView
             titleForRow:(NSInteger)row
            forComponent:(NSInteger)component {
    (void)pickerView;
    (void)component;
    if (row < 0 || (NSUInteger)row >= self.games.count) {
        return @"";
    }
    return self.games[(NSUInteger)row].lastPathComponent;
}

- (void)pickerView:(UIPickerView *)pickerView
      didSelectRow:(NSInteger)row
       inComponent:(NSInteger)component {
    (void)pickerView;
    (void)component;
    if (row < 0 || (NSUInteger)row >= self.games.count) {
        return;
    }
    self.gameURL = self.games[(NSUInteger)row];
    self.statusLabel.text = [NSString stringWithFormat:
        @"Найдено IPA: %lu\nВыбран: %@",
        (unsigned long)self.games.count,
        self.gameURL.lastPathComponent];
}

- (void)importGame:(id)sender {
    (void)sender;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"com.pkware.zip-archive", @"public.archive", @"public.data"]
        inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self.hostWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.count > 0) {
        [self copyImportedGame:urls.firstObject];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentAtURL:(NSURL *)url {
    (void)controller;
    [self copyImportedGame:url];
}

- (void)copyImportedGame:(NSURL *)sourceURL {
    self.statusLabel.text = @"Копирование IPA…";
    self.launchButton.enabled = NO;
    BOOL hasSecurityScope = [sourceURL startAccessingSecurityScopedResource];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *name = sourceURL.lastPathComponent.length > 0
            ? sourceURL.lastPathComponent
            : @"Imported.ipa";
        if (![[name.pathExtension lowercaseString] isEqualToString:@"ipa"]) {
            name = [name stringByAppendingPathExtension:@"ipa"];
        }
        NSURL *destination = [[self appsDirectory] URLByAppendingPathComponent:name];
        NSFileManager *manager = [NSFileManager defaultManager];
        NSError *error = nil;
        if ([manager fileExistsAtPath:destination.path]) {
            [manager removeItemAtURL:destination error:&error];
        }
        if (error == nil) {
            [manager copyItemAtURL:sourceURL toURL:destination error:&error];
        }
        if (hasSecurityScope) {
            [sourceURL stopAccessingSecurityScopedResource];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                [self showError:@"Не удалось импортировать IPA" details:error.localizedDescription];
            }
            [self refreshGameSelection];
        });
    });
}

- (void)deleteGame:(id)sender {
    (void)sender;
    if (self.gameURL == nil) {
        return;
    }

    NSString *name = self.gameURL.lastPathComponent;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Удалить IPA?"
        message:name
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Удалить"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtURL:self.gameURL error:&error];
        if (error != nil) {
            [self showError:@"Не удалось удалить IPA" details:error.localizedDescription];
        }
        [self refreshGameSelection];
    }]];
    [self.hostWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (BOOL)loadCore:(NSString **)errorMessage {
    if (self.coreHandle != NULL && self.runGame != NULL) {
        return YES;
    }

    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    NSString *corePath = [frameworks stringByAppendingPathComponent:@"libhyperhle_core.dylib"];
    self.coreHandle = dlopen(corePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (self.coreHandle == NULL) {
        if (errorMessage != NULL) {
            const char *reason = dlerror();
            *errorMessage = reason ? [NSString stringWithUTF8String:reason] : @"dlopen failed";
        }
        return NO;
    }

    self.runGame = (TouchHLEIOSRunGameFn)dlsym(self.coreHandle, "touchhle_ios_run_game");
    self.requestExit = (TouchHLEIOSRequestExitFn)dlsym(self.coreHandle, "touchhle_ios_request_exit");
    if (self.runGame == NULL) {
        if (errorMessage != NULL) {
            *errorMessage = @"В emulator core отсутствует touchhle_ios_run_game";
        }
        return NO;
    }
    return YES;
}

- (void)launchGame:(id)sender {
    (void)sender;
    if (self.gameURL == nil) {
        [self refreshGameSelection];
        return;
    }

    NSString *loadError = nil;
    if (![self loadCore:&loadError]) {
        [self showError:@"Не удалось загрузить HyperHLE" details:loadError];
        return;
    }

    switch (self.orientationControl.selectedSegmentIndex) {
        case 1:
            self.launchOrientation = 0;
            break;
        case 2:
            self.launchOrientation = 1;
            break;
        case 3:
            self.launchOrientation = 2;
            break;
        default: {
            UIInterfaceOrientation current = UIApplication.sharedApplication.statusBarOrientation;
            self.launchOrientation = current == UIInterfaceOrientationLandscapeLeft
                ? 1
                : (current == UIInterfaceOrientationLandscapeRight ? 2 : 0);
            break;
        }
    }

    touchhle_ios_log_jit_status("legacy-app-launch");
    if (!touchhle_ios_jit_available()) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"JIT не обнаружен"
            message:@"Приложение должно быть установлено через AppSync и подписано entitlement dynamic-codesigning. Без JIT запуск завершится аварийно."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Отмена"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Запустить всё равно"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [self beginEmulation];
        }]];
        [self.hostWindow.rootViewController presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self beginEmulation];
}

- (void)beginEmulation {
    setenv("TOUCHHLE_DEFAULT_OPTIONS_FILE", "touchHLE_default_options.txt", 1);
    self.launchButton.enabled = NO;
    self.statusLabel.text = @"Запуск…";

    LegacyHostViewController *controls = [[LegacyHostViewController alloc] init];
    switch (self.launchOrientation) {
        case 1:
            controls.orientationMask = UIInterfaceOrientationMaskLandscapeLeft;
            break;
        case 2:
            controls.orientationMask = UIInterfaceOrientationMaskLandscapeRight;
            break;
        default:
            controls.orientationMask = UIInterfaceOrientationMaskPortrait;
            break;
    }
    controls.view.backgroundColor = UIColor.clearColor;

    UIButton *exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exitButton.frame = CGRectMake(16.0, 16.0, 54.0, 38.0);
    exitButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    exitButton.backgroundColor = [UIColor colorWithRed:0.55 green:0.03 blue:0.03 alpha:0.75];
    exitButton.tintColor = UIColor.whiteColor;
    exitButton.layer.cornerRadius = 7.0;
    [exitButton setTitle:@"Выход" forState:UIControlStateNormal];
    [exitButton addTarget:self action:@selector(exitGame:) forControlEvents:UIControlEventTouchUpInside];
    [controls.view addSubview:exitButton];

    self.controlsWindow = [[LegacyControlsWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controlsWindow.windowLevel = UIWindowLevelNormal + 3.0;
    self.controlsWindow.rootViewController = controls;
    self.controlsWindow.interactiveView = exitButton;
    self.controlsWindow.backgroundColor = UIColor.clearColor;
    self.controlsWindow.hidden = NO;
    self.hostWindow.hidden = YES;

    UIInterfaceOrientation deviceOrientation = UIInterfaceOrientationPortrait;
    if (self.launchOrientation == 1) {
        deviceOrientation = UIInterfaceOrientationLandscapeLeft;
    } else if (self.launchOrientation == 2) {
        deviceOrientation = UIInterfaceOrientationLandscapeRight;
    }
    [[UIDevice currentDevice] setValue:@(deviceOrientation) forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        int32_t result = touchhle_ios_launch_game(
            self.runGame,
            self.gameURL.path.fileSystemRepresentation,
            1,
            self.launchOrientation,
            0,
            1
        );
        [self finishEmulationWithResult:result];
    });
}

- (void)exitGame:(id)sender {
    (void)sender;
    if (self.requestExit != NULL) {
        self.requestExit();
    }
}

- (void)finishEmulationWithResult:(int32_t)result {
    self.controlsWindow.hidden = YES;
    self.controlsWindow.rootViewController = nil;
    self.controlsWindow = nil;
    self.hostWindow.hidden = NO;
    [self.hostWindow makeKeyAndVisible];
    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait)
                                forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];
    self.launchButton.enabled = YES;
    self.statusLabel.text = result == 0
        ? @"Игра завершена."
        : [NSString stringWithFormat:@"Эмулятор завершился с кодом %d. Смотри Documents/touchhle-host.log.", result];
}

- (void)showError:(NSString *)title details:(NSString *)details {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
        message:details ?: @"Неизвестная ошибка"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self.hostWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

@end
