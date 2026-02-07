//! zplay - A video player application
//! Loads and plays video files using libav/FFmpeg with timeline,
//! transport controls, playback rate control, and audio playback.

const std = @import("std");
const builtin = @import("builtin");

const ziis = @import("zgui_cimgui_implot_sokol");
const zgui = ziis.zgui;
const sg = ziis.sokol.gfx;
const sapp = ziis.sokol.app;
const saudio = ziis.sokol.audio;
const app_wrapper = ziis.app_wrapper;
const cimgui = ziis.cimgui;

const libav = @import("libav.zig");

extern fn saveScreenshot(filename: [*c]const u8) void;

const IS_WASM = builtin.target.cpu.arch.isWasm();

/// State container for the video player
const STATE = struct {
    // Video data
    var video_path: [:0]const u8 = "";
    var decoder: ?*libav.MediaDecoder = null;
    var video_tex: sg.Image = .{};
    var video_view: sg.View = .{};
    var video_texid: u64 = 0;
    var video_width: u32 = 0;
    var video_height: u32 = 0;
    var video_loaded: bool = false;
    var load_error: ?[]const u8 = null;

    // Audio state
    var has_audio: bool = false;
    var audio_initialized: bool = false;
    var volume: f32 = 1.0;
    var is_muted: bool = false;

    // Playback state
    var is_playing: bool = false;
    var playback_rate: f32 = 1.0;
    var current_time: f64 = 0.0;
    var duration: f64 = 0.0;
    var fps: f64 = 30.0;

    // Timing
    var last_frame_time: i64 = 0;
    var frame_accumulator: f64 = 0.0;
    var texture_updated_this_frame: bool = false;

    // View state
    var zoom: f32 = 1.0;
    var needs_initial_fit: bool = true;
    var seek_requested: bool = false;
    var seek_time: f64 = 0.0;

    // UI constants
    const SIDEBAR_WIDTH: f32 = 180.0;
    const HEADER_HEIGHT: f32 = 50.0;
    const SPACING: f32 = 6.0;
    const ELBOW_RADIUS: f32 = 30.0;

    // LCARS Colors (RGBA normalized)
    const LCARS_ORANGE = [4]f32{ 1.0, 0.6, 0.0, 1.0 };
    const LCARS_PURPLE = [4]f32{ 0.8, 0.6, 0.8, 1.0 };
    const LCARS_BLUE = [4]f32{ 0.6, 0.8, 1.0, 1.0 };
    const LCARS_RED = [4]f32{ 0.8, 0.4, 0.4, 1.0 };
    const LCARS_BEIGE = [4]f32{ 1.0, 0.9, 0.7, 1.0 };
    const LCARS_BLACK = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    const LCARS_GRAY = [4]f32{ 0.4, 0.4, 0.4, 1.0 };

    // Playback rates
    const PLAYBACK_RATES = [_]f32{ 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0 };

    var screenshot_counter: u32 = 0;
};

/// GPA for native builds
var debug_allocator = if (IS_WASM) null else std.heap.DebugAllocator(.{}){};
const allocator = if (IS_WASM) std.heap.c_allocator else debug_allocator.allocator();

/// Audio callback - called from audio thread to fill the buffer
fn audioCallback(buffer: [*c]f32, num_frames: i32, num_channels: i32) callconv(.c) void {
    const dec = STATE.decoder orelse {
        // No decoder, fill with silence
        const total_samples: usize = @intCast(num_frames * num_channels);
        for (0..total_samples) |i| {
            buffer[i] = 0;
        }
        return;
    };

    if (!STATE.is_playing or !STATE.has_audio) {
        // Not playing or no audio, fill with silence
        const total_samples: usize = @intCast(num_frames * num_channels);
        for (0..total_samples) |i| {
            buffer[i] = 0;
        }
        return;
    }

    // Calculate effective volume (0 if muted)
    const effective_volume = if (STATE.is_muted) 0.0 else STATE.volume;

    // Read samples from decoder's ring buffer
    const total_samples: usize = @intCast(num_frames * num_channels);
    var buf_slice: []f32 = undefined;
    buf_slice.ptr = buffer;
    buf_slice.len = total_samples;
    _ = dec.readAudioSamples(buf_slice, effective_volume);
}

