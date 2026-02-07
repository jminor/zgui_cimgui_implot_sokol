#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Cocoa/Cocoa.h>
#include "stb_image_write.h"

// Forward declaration
void saveScreenshot(const char* filename);

void saveScreenshot(const char* filename) {
    NSWindow* window = [NSApp keyWindow];
    if (!window) {
        printf("Error: No key window found.\n");
        return;
    }

    NSView* view = [window contentView];
    if (![view isKindOfClass:[MTKView class]]) {
        printf("Error: Content view is not an MTKView.\n");
        return;
    }

    MTKView* mtkView = (MTKView*)view;
    id<CAMetalDrawable> drawable = [mtkView currentDrawable];
    if (!drawable) {
        printf("Error: No current drawable.\n");
        return;
    }

    id<MTLTexture> texture = [drawable texture];
    if (!texture) {
        printf("Error: No texture in drawable.\n");
        return;
    }

    NSUInteger width = [texture width];
    NSUInteger height = [texture height];
    NSUInteger bytesPerPixel = 4; // Assuming BGRA8Unorm or RGBA8Unorm
    NSUInteger bytesPerRow = width * bytesPerPixel;
    NSUInteger totalBytes = height * bytesPerRow;

    // Create a buffer to read the texture pixels
    unsigned char* buffer = (unsigned char*)malloc(totalBytes);
    if (!buffer) {
        printf("Error: Failed to allocate buffer.\n");
        return;
    }

    // Get the region to copy
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    
    // Check pixel format to ensure we handle it correctly
    // Most likely MTLPixelFormatBGRA8Unorm
    [texture getBytes:buffer bytesPerRow:bytesPerRow fromRegion:region mipmapLevel:0];

    // Metal usually uses BGRA, stbi_write_png expects RGBA (usually)
    // We need to swap B and R if it is BGRA
    if ([texture pixelFormat] == MTLPixelFormatBGRA8Unorm || 
        [texture pixelFormat] == MTLPixelFormatBGRA8Unorm_sRGB) {
        for (NSUInteger i = 0; i < totalBytes; i += 4) {
            unsigned char b = buffer[i];
            unsigned char r = buffer[i+2];
            buffer[i] = r;
            buffer[i+2] = b;
        }
    }

    // Write to PNG
    // stbi_write_png(char const *filename, int w, int h, int comp, const void  *data, int stride_in_bytes)
    // comp=4 for RGBA
    if (stbi_write_png(filename, (int)width, (int)height, 4, buffer, (int)bytesPerRow)) {
        printf("Screenshot saved to %s\n", filename);
    } else {
        printf("Error: Failed to write PNG.\n");
    }

    free(buffer);
}
