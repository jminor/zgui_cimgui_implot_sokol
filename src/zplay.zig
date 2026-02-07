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
    const TOOLBAR_HEIGHT: f32 = 40.0;
    const TIMELINE_HEIGHT: f32 = 60.0;
    const CONTROLS_HEIGHT: f32 = 50.0;

    // Playback rates
    const PLAYBACK_RATES = [_]f32{ 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0 };
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
            },
        },
    )) {
        defer zgui.end();

        if (STATE.video_loaded) {
            // Fit to window on first frame
            if (STATE.needs_initial_fit) {
                fitToWindow();
                STATE.needs_initial_fit = false;
            }

            // Video display area
            drawVideoView();

            zgui.separator();

            // Timeline
            drawTimeline();

            zgui.separator();

            // Transport controls
            drawTransportControls();
        } else if (STATE.load_error) |err| {
            zgui.pushStyleColor4f(.{ .idx = .text, .c = .{ 1.0, 0.3, 0.3, 1.0 } });
            zgui.text("Error: {s}", .{err});
            zgui.popStyleColor(.{});
        } else {
            zgui.text("No video loaded", .{});
            zgui.text("Usage: zplay <video_file>", .{});
        }
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

    const avail_w = size[0] - 20;
    const avail_h = size[1] - STATE.TOOLBAR_HEIGHT - STATE.TIMELINE_HEIGHT - STATE.CONTROLS_HEIGHT - 60;

    const vid_w: f32 = @floatFromInt(STATE.video_width);
    const vid_h: f32 = @floatFromInt(STATE.video_height);

    const scale_w = avail_w / vid_w;
    const scale_h = avail_h / vid_h;

    STATE.zoom = @min(scale_w, scale_h);
}

/// Draw the video display area
fn drawVideoView() void {
    const vid_w: f32 = @floatFromInt(STATE.video_width);
    const vid_h: f32 = @floatFromInt(STATE.video_height);

    const display_w = vid_w * STATE.zoom;
    const display_h = vid_h * STATE.zoom;

    // Calculate available space (leave room for timeline and controls)
    const vp = zgui.getMainViewport();
    const size = vp.getSize();
    const avail_h = size[1] - STATE.TIMELINE_HEIGHT - STATE.CONTROLS_HEIGHT - 40;

    if (zgui.beginChild(
        "VideoContainer",
        .{
            .w = -1,
            .h = avail_h,
            .child_flags = .{
                .border = true,
            },
            .window_flags = .{
                .horizontal_scrollbar = true,
            },
        },
    )) {
        defer zgui.endChild();

        const avail = zgui.getContentRegionAvail();

        // Center the video if smaller than available space
        if (display_w < avail[0]) {
            const offset_x = (avail[0] - display_w) / 2;
            zgui.setCursorPosX(offset_x);
        }
        if (display_h < avail[1]) {
            const offset_y = (avail[1] - display_h) / 2;
            zgui.setCursorPosY(offset_y);
        }

        // Draw the video frame
        cimgui.igImage(
            .{ ._TexID = STATE.video_texid },
            .{ .x = display_w, .y = display_h },
        );
    }
}

