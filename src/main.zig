const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const FrameRenderer = @import("FrameRenderer.zig");
const decoder = @import("decoder.zig");
const audio = @import("audio.zig");

pub export fn appstate_snapshot(state: *AppState) c.AppStateSnapshot {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.inner;
}

const PlayerState = struct {
    start_time: std.time.Instant,
    pause_time: ?std.time.Instant,
    time_adjustment: u64,

    fn init(now: std.time.Instant) PlayerState {
        return .{
            .start_time = now,
            .pause_time = null,
            .time_adjustment = 0,
        };
    }

    fn pause(self: *PlayerState, now: std.time.Instant) void {
        // Do not overwrite existing pause start
        if (self.isPaused()) {
            return;
        }
        self.pause_time = now;
    }

    fn play(self: *PlayerState, now: std.time.Instant) void {
        // Avoid invalid access to pause_time below
        if (self.pause_time == null) {
            return;
        }

        self.time_adjustment += now.since(self.pause_time.?);
        self.pause_time = null;
    }

    fn isPaused(self: *const PlayerState) bool {
        return self.pause_time != null;
    }

    fn togglePause(self: *PlayerState, now: std.time.Instant) void {
        if (self.isPaused()) {
            self.play(now);
        } else {
            self.pause(now);
        }
    }

    fn shouldUpdateFrame(self: *const PlayerState, now: std.time.Instant, frame_pts: f32) bool {
        return self.pause_time == null and frame_pts * 1e9 < @as(f32, @floatFromInt(now.since(self.start_time) - self.time_adjustment));
    }
};

const ArgParseError = std.process.ArgIterator.InitError;

const Args = struct {
    it: std.process.ArgIterator,
    input: [:0]const u8,

    const Switch = enum {
        @"--input",
        @"--help",

        fn parse(s: []const u8) ?Switch {
            inline for (std.meta.fields(Switch)) |f| {
                if (std.mem.eql(u8, f.name, s)) {
                    return @enumFromInt(f.value);
                }
            }

            return null;
        }
    };

    fn print(comptime fmt: []const u8, params: anytype) void {
        std.io.getStdErr().writer().print(fmt, params) catch {};
    }

    pub fn init(alloc: std.mem.Allocator) ArgParseError!Args {
        var args = try std.process.argsWithAllocator(alloc);

        var input: ?[:0]const u8 = null;
        const process_name = args.next() orelse "video-editor";
        while (args.next()) |arg| {
            const s = Switch.parse(arg) orelse {
                print("unrecognized argument: {s}\n", .{arg});
                help(process_name);
            };

            switch (s) {
                .@"--input" => {
                    input = args.next() orelse {
                        print("--input provided with no file\n", .{});
                        help(process_name);
                    };
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .it = args,
            .input = input orelse {
                unreachable;
            },
        };
    }

    fn help(process_name: []const u8) noreturn {
        print("Usage: {s} [ARGS]\n\nARGS:\n", .{process_name});

        inline for (std.meta.fields(Switch)) |s| {
            print("{s}: ", .{s.name});
            const value: Switch = @enumFromInt(s.value);
            switch (value) {
                .@"--input" => {
                    print("File to work with", .{});
                },
                .@"--help" => {
                    print("Show this help", .{});
                },
            }
            print("\n", .{});
        }

        std.process.exit(1);
    }

    pub fn deinit(self: *Args) void {
        self.it.deinit();
    }
};

fn getNextVideoFrame(dec: *decoder.VideoDecoder, audio_player: ?*audio.Player) !decoder.VideoFrame {
    while (true) {
        var frame = try dec.next();
        if (frame == null) {
            continue;
        }

        switch (frame.?) {
            .audio => |*af| {
                if (audio_player) |p| {
                    p.pushFrame(af.*) catch {
                        std.log.err("Audio thread falling behind, dropping frame", .{});
                        af.deinit();
                    };
                } else {
                    af.deinit();
                }
            },
            .video => |vf| {
                return vf;
            },
        }
    }
}

const AppState = struct {
    mutex: std.Thread.Mutex,
    inner: c.AppStateSnapshot,

    fn setSnapshot(self: *AppState, snapshot: c.AppStateSnapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.inner = snapshot;
    }
};

fn main_loop(alloc: Allocator, args: Args, frame_renderer: *FrameRenderer.SharedData, gui: ?*c.Gui, app_state: *AppState) !void {
    // If main thread init fails, we need to close the GUI, but if the GUI
    // hadn't launched yet it will miss the shutdown notification and stay
    // open forever
    c.gui_wait_start(gui);
    defer c.gui_close(gui);

    var dec = try decoder.VideoDecoder.init(alloc, args.input);
    defer dec.deinit();
    defer frame_renderer.deinit();
    const total_runtime = dec.duration();

    var audio_player: ?*audio.Player = null;
    defer {
        if (audio_player) |p| {
            p.deinit();
        }
    }

    var streams = dec.streams();
    while (try streams.next()) |stream| {
        switch (stream) {
            .audio => |params| {
                audio_player = try audio.Player.init(alloc, .{
                    .channels = params.num_channels,
                    .format = params.format,
                    .sample_rate = params.sample_rate,
                });
                // No UI for dealing with multiple streams, video ignored
                break;
            },
            else => {},
        }
    }

    var player_state = PlayerState.init(try std.time.Instant.now());

    const img = try getNextVideoFrame(&dec, audio_player);
    var last_pts = img.pts;
    const stream_id = img.stream_id;
    frame_renderer.swapFrame(img);

    if (audio_player) |p| {
        try p.start();
    }

    while (true) {
        const now = try std.time.Instant.now();

        while (true) {
            const action = c.gui_next_action(gui);
            switch (action) {
                c.gui_action_toggle_pause => {
                    player_state.togglePause(now);
                    c.gui_notify_update(gui);
                },
                c.gui_action_none => {
                    break;
                },
                c.gui_action_close => {
                    return;
                },
                else => {
                    std.debug.panic("invalid action: {d}", .{action});
                },
            }
        }

        while (player_state.shouldUpdateFrame(now, last_pts)) {
            var new_img = try getNextVideoFrame(&dec, audio_player);
            if (stream_id != new_img.stream_id) {
                std.log.warn("Ignoring frame from new video stream", .{});
                new_img.deinit();
                continue;
            }

            last_pts = new_img.pts;
            frame_renderer.swapFrame(new_img);
            c.gui_notify_update(gui);
        }

        app_state.setSnapshot(.{
            .paused = player_state.isPaused(),
            .current_position = last_pts,
            .total_runtime = total_runtime,
        });

        std.time.sleep(10_000_000);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.init(alloc);
    defer args.deinit();

    var frame_renderer_shared = FrameRenderer.SharedData{};

    var frame_renderer = FrameRenderer.init(&frame_renderer_shared);

    var app_state = AppState{
        .mutex = .{},
        .inner = .{
            .paused = false,
            .current_position = 0.0,
            .total_runtime = 0.0,
        },
    };

    const gui = c.gui_init(&app_state);
    defer c.gui_free(gui);

    const main_loop_thread = try std.Thread.spawn(.{}, main_loop, .{
        alloc,
        args,
        &frame_renderer_shared,
        gui,
        &app_state,
    });

    c.gui_run(gui, &frame_renderer);
    main_loop_thread.join();
}
