#import <Foundation/Foundation.h>
#import <os/log.h>
#import <unistd.h>

static BOOL SCIAppStoreReceiptSpoofIsActive = NO;

static BOOL SCIURLLooksLikeSandboxReceipt(NSURL *url) {
    return [url isKindOfClass:[NSURL class]] && [url.lastPathComponent isEqualToString:@"sandboxReceipt"];
}

static BOOL SCIPathLooksLikeNormalizedReceipt(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || ![path.lastPathComponent isEqualToString:@"receipt"]) return NO;

    NSString *lowercasePath = [path lowercaseString];
    return [lowercasePath containsString:@"storekit"] ||
           [lowercasePath containsString:@"appstorereceipt"];
}

static BOOL SCIPathExistsWithoutHookingFileManager(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length) return NO;
    return access([path fileSystemRepresentation], F_OK) == 0;
}

static NSURL *SCIFakeAppStoreReceiptURL(void) {
    NSArray<NSURL *> *cacheURLs = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
    NSURL *cacheURL = cacheURLs.firstObject;
    if (![cacheURL isKindOfClass:[NSURL class]]) return nil;

    NSURL *receiptDirectoryURL = [[cacheURL URLByAppendingPathComponent:@"SCInsta" isDirectory:YES] URLByAppendingPathComponent:@"StoreKit" isDirectory:YES];
    NSURL *receiptURL = [receiptDirectoryURL URLByAppendingPathComponent:@"receipt"];

    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:receiptDirectoryURL withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) {
        os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: failed to create receipt directory");
        return nil;
    }

    if (!SCIPathExistsWithoutHookingFileManager(receiptURL.path)) {
        NSData *placeholderReceipt = [@"SCInsta placeholder receipt" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *writeError = nil;
        [placeholderReceipt writeToURL:receiptURL options:NSDataWritingAtomic error:&writeError];
        if (writeError) {
            os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: failed to write placeholder receipt");
            return nil;
        }
    }

    return SCIPathExistsWithoutHookingFileManager(receiptURL.path) ? receiptURL : nil;
}

static NSURL *SCINormalizedAppStoreReceiptURL(NSURL *receiptURL) {
    if (!SCIURLLooksLikeSandboxReceipt(receiptURL)) return receiptURL;

    NSURL *fakeReceiptURL = SCIFakeAppStoreReceiptURL();
    if (fakeReceiptURL) {
        SCIAppStoreReceiptSpoofIsActive = YES;
        os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: sandboxReceipt -> cache receipt");
        return fakeReceiptURL;
    }

    SCIAppStoreReceiptSpoofIsActive = YES;
    NSURL *normalReceiptURL = [[receiptURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"receipt"];
    os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: sandboxReceipt -> receipt fallback");
    return normalReceiptURL;
}

%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    return SCINormalizedAppStoreReceiptURL(%orig);
}
%end

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (SCIAppStoreReceiptSpoofIsActive && SCIPathLooksLikeNormalizedReceipt(path)) {
        os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: reporting normalized receipt exists");
        return YES;
    }

    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (SCIAppStoreReceiptSpoofIsActive && SCIPathLooksLikeNormalizedReceipt(path)) {
        if (isDirectory) *isDirectory = NO;
        os_log(OS_LOG_DEFAULT, "[SCInsta] App Store receipt spoof: reporting normalized receipt exists");
        return YES;
    }

    return %orig;
}
%end
