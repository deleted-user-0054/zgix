//! WebSocket test client (RFC 6455 §5).
//!
//! Purpose: spin up a real zono `App` + `Server`, connect from the same
//! process, and roundtrip frames. Used by `zono`'s own tests and by
//! downstream users who want black-box tests of their WS handlers.
//!
//! Scope:
//! - HTTP/1.1 Upgrade handshake (no TLS).
//! - Masked client → server framing (RFC 6455 mandates the mask bit
//!   for client → server frames; we generate a fresh 4-byte mask per
//!   frame using `Io.random`).
//! - Receive path assembles fragments into a single `Message` and
//!   transparently responds to control frames between data frames
//!   (auto-pong on ping; surface close as a `Message`).
//! - No `permessage-deflate` (PMCE). Tracked for a follow-up PR.
//!
//! Memory:
//! - The client owns its socket buffers and a growable receive
//!   accumulator allocated from the user-supplied allocator.
//! - Returned `Message.payload` slices are valid until the next
//!   `receive` / `close`.
//!
//! This module is **not** wired into the runtime path; it only ships
//! for tests. Keep its API surface small and easy to delete if a
//! richer first-party client appears later.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const MessageKind = enum { text, binary, ping, pong, close };

/// Decoded inbound message. `payload` lives in the client's receive
/// buffer and is invalidated by the next `receive` / `close` call.
/// For `close` messages, `close_code` carries the 2-byte status code
/// per RFC 6455 §5.5.1 when present.
pub const Message = struct {
    kind: MessageKind,
    payload: []const u8,
    close_code: ?u16 = null,
};

pub const ConnectOptions = struct {
    /// Optional `Sec-WebSocket-Protocol` header value.
    protocol: ?[]const u8 = null,
    /// Extra headers to include in the upgrade request. Names should be
    /// lowercase. The standard handshake headers (Host, Upgrade,
    /// Connection, Sec-WebSocket-Key, Sec-WebSocket-Version) are added
    /// automatically and must not be supplied here.
    extra_headers: []const std.http.Header = &.{},
    /// Path component of the URL (must start with `/`). Defaults to `/`.
    path: []const u8 = "/",
    /// Host header value. Defaults to "127.0.0.1".
    host: []const u8 = "127.0.0.1",
    /// Read buffer size. Frames larger than this are still readable
    /// because the receive accumulator grows independently; this only
    /// bounds a single socket read.
    read_buf_len: usize = 8 * 1024,
    /// Write buffer size. Bounds the largest frame that can be sent in
    /// a single `flush`. Outgoing frames are written in one shot, so
    /// this also caps `sendText`/`sendBinary` payload size.
    write_buf_len: usize = 64 * 1024,
};

pub const Error = error{
    HandshakeFailed,
    InvalidAcceptKey,
    UnexpectedOpcode,
    UnexpectedMaskBit,
    ConnectionClosed,
    ProtocolError,
    PayloadTooLarge,
    EntropyUnavailable,
} || std.mem.Allocator.Error || std.Io.net.IpAddress.ConnectError || std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error || std.Io.Reader.Error || std.Io.Writer.Error;

