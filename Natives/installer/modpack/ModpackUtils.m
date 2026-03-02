#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

static NSString *MPStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }
    return nil;
}

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir] ||
            fileInfo.filename.length <= dir.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    if (![dependency isKindOfClass:NSDictionary.class]) {
        return @{};
    }

    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = MPStringValue(dependency[@"minecraft"]);
    NSString *forgeVersion = MPStringValue(dependency[@"forge"]);
    NSString *neoForgeVersion = MPStringValue(dependency[@"neoforge"]);
    NSString *fabricLoaderVersion = MPStringValue(dependency[@"fabric-loader"]);
    NSString *quiltLoaderVersion = MPStringValue(dependency[@"quilt-loader"]);

    if (forgeVersion.length > 0 && minecraftVersion.length > 0) {
        NSString *fullForgeVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, forgeVersion];
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, forgeVersion];
        info[@"installerVendor"] = @"Forge";
        info[@"installerVersion"] = fullForgeVersion;
        info[@"installer"] = [NSString stringWithFormat:
            @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
            fullForgeVersion];
    } else if (neoForgeVersion.length > 0) {
        // NeoForge installer's install_profile.json uses "neoforge-<version>".
        info[@"id"] = [NSString stringWithFormat:@"neoforge-%@", neoForgeVersion];
        info[@"installerVendor"] = @"NeoForge";
        info[@"installerVersion"] = neoForgeVersion;
        info[@"installer"] = [NSString stringWithFormat:
            @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
            neoForgeVersion];
    } else if (fabricLoaderVersion.length > 0 && minecraftVersion.length > 0) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", fabricLoaderVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, fabricLoaderVersion];
    } else if (quiltLoaderVersion.length > 0 && minecraftVersion.length > 0) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", quiltLoaderVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, quiltLoaderVersion];
    }

    return info;
}

+ (BOOL)modpackRequiresShaderFriendlyRenderer:(NSDictionary *)indexDict {
    NSArray *files = indexDict[@"files"];
    if (![files isKindOfClass:NSArray.class]) {
        return NO;
    }

    NSArray<NSString *> *shaderModHints = @[
        @"iris",
        @"oculus",
        @"optifine",
        @"embeddium",
        @"rubidium",
        @"sodium"
    ];
    for (NSDictionary *indexFile in files) {
        if (![indexFile isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *path = [MPStringValue(indexFile[@"path"]) lowercaseString];
        if (path.length == 0) {
            continue;
        }

        if ([path hasPrefix:@"shaderpacks/"] || [path containsString:@"/shaderpacks/"]) {
            return YES;
        }
        if (![path hasPrefix:@"mods/"]) {
            continue;
        }

        for (NSString *hint in shaderModHints) {
            if ([path containsString:hint]) {
                return YES;
            }
        }
    }
    return NO;
}

@end