/// Initialize audio subsystem
fn initAudio() void {
    if (STATE.audio_initialized) return;

    saudio.setup(.{
        .sample_rate = 44100,
        .num_channels = 2,
        .stream_cb = audioCallback,
        .buffer_frames = 2048,
    });

    if (saudio.isvalid()) {
        STATE.audio_initialized = true;
        std.log.info("Audio initialized: {} Hz, {} channels", .{
            saudio.sampleRate(),
            saudio.channels(),
        });
    } else {
        std.log.warn("Failed to initialize audio", .{});
    }
}

/// Shutdown audio subsystem
fn shutdownAudio() void {
    if (STATE.audio_initialized) {
        saudio.shutdown();
        STATE.audio_initialized = false;
    }
}

/// Load video from file path
fn loadVideo(path: [:0]const u8) !void {
    STATE.decoder = libav.MediaDecoder.open(allocator, path) catch |err| {
        STATE.load_error = switch (err) {
            libav.Error.OpenInputFailed => "Failed to open video file",
            libav.Error.FindStreamInfoFailed => "Failed to find stream info",
            libav.Error.NoVideoStream => "No video stream found",
            libav.Error.CodecNotFound => "Codec not found",
            libav.Error.CodecAllocFailed => "Failed to allocate codec",
            libav.Error.CodecOpenFailed => "Failed to open codec",
            else => "Unknown error",
        };
        std.log.err("Failed to open video '{s}': {any}", .{ path, err });
        return err;
    };

    const dec = STATE.decoder.?;
    STATE.video_width = dec.width;
    STATE.video_height = dec.height;
    STATE.duration = dec.duration_sec;
    STATE.fps = dec.fps;
    STATE.has_audio = dec.has_audio;

    // Create initial texture (stream_update for dynamic content)
    STATE.video_tex = sg.makeImage(.{
        .width = @intCast(dec.width),
        .height = @intCast(dec.height),
        .pixel_format = .RGBA8,
        .usage = .{ .stream_update = true },
    });

    STATE.video_view = sg.makeView(.{
        .texture = .{
            .image = STATE.video_tex,
        },
    });

    STATE.video_texid = ziis.sokol.imgui.imtextureid(STATE.video_view);
    STATE.video_loaded = true;
    STATE.last_frame_time = std.time.milliTimestamp();

    // Decode first frame
    if (dec.decodeNextVideoFrame()) |_| {
        updateTexture();
    }

    std.log.info("Video loaded: {}x{} @ {d:.2} fps, duration: {d:.2}s, audio: {}", .{
        dec.width,
        dec.height,
        dec.fps,
        dec.duration_sec,
        dec.has_audio,
    });
}

/// Update the texture with current frame data (only once per frame)
fn updateTexture() void {
    if (STATE.texture_updated_this_frame) return;

    if (STATE.decoder) |dec| {
        var image_data = sg.ImageData{};
        image_data.mip_levels[0] = sg.asRange(dec.rgb_buffer);

        sg.updateImage(STATE.video_tex, image_data);
        STATE.texture_updated_this_frame = true;
    }
}

