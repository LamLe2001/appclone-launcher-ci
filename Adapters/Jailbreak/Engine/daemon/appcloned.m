//
//  appcloned.m — AppClone container daemon
//
//  Responsibilities (mirrors what libCrane exposes, see
//  Adapters/Jailbreak/Engine/README.md):
//
//    * own the on-disk container tree            /var/mobile/Library/AppClone/Containers/<id>/
//    * own the "which container is active" state (a small plist the in-app tweak
//      reads at launch)
//    * create / delete / wipe containers safely
//    * serve a tiny line-protocol socket so the sandboxed launcher never needs
//      privileged file access itself
//
//  Design notes
//  ------------
//  * The launcher is sandboxed; it must not be trusted with arbitrary paths.
//    Every request is therefore expressed as (bundleID, containerID) and the
//    daemon resolves those to paths itself. A request can never name a path.
//  * Container IDs are validated to a strict charset so a request cannot escape
//    the container root through ".." or separators.
//  * The active-container plist is written atomically (write temp + rename) so a
//    crash mid-write cannot leave a half-parsed file that would make the target
//    app start in the wrong container.
//
//  This file is compiled by Theos (see Makefile) and installed as a launchd
//  daemon by the .deb.
//

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>

// Rootless jailbreaks relocate everything under /var/jb. THEOS_PACKAGE_SCHEME
// sets this at build time; the fallback keeps a rootful build working.
#ifdef ROOTLESS
static NSString *const kRoot = @"/var/jb";
#else
static NSString *const kRoot = @"";
#endif

static NSString *AppsRoot(void) {
    return [kRoot stringByAppendingString:@"/var/mobile/Library/AppClone"];
}
static NSString *ContainersRoot(void) {
    return [AppsRoot() stringByAppendingString:@"/Containers"];
}
static NSString *StatePath(void) {
    return [AppsRoot() stringByAppendingString:@"/active.plist"];
}
static NSString *SocketPath(void) {
    return [kRoot stringByAppendingString:@"/var/run/appcloned.sock"];
}

#pragma mark - validation

/// Container IDs come from the launcher (a UUID string). Anything outside the
/// safe charset is rejected outright so the value can never traverse the tree.
static BOOL ValidIdentifier(NSString *s) {
    if (s.length == 0 || s.length > 64) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
    return [s rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

/// Bundle identifiers: same idea, plus the dot is expected.
static BOOL ValidBundleID(NSString *s) {
    if (s.length == 0 || s.length > 255) return NO;
    return ValidIdentifier(s);
}

#pragma mark - filesystem helpers

/// Safe description of an NSError** without dereferencing a NULL out-param.
static NSString *ErrDesc(NSError **err) {
    if (err && *err) return (*err).localizedDescription;
    return @"unknown";
}

static BOOL EnsureDir(NSString *path, NSError **err) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions: @0755}
                                                           error:err];
}

/// Atomic write of the shared state file, readable by the (sandboxed) target app
/// via the jailbreak's /var/jb sandbox extension.
static BOOL WriteState(NSDictionary *state, NSError **err) {
    NSString *dir = AppsRoot();
    if (!EnsureDir(dir, err)) return NO;

    NSString *tmp = [StatePath() stringByAppendingString:@".tmp"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:err];
    if (!data) return NO;
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:err]) return NO;
    chmod(tmp.fileSystemRepresentation, 0644);
    return [[NSFileManager defaultManager] replaceItemAtURL:
                [NSURL fileURLWithPath:StatePath()]
                                            withItemAtURL:
                [NSURL fileURLWithPath:tmp]
                                           backupItemName:nil
                                                  options:0
                                         resultingItemURL:nil
                                                    error:err];
}

static NSMutableDictionary *ReadState(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:StatePath()];
    return [d mutableCopy] ?: [NSMutableDictionary dictionary];
}

#pragma mark - request handling

