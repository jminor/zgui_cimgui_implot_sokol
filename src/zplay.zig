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
    var seek_requested: bool = false;
    var seek_time: f64 = 0.0;

    // UI constants
    const TOOLBAR_HEIGHT: f32 = 38.0;
    const TIMELINE_HEIGHT: f32 = 33.0;
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

        const toolbar_h = STATE.TOOLBAR_HEIGHT;

        // Bottom toolbar is at the very bottom, spanning full width
        const toolbar_y = size[1] - toolbar_h;

        // Status bar (timeline) is above the toolbar
        const bottom_bar_h = STATE.TIMELINE_HEIGHT;
        const bottom_y = toolbar_y - bottom_bar_h;

        // Video content fills top, left, right edges
        const content_x: f32 = 0;
        const content_y: f32 = 0;
        const content_w = size[0];
        const content_h = bottom_y;

        zgui.setCursorPos(.{ content_x, content_y });

        if (STATE.video_loaded) {
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
            zgui.setCursorPos(.{ 50, 50 });
            zgui.text("ERROR: {s}", .{err});
        } else {
            zgui.setCursorPos(.{ 50, 50 });
            zgui.text("WAITING FOR INPUT...", .{});
            zgui.setCursorPosX(50);
            zgui.text("USAGE: zplay <file>", .{});
        }

        // Draw bottom toolbar with transport controls (spans full width)
        drawBottomToolbar(0, toolbar_y, size[0], toolbar_h);
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

/// Draw the video display area
fn drawVideoView(avail_w: f32, avail_h: f32) void {
    const vid_w: f32 = @floatFromInt(STATE.video_width);
    const vid_h: f32 = @floatFromInt(STATE.video_height);

    // Always scale video to fit within available space (no scrollbars)
    const scale_w = avail_w / vid_w;
    const scale_h = avail_h / vid_h;
    const scale = @min(scale_w, scale_h);

    const display_w = vid_w * scale;
    const display_h = vid_h * scale;

    if (zgui.beginChild(
        "VideoFrame",
        .{
            .w = avail_w,
            .h = avail_h,
            .child_flags = .{
                .border = false,
            },
            .window_flags = .{
                .no_scrollbar = true,
                .no_background = true,
            },
        },
    )) {
        defer zgui.endChild();

        // Center the video
        const offset_x = (avail_w - display_w) / 2;
        const offset_y = (avail_h - display_h) / 2;
        zgui.setCursorPos(.{ offset_x, offset_y });

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

    // Draw progress bar (no rounded edges)
    if (progress_w > 0) {
        draw_list.addRectFilled(.{
            .pmin = .{ x, y },
            .pmax = .{ x + progress_w, y + h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.117, 0.565, 0.929, 1.0 }),
            .rounding = 0,
        });
    }

    // Draw bright vertical playhead line
    const playhead_x = x + progress_w;
    draw_list.addLine(.{
        .p1 = .{ playhead_x, y },
        .p2 = .{ playhead_x, y + h },
        .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 1.0 }),
        .thickness = 2.0,
    });

    // Draw timecode: current / total
    // Format current time
    const cur_total_sec: u32 = @intFromFloat(@max(0, STATE.current_time));
    const cur_mins = cur_total_sec / 60;
    const cur_secs = cur_total_sec % 60;
    const cur_ms: u32 = @intFromFloat(@mod(STATE.current_time * 1000, 1000));

    // Format duration
    const dur_total_sec: u32 = @intFromFloat(@max(0, STATE.duration));
    const dur_mins = dur_total_sec / 60;
    const dur_secs = dur_total_sec % 60;
    const dur_ms: u32 = @intFromFloat(@mod(STATE.duration * 1000, 1000));

    var time_buf: [64]u8 = undefined;
    const time_str = std.fmt.bufPrintZ(&time_buf, "{d:0>2}:{d:0>2}.{d:0>3} / {d:0>2}:{d:0>2}.{d:0>3}", .{
        cur_mins, cur_secs, cur_ms,
        dur_mins, dur_secs, dur_ms,
    }) catch "00:00.000 / 00:00.000";

    const text_size = zgui.calcTextSize(time_str, .{});
    zgui.setCursorScreenPos(.{ x + (w - text_size[0]) / 2, y + (h - zgui.getTextLineHeight()) / 2 });
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

