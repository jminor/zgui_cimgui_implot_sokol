//! zview - A simple image viewer application
//! Loads an image file specified on the command line and displays it with
//! zoom and pan controls.

const std = @import("std");
const builtin = @import("builtin");

const ziis = @import("zgui_cimgui_implot_sokol");
const zgui = ziis.zgui;
const sg = ziis.sokol.gfx;
const sapp = ziis.sokol.app;
const app_wrapper = ziis.app_wrapper;
const cimgui = ziis.cimgui;

const IS_WASM = builtin.target.cpu.arch.isWasm();

/// State container for the image viewer
const STATE = struct {
    // Image data
    var image_path: [:0]const u8 = "";
    var image_tex: sg.Image = .{};
    var image_view: sg.View = .{};
    var image_texid: u64 = 0;
    var image_width: u32 = 0;
    var image_height: u32 = 0;
    var image_loaded: bool = false;
    var load_error: ?[]const u8 = null;

    // View state
    var zoom: f32 = 1.0;
    var scroll_x: f32 = 0.0;
    var scroll_y: f32 = 0.0;

    // Screen dimensions for constraining window size
    const MAX_WINDOW_WIDTH: f32 = 1920;
    const MAX_WINDOW_HEIGHT: f32 = 1080;
    const TOOLBAR_HEIGHT: f32 = 40.0;
    const MIN_WINDOW_WIDTH: f32 = 400;
    const MIN_WINDOW_HEIGHT: f32 = 300;
};

/// GPA for native builds
var debug_allocator = (if (IS_WASM) null else std.heap.DebugAllocator(.{}){});
const allocator = (if (IS_WASM) std.heap.c_allocator else debug_allocator.allocator());

/// Load image from file path
fn loadImage(path: []const u8) !void {
    // Read file contents
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        STATE.load_error = "Failed to open file";
        std.log.err("Failed to open file '{s}': {any}", .{ path, err });
        return err;
    };
    defer file.close();

    const file_size = file.getEndPos() catch |err| {
        STATE.load_error = "Failed to get file size";
        std.log.err("Failed to get file size: {any}", .{err});
        return err;
    };

    const file_data = allocator.alloc(u8, file_size) catch |err| {
        STATE.load_error = "Out of memory";
        std.log.err("Failed to allocate memory for file: {any}", .{err});
        return err;
    };
    defer allocator.free(file_data);

    const bytes_read = file.readAll(file_data) catch |err| {
        STATE.load_error = "Failed to read file";
        std.log.err("Failed to read file: {any}", .{err});
        return err;
    };

    // Decode image using stb_image
    var img = ziis.stb_image.loadFromMemory(file_data[0..bytes_read]) orelse {
        const reason = ziis.stb_image.getFailureReason();
        if (reason) |r| {
            std.log.err("Failed to decode image: {s}", .{r});
        } else {
            std.log.err("Failed to decode image: unknown error", .{});
        }
        STATE.load_error = "Failed to decode image";
        return error.ImageDecodeError;
    };
    defer img.deinit();

    STATE.image_width = img.width;
    STATE.image_height = img.height;

    // Create ImageData with the pixel data
    var image_data = sg.ImageData{};
    image_data.mip_levels[0] = sg.asRange(img.data);

    // Create the sokol image/texture
    STATE.image_tex = sg.makeImage(.{
        .width = @intCast(img.width),
        .height = @intCast(img.height),
        .pixel_format = .RGBA8,
        .data = image_data,
    });

    STATE.image_view = sg.makeView(.{
        .texture = .{
            .image = STATE.image_tex,
        },
    });

    STATE.image_texid = ziis.sokol.imgui.imtextureid(STATE.image_view);
    STATE.image_loaded = true;

    std.log.info("Image loaded: {}x{} pixels", .{ img.width, img.height });
}

/// Draw the UI
fn draw() !void {
    const vp = zgui.getMainViewport();
    const size = vp.getSize();

    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = size[0], .h = size[1] });

    if (zgui.begin(
        "###ZVIEW",
        .{
            .flags = .{
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .no_title_bar = true,
                .no_bring_to_front_on_focus = true,
                .menu_bar = false,
            },
        },
    )) {
        defer zgui.end();

        // Toolbar
        drawToolbar();

        zgui.separator();

        // Image display area
        if (STATE.image_loaded) {
            drawImageView();
        } else if (STATE.load_error) |err| {
            zgui.pushStyleColor4f(.{ .idx = .text, .c = .{ 1.0, 0.3, 0.3, 1.0 } });
            zgui.text("Error: {s}", .{err});
            zgui.popStyleColor(.{});
        } else {
            zgui.text("No image loaded", .{});
            zgui.text("Usage: zview <image_file>", .{});
        }
    }
}

