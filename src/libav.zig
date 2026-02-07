//! libav.zig - FFmpeg/libav bindings for Zig
//! Provides video and audio decoding capabilities using FFmpeg libraries.

const std = @import("std");
const builtin = @import("builtin");

// FFmpeg C API bindings
pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libswresample/swresample.h");
});

/// Error types for libav operations
pub const Error = error{
    OpenInputFailed,
    FindStreamInfoFailed,
    NoVideoStream,
    NoAudioStream,
    CodecNotFound,
    CodecAllocFailed,
    CodecOpenFailed,
    FrameAllocFailed,
    PacketAllocFailed,
    SwsContextFailed,
    SwrContextFailed,
    BufferAllocFailed,
    SendPacketFailed,
    ReceiveFrameFailed,
    SeekFailed,
    InvalidState,
};

/// Audio/Video decoder context - handles both streams from a single file
pub const MediaDecoder = struct {
    format_ctx: *c.AVFormatContext,
    allocator: std.mem.Allocator,

    // Video decoding
    video_codec_ctx: ?*c.AVCodecContext,
    video_stream_index: c_int,
    sws_ctx: ?*c.SwsContext,
    video_frame: *c.AVFrame,
    video_frame_rgb: *c.AVFrame,
    rgb_buffer: []u8,

    // Audio decoding
    audio_codec_ctx: ?*c.AVCodecContext,
    audio_stream_index: c_int,
    swr_ctx: ?*c.SwrContext,
    audio_frame: *c.AVFrame,

    // Shared packet
    packet: *c.AVPacket,

    // Video properties
    width: u32,
    height: u32,
    fps: f64,
    video_time_base: f64,

    // Audio properties
    sample_rate: u32,
    channels: u32,
    audio_time_base: f64,
    has_audio: bool,

    // Media properties
    duration_sec: f64,

    // Playback state
    current_video_pts: i64,
    current_audio_pts: i64,
    video_eof: bool,
    audio_eof: bool,

    // Audio ring buffer for decoded samples (interleaved f32)
    audio_ring_buffer: []f32,
    audio_ring_write_pos: usize,
    audio_ring_read_pos: usize,
    audio_ring_size: usize,
    const AUDIO_RING_BUFFER_SECONDS: f32 = 2.0; // Buffer 2 seconds of audio

    /// Open a media file for decoding
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !*MediaDecoder {
        var self = try allocator.create(MediaDecoder);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.sws_ctx = null;
        self.swr_ctx = null;
        self.video_codec_ctx = null;
        self.audio_codec_ctx = null;
        self.current_video_pts = 0;
        self.current_audio_pts = 0;
        self.video_eof = false;
        self.audio_eof = false;
        self.has_audio = false;
        self.video_stream_index = -1;
        self.audio_stream_index = -1;

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

        // Find video and audio streams
        var i: u32 = 0;
        while (i < self.format_ctx.nb_streams) : (i += 1) {
            const stream = self.format_ctx.streams[i];
            if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO and self.video_stream_index < 0) {
                self.video_stream_index = @intCast(i);
            } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO and self.audio_stream_index < 0) {
                self.audio_stream_index = @intCast(i);
            }
        }

        if (self.video_stream_index < 0) {
            return Error.NoVideoStream;
        }

        // Setup video decoder
        try self.setupVideoDecoder();

        // Setup audio decoder if audio stream exists
        if (self.audio_stream_index >= 0) {
            self.setupAudioDecoder() catch |err| {
                std.log.warn("Failed to setup audio decoder: {}, continuing without audio", .{err});
                self.has_audio = false;
            };
        }

        // Calculate duration
        if (self.format_ctx.duration != c.AV_NOPTS_VALUE) {
            self.duration_sec = @as(f64, @floatFromInt(self.format_ctx.duration)) / @as(f64, c.AV_TIME_BASE);
        } else {
            const video_stream = self.format_ctx.streams[@intCast(self.video_stream_index)];
            if (video_stream.*.duration != c.AV_NOPTS_VALUE) {
                self.duration_sec = @as(f64, @floatFromInt(video_stream.*.duration)) * self.video_time_base;
            } else {
                self.duration_sec = 0;
            }
        }

        // Allocate shared packet
        self.packet = c.av_packet_alloc() orelse {
            return Error.PacketAllocFailed;
        };

        return self;
    }

    fn setupVideoDecoder(self: *MediaDecoder) !void {
        const video_stream = self.format_ctx.streams[@intCast(self.video_stream_index)];
        const codecpar = video_stream.*.codecpar;

        // Find decoder
        const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
        if (codec == null) {
            return Error.CodecNotFound;
        }

        // Allocate codec context
        self.video_codec_ctx = c.avcodec_alloc_context3(codec) orelse {
            return Error.CodecAllocFailed;
        };
        errdefer c.avcodec_free_context(@ptrCast(&self.video_codec_ctx));

        // Copy codec parameters
        _ = c.avcodec_parameters_to_context(self.video_codec_ctx.?, codecpar);

        // Open codec
        if (c.avcodec_open2(self.video_codec_ctx.?, codec, null) < 0) {
            return Error.CodecOpenFailed;
        }

        const vctx = self.video_codec_ctx.?;

        // Store video properties
        self.width = @intCast(vctx.width);
        self.height = @intCast(vctx.height);

        // Calculate FPS and time base
        const tb = video_stream.*.time_base;
        self.video_time_base = @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den));

        const fr = video_stream.*.avg_frame_rate;
        if (fr.den != 0 and fr.num != 0) {
            self.fps = @as(f64, @floatFromInt(fr.num)) / @as(f64, @floatFromInt(fr.den));
        } else {
            self.fps = 30.0;
        }

        // Allocate frames
        self.video_frame = c.av_frame_alloc() orelse {
            return Error.FrameAllocFailed;
        };
        errdefer c.av_frame_free(@ptrCast(&self.video_frame));

        self.video_frame_rgb = c.av_frame_alloc() orelse {
            return Error.FrameAllocFailed;
        };
        errdefer c.av_frame_free(@ptrCast(&self.video_frame_rgb));

        // Allocate RGB buffer
        const num_bytes: usize = @intCast(c.av_image_get_buffer_size(
            c.AV_PIX_FMT_RGBA,
            vctx.width,
            vctx.height,
            1,
        ));
        self.rgb_buffer = try self.allocator.alloc(u8, num_bytes);
        errdefer self.allocator.free(self.rgb_buffer);

        // Setup RGB frame
        _ = c.av_image_fill_arrays(
            &self.video_frame_rgb.data,
            &self.video_frame_rgb.linesize,
            self.rgb_buffer.ptr,
            c.AV_PIX_FMT_RGBA,
            vctx.width,
            vctx.height,
            1,
        );

        // Create scaler context
        self.sws_ctx = c.sws_getContext(
            vctx.width,
            vctx.height,
            vctx.pix_fmt,
            vctx.width,
            vctx.height,
            c.AV_PIX_FMT_RGBA,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        );
        if (self.sws_ctx == null) {
            return Error.SwsContextFailed;
        }
    }

    fn setupAudioDecoder(self: *MediaDecoder) !void {
        const audio_stream = self.format_ctx.streams[@intCast(self.audio_stream_index)];
        const codecpar = audio_stream.*.codecpar;

        // Find decoder
        const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
        if (codec == null) {
            return Error.CodecNotFound;
        }

        // Allocate codec context
        self.audio_codec_ctx = c.avcodec_alloc_context3(codec) orelse {
            return Error.CodecAllocFailed;
        };
        errdefer c.avcodec_free_context(@ptrCast(&self.audio_codec_ctx));

        // Copy codec parameters
        _ = c.avcodec_parameters_to_context(self.audio_codec_ctx.?, codecpar);

        // Open codec
        if (c.avcodec_open2(self.audio_codec_ctx.?, codec, null) < 0) {
            return Error.CodecOpenFailed;
        }

        const actx = self.audio_codec_ctx.?;

        // Store audio properties
        self.sample_rate = @intCast(actx.sample_rate);
        self.channels = @intCast(actx.ch_layout.nb_channels);

        const tb = audio_stream.*.time_base;
        self.audio_time_base = @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(tb.den));

        // Allocate audio frame
        self.audio_frame = c.av_frame_alloc() orelse {
            return Error.FrameAllocFailed;
        };
        errdefer c.av_frame_free(@ptrCast(&self.audio_frame));

        // Create resampler context to convert to f32 interleaved stereo at 44100
        self.swr_ctx = c.swr_alloc();
        if (self.swr_ctx == null) {
            return Error.SwrContextFailed;
        }

        // Set output options - stereo f32 at 44100 Hz
        var out_ch_layout: c.AVChannelLayout = undefined;
        c.av_channel_layout_default(&out_ch_layout, 2);

        _ = c.av_opt_set_chlayout(self.swr_ctx, "out_chlayout", &out_ch_layout, 0);
        _ = c.av_opt_set_int(self.swr_ctx, "out_sample_rate", 44100, 0);
        _ = c.av_opt_set_sample_fmt(self.swr_ctx, "out_sample_fmt", c.AV_SAMPLE_FMT_FLT, 0);

        // Set input options from codec
        _ = c.av_opt_set_chlayout(self.swr_ctx, "in_chlayout", &actx.ch_layout, 0);
        _ = c.av_opt_set_int(self.swr_ctx, "in_sample_rate", actx.sample_rate, 0);
        _ = c.av_opt_set_sample_fmt(self.swr_ctx, "in_sample_fmt", actx.sample_fmt, 0);

        if (c.swr_init(self.swr_ctx) < 0) {
            return Error.SwrContextFailed;
        }

        // Update to output sample rate/channels
        self.sample_rate = 44100;
        self.channels = 2;

        // Allocate audio ring buffer
        self.audio_ring_size = @intFromFloat(AUDIO_RING_BUFFER_SECONDS * @as(f32, @floatFromInt(self.sample_rate)) * @as(f32, @floatFromInt(self.channels)));
        self.audio_ring_buffer = try self.allocator.alloc(f32, self.audio_ring_size);
        @memset(self.audio_ring_buffer, 0);
        self.audio_ring_write_pos = 0;
        self.audio_ring_read_pos = 0;

        self.has_audio = true;

        std.log.info("Audio: {} Hz, {} channels", .{ self.sample_rate, self.channels });
    }

    /// Close the decoder and free resources
    pub fn close(self: *MediaDecoder) void {
        if (self.sws_ctx) |ctx| {
            c.sws_freeContext(ctx);
        }
        if (self.swr_ctx) |ctx| {
            var swr_ptr: ?*c.SwrContext = ctx;
            c.swr_free(&swr_ptr);
        }
        c.av_packet_free(@ptrCast(&self.packet));
        c.av_frame_free(@ptrCast(&self.video_frame_rgb));
        c.av_frame_free(@ptrCast(&self.video_frame));
        if (self.audio_codec_ctx != null) {
            c.av_frame_free(@ptrCast(&self.audio_frame));
            c.avcodec_free_context(@ptrCast(&self.audio_codec_ctx));
        }
        if (self.video_codec_ctx) |_| {
            c.avcodec_free_context(@ptrCast(&self.video_codec_ctx));
        }
        c.avformat_close_input(@ptrCast(&self.format_ctx));
        self.allocator.free(self.rgb_buffer);
        if (self.has_audio) {
            self.allocator.free(self.audio_ring_buffer);
        }
        self.allocator.destroy(self);
    }

    /// Decode the next video frame and return RGBA pixel data
    /// Also decodes audio packets encountered along the way
    pub fn decodeNextVideoFrame(self: *MediaDecoder) ?[]const u8 {
        const vctx = self.video_codec_ctx orelse return null;

        while (true) {
            // Try to receive a video frame from the decoder
            const receive_ret = c.avcodec_receive_frame(vctx, self.video_frame);
            if (receive_ret == 0) {
                // Got a frame, convert to RGB
                _ = c.sws_scale(
                    self.sws_ctx,
                    &self.video_frame.data,
                    &self.video_frame.linesize,
                    0,
                    vctx.height,
                    &self.video_frame_rgb.data,
                    &self.video_frame_rgb.linesize,
                );

                self.current_video_pts = self.video_frame.pts;
                return self.rgb_buffer;
            } else if (receive_ret == c.AVERROR_EOF) {
                self.video_eof = true;
                return null;
            } else if (receive_ret != c.AVERROR(c.EAGAIN)) {
                return null;
            }

            // Need more data, read next packet
            if (!self.readAndDispatchPacket()) {
                // No more packets
                _ = c.avcodec_send_packet(vctx, null);
            }
        }
    }

    /// Read a packet and send it to the appropriate decoder
    fn readAndDispatchPacket(self: *MediaDecoder) bool {
        const read_ret = c.av_read_frame(self.format_ctx, self.packet);
        if (read_ret < 0) {
            return false;
        }

        defer c.av_packet_unref(self.packet);

        if (self.packet.stream_index == self.video_stream_index) {
            if (self.video_codec_ctx) |vctx| {
                _ = c.avcodec_send_packet(vctx, self.packet);
            }
        } else if (self.packet.stream_index == self.audio_stream_index) {
            self.decodeAudioPacket();
        }

        return true;
    }

    /// Decode an audio packet and add samples to the ring buffer
    fn decodeAudioPacket(self: *MediaDecoder) void {
        const actx = self.audio_codec_ctx orelse return;
        const swr = self.swr_ctx orelse return;

        _ = c.avcodec_send_packet(actx, self.packet);

        while (true) {
            const ret = c.avcodec_receive_frame(actx, self.audio_frame);
            if (ret < 0) break;

            self.current_audio_pts = self.audio_frame.pts;

            // Calculate output samples
            const out_samples = c.swr_get_out_samples(swr, self.audio_frame.nb_samples);
            if (out_samples <= 0) continue;

            // Temporary buffer for converted samples
            var out_buffer: [*c]u8 = undefined;
            const out_linesize: c_int = 0;
            _ = out_linesize;

            const buffer_size = @as(usize, @intCast(out_samples)) * self.channels * @sizeOf(f32);
            const temp_buffer = self.allocator.alloc(u8, buffer_size) catch continue;
            defer self.allocator.free(temp_buffer);

            out_buffer = temp_buffer.ptr;

            const converted = c.swr_convert(
                swr,
                @ptrCast(&out_buffer),
                out_samples,
                @ptrCast(&self.audio_frame.data),
                self.audio_frame.nb_samples,
            );

            if (converted > 0) {
                // Copy to ring buffer
                const samples: []const f32 = @as([*]const f32, @ptrCast(@alignCast(temp_buffer.ptr)))[0..@intCast(@as(usize, @intCast(converted)) * self.channels)];
                self.writeAudioSamples(samples);
            }
        }
    }

    /// Write samples to the audio ring buffer
    fn writeAudioSamples(self: *MediaDecoder, samples: []const f32) void {
        for (samples) |sample| {
            self.audio_ring_buffer[self.audio_ring_write_pos] = sample;
            self.audio_ring_write_pos = (self.audio_ring_write_pos + 1) % self.audio_ring_size;
        }
    }

    /// Read samples from the audio ring buffer (called from audio callback)
    /// Returns the number of samples read
    pub fn readAudioSamples(self: *MediaDecoder, buffer: []f32, volume: f32) usize {
        var count: usize = 0;
        for (buffer) |*sample| {
            if (self.audio_ring_read_pos == self.audio_ring_write_pos) {
                // Buffer underrun - fill with silence
                sample.* = 0;
            } else {
                sample.* = self.audio_ring_buffer[self.audio_ring_read_pos] * volume;
                self.audio_ring_read_pos = (self.audio_ring_read_pos + 1) % self.audio_ring_size;
                count += 1;
            }
        }
        return count;
    }

    /// Clear the audio ring buffer
    pub fn clearAudioBuffer(self: *MediaDecoder) void {
        self.audio_ring_write_pos = 0;
        self.audio_ring_read_pos = 0;
        @memset(self.audio_ring_buffer, 0);
    }

    /// Get available audio samples in buffer
    pub fn getAudioBufferLevel(self: *MediaDecoder) usize {
        if (self.audio_ring_write_pos >= self.audio_ring_read_pos) {
            return self.audio_ring_write_pos - self.audio_ring_read_pos;
        } else {
            return self.audio_ring_size - self.audio_ring_read_pos + self.audio_ring_write_pos;
        }
    }

    /// Seek to a specific time in seconds
    pub fn seekToTime(self: *MediaDecoder, time_sec: f64) !void {
        const timestamp: i64 = @intFromFloat(time_sec * @as(f64, c.AV_TIME_BASE));

        if (c.av_seek_frame(self.format_ctx, -1, timestamp, c.AVSEEK_FLAG_BACKWARD) < 0) {
            return Error.SeekFailed;
        }

        // Flush codec buffers
        if (self.video_codec_ctx) |vctx| {
            c.avcodec_flush_buffers(vctx);
        }
        if (self.audio_codec_ctx) |actx| {
            c.avcodec_flush_buffers(actx);
        }

        self.video_eof = false;
        self.audio_eof = false;

        // Clear audio buffer
        if (self.has_audio) {
            self.clearAudioBuffer();
        }

        // Decode frames until we reach or pass the target time
        const target_pts: i64 = @intFromFloat(time_sec / self.video_time_base);

        while (true) {
            const frame_data = self.decodeNextVideoFrame();
            if (frame_data == null) {
                break;
            }

            if (self.video_frame.pts >= target_pts) {
                break;
            }
        }
    }

    /// Get current video playback time in seconds
    pub fn getCurrentTime(self: *MediaDecoder) f64 {
        if (self.current_video_pts == c.AV_NOPTS_VALUE) {
            return 0;
        }
        return @as(f64, @floatFromInt(self.current_video_pts)) * self.video_time_base;
    }

    /// Check if end of file has been reached
    pub fn isEof(self: *MediaDecoder) bool {
        return self.video_eof;
    }

    /// Reset to beginning
    pub fn reset(self: *MediaDecoder) !void {
        try self.seekToTime(0);
    }
};

// Keep the old VideoDecoder as an alias for backwards compatibility
pub const VideoDecoder = MediaDecoder;
