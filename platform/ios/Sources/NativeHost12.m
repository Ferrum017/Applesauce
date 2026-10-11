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

@interface DeadSpaceHostViewController : UIViewController
@property(nonatomic, assign) UIInterfaceOrientationMask orientationMask;
@end

@interface DeadSpaceControlsWindow : UIWindow
@property(nonatomic, weak) UIView *interactiveView;
@end

@implementation DeadSpaceControlsWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil || self.interactiveView == nil) {
        return nil;
    }
    return [hit isDescendantOfView:self.interactiveView] ? hit : nil;
}

@end

@implementation DeadSpaceHostViewController

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

@interface TouchHLENativeHost : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow *hostWindow;
@property(nonatomic, strong) DeadSpaceControlsWindow *controlsWindow;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) NSURL *gameURL;
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

    DeadSpaceHostViewController *controller = [[DeadSpaceHostViewController alloc] init];
    controller.orientationMask = UIInterfaceOrientationMaskAll;
    controller.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.045 blue:0.055 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"DEAD SPACE LEGACY";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.92 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:30.0];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"ARMv7 → ARM64 compatibility host for iOS 12";
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

    UIButton *importButton = [self buttonWithTitle:@"Импортировать IPA"
                                           action:@selector(importGame:)];
    self.launchButton = [self buttonWithTitle:@"Запустить Dead Space"
                                       action:@selector(launchGame:)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, subtitle, self.statusLabel, importButton, self.launchButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 20.0;
    [controller.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:34.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-34.0],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [importButton.heightAnchor constraintEqualToConstant:52.0],
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

    self.gameURL = nil;
    for (NSURL *url in files) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"ipa"]) {
            self.gameURL = url;
            break;
        }
    }

    if (self.gameURL != nil) {
        self.statusLabel.text = [NSString stringWithFormat:@"Выбран файл:\n%@", self.gameURL.lastPathComponent];
        self.launchButton.enabled = YES;
        self.launchButton.alpha = 1.0;
    } else {
        self.statusLabel.text = @"Скопируй расшифрованный Dead Space IPA через кнопку ниже или через iTunes/Filza в Documents/touchHLE_apps.";
        self.launchButton.enabled = NO;
        self.launchButton.alpha = 0.45;
    }
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
            : @"DeadSpace.ipa";
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

    touchhle_ios_log_jit_status("dead-space-launch");
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

    DeadSpaceHostViewController *controls = [[DeadSpaceHostViewController alloc] init];
    controls.orientationMask = UIInterfaceOrientationMaskLandscapeRight;
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

    self.controlsWindow = [[DeadSpaceControlsWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controlsWindow.windowLevel = UIWindowLevelNormal + 3.0;
    self.controlsWindow.rootViewController = controls;
    self.controlsWindow.interactiveView = exitButton;
    self.controlsWindow.backgroundColor = UIColor.clearColor;
    self.controlsWindow.hidden = NO;
    self.hostWindow.hidden = YES;

    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeRight)
                                forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        int32_t result = touchhle_ios_launch_game(
            self.runGame,
            self.gameURL.path.fileSystemRepresentation,
            1,
            2,
            0,
            0
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
