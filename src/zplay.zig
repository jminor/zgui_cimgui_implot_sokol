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
    const SIDEBAR_WIDTH: f32 = 200.0;
    const HEADER_HEIGHT: f32 = 60.0;
    const SPACING: f32 = 8.0;

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

        const s_width = STATE.SIDEBAR_WIDTH;
        const h_height = STATE.HEADER_HEIGHT;
        const spacing = STATE.SPACING;

        const bottom_bar_h: f32 = 44.0;
        const bottom_y = size[1] - bottom_bar_h - 12;
        const content_x = s_width + spacing;
        const content_y = h_height + spacing * 2;
        const content_w = size[0] - content_x - spacing;
        const content_h = bottom_y - content_y - spacing;

        zgui.setCursorPos(.{ content_x, content_y });

        if (STATE.video_loaded) {
            if (STATE.needs_initial_fit) {
                fitToWindow();
                STATE.needs_initial_fit = false;
            }

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

                drawVideoView(content_w, content_h);
            }

            drawBottomStatus(content_x, bottom_y, content_w, bottom_bar_h);
        } else if (STATE.load_error) |err| {
            zgui.text("ERROR: {s}", .{err});
        } else {
            zgui.setCursorPos(.{ content_x + 50, content_y + 50 });
            zgui.text("WAITING FOR INPUT...", .{});
            zgui.setCursorPosX(content_x + 50);
            zgui.text("USAGE: zplay <file>", .{});
        }

        drawSidebarControls();

        drawRightRail(content_x + content_w - 170, content_y + 24, 150, 22, 10);
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
                .border = true,
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

/// Draw the bottom status bar with timeline and metadata
fn drawBottomStatus(x: f32, y: f32, w: f32, h: f32) void {
    if (!STATE.video_loaded) return;

    const draw_list = zgui.getWindowDrawList();

    const progress = if (STATE.duration > 0) STATE.current_time / STATE.duration else 0;
    const progress_w = w * @as(f32, @floatCast(progress));

    if (progress_w > 0) {
        draw_list.addRectFilled(.{
            .pmin = .{ x, y },
            .pmax = .{ x + progress_w, y + h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.117, 0.565, 0.929, 1.0 }),
            .rounding = h / 2.0,
            .flags = .{ .round_corners_top_right = true, .round_corners_bottom_right = true },
        });
    }

    zgui.setCursorScreenPos(.{ x + 20, y + (h - zgui.getTextLineHeight()) / 2 });

    var info_buf: [128]u8 = undefined;
    const info_str = std.fmt.bufPrintZ(&info_buf, "RES: {d}x{d}   FPS: {d:.2}", .{
        STATE.video_width,
        STATE.video_height,
        STATE.fps,
    }) catch "INFO ERROR";

    zgui.text("{s}", .{info_str});

    var time_buf: [64]u8 = undefined;
    const time_str = std.fmt.bufPrintZ(&time_buf, "{s} / {s}", .{
        formatTime(STATE.current_time),
        formatTime(STATE.duration),
    }) catch "00:00 / 00:00";

    const text_size = zgui.calcTextSize(time_str, .{});
    zgui.setCursorScreenPos(.{ x + w - text_size[0] - 20, y + (h - zgui.getTextLineHeight()) / 2 });
    zgui.text("{s}", .{time_str});

    zgui.setCursorScreenPos(.{ x, y });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .slider_grab_active, .c = .{ 0, 0, 0, 0 } });

    var time_pos: f32 = @floatCast(STATE.current_time);
    const duration_f: f32 = @floatCast(@max(STATE.duration, 0.001));

    zgui.pushItemWidth(w);
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
}

