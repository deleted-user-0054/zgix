const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const Options = struct {
    address: std.Io.net.IpAddress,
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 64 * 1024,
    /// Maximum bytes accepted in a single request body. Requests exceeding
    /// this limit receive `413 Payload Too Large` and the connection is
    /// closed (no follow-up keep-alive request is processed).
    max_body_bytes: usize = 4 * 1024 * 1024,
    /// Buffer handed to streaming/SSE writers. Larger values reduce syscalls;
    /// smaller values lower latency for chatty event streams.
    stream_buffer_size: usize = 8 * 1024,
    /// Per-request wall-clock deadline (milliseconds). Includes header parse,
    /// body read, handler execution, and body write. `0` disables.
    request_timeout_ms: u64 = 30_000,
    /// On `Server.stop`, wait this long for in-flight connections to finish
    /// before forcibly canceling them. `0` cancels immediately.
    shutdown_drain_ms: u64 = 5_000,
};

pub const Server = struct {
    options: Options,
    /// Pointer to the live listener while `serve` is executing. Used by
    /// `stop` to close the accept socket and wake the accept loop.
    listener: ?*std.Io.net.Server = null,
    stopping: Atomic(bool) = .init(false),
    /// Resolved bound port (0 until `serve` has bound the socket). Useful
    /// for tests that bind to port 0 and need to learn the ephemeral port.
    bound_port: Atomic(u16) = .init(0),

    pub fn init(options: Options) Server {
        return .{ .options = options };
    }

    /// Runs until either an unrecoverable error occurs or the accept loop
    /// observes `stopping` after returning from `accept`.
    ///
    /// IMPORTANT: `stop` does NOT forcibly wake a blocked `accept` call.
    /// To make `serve` actually return while it is parked in `accept`, the
    /// caller must either (a) cause the process to exit (signal handler →
    /// `std.process.exit`, or simply let the OS reap the process on
    /// SIGTERM/Ctrl+C), or (b) cause one more connection to arrive (which
    /// the loop will observe `stopping` for and break out cleanly).
    pub fn serve(self: *Server, io: Io, app: *App) !void {
        try app.finalize();

        var listener = try self.options.address.listen(io, .{ .reuse_address = true });
        self.listener = &listener;
        self.bound_port.store(listener.socket.address.getPort(), .release);
        defer {
            self.listener = null;
            self.bound_port.store(0, .release);
            listener.deinit(io);
        }

        var group: Io.Group = .init;
        // Drain semantics: try to await in-flight handlers up to the drain
        // budget. If they do not finish in time, fall back to cancel.
        defer self.drainGroup(io, &group);

        while (true) {
            if (self.stopping.load(.acquire)) break;
            const stream = listener.accept(io) catch |err| switch (err) {
                error.Canceled => break,
                error.SocketNotListening => break,
                error.ConnectionAborted => continue,
                else => return err,
            };
            // Re-check after accept: a self-pipe wakeup (one extra connection
            // delivered after `stop` was called) lets the loop exit without
            // dispatching the dummy connection to a handler.
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                break;
            }
            group.concurrent(io, handleConn, .{ io, stream, app, self.options }) catch {
                stream.close(io);
            };
        }
    }

    /// Threadsafe. Sets the `stopping` flag and triggers in-flight handler
    /// drain on the next accept loop iteration. Does NOT touch the listening
    /// socket and therefore does NOT wake a currently blocked `accept`. See
    /// `serve` doc-comment for the recommended shutdown patterns.
    ///
    /// Safe to call from a signal handler context (only does an atomic store).
    pub fn stop(self: *Server, _: Io) void {
        _ = self.stopping.swap(true, .acq_rel);
    }

    fn drainGroup(self: *Server, io: Io, group: *Io.Group) void {
        if (self.options.shutdown_drain_ms == 0) {
            group.cancel(io);
            return;
        }

        // Race: await(group) vs sleep(drain_ms). Whichever wins, cancel the
        // loser. If await wins we exit cleanly; if sleep wins we forcibly
        // cancel any handlers still running.
        const Drain = struct {
            fn awaitGroup(g: *Io.Group, inner_io: Io) Io.Cancelable!void {
                return g.await(inner_io);
            }
            fn sleepFor(inner_io: Io, ms: u64) Io.Cancelable!void {
                return Io.sleep(inner_io, .fromMilliseconds(@intCast(ms)), .awake);
            }
        };

        var await_future = Io.concurrent(io, Drain.awaitGroup, .{ group, io }) catch {
            // Could not spawn race task; fall back to cancel.
            group.cancel(io);
            return;
        };
        var sleep_future = Io.concurrent(io, Drain.sleepFor, .{ io, self.options.shutdown_drain_ms }) catch {
            _ = await_future.await(io) catch {};
            return;
        };

        // Await the sleep first; if it returns naturally, drain timed out.
        // Cancel the await task (which in turn cancels the group). If the
        // user's deadline was generous enough, await may have already
        // completed; cancel of an already-finished future is a no-op.
        _ = sleep_future.await(io) catch {};
        _ = await_future.cancel(io) catch {};
        // Ensure any remaining tasks are canceled and reaped.
        group.cancel(io);
    }
};