/// RFC 6455 §1.3 magic GUID, appended to the client key before SHA-1
/// to compute the server's `Sec-WebSocket-Accept` value.
const HANDSHAKE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const WsClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: std.Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    /// Receive accumulator: holds the concatenated payload of all
    /// fragments belonging to the current message (text/binary). Reset
    /// per `receive` call so payload slices are stable until the next
    /// call.
    rx_accum: std.ArrayListUnmanaged(u8),
    closed: bool = false,
    selected_protocol: ?[]const u8 = null,

    /// Connect to `127.0.0.1:port` and perform the WebSocket handshake.
    /// Returns a heap-allocated client; caller must `close()` it.
    pub fn connect(
        allocator: std.mem.Allocator,
        io: Io,
        port: u16,
        opts: ConnectOptions,
    ) Error!*WsClient {
        var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable;
        addr.setPort(port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        const self = try allocator.create(WsClient);
        errdefer allocator.destroy(self);

        const read_buf = try allocator.alloc(u8, opts.read_buf_len);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, opts.write_buf_len);
        errdefer allocator.free(write_buf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            // Placeholder; replaced below once `self.stream` / buffers
            // have stable heap addresses. The Stream.Reader/Writer
            // vtables use `@fieldParentPtr("interface", ...)` to recover
            // their owning struct, so the interface field's address
            // must never be moved after `init`.
            .reader = undefined,
            .writer = undefined,
            .rx_accum = .empty,
        };
        self.reader = std.Io.net.Stream.Reader.init(self.stream, io, self.read_buf);
        self.writer = std.Io.net.Stream.Writer.init(self.stream, io, self.write_buf);

        try self.performHandshake(opts);
        return self;
    }

    /// Close the underlying socket. The peer-side close frame, if any,
    /// has been (or will be) surfaced by `receive` as a `close`
    /// message; we don't probe for one here.
    pub fn close(self: *WsClient) void {
        if (!self.closed) {
            self.closed = true;
            self.stream.close(self.io);
        }
        self.rx_accum.deinit(self.allocator);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        if (self.selected_protocol) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    pub fn sendText(self: *WsClient, payload: []const u8) Error!void {
        try self.sendFrame(.text, payload, true);
    }

    pub fn sendBinary(self: *WsClient, payload: []const u8) Error!void {
        try self.sendFrame(.binary, payload, true);
    }

    pub fn sendPing(self: *WsClient, payload: []const u8) Error!void {
        if (payload.len > 125) return error.PayloadTooLarge; // RFC 6455 §5.5
        try self.sendFrame(.ping, payload, true);
    }

    pub fn sendPong(self: *WsClient, payload: []const u8) Error!void {
        if (payload.len > 125) return error.PayloadTooLarge;
        try self.sendFrame(.pong, payload, true);
    }

    /// Send a CLOSE frame with the given status code and (optional) UTF-8
    /// reason. Does not close the socket — call `close()` for that.
    pub fn sendCloseFrame(self: *WsClient, code: u16, reason: []const u8) Error!void {
        if (reason.len > 123) return error.PayloadTooLarge; // 125 - 2 byte code
        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        @memcpy(buf[2..][0..reason.len], reason);
        try self.sendFrame(.close, buf[0 .. 2 + reason.len], true);
    }

    /// Block until a complete message arrives. Control frames (ping)
    /// received while waiting for a data message are auto-replied to
    /// with a pong; the next call resumes waiting for the data frame.
    /// A `close` frame is surfaced as a `Message` with `kind = .close`
    /// and the connection should be `close()`d afterward.
    pub fn receive(self: *WsClient) Error!Message {
        self.rx_accum.clearRetainingCapacity();

        // Tracks the kind of the in-progress fragmented message; null
        // when we're waiting for the FIRST frame of a new message.
        var data_kind: ?MessageKind = null;

        while (true) {
            const frame = try self.readFrame();

            // RFC 6455 §5.1: server → client frames MUST NOT be masked.
            if (frame.masked) return error.UnexpectedMaskBit;

            switch (frame.opcode) {
                .ping => {
                    // Auto-pong with the same payload. Don't surface to
                    // the caller — they asked for a data message.
                    try self.sendFrame(.pong, frame.payload, true);
                    continue;
                },
                .pong => {
                    // If the caller is waiting on a data message we
                    // ignore unsolicited pongs. Otherwise (no data in
                    // progress) surface so tests can assert it.
                    if (data_kind == null) {
                        // `frame.payload` already lives in `rx_accum`.
                        return .{ .kind = .pong, .payload = frame.payload };
                    }
                    continue;
                },
                .close => {
                    var code: ?u16 = null;
                    var reason: []const u8 = &.{};
                    if (frame.payload.len >= 2) {
                        code = std.mem.readInt(u16, frame.payload[0..2], .big);
                        reason = frame.payload[2..];
                    } else if (frame.payload.len == 1) {
                        // RFC 6455 §5.5.1: payload is either 0 or >= 2.
                        return error.ProtocolError;
                    }
                    // `reason` already points into `rx_accum` (readFrame
                    // wrote the entire payload there); it stays valid
                    // until the next `receive` call clears the buffer.
                    return .{ .kind = .close, .payload = reason, .close_code = code };
                },
                .text, .binary => {
                    if (data_kind != null) {
                        // RFC 6455 §5.4: a non-continuation data frame
                        // received mid-fragment is a protocol error.
                        return error.ProtocolError;
                    }
                    data_kind = if (frame.opcode == .text) .text else .binary;
                    try self.rx_accum.appendSlice(self.allocator, frame.payload);
                    if (frame.fin) {
                        return .{ .kind = data_kind.?, .payload = self.rx_accum.items };
                    }
                },
                .continuation => {
                    if (data_kind == null) {
                        // Continuation without an active fragment.
                        return error.ProtocolError;
                    }
                    try self.rx_accum.appendSlice(self.allocator, frame.payload);
                    if (frame.fin) {
                        return .{ .kind = data_kind.?, .payload = self.rx_accum.items };
                    }
                },
                _ => return error.UnexpectedOpcode,
            }
        }
    }

    // ---- internals --------------------------------------------------

    /// Build and send the HTTP/1.1 Upgrade request, then validate the
    /// 101 response (status line + Sec-WebSocket-Accept).
    fn performHandshake(self: *WsClient, opts: ConnectOptions) Error!void {
        // Generate a fresh 16-byte client nonce per RFC 6455 §4.1.
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &nonce);

        const w = &self.writer.interface;
        try w.print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n",
            .{ opts.path, opts.host, key },
        );
        if (opts.protocol) |p| {
            try w.print("Sec-WebSocket-Protocol: {s}\r\n", .{p});
        }
        for (opts.extra_headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll("\r\n");
        try w.flush();

        // Read response head. We accept any size up to 16 KiB; if
        // headers don't fit it's a misuse / hostile server.
        const r = &self.reader.interface;
        const max_head = 16 * 1024;
        var scanned: usize = 0;
        const head = while (true) {
            const buf = r.buffered();
            // Search for `\r\n\r\n`, resuming from where the last scan
            // left off (minus 3 bytes to catch boundaries that span
            // fillMore boundaries).
            const search_from = if (scanned >= 3) scanned - 3 else 0;
            if (buf.len > search_from) {
                if (std.mem.indexOf(u8, buf[search_from..], "\r\n\r\n")) |rel| {
                    break buf[0 .. search_from + rel + 4];
                }
            }
            scanned = buf.len;
            if (scanned >= max_head) return error.HandshakeFailed;
            r.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.HandshakeFailed,
                else => return err,
            };
        };
        try self.validateHandshakeResponse(head, key);
        // Consume the headers we just peeked at.
        _ = try r.discardAll(head.len);
    }

    fn validateHandshakeResponse(self: *WsClient, head: []const u8, sent_key: []const u8) Error!void {
        // Status line: HTTP/1.1 101 ...
        const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.HandshakeFailed;
        const status_line = head[0..first_line_end];
        if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }

        var found_upgrade = false;
        var found_connection = false;
        var found_accept = false;
        var iter = std.mem.splitSequence(u8, head[first_line_end + 2 ..], "\r\n");
        while (iter.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                if (!std.ascii.eqlIgnoreCase(value, "websocket")) return error.HandshakeFailed;
                found_upgrade = true;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (!headerHasToken(value, "upgrade")) return error.HandshakeFailed;
                found_connection = true;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                var expected: [28]u8 = undefined;
                computeAccept(sent_key, &expected);
                if (!std.mem.eql(u8, value, &expected)) return error.InvalidAcceptKey;
                found_accept = true;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
                self.selected_protocol = try self.allocator.dupe(u8, value);
            }
        }
        if (!found_upgrade or !found_connection or !found_accept) return error.HandshakeFailed;
    }

    fn sendFrame(self: *WsClient, opcode: Opcode, payload: []const u8, fin: bool) Error!void {
        const w = &self.writer.interface;

        // Header byte 0: FIN | RSV1..3=0 | opcode.
        const b0: u8 = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
        try w.writeByte(b0);

        // Header byte 1: MASK=1 | length code.
        const len = payload.len;
        if (len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(len)));
        } else if (len <= 0xFFFF) {
            try w.writeByte(0x80 | 126);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(len), .big);
            try w.writeAll(&be);
        } else {
            try w.writeByte(0x80 | 127);
            var be: [8]u8 = undefined;
            std.mem.writeInt(u64, &be, len, .big);
            try w.writeAll(&be);
        }

        // 4-byte mask, fresh per frame.
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        try w.writeAll(&mask);

        // Masked payload, written in 256-byte chunks so we don't need
        // a full-payload scratch buffer. The mask repeats every 4 bytes
        // starting at index 0 of the payload.
        var chunk: [256]u8 = undefined;
        var i: usize = 0;
        while (i < len) {
            const remaining = len - i;
            const n = @min(remaining, chunk.len);
            for (0..n) |j| chunk[j] = payload[i + j] ^ mask[(i + j) & 3];
            try w.writeAll(chunk[0..n]);
            i += n;
        }

        try w.flush();
    }

    const Frame = struct {
        fin: bool,
        opcode: Opcode,
        masked: bool,
        payload: []const u8, // borrowed from rx_accum
    };

    fn readFrame(self: *WsClient) Error!Frame {
        const r = &self.reader.interface;

        var hdr2: [2]u8 = undefined;
        try r.readSliceAll(&hdr2);

        const b0 = hdr2[0];
        const b1 = hdr2[1];
        const fin = (b0 & 0x80) != 0;
        const opcode_raw: u4 = @truncate(b0 & 0x0F);
        const opcode: Opcode = @enumFromInt(opcode_raw);
        const masked = (b1 & 0x80) != 0;
        var payload_len: u64 = b1 & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try r.readSliceAll(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try r.readSliceAll(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // We never expect a server → client mask, but consume the 4
        // bytes if present so the stream stays aligned and the caller
        // sees the protocol error via `masked`.
        if (masked) {
            var mask: [4]u8 = undefined;
            try r.readSliceAll(&mask);
        }

        // Stash the payload at the END of rx_accum and return a slice
        // that is valid until the next `receive` (which clears the
        // accumulator). For data frames, `receive` will move/concat the
        // bytes into the accumulator anyway; this temporary copy keeps
        // control-frame payloads alive long enough to act on them.
        const start = self.rx_accum.items.len;
        try self.rx_accum.resize(self.allocator, start + @as(usize, @intCast(payload_len)));
        const slot = self.rx_accum.items[start..];
        try r.readSliceAll(slot);
        return .{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .payload = slot,
        };
    }
};

fn headerHasToken(value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

/// Compute the 28-char base64-encoded SHA-1 of `key ++ HANDSHAKE_GUID`
/// per RFC 6455 §4.1. `out` must be exactly 28 bytes.
fn computeAccept(key: []const u8, out: *[28]u8) void {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(HANDSHAKE_GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

// ============================================================================
// Tests — spin up a real zono server, roundtrip frames.
// ============================================================================

const testing = std.testing;
const App = @import("app.zig").App;
const Server = @import("server.zig").Server;
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;
const Request = @import("request.zig").Request;
const upgradeWebSocket = @import("websocket.zig").upgradeWebSocket;
const WebSocketConnection = @import("response.zig").WebSocketConnection;

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

/// Mirror of `server.zig`'s `stopAndJoin`. Inlined because that helper
/// is file-private and replicating it here keeps this module
/// self-contained for both tests and downstream users.
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

fn echoWsHandler(socket: *WebSocketConnection) !void {
    while (true) {
        const msg = socket.readSmallMessage() catch break;
        switch (msg.opcode) {
            .text => try socket.writeText(msg.data),
            .binary => try socket.writeBinary(msg.data),
            .connection_close => break,
            else => {},
        }
    }
}

test "ws_test_client: handshake + text echo roundtrip" {
    // Windows IOCP + Threaded runtime racing a server task and a client
    // socket in the same process surfaces a spurious LOCAL_DISCONNECT
    // (NTSTATUS=0xc000013b) on the client read of the echo frame.
    // Tracked as a known std bug; the client + server protocol code is
    // verified on POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, echoWsHandler, .{});
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);

    const port = try waitForBind(&server, io);

    const client = try WsClient.connect(testing.allocator, io, port, .{ .path = "/ws" });
    defer client.close();

    try client.sendText("hello");
    const reply = try client.receive();
    try testing.expectEqual(MessageKind.text, reply.kind);
    try testing.expectEqualStrings("hello", reply.payload);
}

test "ws_test_client: binary roundtrip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, echoWsHandler, .{});
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    const client = try WsClient.connect(testing.allocator, io, port, .{ .path = "/ws" });
    defer client.close();

    const blob: [256]u8 = blk: {
        var b: [256]u8 = undefined;
        for (&b, 0..) |*x, i| x.* = @intCast(i & 0xFF);
        break :blk b;
    };
    try client.sendBinary(&blob);
    const reply = try client.receive();
    try testing.expectEqual(MessageKind.binary, reply.kind);
    try testing.expectEqualSlices(u8, &blob, reply.payload);
}

test "ws_test_client: large payload (>64KB triggers 8-byte length)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, echoWsHandler, .{});
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    // 70 KiB > 0xFFFF so the client emits a 64-bit length frame.
    const big = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*x, i| x.* = @intCast(i & 0xFF);

    const client = try WsClient.connect(
        testing.allocator,
        io,
        port,
        .{ .path = "/ws", .write_buf_len = 128 * 1024 },
    );
    defer client.close();

    try client.sendBinary(big);
    const reply = try client.receive();
    try testing.expectEqual(MessageKind.binary, reply.kind);
    try testing.expectEqual(big.len, reply.payload.len);
    try testing.expectEqualSlices(u8, big, reply.payload);
}

test "ws_test_client: server-initiated close surfaces with code and reason" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, struct {
                fn h(socket: *WebSocketConnection) !void {
                    // Send a close frame with code 1001 ("going away")
                    // and a reason string, then return.
                    // Close payload: 2-byte big-endian status code + UTF-8 reason.
                    var payload: [5]u8 = undefined;
                    std.mem.writeInt(u16, payload[0..2], 1001, .big);
                    @memcpy(payload[2..5], "bye");
                    try socket.close(&payload);
                }
            }.h, .{});
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    const client = try WsClient.connect(testing.allocator, io, port, .{ .path = "/ws" });
    defer client.close();

    const reply = try client.receive();
    try testing.expectEqual(MessageKind.close, reply.kind);
    try testing.expectEqual(@as(?u16, 1001), reply.close_code);
    try testing.expectEqualStrings("bye", reply.payload);
}