/// Draw the UI
fn draw() !void {
    // Reset per-frame state
    STATE.texture_updated_this_frame = false;

    // Update playback
    updatePlayback();

    const vp = zgui.getMainViewport();
    const size = vp.getSize();

    // Setup full-screen window with no standard UI elements
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = size[0], .h = size[1] });

    // Set LCARS background color
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = STATE.LCARS_BLACK });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = STATE.LCARS_ORANGE });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });

    defer {
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 1 });
    }

    if (zgui.begin(
        "###ZPLAY",
        .{
            .flags = .{
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .no_title_bar = true,
                .no_bring_to_front_on_focus = true,
                .menu_bar = false,
                .no_scrollbar = true,
            },
        },
    )) {
        defer zgui.end();

        // --- LCARS Frame Drawing ---
        const dl = zgui.getWindowDrawList();

        // Define coordinates
        const s_width = STATE.SIDEBAR_WIDTH;
        const h_height = STATE.HEADER_HEIGHT;
        const elbow_r = STATE.ELBOW_RADIUS;
        const spacing = STATE.SPACING;

        // Elbow colors
        const col_elbow = zgui.colorConvertFloat4ToU32(STATE.LCARS_PURPLE);
        const col_bar = zgui.colorConvertFloat4ToU32(STATE.LCARS_PURPLE);

        // 1. Top Header Bar (starts after elbow)
        // Position: x = s_width + spacing, y = 0
        // Width: size[0] - s_width - spacing
        dl.addRectFilled(.{
            .pmin = .{ s_width + spacing, 0 },
            .pmax = .{ size[0] - 20, h_height / 1.5 }, // Make header a bit thinner than full elbow height
            .col = col_bar,
            .rounding = elbow_r,
            .flags = .{ .round_corners_bottom_left = true },
        });

        // 2. The Elbow (Top Left)
        // A complex shape: a filled rect for the column part, and a filled rect for the row part, connected by arc
        // Simplified: Draw a thick reversed 'L' with rounded outer corner

        // Vertical part of elbow
        dl.addRectFilled(.{
            .pmin = .{ 0, 0 },
            .pmax = .{ s_width, h_height + elbow_r },
            .col = col_elbow,
            .rounding = elbow_r,
            .flags = .{ .round_corners_bottom_right = true },
        });

        // Sidebar Background (below elbow)
        // We leave gaps between buttons, so maybe we don't need a solid background,
        // but LCARS usually has a solid column on the left.
        // Let's draw the sidebar column area
        dl.addRectFilled(.{
            .pmin = .{ 0, h_height + elbow_r + spacing },
            .pmax = .{ s_width, size[1] },
            .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_BLACK), // Background is black, buttons are colored
            .rounding = 0,
        });

        // 3. Header Text
        const title_text = if (STATE.video_loaded) std.fs.path.basename(STATE.video_path) else "ZPLAY SYSTEM READY";
        zgui.setCursorPos(.{ s_width + spacing + 20, 5 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = STATE.LCARS_BLACK });
        zgui.text("{s}", .{title_text});
        zgui.popStyleColor(.{});

        // 4. Decoration - Bottom Bar line?
        // LCARS often has a bottom rail too.
        dl.addRectFilled(.{
            .pmin = .{ s_width + spacing, size[1] - 40 },
            .pmax = .{ size[0] - 20, size[1] - 10 },
            .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_PURPLE),
            .rounding = 0,
        });

        // --- Main Content Area ---
        const content_x = s_width + spacing;
        const content_y = h_height + spacing;
        const content_w = size[0] - content_x - spacing;
        const content_h = size[1] - content_y - 40 - spacing; // Reserve space for bottom decoration

        zgui.setCursorPos(.{ content_x, content_y });

        if (STATE.video_loaded) {
            // Fit to window on first frame (needs updated logic)
            if (STATE.needs_initial_fit) {
                fitToWindow();
                STATE.needs_initial_fit = false;
            }

            // Create a child window for the main content to clip it
            if (zgui.beginChild(
                "ContentRegion",
                .{
                    .w = content_w,
                    .h = content_h,
                    .child_flags = .{ .border = false },
                    .window_flags = .{ .no_scrollbar = true, .no_background = true },
                },
            )) {
                defer zgui.endChild();

                // Video Display
                // Reserve space at bottom for timeline
                const timeline_h: f32 = 40.0;
                const video_area_h = content_h - timeline_h;

                drawVideoView(content_w, video_area_h);

                // Timeline at bottom of content area
                zgui.setCursorPos(.{ 0, video_area_h });
                drawTimeline(content_w, timeline_h);
            }
        } else if (STATE.load_error) |err| {
            zgui.pushStyleColor4f(.{ .idx = .text, .c = STATE.LCARS_RED });
            zgui.text("ERROR: {s}", .{err});
            zgui.popStyleColor(.{});
        } else {
            zgui.setCursorPos(.{ content_x + 50, content_y + 50 });
            zgui.text("WAITING FOR INPUT...", .{});
            zgui.setCursorPosX(content_x + 50);
            zgui.text("USAGE: zplay <file>", .{});
        }

        // --- Sidebar Controls ---
        // Render buttons in the left column
        drawSidebarControls();
    }
}