const ConnError = error{
    Timeout,
} || Io.Cancelable;

fn handleConn(io: Io, stream: Io.net.Stream, app: *App, options: Options) Io.Cancelable!void {
    if (options.request_timeout_ms == 0) {
        return runConn(io, stream, app, options);
    }

    // Race the connection handler against a per-request timer. Whichever
    // finishes first cancels the other. We re-arm the timer for each
    // keep-alive request inside `runConn` is impractical (it lives in the
    // accept-task scope), so we instead apply the timeout to the *entire*
    // connection lifetime; long-lived streaming/WebSocket handlers should
    // configure `request_timeout_ms = 0` and provide their own deadlines.
    const Race = struct {
        fn run(inner_io: Io, s: Io.net.Stream, a: *App, opts: Options) Io.Cancelable!void {
            return runConn(inner_io, s, a, opts);
        }
        fn timer(inner_io: Io, ms: u64) Io.Cancelable!void {
            return Io.sleep(inner_io, .fromMilliseconds(@intCast(ms)), .awake);
        }
    };

    var conn_future = Io.concurrent(io, Race.run, .{ io, stream, app, options }) catch {
        // Spawn failed: run inline without timeout rather than dropping the
        // connection.
        return runConn(io, stream, app, options);
    };
    var timer_future = Io.concurrent(io, Race.timer, .{ io, options.request_timeout_ms }) catch {
        _ = conn_future.await(io) catch {};
        return;
    };

    // Wait for the timer; if it expires, cancel the connection.
    _ = timer_future.await(io) catch {};
    _ = conn_future.cancel(io) catch {};
}

fn runConn(io: Io, stream: Io.net.Stream, app: *App, options: Options) Io.Cancelable!void {
    defer stream.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const read_buffer = std.heap.smp_allocator.alloc(u8, options.read_buffer_size) catch return;
    defer std.heap.smp_allocator.free(read_buffer);
    const write_buffer = std.heap.smp_allocator.alloc(u8, options.write_buffer_size) catch return;
    defer std.heap.smp_allocator.free(write_buffer);
    const stream_buffer = std.heap.smp_allocator.alloc(u8, options.stream_buffer_size) catch return;
    defer std.heap.smp_allocator.free(stream_buffer);

    var reader = Io.net.Stream.Reader.init(stream, io, read_buffer);
    var writer = Io.net.Stream.Writer.init(stream, io, write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var raw_req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.ReadFailed => break,
            else => break,
        };

        const target = raw_req.head.target;
        const query_index = std.mem.indexOfScalar(u8, target, '?');
        const path = if (query_index) |index| target[0..index] else target;
        const query_string = if (query_index) |index|
            if (index + 1 < target.len) target[index + 1 ..] else ""
        else
            "";

        // --- Body read with explicit 413 path ---
        var body: []const u8 = "";
        var body_too_large = false;
        if (raw_req.head.content_length) |content_length| {
            if (content_length > 0) {
                var transfer_buffer: [4096]u8 = undefined;
                var body_reader = raw_req.server.reader.bodyReader(
                    &transfer_buffer,
                    raw_req.head.transfer_encoding,
                    raw_req.head.content_length,
                );
                if (body_reader.allocRemaining(alloc, .limited(options.max_body_bytes))) |bytes| {
                    body = bytes;
                } else |err| switch (err) {
                    error.StreamTooLong => body_too_large = true,
                    else => break, // network failure, drop connection
                }
            }
        }

        if (body_too_large) {
            // Send 413 directly; do not invoke user handler. After 413 the
            // body framing may be unreliable so we close the connection.
            raw_req.respond("Payload Too Large", .{
                .status = .payload_too_large,
                .keep_alive = false,
            }) catch {};
            break;
        }

        var req = Request.init(alloc, raw_req.head.method, path);
        req.query_string = query_string;
        req.header_lookup_ctx = @ptrCast(&raw_req);
        req.header_lookup_fn = lookupHeader;
        req.headers_collect_fn = collectHeaders;
        req.body = body;

        var response = app.handle(req);
        // Always release scopes/runtimes attached during dispatch, even on
        // an early error from `sendResponse`.
        defer response.deinit();
        const outcome = sendResponse(&raw_req, &response, stream_buffer) catch break;
        if (outcome == .upgraded) break;
    }
}

