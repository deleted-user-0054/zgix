const builtin = @import("builtin");
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

        const DrainSelect = union(enum) {
            await_group: Io.Cancelable!void,
            timer: Io.Cancelable!void,
        };

        var select_buffer: [2]DrainSelect = undefined;
        var select = Io.Select(DrainSelect).init(io, &select_buffer);

        select.concurrent(.await_group, Drain.awaitGroup, .{ group, io }) catch {
            // Could not spawn race task; fall back to cancel.
            group.cancel(io);
            return;
        };
        errdefer select.cancelDiscard();

        select.concurrent(.timer, Drain.sleepFor, .{ io, self.options.shutdown_drain_ms }) catch {
            defer select.cancelDiscard();
            return switch (select.await() catch {
                group.cancel(io);
                return;
            }) {
                .await_group => |result| result catch {
                    group.cancel(io);
                    return;
                },
                .timer => unreachable,
            };
        };
        defer select.cancelDiscard();

        switch (select.await() catch {
            group.cancel(io);
            return;
        }) {
            .await_group => |result| {
                result catch {
                    group.cancel(io);
                    return;
                };
            },
            .timer => |result| {
                result catch {};
                group.cancel(io);
            },
        }
    }
};

// Linux/macOS threaded std.Io can enforce a read deadline directly on the
// socket without spawning extra per-connection race tasks. Windows currently
// reports `error.ConcurrencyUnavailable` for timed `net_receive` under
// `Threaded`, so it keeps the outer fallback below.
const use_socket_read_timeout = builtin.os.tag != .windows;