/// Draw controls in the sidebar
fn drawSidebarControls() void {
    const s_width = STATE.SIDEBAR_WIDTH;
    const h_height = STATE.HEADER_HEIGHT;
    const spacing = STATE.SPACING;

    zgui.setCursorPos(.{ spacing, h_height + spacing });

    const btn_w = s_width - spacing * 2;
    const btn_h = 30.0;

    zgui.setCursorPos(.{ spacing, h_height + spacing });

    if (zgui.button(if (STATE.is_playing) "PAUSE" else "PLAY", .{ .w = btn_w, .h = btn_h })) {
        STATE.is_playing = !STATE.is_playing;
        if (STATE.is_playing) {
            STATE.last_frame_time = std.time.milliTimestamp();
            STATE.frame_accumulator = 0;
        }
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    if (zgui.button("<<", .{ .w = (btn_w - spacing) / 2, .h = btn_h })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.current_time - step * 60);
    }
    zgui.sameLine(.{});
    if (zgui.button(">>", .{ .w = (btn_w - spacing) / 2, .h = btn_h })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @min(STATE.duration, STATE.current_time + step * 60);
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    var speed_buf: [16]u8 = undefined;
    const speed_str = std.fmt.bufPrintZ(&speed_buf, "SPD {d:.2}x", .{STATE.playback_rate}) catch "SPD 1.00x";

    if (zgui.button(speed_str, .{ .w = btn_w, .h = btn_h })) {
        var current_idx: usize = 3;
        for (STATE.PLAYBACK_RATES, 0..) |rate, i| {
            if (STATE.playback_rate == rate) {
                current_idx = i;
                break;
            }
        }
        const next_idx = (current_idx + 1) % STATE.PLAYBACK_RATES.len;
        STATE.playback_rate = STATE.PLAYBACK_RATES[next_idx];
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    if (STATE.has_audio) {
        if (zgui.button(if (STATE.is_muted) "UNMUTE" else "MUTE", .{ .w = btn_w, .h = btn_h })) {
            STATE.is_muted = !STATE.is_muted;
        }

        zgui.dummy(.{ .w = 0, .h = spacing });

        if (zgui.button("VOL -", .{ .w = (btn_w - spacing) / 2, .h = btn_h })) {
            STATE.volume = @max(0.0, STATE.volume - 0.1);
        }
        zgui.sameLine(.{});
        if (zgui.button("VOL +", .{ .w = (btn_w - spacing) / 2, .h = btn_h })) {
            STATE.volume = @min(1.0, STATE.volume + 0.1);
        }

        const draw_list = zgui.getWindowDrawList();
        const bar_pos = zgui.getCursorScreenPos();
        const bar_w = btn_w;
        const bar_h: f32 = 10;

        draw_list.addRectFilled(.{
            .pmin = .{ bar_pos[0], bar_pos[1] },
            .pmax = .{ bar_pos[0] + bar_w, bar_pos[1] + bar_h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 }),
            .rounding = 3,
        });

        draw_list.addRectFilled(.{
            .pmin = .{ bar_pos[0], bar_pos[1] },
            .pmax = .{ bar_pos[0] + bar_w * STATE.volume, bar_pos[1] + bar_h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.117, 0.565, 0.929, 1.0 }),
            .rounding = 3,
        });

        zgui.dummy(.{ .w = bar_w, .h = bar_h });
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    if (zgui.button("CAPTURE", .{ .w = btn_w, .h = btn_h })) {
        var buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrintZ(&buf, "screenshot_{d:0>3}.png", .{STATE.screenshot_counter}) catch "screenshot.png";
        saveScreenshot(filename.ptr);
        STATE.screenshot_counter += 1;
        std.log.info("Screenshot request: {s}", .{filename});
    }

    zgui.dummy(.{ .w = 0, .h = spacing });

    if (zgui.button("EXIT", .{ .w = btn_w, .h = btn_h })) {
        sapp.quit();
    }
}

fn drawRightRail(x: f32, y: f32, w: f32, h: f32, count: usize) void {
    const dl = zgui.getWindowDrawList();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const top = y + @as(f32, @floatFromInt(i)) * (h + 10.0);
        const base_col = zgui.colorConvertFloat4ToU32(.{ 0.117, 0.565, 0.929, 1.0 });
        dl.addRectFilled(.{
            .pmin = .{ x, top },
            .pmax = .{ x + w, top + h },
            .col = base_col,
            .rounding = h / 2.0,
        });
        dl.addRectFilled(.{
            .pmin = .{ x + w - 36, top + 6 },
            .pmax = .{ x + w - 8, top + h - 6 },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.20, 0.20, 0.20, 1.0 }),
            .rounding = 6,
        });
        zgui.setCursorScreenPos(.{ x + 10, top + 3 });
        zgui.text("{d:0>2}", .{i + 1});
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
