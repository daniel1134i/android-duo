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

        NSMutableArray *modes = [NSMutableArray array];
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:primaryWidth height:primaryHeight refreshRate:primaryRate]];

        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = modes;
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

        CGDisplayConfigRef configRef;
        if (CGBeginDisplayConfiguration(&configRef) != kCGErrorSuccess) return NO;

        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        CGRect myBounds = CGDisplayBounds(dID);
        int32_t originX = 0;
        int32_t originY = (int32_t)(mainBounds.origin.y + (mainBounds.size.height - myBounds.size.height));

        if (position && strcmp(position, "left") == 0) {
            originX = (int32_t)(mainBounds.origin.x - myBounds.size.width);
        } else {
            // Default: "right"
            originX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
        }

        CGConfigureDisplayOrigin(configRef, dID, originX, originY);
        CGError err = CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        if (err == kCGErrorSuccess) {
            NSLog(@"[VirtualDisplay] Repositioned display %u to %s at (%d, %d)", dID, position ? position : "right", originX, originY);
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

        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:(refreshRate > 0 ? refreshRate : 60.0)];
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = @[mode];
        settings.hiDPI = 0;

        BOOL applied = [s_activeVirtualDisplay applySettings:settings];
        if (applied) {
            NSLog(@"[VirtualDisplay] Mode successfully changed to %ux%u @ %.1fHz", width, height, refreshRate > 0 ? refreshRate : 60.0);
        } else {
            NSLog(@"[VirtualDisplay] Failed to change mode to %ux%u", width, height);
        }
        return applied;
    }
}

void destroy_virtual_display(CGDirectDisplayID displayID) {
    @autoreleasepool {
        if (s_activeVirtualDisplay != nil && [s_activeVirtualDisplay displayID] == displayID) {
            s_activeVirtualDisplay = nil;
            NSLog(@"[VirtualDisplay] Virtual Display destroyed: ID=%u", displayID);
        }
    }
}
