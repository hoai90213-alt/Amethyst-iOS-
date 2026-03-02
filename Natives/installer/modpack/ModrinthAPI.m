#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

static NSDictionary *ModrinthPreferredVersionFile(NSDictionary *versionDict) {
    NSArray *files = versionDict[@"files"];
    if (![files isKindOfClass:NSArray.class] || files.count == 0) {
        return nil;
    }

    for (NSDictionary *file in files) {
        if ([file[@"primary"] boolValue]) {
            return file;
        }
    }
    for (NSDictionary *file in files) {
        NSString *fileName = [file[@"filename"] lowercaseString];
        if ([fileName hasSuffix:@".mrpack"]) {
            return file;
        }
    }
    return files.firstObject;
}

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (![response isKindOfClass:NSArray.class]) {
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        if (![version isKindOfClass:NSDictionary.class]) {
            return;
        }
        NSDictionary *file = ModrinthPreferredVersionFile(version);
        NSString *url = file[@"url"];
        if (![url isKindOfClass:NSString.class] || url.length == 0) {
            return;
        }

        NSString *name = version[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            name = version[@"version_number"];
        }
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            name = [NSString stringWithFormat:@"Version %lu", (unsigned long)(i + 1)];
        }
        [names addObject:name];

        NSArray *gameVersions = version[@"game_versions"];
        NSString *mcVersion = [gameVersions isKindOfClass:NSArray.class] ? gameVersions.firstObject : nil;
        [mcNames addObject:[mcVersion isKindOfClass:NSString.class] ? mcVersion : @"unknown"];

        [sizes addObject:@([file[@"size"] unsignedLongLongValue])];
        [urls addObject:url];

        NSDictionary *hashesMap = file[@"hashes"];
        id sha1 = [hashesMap[@"sha1"] isKindOfClass:NSString.class] ? hashesMap[@"sha1"] : [NSNull null];
        [hashes addObject:sha1];
    }];

    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:1001 userInfo:@{
            NSLocalizedDescriptionKey: @"No installable version files were found for this project."
        }];
        return;
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error || !archive) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (error || !indexData) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error || ![indexDict isKindOfClass:NSDictionary.class]) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    NSArray *indexFiles = indexDict[@"files"];
    if (![indexFiles isKindOfClass:NSArray.class]) {
        [downloader finishDownloadWithErrorString:@"Invalid modrinth.index.json: files list is missing."];
        return;
    }

    // Drop the placeholder unit injected by prepareForDownload().
    if (downloader.progress.totalUnitCount > 0 && downloader.textProgress.totalUnitCount > 0) {
        downloader.progress.totalUnitCount--;
        downloader.textProgress.totalUnitCount--;
    }

    for (NSDictionary *indexFile in indexFiles) {
        if (![indexFile isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSArray *downloads = indexFile[@"downloads"];
        NSString *url = [downloads isKindOfClass:NSArray.class] ? downloads.firstObject : nil;
        NSString *relativePath = [indexFile[@"path"] isKindOfClass:NSString.class] ? indexFile[@"path"] : nil;
        if (url.length == 0 || relativePath.length == 0) {
            continue;
        }
        NSDictionary *hashes = [indexFile[@"hashes"] isKindOfClass:NSDictionary.class] ? indexFile[@"hashes"] : nil;
        NSString *sha = [hashes[@"sha1"] isKindOfClass:NSString.class] ? hashes[@"sha1"] : nil;
        NSString *path = [destPath stringByAppendingPathComponent:relativePath];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [task resume];
        } else {
            if (downloader.progress.cancelled) {
                return;
            }
        }
    }

    error = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    error = nil;
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *dependencies = [indexDict[@"dependencies"] isKindOfClass:NSDictionary.class] ? indexDict[@"dependencies"] : nil;
    NSDictionary *depInfo = [ModpackUtils infoForDependencies:dependencies];
    NSString *depId = [depInfo[@"id"] isKindOfClass:NSString.class] ? depInfo[@"id"] : nil;

    // Download dependency client json (Fabric/Quilt) if available.
    NSString *depJsonURL = [depInfo[@"json"] isKindOfClass:NSString.class] ? depInfo[@"json"] : nil;
    if (depJsonURL.length > 0 && depId.length > 0) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depId];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depJsonURL size:0 sha:nil altName:nil toPath:jsonPath];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }

    // Download loader installer (Forge/NeoForge) so user can run it immediately.
    NSString *installerURL = [depInfo[@"installer"] isKindOfClass:NSString.class] ? depInfo[@"installer"] : nil;
    if (installerURL.length > 0) {
        NSString *installerVendor = [depInfo[@"installerVendor"] isKindOfClass:NSString.class] ? depInfo[@"installerVendor"] : @"Mod Loader";
        NSString *installerVersion = [depInfo[@"installerVersion"] isKindOfClass:NSString.class] ? depInfo[@"installerVersion"] : (depId ?: @"latest");
        NSString *safeVersion = [[installerVersion stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
            stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        NSString *installerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"modpack-%@-%@-installer.jar", installerVendor.lowercaseString, safeVersion]];

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:installerURL size:0 sha:nil altName:nil toPath:installerPath];
        if (task) {
            downloader.pendingModLoaderInstallerPath = installerPath;
            downloader.pendingModLoaderName = installerVendor;
            [task resume];
        } else if ([NSFileManager.defaultManager fileExistsAtPath:installerPath]) {
            downloader.pendingModLoaderInstallerPath = installerPath;
            downloader.pendingModLoaderName = installerVendor;
        } else if (downloader.progress.cancelled) {
            return;
        } else {
            [downloader finishDownloadWithErrorString:
                [NSString stringWithFormat:@"Failed to prepare %@ installer for this modpack.", installerVendor]];
            return;
        }
    }

    // Create profile
    NSString *profileName = indexDict[@"name"];
    if (![profileName isKindOfClass:NSString.class] || profileName.length == 0) {
        profileName = destPath.lastPathComponent ?: @"Imported Modpack";
    }
    NSString *lastVersionId = depId;
    if (lastVersionId.length == 0) {
        NSString *mcVersion = [dependencies[@"minecraft"] isKindOfClass:NSString.class] ? dependencies[@"minecraft"] : nil;
        lastVersionId = [mcVersion isKindOfClass:NSString.class] && mcVersion.length > 0 ? mcVersion : @"latest-release";
    }

    NSMutableDictionary *profile = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": lastVersionId
    }.mutableCopy;

    if ([ModpackUtils modpackRequiresShaderFriendlyRenderer:indexDict]) {
        // Use the OpenGL 4.1 renderer for shader-focused packs.
        profile[@"renderer"] = @"libOSMesa.8.dylib";
    }

    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData.length > 0) {
        profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@",
            [iconData base64EncodedStringWithOptions:0]];
    }

    PLProfiles.current.profiles[profileName] = profile;
    PLProfiles.current.selectedProfileName = profileName;
}

@end