const ServerStreamReader = struct {
    io: Io,
    interface: Io.Reader,
    stream: Io.net.Stream,
    timeout_ms: u64,
    deadline: ?Io.Clock.Timestamp = null,
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    fn init(stream: Io.net.Stream, io: Io, buffer: []u8, timeout_ms: u64) ServerStreamReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
        };
    }

    fn armRequestDeadline(self: *ServerStreamReader) void {
        if (!use_socket_read_timeout or self.timeout_ms == 0) {
            self.deadline = null;
            return;
        }
        self.deadline = Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromMilliseconds(@intCast(self.timeout_ms)),
            .clock = .awake,
        });
    }

    fn deadlineExceeded(self: *const ServerStreamReader) bool {
        if (self.deadline) |deadline| {
            return Io.Clock.Timestamp.compare(
                deadline,
                .lte,
                deadline.clock.now(self.io).withClock(deadline.clock),
            );
        }
        return false;
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *ServerStreamReader = @alignCast(@fieldParentPtr("interface", io_r));
        if (use_socket_read_timeout and r.deadline != null) {
            return readVecTimed(r, io_r, data);
        }
        return readVecUntimed(r, io_r, data);
    }

    fn readVecUntimed(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const n = r.io.vtable.netRead(r.io.userdata, r.stream.socket.handle, dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn readVecTimed(r: *ServerStreamReader, io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const deadline = r.deadline orelse return readVecUntimed(r, io_r, data);

        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const message = r.stream.socket.receiveTimeout(r.io, dest[0], .{ .deadline = deadline }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return readVecUntimed(r, io_r, data),
            else => {
                r.err = err;
                return error.ReadFailed;
            },
        };
        const n = message.data.len;
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

fn handleConn(io: Io, stream: Io.net.Stream, app: *App, options: Options) Io.Cancelable!void {
    if (options.request_timeout_ms == 0 or use_socket_read_timeout) {
        return runConn(io, stream, app, options);
    }

    // Windows fallback: `Threaded` cannot currently apply timed socket reads
    // inline, so race the connection lifetime against the configured budget.
    // This preserves the public timeout knob without adding the extra timer
    // workers on the Linux/macOS benchmark path.
    const Race = struct {
        fn run(inner_io: Io, s: Io.net.Stream, a: *App, opts: Options) Io.Cancelable!void {
            return runConn(inner_io, s, a, opts);
        }
        fn timer(inner_io: Io, ms: u64) Io.Cancelable!void {
            return Io.sleep(inner_io, .fromMilliseconds(@intCast(ms)), .awake);
        }
    };

    const TimeoutSelect = union(enum) {
        conn: Io.Cancelable!void,
        timer: Io.Cancelable!void,
    };

    var select_buffer: [2]TimeoutSelect = undefined;
    var select = Io.Select(TimeoutSelect).init(io, &select_buffer);

    select.concurrent(.conn, Race.run, .{ io, stream, app, options }) catch {
        // Spawn failed: run inline without timeout rather than dropping the
        // connection.
        return runConn(io, stream, app, options);
    };
    errdefer select.cancelDiscard();

    select.concurrent(.timer, Race.timer, .{ io, options.request_timeout_ms }) catch {
        defer select.cancelDiscard();
        return switch (try select.await()) {
            .conn => |result| result,
            .timer => unreachable,
        };
    };
    defer select.cancelDiscard();

    return switch (try select.await()) {
        .conn => |result| result,
        .timer => |result| result,
    };
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

    var reader = ServerStreamReader.init(stream, io, read_buffer, options.request_timeout_ms);
    var writer = Io.net.Stream.Writer.init(stream, io, write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        reader.armRequestDeadline();
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var raw_req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing, error.ReadFailed, error.HttpRequestTruncated => break,
            // Header oversize / malformed → 431/400 if we still can, then close.
            error.HttpHeadersOversize => {
                writeStatusLineAndClose(&writer.interface, .request_header_fields_too_large) catch {};
                break;
            },
            error.HttpHeadersInvalid => {
                writeStatusLineAndClose(&writer.interface, .bad_request) catch {};
                break;
            },
        };

        // --- Expect: 100-continue handling ---
        // RFC 7231 §5.1.1: a server MUST respond with either 100 Continue
        // (so the client sends the body) or a final status (typically 417).
        // We accept only the literal "100-continue" token; anything else
        // gets 417 Expectation Failed and the connection is closed.
        if (raw_req.head.expect) |expect_value| {
            if (std.ascii.eqlIgnoreCase(expect_value, "100-continue")) {
                raw_req.server.out.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch break;
                raw_req.server.out.flush() catch break;
                raw_req.head.expect = null;
            } else {
                // std.http.Server.Request.respond asserts head.expect == null
                // and otherwise refuses to write a final status. Bypass it by
                // emitting a minimal 417 directly on the underlying writer.
                writeStatusLineAndClose(&writer.interface, .expectation_failed) catch {};
                break;
            }
        }

        const target = raw_req.head.target;
        const query_index = std.mem.indexOfScalar(u8, target, '?');
        const path = if (query_index) |index| target[0..index] else target;
        const query_string = if (query_index) |index|
            if (index + 1 < target.len) target[index + 1 ..] else ""
        else
            "";

        // --- Body read with explicit 413 path ---
        // We read the body whenever the request announces one, regardless of
        // framing (Content-Length OR Transfer-Encoding: chunked). Reading
        // chunked-but-ignored bodies is critical: leaving bytes on the wire
        // would desync the next keep-alive request.
        var body: []const u8 = "";
        var body_too_large = false;
        const has_body = raw_req.head.transfer_encoding == .chunked or
            (raw_req.head.content_length orelse 0) > 0;
        if (has_body) {
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
        req.server_io = io;

        if (reader.deadlineExceeded()) break;
        var response = app.handle(req);
        // Always release scopes/runtimes attached during dispatch, even on
        // an early error from `sendResponse`.
        defer response.deinit();
        if (reader.deadlineExceeded()) break;
        const outcome = sendResponse(io, &raw_req, &response, stream_buffer) catch break;
        if (outcome == .upgraded) break;
    }
}

const SendOutcome = enum {
    keep_alive,
    upgraded,
};

/// Writes a minimal HTTP/1.1 status line + Connection: close + empty body.
/// Used when receiveHead fails before we have a Request struct to call
/// .respond on. The caller is expected to break out of the keep-alive loop
/// after this returns.
fn writeStatusLineAndClose(out: *std.Io.Writer, status: std.http.Status) !void {
    const phrase = status.phrase() orelse "Error";
    try out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{
        @intFromEnum(status), phrase,
    });
    try out.flush();
}

fn sendResponse(
    io: Io,
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
            return sendBody(io, raw_req, response, combined_headers, stream_buffer);
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

/// Drives buffered, streaming, SSE, or file bodies. Streaming variants drive a
/// `std.http.BodyWriter` (chunked or content-length) and surface the writer to
/// user code through `response_mod.StreamWriter`/`SseWriter`. `.file` opens
/// the path relative to `cwd`, stats it for `Content-Length`, and pumps
/// file bytes into the body writer without materializing the file in memory.
fn sendBody(
    io: Io,
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
        .file => |runtime| {
            return sendFileBody(io, raw_req, response, combined_headers, stream_buffer, runtime);
        },
    }
}

/// Streams `runtime.path` into the response without buffering it all in
/// memory. Flow:
///   1. open the file at `cwd + runtime.path`
///   2. stat it via `File.Reader.getSize` (sendfile-friendly path in std)
///   3. reject with 500 if the file exceeds `runtime.max_bytes`
///   4. `respondStreaming` with `Content-Length = size` (no chunked encoding)
///   5. pump file bytes into the body writer via `streamRemaining`
///
/// On `HEAD` (`runtime.head_only`), emits identical headers with an empty
/// body and skips the pump. On open/stat failure returns a 500; callers that
/// want fallthrough-if-missing must pre-check existence themselves (see
/// `serve_static.zig`).
fn sendFileBody(
    io: Io,
    raw_req: *std.http.Server.Request,
    response: *const Response,
    combined_headers: []const std.http.Header,
    stream_buffer: []u8,
    runtime: response_mod.FileRuntime,
) !SendOutcome {
    var file = std.Io.Dir.cwd().openFile(io, runtime.path, .{}) catch {
        try raw_req.respond("", .{
            .status = .internal_server_error,
            .extra_headers = combined_headers,
        });
        return .keep_alive;
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);

    const file_size = file_reader.getSize() catch {
        try raw_req.respond("", .{
            .status = .internal_server_error,
            .extra_headers = combined_headers,
        });
        return .keep_alive;
    };

    if (file_size > runtime.max_bytes) {
        try raw_req.respond("", .{
            .status = .internal_server_error,
            .extra_headers = combined_headers,
        });
        return .keep_alive;
    }

    // Derive the actual byte window to serve. For non-range responses,
    // `length` is null and we stream [0, file_size). For 206 Partial
    // Content, the handler has already validated/clamped `offset` and
    // `length` against `file_size`, so we trust them here.
    const content_length: u64 = runtime.length orelse (file_size - runtime.offset);

    if (runtime.head_only) {
        var body_writer = try raw_req.respondStreaming(stream_buffer, .{
            .content_length = content_length,
            .respond_options = .{
                .status = response.status,
                .extra_headers = combined_headers,
            },
        });
        body_writer.end() catch {
            return .upgraded;
        };
        return .keep_alive;
    }

    if (runtime.offset != 0) {
        file_reader.seekTo(runtime.offset) catch {
            try raw_req.respond("", .{
                .status = .internal_server_error,
                .extra_headers = combined_headers,
            });
            return .keep_alive;
        };
    }

    var body_writer = try raw_req.respondStreaming(stream_buffer, .{
        .content_length = content_length,
        .respond_options = .{
            .status = response.status,
            .extra_headers = combined_headers,
        },
    });

    var aborted = false;
    if (runtime.length) |n| {
        file_reader.interface.streamExact64(&body_writer.writer, n) catch {
            aborted = true;
        };
    } else {
        _ = file_reader.interface.streamRemaining(&body_writer.writer) catch {
            aborted = true;
        };
    }
    body_writer.end() catch {
        aborted = true;
    };
    return if (aborted) .upgraded else .keep_alive;
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

// ---------------------------------------------------------------------------
// PR3: HTTP/1.1 protocol correctness
// ---------------------------------------------------------------------------

/// Sends `request_bytes` on a persistent connection and reads the next
/// response (parsed via std.http.Server.Response framing rules: headers up
/// to CRLFCRLF + Content-Length body). Leaves the stream open so callers
/// can pipeline more requests.
const PersistentClient = struct {
    stream: Io.net.Stream,
    io: Io,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    fn connect(io: Io, port: u16) !*PersistentClient {
        const c = try testing.allocator.create(PersistentClient);
        errdefer testing.allocator.destroy(c);
        c.* = .{ .stream = undefined, .io = io };
        var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        addr.setPort(port);
        c.stream = try addr.connect(io, .{ .mode = .stream });
        c.reader = Io.net.Stream.Reader.init(c.stream, io, &c.read_buf);
        c.writer = Io.net.Stream.Writer.init(c.stream, io, &c.write_buf);
        return c;
    }

    fn close(c: *PersistentClient) void {
        c.stream.close(c.io);
        testing.allocator.destroy(c);
    }

    fn send(c: *PersistentClient, bytes: []const u8) !void {
        try c.writer.interface.writeAll(bytes);
        try c.writer.interface.flush();
    }

    /// Reads a complete HTTP response (status line + headers + body sized by
    /// Content-Length or chunked terminator). Returns owned bytes.
    fn recvResponse(c: *PersistentClient) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        const r = &c.reader.interface;

        // Read header block.
        while (std.mem.indexOf(u8, out.items, "\r\n\r\n") == null) {
            const chunk = r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => if (out.items.len > 0)
                    return out.toOwnedSlice(testing.allocator)
                else
                    return error.ResponseTruncated,
                else => return err,
            };
            if (chunk.len == 0) return error.ResponseTruncated;
            try out.appendSlice(testing.allocator, chunk);
            r.toss(chunk.len);
            if (out.items.len > 32 * 1024) return error.ResponseTooLarge;
        }

        const header_end = std.mem.indexOf(u8, out.items, "\r\n\r\n").? + 4;
        const headers_view = out.items[0..header_end];

        // Parse Content-Length.
        var body_remaining: ?usize = null;
        var is_chunked = false;
        var line_iter = std.mem.splitSequence(u8, headers_view, "\r\n");
        _ = line_iter.next(); // status line
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            var value = line[colon + 1 ..];
            value = std.mem.trim(u8, value, " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                body_remaining = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) is_chunked = true;
            }
        }

        const already_body = out.items.len - header_end;

        if (is_chunked) {
            // Read until we see the terminating "0\r\n\r\n".
            while (std.mem.indexOf(u8, out.items[header_end..], "0\r\n\r\n") == null) {
                const chunk = r.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return out.toOwnedSlice(testing.allocator),
                    else => return err,
                };
                if (chunk.len == 0) break;
                try out.appendSlice(testing.allocator, chunk);
                r.toss(chunk.len);
                if (out.items.len > 256 * 1024) return error.ResponseTooLarge;
            }
        } else if (body_remaining) |total| {
            var have = already_body;
            while (have < total) {
                const chunk = r.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return out.toOwnedSlice(testing.allocator),
                    else => return err,
                };
                if (chunk.len == 0) break;
                const want = @min(total - have, chunk.len);
                try out.appendSlice(testing.allocator, chunk[0..want]);
                r.toss(want);
                have += want;
            }
        }

        return out.toOwnedSlice(testing.allocator);
    }
};

