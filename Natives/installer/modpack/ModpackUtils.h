#import <Foundation/Foundation.h>

@class UZKArchive;

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;
+ (BOOL)modpackRequiresShaderFriendlyRenderer:(NSDictionary *)indexDict;

@end