/// Update playback state
fn updatePlayback() void {
    if (!STATE.video_loaded) return;

    const dec = STATE.decoder orelse return;

    // Handle seek requests
    if (STATE.seek_requested) {
        dec.seekToTime(STATE.seek_time) catch {
            std.log.err("Seek failed", .{});
        };
        STATE.current_time = dec.getCurrentTime();
        updateTexture();
        STATE.seek_requested = false;
    }

    if (!STATE.is_playing) return;

    // Calculate time since last frame
    const current_time = std.time.milliTimestamp();
    const delta_ms = current_time - STATE.last_frame_time;
    STATE.last_frame_time = current_time;

    // Accumulate time
    const delta_sec = @as(f64, @floatFromInt(delta_ms)) / 1000.0;
    STATE.frame_accumulator += delta_sec * @as(f64, STATE.playback_rate);

    // Calculate frame duration
    const frame_duration = 1.0 / STATE.fps;

    // Decode frames as needed
    while (STATE.frame_accumulator >= frame_duration) {
        STATE.frame_accumulator -= frame_duration;

        if (dec.decodeNextVideoFrame()) |_| {
            STATE.current_time = dec.getCurrentTime();
            updateTexture();
        } else if (dec.isEof()) {
            // Loop or stop at end
            STATE.is_playing = false;
            dec.reset() catch {};
            STATE.current_time = 0;
            if (dec.decodeNextVideoFrame()) |_| {
                updateTexture();
            }
            break;
        }
    }
}

/// Fit video to window
fn fitToWindow() void {
    if (!STATE.video_loaded) return;

    const vp = zgui.getMainViewport();
    const size = vp.getSize();

    // Calculate available space for video
    // Subtract Sidebar, Header, and Timeline space
    const avail_w = size[0] - STATE.SIDEBAR_WIDTH - STATE.SPACING * 2;
    const avail_h = size[1] - STATE.HEADER_HEIGHT - 60; // Approximate

    const vid_w: f32 = @floatFromInt(STATE.video_width);
    const vid_h: f32 = @floatFromInt(STATE.video_height);

    const scale_w = avail_w / vid_w;
    const scale_h = avail_h / vid_h;

    STATE.zoom = @min(scale_w, scale_h);
}

/// Draw the video display area
fn drawVideoView(avail_w: f32, avail_h: f32) void {
    const vid_w: f32 = @floatFromInt(STATE.video_width);
    const vid_h: f32 = @floatFromInt(STATE.video_height);

    const display_w = vid_w * STATE.zoom;
    const display_h = vid_h * STATE.zoom;

    if (zgui.beginChild(
        "VideoFrame",
        .{
            .w = avail_w,
            .h = avail_h,
            .child_flags = .{
                .border = false,
            },
            .window_flags = .{
                .horizontal_scrollbar = false,
                .no_background = true,
            },
        },
    )) {
        defer zgui.endChild();

        // Center the video
        if (display_w < avail_w) {
            const offset_x = (avail_w - display_w) / 2;
            zgui.setCursorPosX(offset_x);
        }
        if (display_h < avail_h) {
            const offset_y = (avail_h - display_h) / 2;
            zgui.setCursorPosY(offset_y);
        }

        // Draw the video frame
        cimgui.igImage(
            .{ ._TexID = STATE.video_texid },
            .{ .x = display_w, .y = display_h },
        );
    }
}

/// Draw the timeline
fn drawTimeline(width: f32, height: f32) void {
    if (!STATE.video_loaded) return;

    // Use custom drawing for LCARS style timeline
    const draw_list = zgui.getWindowDrawList();
    const cursor_pos = zgui.getCursorScreenPos();
    const start_x = cursor_pos[0];
    const start_y = cursor_pos[1];

    // Background bar
    draw_list.addRectFilled(.{
        .pmin = .{ start_x, start_y + 10 },
        .pmax = .{ start_x + width, start_y + height - 10 },
        .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_GRAY),
        .rounding = height / 4,
    });

    // Progress
    const progress = if (STATE.duration > 0) STATE.current_time / STATE.duration else 0;
    const progress_w = width * @as(f32, @floatCast(progress));

    draw_list.addRectFilled(.{
        .pmin = .{ start_x, start_y + 10 },
        .pmax = .{ start_x + progress_w, start_y + height - 10 },
        .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_ORANGE),
        .rounding = height / 4,
    });

    // Invisible slider for interaction
    zgui.setCursorScreenPos(.{ start_x, start_y });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = .{ 0, 0, 0, 0 } });

    var time_pos: f32 = @floatCast(STATE.current_time);
    const duration_f: f32 = @floatCast(@max(STATE.duration, 0.001));

    zgui.pushItemWidth(width);
    if (zgui.sliderFloat("##timeline_overlay", .{
        .v = &time_pos,
        .min = 0,
        .max = duration_f,
        .cfmt = "",
        .flags = .{},
    })) {
        STATE.seek_requested = true;
        STATE.seek_time = @floatCast(time_pos);
    }
    zgui.popItemWidth();

    zgui.popStyleColor(.{ .count = 5 });

    // Time text overlay (Centered)
    var buf: [64]u8 = undefined;
    const time_str = std.fmt.bufPrintZ(&buf, "{s} / {s}", .{
        formatTime(STATE.current_time),
        formatTime(STATE.duration),
    }) catch "00:00 / 00:00";

    const text_size = zgui.calcTextSize(time_str, .{});
    zgui.setCursorScreenPos(.{ start_x + (width - text_size[0]) / 2, start_y + (height - text_size[1]) / 2 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = STATE.LCARS_BLACK });
    zgui.text("{s}", .{time_str});
    zgui.popStyleColor(.{});
}

