#import "CryptoMakoFuseHost.h"
#import <macFUSE/macFUSE.h>

@interface CryptoMakoFuseAdapter : NSObject
@property (nonatomic, weak) id<CryptoMakoVaultFS> vaultFS;
@end

@implementation CryptoMakoFuseAdapter

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path
            includingAttributesForKeys:(NSArray *)keys
                                 error:(NSError **)error {
    NSArray<NSDictionary *> *items = [self.vaultFS listDirectoryAtPath:path error:error];
    if (!items) { return nil; }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSString *name = item[@"name"];
        NSDictionary *attrs = item[@"attributes"];
        if (!name) { continue; }
        [out addObject:[GMDirectoryEntry directoryEntryWithName:name attributes:attrs ?: @{}]];
    }
    return out;
}

- (NSDictionary *)attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error {
    return [self.vaultFS attributesOfFileSystemForPath:path error:error];
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path userData:(id)userData error:(NSError **)error {
    return [self.vaultFS attributesOfItemAtPath:path userData:userData error:error];
}

- (BOOL)createDirectoryAtPath:(NSString *)path attributes:(NSDictionary *)attributes error:(NSError **)error {
    return [self.vaultFS createDirectoryAtPath:path attributes:attributes error:error];
}

- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError **)error {
    return [self.vaultFS removeDirectoryAtPath:path error:error];
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    return [self.vaultFS removeItemAtPath:path error:error];
}

- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                   flags:(int)flags
                userData:(id *)userData
                   error:(NSError **)error {
    return [self.vaultFS createFileAtPath:path attributes:attributes flags:flags userData:userData error:error];
}

- (BOOL)openFileAtPath:(NSString *)path mode:(int)mode userData:(id *)userData error:(NSError **)error {
    return [self.vaultFS openFileAtPath:path mode:mode userData:userData error:error];
}

- (void)releaseFileAtPath:(NSString *)path userData:(id)userData {
    [self.vaultFS releaseFileAtPath:path userData:userData];
}

- (int)readFileAtPath:(NSString *)path
             userData:(id)userData
               buffer:(char *)buffer
                 size:(size_t)size
               offset:(off_t)offset
                error:(NSError **)error {
    return [self.vaultFS readFileAtPath:path userData:userData buffer:buffer size:size offset:offset error:error];
}

- (int)writeFileAtPath:(NSString *)path
              userData:(id)userData
                buffer:(const char *)buffer
                  size:(size_t)size
                offset:(off_t)offset
                 error:(NSError **)error {
    return [self.vaultFS writeFileAtPath:path userData:userData buffer:buffer size:size offset:offset error:error];
}

- (BOOL)setAttributes:(NSDictionary *)attributes
         ofItemAtPath:(NSString *)path
             userData:(id)userData
                error:(NSError **)error {
    return [self.vaultFS setAttributes:attributes ofItemAtPath:path userData:userData error:error];
}

@end

@implementation CryptoMakoFuseHost {
    GMUserFileSystem *_fs;
    CryptoMakoFuseAdapter *_adapter;
}

- (instancetype)initWithVaultFS:(id<CryptoMakoVaultFS>)vaultFS {
    self = [super init];
    if (self) {
        _adapter = [[CryptoMakoFuseAdapter alloc] init];
        _adapter.vaultFS = vaultFS;
        _fs = [[GMUserFileSystem alloc] initWithDelegate:_adapter isThreadSafe:NO];
    }
    return self;
}

- (void)mountAtPath:(NSString *)path options:(NSArray<NSString *> *)options {
    [_fs mountAtPath:path withOptions:options shouldForeground:YES detachNewThread:YES];
}

- (void)unmount {
    [_fs unmount];
}

+ (NSNotificationName)didMountNotification { return kGMUserFileSystemDidMount; }
+ (NSNotificationName)mountFailedNotification { return kGMUserFileSystemMountFailed; }
+ (NSNotificationName)didUnmountNotification { return kGMUserFileSystemDidUnmount; }
+ (NSString *)errorUserInfoKey { return kGMUserFileSystemErrorKey; }

@end