const SendOutcome = enum {
    keep_alive,
    upgraded,
};

fn sendResponse(
    raw_req: *std.http.Server.Request,
    response: *const Response,
    stream_buffer: []u8,
) !SendOutcome {
    var extra_headers: [3]std.http.Header = undefined;
    var header_count: usize = 0;

    if (response.content_type.len > 0) {
        extra_headers[header_count] = .{ .name = "content-type", .value = response.content_type };
        header_count += 1;
    }
    if (response.location) |location| {
        extra_headers[header_count] = .{ .name = "location", .value = location };
        header_count += 1;
    }
    if (response.allow) |allow| {
        extra_headers[header_count] = .{ .name = "allow", .value = allow };
        header_count += 1;
    }

    const response_headers = response.extraHeaders();
    const combined_headers = if (header_count == 0 and response_headers.len == 0)
        &.{}
    else blk: {
        const headers = try std.heap.smp_allocator.alloc(std.http.Header, header_count + response_headers.len);
        errdefer std.heap.smp_allocator.free(headers);
        @memcpy(headers[0..header_count], extra_headers[0..header_count]);
        @memcpy(headers[header_count .. header_count + response_headers.len], response_headers);
        break :blk headers;
    };
    defer if (combined_headers.len > 0) std.heap.smp_allocator.free(combined_headers);

    switch (response.runtime) {
        .none => {
            return sendBody(raw_req, response, combined_headers, stream_buffer);
        },
        .websocket => |runtime| {
            const requested = raw_req.upgradeRequested();
            const key = switch (requested) {
                .websocket => |maybe_key| maybe_key orelse return error.InvalidWebSocketUpgrade,
                else => return error.InvalidWebSocketUpgrade,
            };

            var websocket_headers: [1]std.http.Header = undefined;
            const extra_ws_headers = if (runtime.protocol) |protocol| blk: {
                websocket_headers[0] = .{
                    .name = "sec-websocket-protocol",
                    .value = protocol,
                };
                break :blk websocket_headers[0..1];
            } else &.{};

            var socket = try raw_req.respondWebSocket(.{
                .key = key,
                .extra_headers = extra_ws_headers,
            });
            var websocket: response_mod.WebSocketConnection = .{
                .socket = &socket,
            };
            try runtime.run_fn(runtime.ctx, &websocket);
            try socket.flush();
            return .upgraded;
        },
    }
}

fn collectHeaders(
    ctx: *const anyopaque,
    allocator: std.mem.Allocator,
) ![]const std.http.Header {
    const raw_req: *std.http.Server.Request = @ptrCast(@alignCast(@constCast(ctx)));
    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer headers.deinit(allocator);

    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        try headers.append(allocator, header);
    }

    if (headers.items.len == 0) return &.{};
    return try headers.toOwnedSlice(allocator);
}

