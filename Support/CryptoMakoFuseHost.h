#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plain-typed ops implemented in Swift. No macFUSE types cross this boundary.
@protocol CryptoMakoVaultFS <NSObject>
- (nullable NSArray<NSDictionary *> *)listDirectoryAtPath:(NSString *)path error:(NSError **)error;
- (nullable NSDictionary *)attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error;
- (nullable NSDictionary *)attributesOfItemAtPath:(NSString *)path userData:(nullable id)userData error:(NSError **)error;
- (BOOL)createDirectoryAtPath:(NSString *)path attributes:(NSDictionary *)attributes error:(NSError **)error;
- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)createFileAtPath:(NSString *)path attributes:(NSDictionary *)attributes flags:(int)flags userData:(id _Nullable * _Nonnull)userData error:(NSError **)error;
- (BOOL)openFileAtPath:(NSString *)path mode:(int)mode userData:(id _Nullable * _Nonnull)userData error:(NSError **)error;
- (void)releaseFileAtPath:(NSString *)path userData:(nullable id)userData;
- (int)readFileAtPath:(NSString *)path userData:(nullable id)userData buffer:(char *)buffer size:(size_t)size offset:(off_t)offset error:(NSError **)error;
- (int)writeFileAtPath:(NSString *)path userData:(nullable id)userData buffer:(const char *)buffer size:(size_t)size offset:(off_t)offset error:(NSError **)error;
- (BOOL)setAttributes:(NSDictionary *)attributes ofItemAtPath:(NSString *)path userData:(nullable id)userData error:(NSError **)error;
@end

@interface CryptoMakoFuseHost : NSObject
- (instancetype)initWithVaultFS:(id<CryptoMakoVaultFS>)vaultFS;
- (void)mountAtPath:(NSString *)path options:(NSArray<NSString *> *)options;
- (void)unmount;

+ (NSNotificationName)didMountNotification;
+ (NSNotificationName)mountFailedNotification;
+ (NSNotificationName)didUnmountNotification;
+ (NSString *)errorUserInfoKey;
@end

NS_ASSUME_NONNULL_END
