#import "virtual_display.h"

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic, assign) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static CGVirtualDisplay *s_activeVirtualDisplay = nil;
static NSMutableArray *s_registeredModes = nil;
static char s_currentPosition[16] = "right";

CGDirectDisplayID create_virtual_display(uint32_t width, uint32_t height, double refreshRate, const char *name) {
    @autoreleasepool {
        if (s_activeVirtualDisplay != nil) {
            return [s_activeVirtualDisplay displayID];
        }

        uint32_t primaryWidth = (width > 0) ? width : 1280;
        uint32_t primaryHeight = (height > 0) ? height : 800;
        double primaryRate = (refreshRate > 0) ? refreshRate : 90.0;

        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = name ? [NSString stringWithUTF8String:name] : @"Xiaomi Pad SE (Android Duo)";
        desc.maxPixelsWide = (primaryWidth < 2560) ? 2560 : primaryWidth;
        desc.maxPixelsHigh = (primaryHeight < 1600) ? 1600 : primaryHeight;
        desc.sizeInMillimeters = CGSizeMake(508, 317);
        desc.productID = 0x1923;
        desc.vendorID = 0x1200;
        desc.queue = dispatch_get_main_queue();

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (!display) {
            NSLog(@"[VirtualDisplay] Failed to initialize CGVirtualDisplay");
            return 0;
        }

        s_registeredModes = [NSMutableArray array];
        uint32_t presets[][2] = {
            {1280, 800},
            {1440, 900},
            {1600, 1000},
            {1920, 1200},
            {2560, 1600},
            {1024, 640}
        };
        for (int i = 0; i < 6; i++) {
            [s_registeredModes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:presets[i][0] height:presets[i][1] refreshRate:primaryRate]];
        }
        BOOL hasPrimary = NO;
        for (int i = 0; i < 6; i++) {
            if (presets[i][0] == primaryWidth && presets[i][1] == primaryHeight) {
                hasPrimary = YES;
                break;
            }
        }
        if (!hasPrimary) {
            [s_registeredModes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:primaryWidth height:primaryHeight refreshRate:primaryRate]];
        }

        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = s_registeredModes;
        settings.hiDPI = 0;

        BOOL applied = [display applySettings:settings];
        if (!applied) {
            NSLog(@"[VirtualDisplay] Failed to apply display settings");
            return 0;
        }

        s_activeVirtualDisplay = display;
        NSLog(@"[VirtualDisplay] Virtual Display created successfully: ID=%u (%ux%u @ %.1fHz)",
              display.displayID, primaryWidth, primaryHeight, primaryRate);

        // Automatically position virtual display to the RIGHT of the primary display
        CGDisplayConfigRef configRef;
        if (CGBeginDisplayConfiguration(&configRef) == kCGErrorSuccess) {
            CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
            int32_t originX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
            int32_t originY = (int32_t)(mainBounds.origin.y + (mainBounds.size.height - primaryHeight));
            CGConfigureDisplayOrigin(configRef, display.displayID, originX, originY);
            CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
            NSLog(@"[VirtualDisplay] Auto-placed display %u to the RIGHT of main display at (%d, %d) with bottom alignment",
                  display.displayID, originX, originY);
        }

        return display.displayID;
    }
}

BOOL set_virtual_display_position(const char *position) {
    @autoreleasepool {
        if (!s_activeVirtualDisplay) return NO;
        CGDirectDisplayID dID = [s_activeVirtualDisplay displayID];
        if (dID == 0) return NO;

        if (position && strcmp(position, "left") == 0) {
            strlcpy(s_currentPosition, "left", sizeof(s_currentPosition));
        } else {
            strlcpy(s_currentPosition, "right", sizeof(s_currentPosition));
        }

        CGDisplayConfigRef configRef;
        if (CGBeginDisplayConfiguration(&configRef) != kCGErrorSuccess) return NO;

        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        CGRect myBounds = CGDisplayBounds(dID);
        int32_t originX = 0;
        int32_t originY = (int32_t)(mainBounds.origin.y + (mainBounds.size.height - myBounds.size.height));

        if (strcmp(s_currentPosition, "left") == 0) {
            originX = (int32_t)(mainBounds.origin.x - myBounds.size.width);
        } else {
            // Default: "right"
            originX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
        }

        CGConfigureDisplayOrigin(configRef, dID, originX, originY);
        CGError err = CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        if (err == kCGErrorSuccess) {
            NSLog(@"[VirtualDisplay] Repositioned display %u to %s at (%d, %d)", dID, s_currentPosition, originX, originY);
            return YES;
        }
        return NO;
    }
}