/// Draw the toolbar with zoom controls
fn drawToolbar() void {
    // Zoom out button
    if (zgui.button("-  Zoom Out", .{})) {
        STATE.zoom = @max(0.1, STATE.zoom * 0.8);
    }

    zgui.sameLine(.{});

    // Zoom level display
    zgui.text("{d:.0}%%", .{STATE.zoom * 100});

    zgui.sameLine(.{});

    // Zoom in button
    if (zgui.button("+  Zoom In", .{})) {
        STATE.zoom = @min(10.0, STATE.zoom * 1.25);
    }

    zgui.sameLine(.{});

    // Reset zoom button (1:1)
    if (zgui.button("1:1 Reset", .{})) {
        STATE.zoom = 1.0;
        STATE.scroll_x = 0;
        STATE.scroll_y = 0;
    }

    zgui.sameLine(.{});

    // Fit to window button
    if (zgui.button("Fit", .{})) {
        fitToWindow();
    }

    zgui.sameLine(.{});
    zgui.spacing();
    zgui.sameLine(.{});

    // Display image info
    if (STATE.image_loaded) {
        zgui.text("| {}x{} pixels | {s}", .{ STATE.image_width, STATE.image_height, STATE.image_path });
    }
}

/// Fit image to current window size
fn fitToWindow() void {
    if (!STATE.image_loaded) return;

    const vp = zgui.getMainViewport();
    const size = vp.getSize();

    const avail_w = size[0] - 20; // Account for window padding
    const avail_h = size[1] - STATE.TOOLBAR_HEIGHT - 40; // Account for toolbar and padding

    const img_w: f32 = @floatFromInt(STATE.image_width);
    const img_h: f32 = @floatFromInt(STATE.image_height);

    const scale_w = avail_w / img_w;
    const scale_h = avail_h / img_h;

    STATE.zoom = @min(scale_w, scale_h);
    STATE.scroll_x = 0;
    STATE.scroll_y = 0;
}

/// Draw the image with scrollbars
fn drawImageView() void {
    const img_w: f32 = @floatFromInt(STATE.image_width);
    const img_h: f32 = @floatFromInt(STATE.image_height);

    // Calculate display dimensions
    const display_w = img_w * STATE.zoom;
    const display_h = img_h * STATE.zoom;

    // Get available space
    const avail = zgui.getContentRegionAvail();

    // Create a child window with scrollbars
    if (zgui.beginChild(
        "ImageContainer",
        .{
            .w = avail[0],
            .h = avail[1],
            .child_flags = .{
                .border = true,
            },
            .window_flags = .{
                .horizontal_scrollbar = true,
            },
        },
    )) {
        defer zgui.endChild();

        // Handle mouse wheel zoom
        if (zgui.isWindowHovered(.{})) {
            const io_ptr = cimgui.igGetIO();
            const wheel = io_ptr.*.MouseWheel;
            if (wheel != 0) {
                const old_zoom = STATE.zoom;
                if (wheel > 0) {
                    STATE.zoom = @min(10.0, STATE.zoom * 1.1);
                } else {
                    STATE.zoom = @max(0.1, STATE.zoom * 0.9);
                }

                // Try to keep zoom centered on mouse position
                if (old_zoom != STATE.zoom) {
                    const mouse_pos = zgui.getMousePos();
                    const window_pos = zgui.getWindowPos();
                    const scroll_x = zgui.getScrollX();
                    const scroll_y = zgui.getScrollY();

                    // Mouse position relative to window content
                    const rel_x = mouse_pos[0] - window_pos[0] + scroll_x;
                    const rel_y = mouse_pos[1] - window_pos[1] + scroll_y;

                    // Adjust scroll to keep mouse position stable
                    const zoom_ratio = STATE.zoom / old_zoom;
                    const new_scroll_x = rel_x * zoom_ratio - (mouse_pos[0] - window_pos[0]);
                    const new_scroll_y = rel_y * zoom_ratio - (mouse_pos[1] - window_pos[1]);

                    zgui.setScrollX(@max(0, new_scroll_x));
                    zgui.setScrollY(@max(0, new_scroll_y));
                }
            }
        }

        // Center the image if it's smaller than the available space
        if (display_w < avail[0]) {
            const offset_x = (avail[0] - display_w) / 2;
            zgui.setCursorPosX(offset_x);
        }
        if (display_h < avail[1]) {
            const offset_y = (avail[1] - display_h) / 2;
            zgui.setCursorPosY(offset_y);
        }

        // Draw the image
        cimgui.igImage(
            .{ ._TexID = STATE.image_texid },
            .{ .x = display_w, .y = display_h },
        );
    }
}

fn cleanup() void {
    if (IS_WASM == false) {
        const result = debug_allocator.deinit();
        if (result == .leak) {
            std.log.debug("Memory leak detected!", .{});
        }
    }
}

fn init() void {
    // Image loading happens in main() before sokol_main, but texture creation
    // must happen here after graphics are initialized
    if (STATE.image_path.len > 0 and !STATE.image_loaded) {
        loadImage(STATE.image_path) catch {
            // Error already logged and stored
        };
        // Auto-fit to window on initial load
        fitToWindow();
    }
}

pub fn main() !void {
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zview <image_file>\n", .{});
        std.debug.print("  Supported formats: PNG, JPG, BMP, GIF, TGA, PSD, HDR, PIC, PNM\n", .{});
        std.process.exit(1);
    }

    // Store the image path
    STATE.image_path = try allocator.dupeZ(u8, args[1]);

    app_wrapper.sokol_main(
        .{
            .draw = draw,
            .maybe_pre_zgui_shutdown_cleanup = cleanup,
            .maybe_post_zgui_init = init,
            .title = "zview - Image Viewer",
            .dimensions = .{ 1024, 768 },
        },
    );
}