fn boot(io: Io, app: *App, opts: Options) !struct {
    server: *Server,
    future: Io.Future(anyerror!void),
} {
    const server = try testing.allocator.create(Server);
    server.* = Server.init(opts);
    var future = try Io.concurrent(io, runServe, .{ server, io, app });
    _ = waitForBind(server, io) catch |err| {
        _ = future.await(io) catch {};
        testing.allocator.destroy(server);
        return err;
    };
    return .{ .server = server, .future = future };
}

fn shutdown(handle: anytype, io: Io) void {
    var f = handle.future;
    stopAndJoin(handle.server, io, &f);
    testing.allocator.destroy(handle.server);
}

test "PR3: client Connection: close closes after one response" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const client = try PersistentClient.connect(io, port);
    defer client.close();

    try client.send(
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    const resp = try client.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: close") != null);
}

test "PR3: HTTP/1.0 closes by default, keeps alive when requested" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);

    // 1.0 default: server should not say "keep-alive".
    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();
        try c.send("GET / HTTP/1.0\r\nHost: x\r\n\r\n");
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: keep-alive") == null);
    }

    // 1.0 with explicit keep-alive: server should NOT close the connection.
    // (std promotes the response to HTTP/1.1 and relies on the absence of a
    // `connection: close` header to signal persistence; it does not echo
    // `connection: keep-alive` back.)
    {
        const c = try PersistentClient.connect(io, port);
        defer c.close();
        try c.send("GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
        const resp = try c.recvResponse();
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: close") == null);
    }
}

