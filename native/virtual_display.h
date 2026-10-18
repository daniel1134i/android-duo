#ifndef VIRTUAL_DISPLAY_H
#define VIRTUAL_DISPLAY_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// Creates a virtual display with specified width, height and refresh rate.
// Returns the CGDirectDisplayID of the created display, or 0 on failure.
CGDirectDisplayID create_virtual_display(uint32_t width, uint32_t height, double refreshRate, const char *name);

// Dynamically changes the resolution/mode of the active virtual display
BOOL set_virtual_display_mode(uint32_t width, uint32_t height, double refreshRate);

// Dynamically changes arrangement position: "right" (default) or "left"
BOOL set_virtual_display_position(const char *position);

// Destroys the virtual display.
void destroy_virtual_display(CGDirectDisplayID displayID);

#ifdef __cplusplus
}
#endif

#endif // VIRTUAL_DISPLAY_H