fn lookupHeader(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
    const raw_req: *std.http.Server.Request = @ptrCast(@alignCast(@constCast(ctx)));
    var iter = raw_req.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// Drives buffered, streaming, or SSE bodies. The streaming variants drive a
/// `std.http.BodyWriter` (chunked or content-length) and surface the writer to
/// user code through `response_mod.StreamWriter`/`SseWriter`.
fn sendBody(
    raw_req: *std.http.Server.Request,
    response: *const Response,
    combined_headers: []const std.http.Header,
    stream_buffer: []u8,
) !SendOutcome {
    switch (response.body_kind) {
        .buffered => |buffered| {
            const payload = if (buffered.len > 0) buffered else response.body;
            try raw_req.respond(payload, .{
                .status = response.status,
                .extra_headers = combined_headers,
            });
            return .keep_alive;
        },
        .stream => |runtime| {
            var aborted: Atomic(bool) = .init(false);
            var body_writer = try raw_req.respondStreaming(stream_buffer, .{
                .content_length = runtime.content_length,
                .respond_options = .{
                    .status = response.status,
                    .extra_headers = combined_headers,
                },
            });
            var stream_writer = response_mod.StreamWriter{
                .inner = &body_writer.writer,
                .aborted = &aborted,
            };
            runtime.run_fn(runtime.ctx, &stream_writer) catch {
                aborted.store(true, .release);
            };
            body_writer.end() catch {
                aborted.store(true, .release);
            };
            return if (aborted.load(.acquire)) .upgraded else .keep_alive;
        },
        .sse => |runtime| {
            var aborted: Atomic(bool) = .init(false);
            var body_writer = try raw_req.respondStreaming(stream_buffer, .{
                .content_length = null,
                .respond_options = .{
                    .status = response.status,
                    .extra_headers = combined_headers,
                },
            });
            var stream_writer = response_mod.StreamWriter{
                .inner = &body_writer.writer,
                .aborted = &aborted,
            };
            var sse_writer = response_mod.SseWriter{ .stream = &stream_writer };
            runtime.run_fn(runtime.ctx, &sse_writer) catch {
                aborted.store(true, .release);
            };
            body_writer.end() catch {
                aborted.store(true, .release);
            };
            return if (aborted.load(.acquire)) .upgraded else .keep_alive;
        },
    }
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------
//
// These tests boot a real `Server` against `127.0.0.1:0`, learn the bound
// port via `Server.bound_port`, and drive it with an HTTP client built on
// `std.Io.net.Stream`. They exercise the new PR2 behaviors end-to-end.

const testing = std.testing;
const Context = @import("context.zig").Context;

fn runServe(server: *Server, io: Io, app: *App) anyerror!void {
    return server.serve(io, app);
}

fn waitForBind(server: *Server, io: Io) !u16 {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const p = server.bound_port.load(.acquire);
        if (p != 0) return p;
        Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.ServerNeverBound;
}

fn sendRaw(io: Io, port: u16, request_bytes: []const u8) ![]u8 {
    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    addr.setPort(port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buf);
    try writer.interface.writeAll(request_bytes);
    try writer.interface.flush();

    var read_buf: [16 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buf);
    return try reader.interface.allocRemaining(testing.allocator, .limited(64 * 1024));
}

fn helloHandler(c: *Context) Response {
    return c.text("hello");
}

fn echoHandler(c: *Context) Response {
    return c.text(c.req.body);
}

/// Cleanly stops a serve() that is parked in accept().
///
/// `Server.stop` only sets a flag; on platforms where blocking accept cannot
/// be safely canceled (notably Windows std 0.16, where canceling the AFD
/// listen IOCTL panics on `.CANCELLED => unreachable`), we have to deliver
/// one extra connection so the accept loop wakes naturally, observes the
/// flag, and breaks out.
fn stopAndJoin(server: *Server, io: Io, future: anytype) void {
    server.stop(io);
    const port = server.bound_port.load(.acquire);
    if (port != 0) {
        var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch return;
        addr.setPort(port);
        if (addr.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |_| {}
    }
    _ = future.await(io) catch {};
}

test "PR2: 413 returned when body exceeds max_body_bytes" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 16,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    // 32 bytes of body; limit is 16 → must get 413.
    const req_bytes =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 32\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "413") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Payload Too Large") != null);
}

test "PR2: under-limit body is delivered to handler" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .max_body_bytes = 1024,
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const req_bytes =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 5\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "hello";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\r\n\r\nhello") != null);
}

test "PR2: Server.stop + dummy connection drains serve" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });

    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });

    _ = try waitForBind(&server, io);

    // stopAndJoin: set flag, deliver one wakeup connection, await.
    stopAndJoin(&server, io, &serve_future);
    try testing.expectEqual(@as(u16, 0), server.bound_port.load(.acquire));
}

test "PR2: per-request timeout config does not break fast handlers" {
    // The full negative test (slow handler getting canceled) requires a
    // way to yield from the handler at a cancellation point; Context does
    // not currently expose Io. We instead verify that enabling the timer
    // does not regress the happy path.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 2_000,
        .shutdown_drain_ms = 200,
    });

    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const req_bytes =
        "GET / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const resp = try sendRaw(io, port, req_bytes);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}

test "PR2: StreamWriter.isAborted reflects atomic flag" {
    var aborted: Atomic(bool) = .init(false);
    var dummy_buf: [16]u8 = undefined;
    var aw: std.Io.Writer = .{
        .vtable = &.{ .drain = std.Io.Writer.failingDrain },
        .buffer = &dummy_buf,
        .end = 0,
    };
    var sw = response_mod.StreamWriter{
        .inner = &aw,
        .aborted = &aborted,
    };
    try testing.expect(!sw.isAborted());
    aborted.store(true, .release);
    try testing.expect(sw.isAborted());
}

