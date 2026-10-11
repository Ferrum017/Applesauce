#include <SDL.h>
#include <SDL_system.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

// Each emulator core exports this; the host passes in the one belonging to the
// core it loaded for this game.
typedef int32_t (*TouchHLEIOSRunGameFn)(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

// Dynarmic needs writable-executable memory, and two things can grant it:
//
//   * An attached debugger (StikDebug, AltJIT, TrollStore's "Enable JIT"),
//     which sets CS_DEBUGGED on the process. This has to be redone every time
//     the app starts as a new process.
//   * The `dynamic-codesigning` entitlement, which makes it permanent. Only
//     TrollStore can grant that, and iOS 15+ only honours it on A11 and older
//     chips.
//
// Checking only for a debugger would tell a TrollStore user with permanent JIT
// that they have none, and hold back a launch that would have worked.

// Not declared in the public SDK, but a stable syscall wrapper in libSystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define TOUCHHLE_CS_OPS_STATUS 0
#define TOUCHHLE_CS_DEBUGGED 0x10000000

bool touchhle_ios_jit_is_from_debugger(void) {
    // dynarmic's code allocator asks for its executable memory by executing
    // `brk #0xf00d` (see oaknut's prepare_jit_region), a trap that only an
    // attached debugger can service. With none attached the trap is fatal the
    // instant a game starts, which reads as the app quitting for no reason.
    unsigned int flags = 0;
    if (csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags)) == 0
        && (flags & TOUCHHLE_CS_DEBUGGED) != 0) {
        return true;
    }

    // P_TRACED is the older signal for the same thing, and is what this app
    // shipped with through 0.3.0. Keep it as a second opinion rather than
    // replace it.
    struct kinfo_proc info;
    info.kp_proc.p_flag = 0;

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return false;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// SecTask lives in Security.framework but is not declared in the iOS SDK.
// Resolve it at runtime so a missing symbol degrades to "no entitlement"
// rather than stopping the app from launching at all.
static bool touchhle_has_dynamic_codesigning(void) {
    typedef CFTypeRef (*create_from_self_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_entitlement_fn)(CFTypeRef, CFStringRef, CFErrorRef *);

    static create_from_self_fn create_task;
    static copy_entitlement_fn copy_entitlement;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY
        );
        if (security == NULL) {
            return;
        }
        create_task = (create_from_self_fn)dlsym(security, "SecTaskCreateFromSelf");
        copy_entitlement =
            (copy_entitlement_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
    });

    if (create_task == NULL || copy_entitlement == NULL) {
        return false;
    }

    CFTypeRef task = create_task(kCFAllocatorDefault);
    if (task == NULL) {
        return false;
    }
    CFTypeRef value = copy_entitlement(task, CFSTR("dynamic-codesigning"), NULL);
    bool granted = value != NULL
        && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return granted;
}

// Verify what the kernel granted, rather than trusting the entitlement string
// alone.  AppSync can preserve an entitlement in the signature even when the
// kernel refuses its capability.  iOS may also return a writable mapping for
// an RWX request while silently removing execute permission.
static bool touchhle_can_allocate_executable_memory(void) {
    const size_t size = (size_t)getpagesize();
    int flags = MAP_ANON | MAP_PRIVATE;
#ifdef MAP_JIT
    flags |= MAP_JIT;
#endif

    void *mapping = mmap(
        NULL,
        size,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        flags,
        -1,
        0
    );
    if (mapping == MAP_FAILED) {
        return false;
    }

    mach_vm_address_t region_address = (mach_vm_address_t)mapping;
    mach_vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name = MACH_PORT_NULL;
    kern_return_t result = mach_vm_region(
        mach_task_self(),
        &region_address,
        &region_size,
        VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info,
        &info_count,
        &object_name
    );
    if (object_name != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), object_name);
    }

    bool executable = result == KERN_SUCCESS
        && region_address == (mach_vm_address_t)mapping
        && (info.protection & VM_PROT_EXECUTE) != 0;
    munmap(mapping, size);
    return executable;
}

bool touchhle_ios_jit_available(void) {
    return touchhle_ios_jit_is_from_debugger()
        || (touchhle_has_dynamic_codesigning()
            && touchhle_can_allocate_executable_memory());
}