test "PR3: chunked request body is read and delivered to handler" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // "Hello, " + "World!" sent as two chunks.
    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "7\r\nHello, \r\n" ++
            "6\r\nWorld!\r\n" ++
            "0\r\n\r\n",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Hello, World!") != null);
}

test "PR3: Expect: 100-continue gets 100 then final response" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Send headers first; expect server to respond with 100 Continue.
    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 5\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const continue_resp = try c.recvResponse();
    defer testing.allocator.free(continue_resp);
    try testing.expect(std.mem.startsWith(u8, continue_resp, "HTTP/1.1 100"));

    // Now send the body; expect 200 with echo.
    try c.send("hello");
    const final_resp = try c.recvResponse();
    defer testing.allocator.free(final_resp);
    try testing.expect(std.mem.indexOf(u8, final_resp, "200") != null);
    try testing.expect(std.mem.indexOf(u8, final_resp, "\r\n\r\nhello") != null);
}

test "PR3: unknown Expect value returns 417" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Content-Length: 5\r\n" ++
            "Expect: i-want-magic\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );

    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "417") != null);
}

test "PR3: handler that ignores body still keeps connection alive" {
    // Verifies std.http.Server.discardBody runs inside respond() and drains
    // the unread body so a second pipelined request frames correctly.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    // POST handler returns "ok" without ever touching c.req.body.
    try app.post("/drop", struct {
        fn h(c: *Context) Response {
            return c.text("ok");
        }
    }.h);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
        // Force the body read path to actually pull bytes off the wire by
        // making the body real (server reads then discards via respond).
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Two pipelined requests on the same connection. The second must succeed.
    try c.send(
        "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
            "POST /drop HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nworld",
    );

    const r1 = try c.recvResponse();
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "200") != null);

    const r2 = try c.recvResponse();
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "200") != null);
}

test "PR3: oversize headers return 431" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/", helloHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .read_buffer_size = 1024, // small head buffer to trigger oversize
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    // Build a request with a single header value larger than the head buffer.
    var big: [4096]u8 = undefined;
    @memset(&big, 'A');
    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(testing.allocator);
    try req_buf.appendSlice(testing.allocator, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: ");
    try req_buf.appendSlice(testing.allocator, &big);
    try req_buf.appendSlice(testing.allocator, "\r\nConnection: close\r\n\r\n");

    try c.send(req_buf.items);
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "431") != null);
}

test "PR3: 405 returned for wrong method on existing route" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/only-get", helloHandler);

    const handle = try boot(io, &app, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 200,
    });
    defer shutdown(handle, io);

    const port = handle.server.bound_port.load(.acquire);
    const c = try PersistentClient.connect(io, port);
    defer c.close();

    try c.send(
        "POST /only-get HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    const resp = try c.recvResponse();
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "405") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(resp, "allow:") != null);
}
