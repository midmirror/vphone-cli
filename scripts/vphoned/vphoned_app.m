/*
 * vphoned_app — IPA application installation support.
 */

#import "vphoned_app.h"
#import "vphoned_protocol.h"
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <objc/runtime.h>

// MARK: - IPA Extraction

/// Run a command via posix_spawn and return exit status. Returns -1 on spawn failure.
static int run_command(const char *path, char *const argv[]) {
    pid_t pid;
    int status;

    extern char **environ;
    int ret = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (ret != 0) return -1;

    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/// Try to extract IPA using /usr/bin/unzip.
static BOOL extract_with_unzip(NSString *ipaPath, NSString *destDir) {
    const char *unzip = "/usr/bin/unzip";
    if (access(unzip, X_OK) != 0) return NO;

    char *argv[] = {
        (char *)"unzip", (char *)"-o", (char *)"-q",
        (char *)[ipaPath fileSystemRepresentation],
        (char *)"-d", (char *)[destDir fileSystemRepresentation],
        NULL
    };
    return run_command(unzip, argv) == 0;
}

/// Try to extract IPA using NSFileManager (ZIP is just a directory of entries).
/// Uses NSData to read the file and NSTask/posix_spawn with /usr/bin/tar as last resort,
/// but primarily relies on the fact that IPA is a ZIP and we can use ditto if available.
static BOOL extract_with_ditto(NSString *ipaPath, NSString *destDir) {
    // Try ditto (available on macOS and some iOS toolchains)
    const char *ditto = "/usr/bin/ditto";
    if (access(ditto, X_OK) == 0) {
        char *argv[] = {
            (char *)"ditto", (char *)"-x", (char *)"-k",
            (char *)[ipaPath fileSystemRepresentation],
            (char *)[destDir fileSystemRepresentation],
            NULL
        };
        return run_command(ditto, argv) == 0;
    }
    return NO;
}

/// Find Payload/*.app inside extracted directory.
static NSString *find_app_bundle(NSString *extractDir) {
    NSString *payloadDir = [extractDir stringByAppendingPathComponent:@"Payload"];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:payloadDir isDirectory:&isDir] || !isDir) {
        return nil;
    }

    NSArray *contents = [fm contentsOfDirectoryAtPath:payloadDir error:nil];
    for (NSString *name in contents) {
        if ([name hasSuffix:@".app"]) {
            return [payloadDir stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

NSString *vp_app_extract_ipa(NSString *ipaPath, NSDictionary **outError) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Validate IPA file exists
    if (![fm fileExistsAtPath:ipaPath]) {
        if (outError) *outError = @{@"msg": @"IPA file not found"};
        return nil;
    }

    // Create temp extraction directory: /tmp/<UUID>/
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *extractDir = [NSString stringWithFormat:@"/tmp/%@", uuid];

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:extractDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirErr]) {
        if (outError) {
            *outError = @{@"msg": [NSString stringWithFormat:@"failed to create temp dir: %@",
                          dirErr.localizedDescription]};
        }
        return nil;
    }

    // Try unzip first, fall back to ditto
    BOOL extracted = extract_with_unzip(ipaPath, extractDir);
    if (!extracted) {
        NSLog(@"vphoned: unzip not available or failed, trying ditto fallback");
        extracted = extract_with_ditto(ipaPath, extractDir);
    }

    if (!extracted) {
        vp_app_cleanup(extractDir);
        if (outError) *outError = @{@"msg": @"failed to extract IPA: no unzip or ditto available"};
        return nil;
    }

    // Locate Payload/*.app
    NSString *appPath = find_app_bundle(extractDir);
    if (!appPath) {
        vp_app_cleanup(extractDir);
        if (outError) *outError = @{@"msg": @"invalid IPA format: Payload/*.app not found"};
        return nil;
    }

    NSLog(@"vphoned: extracted IPA to %@", appPath);
    return appPath;
}

// MARK: - LSApplicationWorkspace Installation

/// Get the bundle identifier from the app's Info.plist.
static NSString *get_bundle_id(NSString *appPath) {
    NSString *infoPlist = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
    return info[@"CFBundleIdentifier"];
}

/// Load CoreServices framework and return LSApplicationWorkspace class.
static Class load_ls_workspace(void) {
    // Try PrivateFrameworks path first (iOS 16+)
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    if (!handle) {
        // Fallback to MobileCoreServices
        handle = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    }
    if (!handle) {
        NSLog(@"vphoned: failed to load CoreServices: %s", dlerror());
        return nil;
    }

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) {
        NSLog(@"vphoned: LSApplicationWorkspace class not found");
    }
    return cls;
}