// The mmap probe above must inspect the kernel-reported VM protection. Merely
// checking MAP_FAILED produces a false positive on iOS, which may return a
// writable-but-not-executable mapping when JIT is unavailable.
void touchhle_ios_log_jit_status(const char *context) {
    unsigned int flags = 0;
    int result = csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags));
    bool entitlement = touchhle_has_dynamic_codesigning();
    bool executable_mapping = entitlement
        && touchhle_can_allocate_executable_memory();
    fprintf(
        stderr,
        "touchHLE JIT [%s]: available=%d debugger=%d entitlement=%d executable_mapping=%d "
        "cs_flags=0x%08x csops=%d/%d\n",
        context ? context : "?",
        touchhle_ios_jit_is_from_debugger() || executable_mapping,
        touchhle_ios_jit_is_from_debugger(),
        entitlement,
        executable_mapping,
        flags,
        result,
        (result == 0) ? 0 : errno
    );
}

static FILE *diagnostic_log;

static void redirect_diagnostics(void) {
    const char *home = getenv("HOME");
    if (home == NULL) {
        return;
    }

    char log_path[PATH_MAX];
    int length = snprintf(log_path, sizeof(log_path), "%s/Documents/touchhle-host.log", home);
    if (length < 0 || (size_t)length >= sizeof(log_path)) {
        return;
    }

    // If a game hangs, the only way out is to force-quit, and the next launch
    // would truncate the log that recorded the hang. Keep one generation back
    // so the interesting session survives the relaunch needed to retrieve it.
    char previous_path[PATH_MAX];
    length = snprintf(
        previous_path,
        sizeof(previous_path),
        "%s/Documents/touchhle-host-previous.log",
        home
    );
    if (length > 0 && (size_t)length < sizeof(previous_path)) {
        rename(log_path, previous_path);
    }

    diagnostic_log = fopen(log_path, "w");
    if (diagnostic_log == NULL) {
        return;
    }

    setvbuf(diagnostic_log, NULL, _IONBF, 0);
    dup2(fileno(diagnostic_log), STDOUT_FILENO);
    dup2(fileno(diagnostic_log), STDERR_FILENO);
    fprintf(stderr, "touchHLE iOS port diagnostics started\n");
}

static void start_native_host(void) {
    Class host_class = NSClassFromString(@"TouchHLENativeHost");
    SEL selector = NSSelectorFromString(@"start");
    if (host_class == Nil || ![host_class respondsToSelector:selector]) {
        fprintf(stderr, "Could not start the native iOS port UI\n");
        return;
    }

    ((void (*)(id, SEL))objc_msgSend)(host_class, selector);
}

int32_t touchhle_ios_launch_game(
    TouchHLEIOSRunGameFn run_game,
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
) {
    if (run_game == NULL) {
        fprintf(stderr, "touchHLE failed: no emulator core was loaded\n");
        return 1;
    }

    const char *orientation_hint = "Portrait";
    if (orientation == 1) {
        orientation_hint = "LandscapeLeft";
    } else if (orientation == 2) {
        orientation_hint = "LandscapeRight";
    }
    SDL_SetHint(SDL_HINT_ORIENTATIONS, orientation_hint);

    // Breadcrumbs: the emulator runs on the main thread, so if it hangs the UI
    // freezes with it and the log is the only way to see how far it got.
    touchhle_ios_log_jit_status("game-launch");
    fprintf(
        stderr,
        "touchHLE: entering emulator: scale_hack=%d orientation=%s network=%d "
        "analog_tilt=%d\n",
        scale_hack,
        orientation_hint,
        network_access,
        analog_stick_tilt_controls
    );

    SDL_iPhoneSetEventPump(SDL_TRUE);
    int32_t result = run_game(
        path,
        scale_hack,
        orientation,
        network_access,
        analog_stick_tilt_controls
    );
    SDL_iPhoneSetEventPump(SDL_FALSE);
    SDL_ResetHint(SDL_HINT_ORIENTATIONS);

    fprintf(stderr, "touchHLE: emulator returned %d\n", result);
    return result;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    redirect_diagnostics();
    touchhle_ios_log_jit_status("launch");

    char *base_path = SDL_GetBasePath();
    if (base_path != NULL) {
        chdir(base_path);
        SDL_free(base_path);
    }

    start_native_host();
    return 0;
}
