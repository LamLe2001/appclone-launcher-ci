//
//  AppCloneKit.xm — in-process container redirector
//
//  Injected into the *target app* (default filter: com.facebook.Facebook).
//  It makes that one binary behave as if it had a different data container,
//  keyed by the container the launcher told the daemon to activate.
//
//  What is redirected
//  ------------------
//  * NSHomeDirectory()      -> /var/mobile/Library/AppClone/Containers/<bid>/<cid>/Data
//  * NSTemporaryDirectory() -> .../Data/tmp
//  * -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]
//      -> .../Data/Library/AppGroup/<group id>   (per-container App Groups)
//  * SecItemAdd / SecItemCopyMatching / SecItemUpdate / SecItemDelete
//      -> service and account are prefixed with the container id, so each
//         clone gets its own keychain namespace without needing a custom
//         access group (which would require an entitlement the host app lacks).
//
//  Why these five and not more
//  ---------------------------
//  Nearly every file path an app touches is derived from NSHomeDirectory(), and
//  CoreFoundation preferences live under <home>/Library/Preferences. Redirecting
//  the home directory therefore moves documents, caches, preferences and the
//  sqlite stores the app creates. App Groups and the keychain are the two things
//  that are NOT derived from the home directory, which is why they are hooked
//  explicitly.
//
//  Safety
//  ------
//  If no container is active, or the container directory does not exist, every
//  hook returns the original value. A misconfigured state therefore degrades to
//  "behave exactly like the unmodified app" instead of making the app fail to
//  launch.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <substrate.h>

#ifdef ROOTLESS
static NSString *const kRoot = @"/var/jb";
#else
static NSString *const kRoot = @"";
#endif

static NSString *StatePath(void) {
    return [kRoot stringByAppendingString:@"/var/mobile/Library/AppClone/active.plist"];
}
static NSString *ContainersRoot(void) {
    return [kRoot stringByAppendingString:@"/var/mobile/Library/AppClone/Containers"];
}

/// Reads the active container for this bundle id. Returns nil when none is set,
/// in which case every hook behaves as if it were not installed.
static NSString *ActiveContainerID(void) {
    static NSString *cachedBundle = nil;
    static NSString *cachedResult = nil;
    static NSTimeInterval cachedAt = 0;

    // Re-read at most every 2 seconds so switching containers takes effect
    // without the app having to be killed and relaunched manually.
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (cachedResult && [bid isEqualToString:cachedBundle] && (now - cachedAt) < 2.0) {
        return cachedResult;
    }

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:StatePath()];
    NSString *cid = state[@"active"][bid];
    if (![cid isKindOfClass:[NSString class]] || cid.length == 0) cid = nil;

    cachedBundle = bid;
    cachedResult = cid;
    cachedAt = now;
    return cid;
}

/// Resolves the container data directory, verifying it exists. Returning nil
/// means "fall back to the stock behaviour".
static NSString *ContainerDataPath(void) {
    NSString *cid = ActiveContainerID();
    if (!cid) return nil;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *path = [[[ContainersRoot() stringByAppendingPathComponent:bid]
                          stringByAppendingPathComponent:cid]
                          stringByAppendingPathComponent:@"Data"];
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return nil;
    }
    return path;
}

#pragma mark - path hooks

%hookf(NSString *, NSHomeDirectory) {
    NSString *redirected = ContainerDataPath();
    return redirected ?: %orig;
}

%hookf(NSString *, NSTemporaryDirectory) {
    NSString *redirected = ContainerDataPath();
    if (!redirected) return %orig;
    NSString *tmp = [redirected stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return tmp;
}

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupID {
    NSString *dataPath = ContainerDataPath();
    if (!dataPath) return %orig;
    NSString *groupDir = [[dataPath stringByAppendingPathComponent:@"Library/AppGroup"]
                             stringByAppendingPathComponent:groupID ?: @"default"];
    [[NSFileManager defaultManager] createDirectoryAtPath:groupDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [NSURL fileURLWithPath:groupDir isDirectory:YES];
}
%end

#pragma mark - keychain namespacing

/// Prefixes the identifying attributes so two clones never see each other's
/// items. Only service and account are rewritten; everything else (class,
/// access group, attributes) is preserved so the system behaviour is unchanged.
static void NamespaceQuery(NSMutableDictionary *dict, NSString *prefix) {
    if (!dict || prefix.length == 0) return;

    id service = dict[(__bridge id)kSecAttrService];
    if ([service isKindOfClass:[NSString class]]) {
        dict[(__bridge id)kSecAttrService] = [prefix stringByAppendingString:service];
    }
    id account = dict[(__bridge id)kSecAttrAccount];
    if ([account isKindOfClass:[NSString class]]) {
        dict[(__bridge id)kSecAttrAccount] = [prefix stringByAppendingString:account];
    }
}

static NSString *KeychainPrefix(void) {
    NSString *cid = ActiveContainerID();
    if (!cid) return nil;
    return [NSString stringWithFormat:@"appclone.%@.", cid];
}

static NSMutableDictionary *MutableCopyOf(CFDictionaryRef d) {
    return d ? [(__bridge NSDictionary *)d mutableCopy] : nil;
}

%hookf(OSStatus, SecItemAdd, CFDictionaryRef attributes, CFTypeRef *result) {
    NSString *prefix = KeychainPrefix();
    if (!prefix) return %orig;
    NSMutableDictionary *copy = MutableCopyOf(attributes);
    NamespaceQuery(copy, prefix);
    return %orig((__bridge CFDictionaryRef)copy, result);
}

%hookf(OSStatus, SecItemCopyMatching, CFDictionaryRef query, CFTypeRef *result) {
    NSString *prefix = KeychainPrefix();
    if (!prefix) return %orig;
    NSMutableDictionary *copy = MutableCopyOf(query);
    NamespaceQuery(copy, prefix);
    return %orig((__bridge CFDictionaryRef)copy, result);
}

%hookf(OSStatus, SecItemUpdate, CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSString *prefix = KeychainPrefix();
    if (!prefix) return %orig;
    NSMutableDictionary *q = MutableCopyOf(query);
    NSMutableDictionary *a = MutableCopyOf(attributesToUpdate);
    NamespaceQuery(q, prefix);
    // attributesToUpdate may itself contain a new service/account value.
    NamespaceQuery(a, prefix);
    return %orig((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)a);
}

%hookf(OSStatus, SecItemDelete, CFDictionaryRef query) {
    NSString *prefix = KeychainPrefix();
    if (!prefix) return %orig;
    NSMutableDictionary *copy = MutableCopyOf(query);
    NamespaceQuery(copy, prefix);
    return %orig((__bridge CFDictionaryRef)copy);
}

#pragma mark - constructor

%ctor {
    NSLog(@"[AppCloneKit] loaded into %@ (container=%@)",
          [NSBundle mainBundle].bundleIdentifier ?: @"?",
          ActiveContainerID() ?: @"none");
}
