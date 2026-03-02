#import "GameSurfaceView.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

@interface GameSurfaceView()
@end

@implementation GameSurfaceView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.layer.drawsAsynchronously = YES;
    self.layer.opaque = YES;

    return self;
}

+ (Class)layerClass {
    NSString *rendererEnv = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    if ([rendererEnv hasPrefix:@"libOSMesa"]) {
        return CALayer.class;
    }

    NSString *rendererPref = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    if ([rendererPref hasPrefix:@"libOSMesa"]) {
        return CALayer.class;
    }

    BOOL shaderWorkload = [NSProcessInfo.processInfo.environment[@"POJAV_SHADER_WORKLOAD"] boolValue];
    if (shaderWorkload && [rendererPref isEqualToString:@"auto"]) {
        return CALayer.class;
    } else {
        return CAMetalLayer.class;
    }
}

@end