test "ws_test_client: client ping is auto-ponged by server, pong surfaces" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, echoWsHandler, .{});
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    const client = try WsClient.connect(testing.allocator, io, port, .{ .path = "/ws" });
    defer client.close();

    try client.sendPing("ping-data");
    const reply = try client.receive();
    try testing.expectEqual(MessageKind.pong, reply.kind);
    try testing.expectEqualStrings("ping-data", reply.payload);
}

test "ws_test_client: handshake fails on non-101 response" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    // No /ws route → 404 to upgrade attempt.
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    try testing.expectError(
        error.HandshakeFailed,
        WsClient.connect(testing.allocator, io, port, .{ .path = "/ws" }),
    );
}

test "ws_test_client: subprotocol echoed back" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return upgradeWebSocket(c.req, echoWsHandler, .{ .protocol = "chat" });
        }
    }.run);

    var server = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });
    var serve_future = try Io.concurrent(io, runServe, .{ &server, io, &app });
    defer stopAndJoin(&server, io, &serve_future);
    const port = try waitForBind(&server, io);

    const client = try WsClient.connect(
        testing.allocator,
        io,
        port,
        .{ .path = "/ws", .protocol = "chat" },
    );
    defer client.close();

    try testing.expect(client.selected_protocol != null);
    try testing.expectEqualStrings("chat", client.selected_protocol.?);
}

test "computeAccept matches the RFC 6455 §1.3 example" {
    // RFC 6455 §1.3 worked example.
    var out: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
