//! libav.zig - FFmpeg/libav bindings for Zig
//! Provides video decoding capabilities using FFmpeg libraries.

const std = @import("std");
const builtin = @import("builtin");

// FFmpeg C API bindings
pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

/// Error types for libav operations
pub const Error = error{
    OpenInputFailed,
    FindStreamInfoFailed,
    NoVideoStream,
    CodecNotFound,
    CodecAllocFailed,
    CodecOpenFailed,
    FrameAllocFailed,
    PacketAllocFailed,
    SwsContextFailed,
    BufferAllocFailed,
    SendPacketFailed,
    ReceiveFrameFailed,
    SeekFailed,
    InvalidState,
};

/// Video decoder context
pub const VideoDecoder = struct {
    format_ctx: *c.AVFormatContext,
    codec_ctx: *c.AVCodecContext,
    sws_ctx: ?*c.SwsContext,
    frame: *c.AVFrame,
    frame_rgb: *c.AVFrame,
    packet: *c.AVPacket,
    video_stream_index: c_int,
    rgb_buffer: []u8,
    allocator: std.mem.Allocator,

    // Video properties
    width: u32,
    height: u32,
    fps: f64,
    duration_sec: f64,
    total_frames: i64,
    time_base: f64,

    // Playback state
    current_pts: i64,
    eof_reached: bool,

    /// Open a video file for decoding
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !*VideoDecoder {
        var self = try allocator.create(VideoDecoder);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.sws_ctx = null;
        self.current_pts = 0;
        self.eof_reached = false;

        // Open input file
        var format_ctx: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&format_ctx, path.ptr, null, null) < 0) {
            return Error.OpenInputFailed;
        }
        self.format_ctx = format_ctx.?;
        errdefer c.avformat_close_input(@ptrCast(&self.format_ctx));

        // Find stream info
        if (c.avformat_find_stream_info(self.format_ctx, null) < 0) {
            return Error.FindStreamInfoFailed;
        }

        // Find video stream
        self.video_stream_index = -1;
        var i: u32 = 0;
        while (i < self.format_ctx.nb_streams) : (i += 1) {
            const stream = self.format_ctx.streams[i];
            if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                self.video_stream_index = @intCast(i);
                break;
            }
        }

        if (self.video_stream_index < 0) {
            return Error.NoVideoStream;
        }

        const video_stream = self.format_ctx.streams[@intCast(self.video_stream_index)];
        const codecpar = video_stream.*.codecpar;

        // Find decoder
        const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
        if (codec == null) {
            return Error.CodecNotFound;
        }

        // Allocate codec context
        self.codec_ctx = c.avcodec_alloc_context3(codec) orelse {
            return Error.CodecAllocFailed;
        };
        errdefer c.avcodec_free_context(@ptrCast(&self.codec_ctx));

        // Copy codec parameters
        _ = c.avcodec_parameters_to_context(self.codec_ctx, codecpar);

        // Open codec
        if (c.avcodec_open2(self.codec_ctx, codec, null) < 0) {
            return Error.CodecOpenFailed;
        }

        // Store video properties
        self.width = @intCast(self.codec_ctx.width);
        self.height = @intCast(self.codec_ctx.height);

        // Calculate FPS
        const tb = video_stream.*.time_base;
        self.time_base = @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den));

        const fr = video_stream.*.avg_frame_rate;
        if (fr.den != 0 and fr.num != 0) {
            self.fps = @as(f64, @floatFromInt(fr.num)) / @as(f64, @floatFromInt(fr.den));
        } else {
            self.fps = 30.0; // Default fallback
        }

        // Calculate duration
        if (self.format_ctx.duration != c.AV_NOPTS_VALUE) {
            self.duration_sec = @as(f64, @floatFromInt(self.format_ctx.duration)) / @as(f64, c.AV_TIME_BASE);
        } else if (video_stream.*.duration != c.AV_NOPTS_VALUE) {
            self.duration_sec = @as(f64, @floatFromInt(video_stream.*.duration)) * self.time_base;
        } else {
            self.duration_sec = 0;
        }

        self.total_frames = @intFromFloat(self.duration_sec * self.fps);

        // Allocate frames
        self.frame = c.av_frame_alloc() orelse {
            return Error.FrameAllocFailed;
        };
        errdefer c.av_frame_free(@ptrCast(&self.frame));

        self.frame_rgb = c.av_frame_alloc() orelse {
            return Error.FrameAllocFailed;
        };
        errdefer c.av_frame_free(@ptrCast(&self.frame_rgb));

        // Allocate packet
        self.packet = c.av_packet_alloc() orelse {
            return Error.PacketAllocFailed;
        };
        errdefer c.av_packet_free(@ptrCast(&self.packet));

        // Allocate RGB buffer
        const num_bytes: usize = @intCast(c.av_image_get_buffer_size(
            c.AV_PIX_FMT_RGBA,
            self.codec_ctx.width,
            self.codec_ctx.height,
            1,
        ));
        self.rgb_buffer = try allocator.alloc(u8, num_bytes);
        errdefer allocator.free(self.rgb_buffer);

        // Setup RGB frame
        _ = c.av_image_fill_arrays(
            &self.frame_rgb.data,
            &self.frame_rgb.linesize,
            self.rgb_buffer.ptr,
            c.AV_PIX_FMT_RGBA,
            self.codec_ctx.width,
            self.codec_ctx.height,
            1,
        );

        // Create scaler context
        self.sws_ctx = c.sws_getContext(
            self.codec_ctx.width,
            self.codec_ctx.height,
            self.codec_ctx.pix_fmt,
            self.codec_ctx.width,
            self.codec_ctx.height,
            c.AV_PIX_FMT_RGBA,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        );
        if (self.sws_ctx == null) {
            return Error.SwsContextFailed;
        }

        return self;
    }

    /// Close the decoder and free resources
    pub fn close(self: *VideoDecoder) void {
        if (self.sws_ctx) |ctx| {
            c.sws_freeContext(ctx);
        }
        c.av_packet_free(@ptrCast(&self.packet));
        c.av_frame_free(@ptrCast(&self.frame_rgb));
        c.av_frame_free(@ptrCast(&self.frame));
        c.avcodec_free_context(@ptrCast(&self.codec_ctx));
        c.avformat_close_input(@ptrCast(&self.format_ctx));
        self.allocator.free(self.rgb_buffer);
        self.allocator.destroy(self);
    }

    /// Decode the next frame and return RGBA pixel data
    /// Returns null if EOF reached
    pub fn decodeNextFrame(self: *VideoDecoder) ?[]const u8 {
        while (true) {
            // Try to receive a frame from the decoder
            const receive_ret = c.avcodec_receive_frame(self.codec_ctx, self.frame);
            if (receive_ret == 0) {
                // Got a frame, convert to RGB
                _ = c.sws_scale(
                    self.sws_ctx,
                    &self.frame.data,
                    &self.frame.linesize,
                    0,
                    self.codec_ctx.height,
                    &self.frame_rgb.data,
                    &self.frame_rgb.linesize,
                );

                self.current_pts = self.frame.pts;
                return self.rgb_buffer;
            } else if (receive_ret == c.AVERROR_EOF) {
                self.eof_reached = true;
                return null;
            } else if (receive_ret != c.AVERROR(c.EAGAIN)) {
                // Real error
                return null;
            }

            // Need more data, read next packet
            while (true) {
                const read_ret = c.av_read_frame(self.format_ctx, self.packet);
                if (read_ret < 0) {
                    // EOF or error - flush decoder
                    _ = c.avcodec_send_packet(self.codec_ctx, null);
                    break;
                }

                if (self.packet.stream_index == self.video_stream_index) {
                    _ = c.avcodec_send_packet(self.codec_ctx, self.packet);
                    c.av_packet_unref(self.packet);
                    break;
                }
                c.av_packet_unref(self.packet);
            }
        }
    }

    /// Seek to a specific time in seconds
    pub fn seekToTime(self: *VideoDecoder, time_sec: f64) !void {
        const timestamp: i64 = @intFromFloat(time_sec * @as(f64, c.AV_TIME_BASE));

        if (c.av_seek_frame(self.format_ctx, -1, timestamp, c.AVSEEK_FLAG_BACKWARD) < 0) {
            return Error.SeekFailed;
        }

        // Flush codec buffers
        c.avcodec_flush_buffers(self.codec_ctx);
        self.eof_reached = false;

        // Decode frames until we reach or pass the target time
        const video_stream = self.format_ctx.streams[@intCast(self.video_stream_index)];
        const target_pts: i64 = @intFromFloat(time_sec / self.time_base);

        while (true) {
            const frame_data = self.decodeNextFrame();
            if (frame_data == null) {
                break;
            }

            // Check if we've reached the target
            if (self.frame.pts >= target_pts) {
                break;
            }
        }

        _ = video_stream;
    }

    /// Get current playback time in seconds
    pub fn getCurrentTime(self: *VideoDecoder) f64 {
        if (self.current_pts == c.AV_NOPTS_VALUE) {
            return 0;
        }
        return @as(f64, @floatFromInt(self.current_pts)) * self.time_base;
    }

    /// Check if end of file has been reached
    pub fn isEof(self: *VideoDecoder) bool {
        return self.eof_reached;
    }

    /// Reset to beginning of video
    pub fn reset(self: *VideoDecoder) !void {
        try self.seekToTime(0);
    }
};