/// Helper to draw a styled LCARS button
fn lcarsButton(label: [:0]const u8, color: [4]f32, w: f32, h: f32) bool {
    zgui.pushStyleColor4f(.{ .idx = .button, .c = color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = .{ color[0] * 1.1, color[1] * 1.1, color[2] * 1.1, 1.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = .{ color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, 1.0 } });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 5, 2 } });
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = h / 2.0 }); // Pill shape

    const result = zgui.button(label, .{ .w = w, .h = h });

    zgui.popStyleVar(.{ .count = 2 });
    zgui.popStyleColor(.{ .count = 3 });
    return result;
}

/// Draw controls in the sidebar
fn drawSidebarControls() void {
    const s_width = STATE.SIDEBAR_WIDTH;
    const h_height = STATE.HEADER_HEIGHT;
    const elbow_r = STATE.ELBOW_RADIUS;
    const spacing = STATE.SPACING;

    // Start below the elbow
    zgui.setCursorPos(.{ 10, h_height + elbow_r + spacing * 2 });

    const btn_w = s_width - 20;
    const btn_h = 30.0;

    // Transport
    zgui.text("TRANSPORT", .{});
    if (lcarsButton(if (STATE.is_playing) "PAUSE" else "PLAY", STATE.LCARS_ORANGE, btn_w, btn_h)) {
        STATE.is_playing = !STATE.is_playing;
        if (STATE.is_playing) {
            STATE.last_frame_time = std.time.milliTimestamp();
            STATE.frame_accumulator = 0;
        }
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    // Horizontal row for Rewind/FF
    if (lcarsButton("<<", STATE.LCARS_BEIGE, (btn_w - spacing) / 2, btn_h)) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.current_time - step * 60); // 2s approx
    }
    zgui.sameLine(.{});
    if (lcarsButton(">>", STATE.LCARS_BEIGE, (btn_w - spacing) / 2, btn_h)) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @min(STATE.duration, STATE.current_time + step * 60);
    }

    zgui.dummy(.{ .w = 0, .h = spacing * 2 });

    // Speed Control
    zgui.text("SPEED", .{});
    var speed_buf: [16]u8 = undefined;
    const speed_str = std.fmt.bufPrintZ(&speed_buf, "{d:.2}x", .{STATE.playback_rate}) catch "1.00x";

    if (lcarsButton(speed_str, STATE.LCARS_BLUE, btn_w, btn_h)) {
        // Cycle speed
        var current_idx: usize = 3; // Default 1.0
        for (STATE.PLAYBACK_RATES, 0..) |rate, i| {
            if (STATE.playback_rate == rate) {
                current_idx = i;
                break;
            }
        }
        const next_idx = (current_idx + 1) % STATE.PLAYBACK_RATES.len;
        STATE.playback_rate = STATE.PLAYBACK_RATES[next_idx];
    }

    zgui.dummy(.{ .w = 0, .h = spacing * 2 });

    // Audio
    if (STATE.has_audio) {
        zgui.text("AUDIO", .{});
        if (lcarsButton(if (STATE.is_muted) "UNMUTE" else "MUTE", STATE.LCARS_RED, btn_w, btn_h)) {
            STATE.is_muted = !STATE.is_muted;
        }

        zgui.dummy(.{ .w = 0, .h = spacing });

        // Volume Buttons (+ / -) instead of slider for touch/lcars feel
        if (lcarsButton("VOL -", STATE.LCARS_BEIGE, (btn_w - spacing) / 2, btn_h)) {
            STATE.volume = @max(0.0, STATE.volume - 0.1);
        }
        zgui.sameLine(.{});
        if (lcarsButton("VOL +", STATE.LCARS_BEIGE, (btn_w - spacing) / 2, btn_h)) {
            STATE.volume = @min(1.0, STATE.volume + 0.1);
        }

        // Volume indicator bar
        const draw_list = zgui.getWindowDrawList();
        const cursor_pos = zgui.getCursorScreenPos();
        const bar_w = btn_w;
        const bar_h: f32 = 10;

        draw_list.addRectFilled(.{
            .pmin = .{ cursor_pos[0], cursor_pos[1] },
            .pmax = .{ cursor_pos[0] + bar_w, cursor_pos[1] + bar_h },
            .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_GRAY),
        });

        draw_list.addRectFilled(.{
            .pmin = .{ cursor_pos[0], cursor_pos[1] },
            .pmax = .{ cursor_pos[0] + bar_w * STATE.volume, cursor_pos[1] + bar_h },
            .col = zgui.colorConvertFloat4ToU32(STATE.LCARS_BLUE),
        });

        zgui.dummy(.{ .w = bar_w, .h = bar_h });
    }

    // Bottom filler
    zgui.dummy(.{ .w = 0, .h = spacing * 2 });

    if (lcarsButton("SCREENSHOT", STATE.LCARS_BLUE, btn_w, btn_h)) {
        var buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrintZ(&buf, "screenshot_{d:0>3}.png", .{STATE.screenshot_counter}) catch "screenshot.png";
        saveScreenshot(filename.ptr);
        STATE.screenshot_counter += 1;
        std.log.info("Screenshot request: {s}", .{filename});
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    if (lcarsButton("EXIT", STATE.LCARS_RED, btn_w, btn_h)) {
        sapp.quit();
    }
}

