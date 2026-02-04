//! Zig bindings for stb_image
//! Provides image loading functionality for PNG, JPG, BMP, etc.

const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

/// Result of loading an image
pub const Image = struct {
    /// Pixel data in RGBA format (4 bytes per pixel)
    data: []u8,
    /// Image width in pixels
    width: u32,
    /// Image height in pixels
    height: u32,
    /// Number of channels (typically 4 for RGBA)
    channels: u32,

    /// Free the image data
    pub fn deinit(self: *Image) void {
        c.stbi_image_free(self.data.ptr);
        self.* = undefined;
    }
};

/// Load image from memory buffer
/// Returns null if loading fails
pub fn loadFromMemory(data: []const u8) ?Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    // Request 4 channels (RGBA)
    const pixels = c.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4, // desired channels: RGBA
    );

    if (pixels == null) {
        return null;
    }

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const pixel_count = w * h * 4;

    return Image{
        .data = pixels[0..pixel_count],
        .width = w,
        .height = h,
        .channels = 4,
    };
}

/// Get the last error message from stb_image
pub fn getFailureReason() ?[*:0]const u8 {
    const reason = c.stbi_failure_reason();
    return if (reason != null) reason else null;
}