/// Draw the bottom toolbar with transport controls
fn drawBottomToolbar(x: f32, y: f32, w: f32, h: f32) void {
    const draw_list = zgui.getWindowDrawList();
    const spacing: f32 = 6.0;
    const btn_h: f32 = 25.0;
    const btn_w: f32 = 55.0;

    // Draw toolbar background
    draw_list.addRectFilled(.{
        .pmin = .{ x, y },
        .pmax = .{ x + w, y + h },
        .col = zgui.colorConvertFloat4ToU32(.{ 0.15, 0.15, 0.15, 1.0 }),
        .rounding = 0,
    });

    // Calculate vertical center for buttons
    const btn_y = y + (h - btn_h) / 2;
    var cur_x = x + spacing;

    // Skip backward button
    zgui.setCursorScreenPos(.{ cur_x, btn_y });
    if (zgui.button("<<", .{ .w = 35, .h = btn_h })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.current_time - step * 60);
    }
    cur_x += 35 + spacing;

    // Play/Pause button
    zgui.setCursorScreenPos(.{ cur_x, btn_y });
    if (zgui.button(if (STATE.is_playing) "PAUSE" else "PLAY", .{ .w = btn_w, .h = btn_h })) {
        STATE.is_playing = !STATE.is_playing;
        if (STATE.is_playing) {
            STATE.last_frame_time = std.time.milliTimestamp();
            STATE.frame_accumulator = 0;
        }
    }
    cur_x += btn_w + spacing;

    // Skip forward button
    zgui.setCursorScreenPos(.{ cur_x, btn_y });
    if (zgui.button(">>", .{ .w = 35, .h = btn_h })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @min(STATE.duration, STATE.current_time + step * 60);
    }
    cur_x += 35 + spacing * 2;

    // Speed button
    var speed_buf: [16]u8 = undefined;
    const speed_str = std.fmt.bufPrintZ(&speed_buf, "{d:.2}x", .{STATE.playback_rate}) catch "1.00x";

    zgui.setCursorScreenPos(.{ cur_x, btn_y });
    if (zgui.button(speed_str, .{ .w = 48, .h = btn_h })) {
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
    cur_x += 48 + spacing * 2;

    // Audio controls (if has audio)
    if (STATE.has_audio) {
        // Mute button
        zgui.setCursorScreenPos(.{ cur_x, btn_y });
        if (zgui.button(if (STATE.is_muted) "UNMUTE" else "MUTE", .{ .w = 58, .h = btn_h })) {
            STATE.is_muted = !STATE.is_muted;
        }
        cur_x += 58 + spacing;

        // Volume down
        zgui.setCursorScreenPos(.{ cur_x, btn_y });
        if (zgui.button("-", .{ .w = 22, .h = btn_h })) {
            STATE.volume = @max(0.0, STATE.volume - 0.1);
        }
        cur_x += 22 + spacing / 2;

        // Volume bar
        const vol_bar_w: f32 = 70;
        const vol_bar_h: f32 = 9;
        const vol_bar_y = y + (h - vol_bar_h) / 2;

        draw_list.addRectFilled(.{
            .pmin = .{ cur_x, vol_bar_y },
            .pmax = .{ cur_x + vol_bar_w, vol_bar_y + vol_bar_h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.25, 0.25, 0.25, 1.0 }),
            .rounding = 2,
        });

        draw_list.addRectFilled(.{
            .pmin = .{ cur_x, vol_bar_y },
            .pmax = .{ cur_x + vol_bar_w * STATE.volume, vol_bar_y + vol_bar_h },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.117, 0.565, 0.929, 1.0 }),
            .rounding = 2,
        });
        cur_x += vol_bar_w + spacing / 2;

        // Volume up
        zgui.setCursorScreenPos(.{ cur_x, btn_y });
        if (zgui.button("+", .{ .w = 22, .h = btn_h })) {
            STATE.volume = @min(1.0, STATE.volume + 0.1);
        }
        cur_x += 22 + spacing;
    }

    // Right-aligned buttons: CAPTURE and EXIT
    const right_margin = spacing;
    const exit_w: f32 = 45;
    const capture_w: f32 = 65;

    // EXIT button (rightmost)
    const exit_x = x + w - right_margin - exit_w;
    zgui.setCursorScreenPos(.{ exit_x, btn_y });
    if (zgui.button("EXIT", .{ .w = exit_w, .h = btn_h })) {
        sapp.quit();
    }

    // CAPTURE button (left of EXIT)
    const capture_x = exit_x - spacing - capture_w;
    zgui.setCursorScreenPos(.{ capture_x, btn_y });
    if (zgui.button("CAPTURE", .{ .w = capture_w, .h = btn_h })) {
        var buf: [64]u8 = undefined;
        const filename = std.fmt.bufPrintZ(&buf, "screenshot_{d:0>3}.png", .{STATE.screenshot_counter}) catch "screenshot.png";
        saveScreenshot(filename.ptr);
        STATE.screenshot_counter += 1;
        std.log.info("Screenshot request: {s}", .{filename});
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