/// Format time as MM:SS.mmm
fn formatTime(seconds: f64) [:0]const u8 {
    const total_sec: u32 = @intFromFloat(@max(0, seconds));
    const mins = total_sec / 60;
    const secs = total_sec % 60;
    const ms: u32 = @intFromFloat(@mod(seconds * 1000, 1000));

    return std.fmt.bufPrintZ(&time_buffer, "{d:0>2}:{d:0>2}.{d:0>3}", .{ mins, secs, ms }) catch "00:00.000";
}

var time_buffer: [32]u8 = undefined;

/// Format playback rate
fn formatRate(rate: f32) [:0]const u8 {
    return std.fmt.bufPrintZ(&rate_buffer, "{d:.2}x", .{rate}) catch "1.00x";
}

var rate_buffer: [16]u8 = undefined;

fn cleanup() void {
    // Shutdown audio
    shutdownAudio();

    // Close video decoder
    if (STATE.decoder) |dec| {
        dec.close();
        STATE.decoder = null;
    }

    // Free the duplicated video path if it was allocated
    if (STATE.video_path.len > 0) {
        allocator.free(STATE.video_path);
    }

    // Destroy texture
    if (STATE.video_loaded) {
        sg.destroyView(STATE.video_view);
        sg.destroyImage(STATE.video_tex);
    }

    if (IS_WASM == false) {
        const result = debug_allocator.deinit();
        if (result == .leak) {
            std.log.debug("Memory leak detected!", .{});
        }
    }
}

fn init() void {
    // Initialize audio
    initAudio();

    // Video loading happens in main() before sokol_main, but texture creation
    // must happen here after graphics are initialized
    if (STATE.video_path.len > 0 and !STATE.video_loaded) {
        loadVideo(STATE.video_path) catch {
            // Error already logged and stored
        };
        fitToWindow();
    }
}

pub fn main() !void {
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);

    if (args.len < 2) {
        std.debug.print("Usage: zplay <video_file>\n", .{});
        std.debug.print("  A simple video player with transport controls.\n", .{});
        std.debug.print("  Supported formats: MP4, MKV, AVI, MOV, WEBM, and more.\n", .{});
        std.process.exit(1);
    }

    // Store the video path and free args
    STATE.video_path = try allocator.dupeZ(u8, args[1]);
    std.process.argsFree(allocator, args);

    app_wrapper.sokol_main(
        .{
            .draw = draw,
            .maybe_pre_zgui_shutdown_cleanup = cleanup,
            .maybe_post_zgui_init = init,
            .title = "zplay - Video Player",
            .dimensions = .{ 1280, 720 },
        },
    );
}