/// Draw the timeline with playhead
fn drawTimeline() void {
    const avail = zgui.getContentRegionAvail();
    const timeline_width = avail[0] - 20;

    // Time display
    zgui.text("{s} / {s}", .{
        formatTime(STATE.current_time),
        formatTime(STATE.duration),
    });

    zgui.sameLine(.{});
    zgui.spacing();
    zgui.sameLine(.{});

    // Timeline slider
    zgui.pushItemWidth(timeline_width - 150);
    var time_pos: f32 = @floatCast(STATE.current_time);
    const duration_f: f32 = @floatCast(@max(STATE.duration, 0.001));

    if (zgui.sliderFloat("##timeline", .{
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

    // Draw timeline visual
    const draw_list = zgui.getWindowDrawList();
    const cursor_pos = zgui.getCursorScreenPos();
    const timeline_y = cursor_pos[1];
    const timeline_x = cursor_pos[0];
    const timeline_h: f32 = 20;

    // Timeline background
    draw_list.addRectFilled(
        .{ .pmin = .{ timeline_x, timeline_y }, .pmax = .{ timeline_x + timeline_width, timeline_y + timeline_h }, .col = 0xFF404040 },
    );

    // Progress bar
    const progress = if (STATE.duration > 0) STATE.current_time / STATE.duration else 0;
    const progress_width = timeline_width * @as(f32, @floatCast(progress));
    draw_list.addRectFilled(
        .{ .pmin = .{ timeline_x, timeline_y }, .pmax = .{ timeline_x + progress_width, timeline_y + timeline_h }, .col = 0xFF00AA00 },
    );

    // Playhead
    const playhead_x = timeline_x + progress_width;
    draw_list.addLine(
        .{ .p1 = .{ playhead_x, timeline_y - 5 }, .p2 = .{ playhead_x, timeline_y + timeline_h + 5 }, .col = 0xFFFFFFFF, .thickness = 2 },
    );

    // Reserve space for the visual timeline
    zgui.dummy(.{ .w = timeline_width, .h = timeline_h + 10 });
}

/// Draw transport controls (play/pause, stop, rate, volume)
fn drawTransportControls() void {
    // Skip backward
    if (zgui.button("|<", .{ .w = 40 })) {
        STATE.seek_requested = true;
        STATE.seek_time = 0;
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Go to start", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});

    // Step backward
    if (zgui.button("<<", .{ .w = 40 })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.current_time - step * 10);
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Step backward 10 frames", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});

    // Frame backward
    if (zgui.button("<", .{ .w = 30 })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.current_time - step);
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Previous frame", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});

    // Play/Pause button
    if (STATE.is_playing) {
        if (zgui.button("||  Pause", .{ .w = 80 })) {
            STATE.is_playing = false;
        }
    } else {
        if (zgui.button(">  Play", .{ .w = 80 })) {
            STATE.is_playing = true;
            STATE.last_frame_time = std.time.milliTimestamp();
            STATE.frame_accumulator = 0;
        }
    }

    zgui.sameLine(.{});

    // Frame forward
    if (zgui.button(">", .{ .w = 30 })) {
        if (STATE.decoder) |dec| {
            if (dec.decodeNextVideoFrame()) |_| {
                STATE.current_time = dec.getCurrentTime();
                updateTexture();
            }
        }
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Next frame", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});

    // Step forward
    if (zgui.button(">>", .{ .w = 40 })) {
        const step = 1.0 / STATE.fps;
        STATE.seek_requested = true;
        STATE.seek_time = @min(STATE.duration, STATE.current_time + step * 10);
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Step forward 10 frames", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});

    // Skip forward
    if (zgui.button(">|", .{ .w = 40 })) {
        STATE.seek_requested = true;
        STATE.seek_time = @max(0, STATE.duration - 0.1);
    }
    if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
        zgui.text("Go to end", .{});
        zgui.endTooltip();
    }

    zgui.sameLine(.{});
    zgui.spacing();
    zgui.sameLine(.{});

    // Playback rate
    zgui.text("Speed:", .{});
    zgui.sameLine(.{});

    zgui.pushItemWidth(80);
    if (zgui.beginCombo("##rate", .{ .preview_value = formatRate(STATE.playback_rate) })) {
        for (STATE.PLAYBACK_RATES) |rate| {
            const is_selected = (STATE.playback_rate == rate);
            if (zgui.selectable(formatRate(rate), .{ .selected = is_selected })) {
                STATE.playback_rate = rate;
            }
            if (is_selected) {
                zgui.setItemDefaultFocus();
            }
        }
        zgui.endCombo();
    }
    zgui.popItemWidth();

    zgui.sameLine(.{});
    zgui.spacing();
    zgui.sameLine(.{});

    // Audio controls (only show if audio is available)
    if (STATE.has_audio) {
        // Mute button
        const mute_label = if (STATE.is_muted) "Unmute" else "Mute";
        if (zgui.button(mute_label, .{ .w = 60 })) {
            STATE.is_muted = !STATE.is_muted;
        }

        zgui.sameLine(.{});

        // Volume slider
        zgui.text("Vol:", .{});
        zgui.sameLine(.{});

        zgui.pushItemWidth(80);
        _ = zgui.sliderFloat("##volume", .{
            .v = &STATE.volume,
            .min = 0.0,
            .max = 1.0,
            .cfmt = "%.0f%%",
            .flags = .{},
        });
        // Display as percentage
        if (zgui.isItemHovered(.{}) and zgui.beginItemTooltip()) {
            zgui.text("Volume: {d:.0}%", .{STATE.volume * 100});
            zgui.endTooltip();
        }
        zgui.popItemWidth();

        zgui.sameLine(.{});
        zgui.spacing();
        zgui.sameLine(.{});
    }

    // Video info
    const audio_str = if (STATE.has_audio) " [Audio]" else "";
    zgui.text("| {d:.2} fps | {}x{}{s}", .{
        STATE.fps,
        STATE.video_width,
        STATE.video_height,
        audio_str,
    });
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