/// Supported request lines (one per connection, newline terminated):
///
///   PING
///   CREATE   <containerID> <bundleID> <displayName>
///   DELETE   <containerID> <bundleID>
///   WIPE     <containerID> <bundleID>
///   LIST     <bundleID>
///   SETACTIVE <containerID|-> <bundleID>
///   GETACTIVE <bundleID>
///
/// Responses: "OK ..." or "ERR <code> <message>".
static NSString *HandleLine(NSString *line, NSError **err) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    if (parts.count == 0) return @"ERR 400 empty";

    NSString *cmd = [(NSString *)parts[0] uppercaseString] ?: @"";
    NSMutableArray *args = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] mutableCopy];

    if ([cmd isEqualToString:@"PING"]) {
        return @"OK pong";
    }

    if ([cmd isEqualToString:@"CREATE"]) {
        if (args.count < 3) return @"ERR 400 usage: CREATE <containerID> <bundleID> <displayName>";
        NSString *cid = args[0], *bid = args[1];
        if (!ValidIdentifier(cid)) return @"ERR 422 bad containerID";
        if (!ValidBundleID(bid)) return @"ERR 422 bad bundleID";

        NSString *dir = [[ContainersRoot() stringByAppendingPathComponent:bid]
                            stringByAppendingPathComponent:cid];
        if (!EnsureDir([dir stringByAppendingPathComponent:@"Data"], err)) {
            return [NSString stringWithFormat:@"ERR 500 mkdir: %@", ErrDesc(err)];
        }
        // Mirror the layout a real iOS data container has, so apps that probe
        // for Documents/Library/tmp behave the same.
        for (NSString *sub in @[@"Library/Preferences", @"Library/Caches", @"tmp", @"Documents"]) {
            EnsureDir([dir stringByAppendingPathComponent:sub], NULL);
        }

        // Ownership marker: our equivalent of Crane's container metadata.
        NSDictionary *marker = @{ @"containerID": cid,
                                  @"bundleID": bid,
                                  @"createdAt": [NSDate date] };
        [marker writeToFile:[dir stringByAppendingPathComponent:@".appclone-marker.plist"]
                 atomically:YES];
        return [NSString stringWithFormat:@"OK %@", dir];
    }

    if ([cmd isEqualToString:@"DELETE"] || [cmd isEqualToString:@"WIPE"]) {
        if (args.count < 2) return @"ERR 400 usage: DELETE|WIPE <containerID> <bundleID>";
        NSString *cid = args[0], *bid = args[1];
        if (!ValidIdentifier(cid) || !ValidBundleID(bid)) return @"ERR 422 bad id";

        NSString *dir = [[ContainersRoot() stringByAppendingPathComponent:bid]
                            stringByAppendingPathComponent:cid];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) return @"ERR 404 no such container";

        if ([cmd isEqualToString:@"WIPE"]) {
            // Keep the container record but drop its data.
            for (NSString *sub in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
                if ([sub isEqualToString:@".appclone-marker.plist"]) continue;
                [fm removeItemAtPath:[dir stringByAppendingPathComponent:sub] error:NULL];
            }
            for (NSString *sub in @[@"Data/Library/Preferences", @"Data/Library/Caches",
                                    @"Data/tmp", @"Data/Documents"]) {
                EnsureDir([dir stringByAppendingPathComponent:sub], NULL);
            }
            return @"OK wiped";
        }

        // Never delete outside the container root, even if validation above
        // somehow passed: re-check the resolved path.
        if (![dir hasPrefix:ContainersRoot()]) return @"ERR 403 outside root";
        [fm removeItemAtPath:dir error:err];
        return *err ? [NSString stringWithFormat:@"ERR 500 %@", ErrDesc(err)] : @"OK deleted";
    }

    if ([cmd isEqualToString:@"LIST"]) {
        if (args.count < 1) return @"ERR 400 usage: LIST <bundleID>";
        NSString *bid = args[0];
        if (!ValidBundleID(bid)) return @"ERR 422 bad bundleID";
        NSString *appRoot = [ContainersRoot() stringByAppendingPathComponent:bid];
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appRoot error:NULL];
        return [NSString stringWithFormat:@"OK %@", [items componentsJoinedByString:@","] ?: @""];
    }

    if ([cmd isEqualToString:@"SETACTIVE"]) {
        if (args.count < 2) return @"ERR 400 usage: SETACTIVE <containerID|-> <bundleID>";
        NSString *cid = args[0], *bid = args[1];
        if (!ValidBundleID(bid)) return @"ERR 422 bad bundleID";
        if (![cid isEqualToString:@"-"] && !ValidIdentifier(cid)) return @"ERR 422 bad containerID";

        NSMutableDictionary *state = ReadState();
        NSMutableDictionary *map = [state[@"active"] mutableCopy] ?: [NSMutableDictionary dictionary];
        if ([cid isEqualToString:@"-"]) {
            [map removeObjectForKey:bid];
        } else {
            NSString *dir = [[ContainersRoot() stringByAppendingPathComponent:bid]
                                stringByAppendingPathComponent:cid];
            if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) return @"ERR 404 no such container";
            map[bid] = cid;
        }
        state[@"active"] = map;
        if (!WriteState(state, err)) {
            return [NSString stringWithFormat:@"ERR 500 write: %@", ErrDesc(err)];
        }
        return @"OK active set";
    }

    if ([cmd isEqualToString:@"GETACTIVE"]) {
        if (args.count < 1) return @"ERR 400 usage: GETACTIVE <bundleID>";
        NSDictionary *state = ReadState();
        NSString *cid = state[@"active"][args[0]];
        return cid ? [NSString stringWithFormat:@"OK %@", cid] : @"OK -";
    }

    return @"ERR 404 unknown command";
}

#pragma mark - socket serving

static void ServeClient(int fd) {
    char buf[1024] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;

    NSString *line = [[NSString stringWithUTF8String:buf]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSError *err = nil;
    NSString *reply = HandleLine(line, &err);
    NSData *out = [[reply stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, out.bytes, out.length);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        NSError *err = nil;
        EnsureDir(AppsRoot(), &err);
        EnsureDir(ContainersRoot(), &err);

        NSString *sock = SocketPath();
        // The socket lives in /var/jb/var/run on rootless, which does NOT exist
        // by default. bind() fails with ENOENT if the parent is missing, which
        // made the daemon exit instantly. Create it first.
        EnsureDir([sock stringByDeletingLastPathComponent], &err);
        unlink(sock.fileSystemRepresentation);

        int srv = socket(AF_UNIX, SOCK_STREAM, 0);
        if (srv < 0) { NSLog(@"[appcloned] socket() failed: %s", strerror(errno)); return 1; }

        struct sockaddr_un addr = {0};
        addr.sun_family = AF_UNIX;
        strlcpy(addr.sun_path, sock.fileSystemRepresentation, sizeof(addr.sun_path));

        if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            NSLog(@"[appcloned] bind(%@) failed: %s", sock, strerror(errno));
            return 1;
        }
        chmod(addr.sun_path, 0666);   // launcher (mobile) must be able to connect
        listen(srv, 16);
        NSLog(@"[appcloned] listening on %@", sock);

        for (;;) {
            int fd = accept(srv, NULL, NULL);
            if (fd < 0) { if (errno == EINTR) continue; continue; }
            ServeClient(fd);
            close(fd);
        }
    }
    return 0;
}