/// Refresh SpringBoard icon cache after installation.
static void rebuild_icon_cache(void) {
    // _LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:
    // Parameters: (BOOL systemApps, BOOL internal, BOOL user)
    // We pass NO, NO, YES to rebuild user app databases only.
    SEL rebuildSel = NSSelectorFromString(
        @"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");

    // This is a class method on LSApplicationWorkspace or a C function —
    // try invoking via NSClassFromString to find the function.
    Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (lsClass && [lsClass respondsToSelector:rebuildSel]) {
        NSMethodSignature *sig = [lsClass methodSignatureForSelector:rebuildSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:rebuildSel];
            [inv setTarget:lsClass];
            BOOL no = NO, yes = YES;
            [inv setArgument:&no atIndex:2];   // systemApps
            [inv setArgument:&no atIndex:3];   // internal
            [inv setArgument:&yes atIndex:4];  // user
            [inv invoke];
            NSLog(@"vphoned: rebuilt application databases");
            return;
        }
    }

    // Fallback: try uicache if available
    const char *uicache = "/usr/bin/uicache";
    if (access(uicache, X_OK) == 0) {
        char *argv[] = { (char *)"uicache", (char *)"-a", NULL };
        run_command(uicache, argv);
        NSLog(@"vphoned: ran uicache -a");
    } else {
        NSLog(@"vphoned: no icon cache refresh method available");
    }
}

NSString *vp_app_install(NSString *appPath, NSDictionary **outError) {
    // Load LSApplicationWorkspace
    Class wsClass = load_ls_workspace();
    if (!wsClass) {
        if (outError) *outError = @{@"msg": @"failed to load CoreServices framework"};
        return nil;
    }

    // Get workspace instance
    id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
    if (!workspace) {
        if (outError) *outError = @{@"msg": @"LSApplicationWorkspace defaultWorkspace returned nil"};
        return nil;
    }

    // Install the .app bundle
    NSURL *appURL = [NSURL fileURLWithPath:appPath];
    NSDictionary *options = @{@"PackageType": @"Developer"};
    NSError *installError = nil;

    // Use objc_msgSend to call installApplication:withOptions:error:
    // because the method takes NSURL*, NSDictionary*, NSError** which
    // performSelector: cannot handle directly.
    SEL installSel = NSSelectorFromString(@"installApplication:withOptions:error:");
    NSMethodSignature *sig = [workspace methodSignatureForSelector:installSel];
    if (!sig) {
        if (outError) *outError = @{@"msg": @"installApplication:withOptions:error: not found"};
        return nil;
    }

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:installSel];
    [inv setTarget:workspace];
    [inv setArgument:&appURL atIndex:2];
    [inv setArgument:&options atIndex:3];
    [inv setArgument:&installError atIndex:4];
    [inv invoke];

    BOOL success = NO;
    [inv getReturnValue:&success];

    if (!success) {
        NSString *errMsg = installError ? [installError localizedDescription]
                                        : @"installApplication returned NO";
        NSLog(@"vphoned: install failed: %@", errMsg);
        if (outError) *outError = @{@"msg": errMsg};
        return nil;
    }

    // Get bundle ID from Info.plist
    NSString *bundleId = get_bundle_id(appPath);
    NSLog(@"vphoned: installed %@ successfully", bundleId ?: @"(unknown)");

    // Refresh SpringBoard icon cache
    rebuild_icon_cache();

    return bundleId;
}

// MARK: - Command Handler

NSDictionary *vp_handle_app_install(NSDictionary *msg, id reqId) {
    NSString *ipaPath = msg[@"path"];
    if (!ipaPath || ipaPath.length == 0) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"missing 'path' parameter";
        r[@"stage"] = @"unzip";
        return r;
    }

    // Stage 1: Extract IPA
    NSLog(@"vphoned: app_install: extracting %@", ipaPath);
    NSDictionary *extractErr = nil;
    NSString *appPath = vp_app_extract_ipa(ipaPath, &extractErr);
    if (!appPath) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = extractErr[@"msg"] ?: @"extraction failed";
        r[@"stage"] = @"unzip";
        return r;
    }

    // Derive extractDir from appPath: /tmp/<UUID>/Payload/X.app → /tmp/<UUID>/
    NSString *extractDir = [[appPath stringByDeletingLastPathComponent]
                            stringByDeletingLastPathComponent];

    // Stage 2: Optional re-sign
    BOOL resigned = NO;
    NSDictionary *resignErr = nil;
    BOOL resignResult = vp_app_resign(appPath, &resignErr);

    if (!resignResult && resignErr) {
        // ldid exists but signing failed
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = resignErr[@"msg"] ?: @"re-signing failed";
        r[@"stage"] = @"resign";
        vp_app_cleanup_ipa(extractDir, ipaPath);
        return r;
    }
    resigned = resignResult; // YES if ldid available and succeeded, NO if ldid not available

    // Stage 3: Install via LSApplicationWorkspace
    NSLog(@"vphoned: app_install: installing %@", appPath);
    NSDictionary *installErr = nil;
    NSString *bundleId = vp_app_install(appPath, &installErr);

    if (!bundleId) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = installErr[@"msg"] ?: @"installation failed";
        r[@"stage"] = @"install";
        vp_app_cleanup_ipa(extractDir, ipaPath);
        return r;
    }

    // Success — clean up and return result
    vp_app_cleanup_ipa(extractDir, ipaPath);

    NSMutableDictionary *r = vp_make_response(@"ok", reqId);
    r[@"bundle_id"] = bundleId;
    return r;
}

// MARK: - Cleanup

void vp_app_cleanup(NSString *extractDir) {
    if (!extractDir) return;
    [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
}

void vp_app_cleanup_ipa(NSString *extractDir, NSString *ipaPath) {
    vp_app_cleanup(extractDir);
    if (ipaPath) {
        [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
    }
}