BOOL set_virtual_display_mode(uint32_t width, uint32_t height, double refreshRate) {
    @autoreleasepool {
        if (!s_activeVirtualDisplay) {
            NSLog(@"[VirtualDisplay] Cannot set mode: no active virtual display");
            return NO;
        }

        CGDirectDisplayID dID = [s_activeVirtualDisplay displayID];
        if (dID == 0) return NO;

        double rate = (refreshRate > 0) ? refreshRate : 90.0;

        // Find existing mode in CoreGraphics display modes
        CFArrayRef modeList = CGDisplayCopyAllDisplayModes(dID, NULL);
        CGDisplayModeRef targetMode = NULL;
        if (modeList) {
            CFIndex count = CFArrayGetCount(modeList);
            for (CFIndex i = 0; i < count; i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modeList, i);
                if (CGDisplayModeGetWidth(m) == width && CGDisplayModeGetHeight(m) == height) {
                    targetMode = m;
                    break;
                }
            }
        }

        // If not found in WindowServer mode list, add to s_registeredModes and apply settings
        if (!targetMode) {
            if (!s_registeredModes) {
                s_registeredModes = [NSMutableArray array];
            }
            CGVirtualDisplayMode *newMode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:rate];
            [s_registeredModes addObject:newMode];
            CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
            settings.modes = s_registeredModes;
            settings.hiDPI = 0;
            [s_activeVirtualDisplay applySettings:settings];

            if (modeList) CFRelease(modeList);
            modeList = CGDisplayCopyAllDisplayModes(dID, NULL);
            if (modeList) {
                CFIndex count = CFArrayGetCount(modeList);
                for (CFIndex i = 0; i < count; i++) {
                    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modeList, i);
                    if (CGDisplayModeGetWidth(m) == width && CGDisplayModeGetHeight(m) == height) {
                        targetMode = m;
                        break;
                    }
                }
            }
        }

        if (!targetMode) {
            NSLog(@"[VirtualDisplay] Mode %ux%u could not be resolved in CoreGraphics modes", width, height);
            if (modeList) CFRelease(modeList);
            return NO;
        }

        CGDisplayConfigRef configRef;
        if (CGBeginDisplayConfiguration(&configRef) != kCGErrorSuccess) {
            NSLog(@"[VirtualDisplay] CGBeginDisplayConfiguration failed");
            if (modeList) CFRelease(modeList);
            return NO;
        }

        CGConfigureDisplayWithDisplayMode(configRef, dID, targetMode, NULL);

        // Keep display aligned with main display
        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        int32_t originX;
        if (strcmp(s_currentPosition, "left") == 0) {
            originX = (int32_t)(mainBounds.origin.x - width);
        } else {
            originX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
        }
        int32_t originY = (int32_t)(mainBounds.origin.y + (mainBounds.size.height - height));
        CGConfigureDisplayOrigin(configRef, dID, originX, originY);

        CGError err = CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        if (modeList) CFRelease(modeList);

        if (err == kCGErrorSuccess) {
            NSLog(@"[VirtualDisplay] Display mode successfully switched to %ux%u @ (X:%d, Y:%d)", width, height, originX, originY);
            return YES;
        } else {
            NSLog(@"[VirtualDisplay] CGCompleteDisplayConfiguration failed with error %d", err);
            return NO;
        }
    }
}

void destroy_virtual_display(CGDirectDisplayID displayID) {
    @autoreleasepool {
        if (s_activeVirtualDisplay != nil && [s_activeVirtualDisplay displayID] == displayID) {
            s_activeVirtualDisplay = nil;
            s_registeredModes = nil;
            NSLog(@"[VirtualDisplay] Virtual Display destroyed: ID=%u", displayID);
        }
    }
}
