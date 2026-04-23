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

const WinSockSocket = usize;
const invalid_winsock_socket = std.math.maxInt(WinSockSocket);

const wsa_get_last_error = @extern(
    *const fn () callconv(.winapi) c_int,
    .{ .name = "WSAGetLastError", .library_name = "ws2_32" },
);
const wsa_startup = @extern(
    *const fn (version_requested: u16, data: *WindowsWsaData) callconv(.winapi) c_int,
    .{ .name = "WSAStartup", .library_name = "ws2_32" },
);
const winsock_socket = @extern(
    *const fn (af: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) WinSockSocket,
    .{ .name = "socket", .library_name = "ws2_32" },
);
const winsock_connect = @extern(
    *const fn (socket: WinSockSocket, name: *const std.os.windows.ws2_32.sockaddr, namelen: c_int) callconv(.winapi) c_int,
    .{ .name = "connect", .library_name = "ws2_32" },
);
const winsock_bind = @extern(
    *const fn (socket: WinSockSocket, name: *const std.os.windows.ws2_32.sockaddr, namelen: c_int) callconv(.winapi) c_int,
    .{ .name = "bind", .library_name = "ws2_32" },
);
const winsock_listen = @extern(
    *const fn (socket: WinSockSocket, backlog: c_int) callconv(.winapi) c_int,
    .{ .name = "listen", .library_name = "ws2_32" },
);
const winsock_accept = @extern(
    *const fn (socket: WinSockSocket, addr: ?*std.os.windows.ws2_32.sockaddr, addrlen: ?*c_int) callconv(.winapi) WinSockSocket,
    .{ .name = "accept", .library_name = "ws2_32" },
);
const winsock_getsockname = @extern(
    *const fn (socket: WinSockSocket, name: *std.os.windows.ws2_32.sockaddr, namelen: *c_int) callconv(.winapi) c_int,
    .{ .name = "getsockname", .library_name = "ws2_32" },
);
const winsock_send = @extern(
    *const fn (socket: WinSockSocket, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int,
    .{ .name = "send", .library_name = "ws2_32" },
);
const winsock_recv = @extern(
    *const fn (socket: WinSockSocket, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int,
    .{ .name = "recv", .library_name = "ws2_32" },
);
const winsock_close = @extern(
    *const fn (socket: WinSockSocket) callconv(.winapi) c_int,
    .{ .name = "closesocket", .library_name = "ws2_32" },
);
const winsock_version_2_2 = 0x0202;

const WindowsWsaData = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*:0]u8,
};

var winsock_initialized: std.atomic.Value(bool) = .init(false);

fn winsockLoopbackAddress(port: u16) std.os.windows.ws2_32.sockaddr.in {
    const loopback = [4]u8{ 127, 0, 0, 1 };
    return .{
        .family = std.os.windows.ws2_32.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.readInt(u32, &loopback, .little),
    };
}

fn winsockWriteAll(socket_handle: WinSockSocket, bytes: []const u8) error{ConnectionClosed}!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const chunk_len = @min(bytes.len - sent, std.math.maxInt(c_int));
        const rc = winsock_send(
            socket_handle,
            bytes[sent..].ptr,
            @as(c_int, @intCast(chunk_len)),
            0,
        );
        if (rc == 0 or rc == -1) return error.ConnectionClosed;
        sent += @as(usize, @intCast(rc));
    }
}

fn winsockRecv(socket_handle: WinSockSocket, dest: []u8) error{ConnectionClosed}!usize {
    const rc = winsock_recv(
        socket_handle,
        dest.ptr,
        @as(c_int, @intCast(@min(dest.len, std.math.maxInt(c_int)))),
        0,
    );
    if (rc == 0 or rc == -1) return error.ConnectionClosed;
    return @as(usize, @intCast(rc));
}

fn winsockReadExact(socket_handle: WinSockSocket, dest: []u8) error{ConnectionClosed}!void {
    var filled: usize = 0;
    while (filled < dest.len) {
        filled += try winsockRecv(socket_handle, dest[filled..]);
    }
}

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
    WindowsSocketInitFailed,
} || std.mem.Allocator.Error || std.Io.net.IpAddress.ConnectError || std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error || std.Io.Reader.Error || std.Io.Writer.Error;

/// RFC 6455 §1.3 magic GUID, appended to the client key before SHA-1
/// to compute the server's `Sec-WebSocket-Accept` value.
const HANDSHAKE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const WsClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: std.Io.net.Stream,
    raw_socket: ?WinSockSocket = null,
    read_buf: []u8,
    write_buf: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    raw_read_start: usize = 0,
    raw_read_end: usize = 0,
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
        const self = try allocator.create(WsClient);
        errdefer allocator.destroy(self);

        const read_buf = try allocator.alloc(u8, opts.read_buf_len);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, opts.write_buf_len);
        errdefer allocator.free(write_buf);

        if (builtin.os.tag == .windows) {
            try ensureWindowsSocketApi();
            const raw_socket = try connectWindowsSocket(port);
            errdefer _ = winsock_close(raw_socket);

            self.* = .{
                .allocator = allocator,
                .io = io,
                .stream = undefined,
                .raw_socket = raw_socket,
                .read_buf = read_buf,
                .write_buf = write_buf,
                .reader = undefined,
                .writer = undefined,
                .rx_accum = .empty,
            };
        } else {
            var addr = std.Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable;
            addr.setPort(port);
            const stream = try addr.connect(io, .{ .mode = .stream });
            errdefer stream.close(io);

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
        }

        try self.performHandshake(opts);
        return self;
    }

    fn ensureWindowsSocketApi() Error!void {
        if (builtin.os.tag != .windows) return;
        if (winsock_initialized.load(.acquire)) return;

        var data: WindowsWsaData = undefined;
        if (wsa_startup(winsock_version_2_2, &data) != 0) {
            return error.WindowsSocketInitFailed;
        }
        winsock_initialized.store(true, .release);
    }

    fn connectWindowsSocket(port: u16) std.Io.net.IpAddress.ConnectError!WinSockSocket {
        const socket_handle = winsock_socket(
            std.os.windows.ws2_32.AF.INET,
            std.os.windows.ws2_32.SOCK.STREAM,
            std.os.windows.ws2_32.IPPROTO.TCP,
        );
        if (socket_handle == invalid_winsock_socket) {
            return mapWindowsConnectError(wsa_get_last_error());
        }
        errdefer _ = winsock_close(socket_handle);

        var addr = winsockLoopbackAddress(port);
        if (winsock_connect(
            socket_handle,
            @ptrCast(&addr),
            @as(c_int, @intCast(@sizeOf(@TypeOf(addr)))),
        ) == -1) {
            return mapWindowsConnectError(wsa_get_last_error());
        }

        return socket_handle;
    }

    fn mapWindowsConnectError(code: c_int) std.Io.net.IpAddress.ConnectError {
        return switch (code) {
            10013 => error.AccessDenied,
            10049 => error.AddressUnavailable,
            10047 => error.AddressFamilyUnsupported,
            10050 => error.NetworkDown,
            10051 => error.NetworkUnreachable,
            10055 => error.SystemResources,
            10060 => error.Timeout,
            10061 => error.ConnectionRefused,
            10065 => error.HostUnreachable,
            else => error.ConnectionRefused,
        };
    }

    fn writeAllSocketWindows(self: *WsClient, bytes: []const u8) Error!void {
        const socket_handle = self.raw_socket orelse unreachable;
        try winsockWriteAll(socket_handle, bytes);
    }

    fn recvSocketWindows(self: *WsClient, dest: []u8) Error!usize {
        const socket_handle = self.raw_socket orelse unreachable;
        return try winsockRecv(socket_handle, dest);
    }

    /// Close the underlying socket. The peer-side close frame, if any,
    /// has been (or will be) surfaced by `receive` as a `close`
    /// message; we don't probe for one here.
    pub fn close(self: *WsClient) void {
        if (!self.closed) {
            self.closed = true;
            if (self.raw_socket) |socket_handle| {
                _ = winsock_close(socket_handle);
            } else {
                self.stream.close(self.io);
            }
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
                    if (frame.fin) {
                        return .{ .kind = data_kind.?, .payload = self.rx_accum.items };
                    }
                },
                .continuation => {
                    if (data_kind == null) {
                        // Continuation without an active fragment.
                        return error.ProtocolError;
                    }
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

        if (self.raw_socket != null) {
            var request_bytes: std.Io.Writer.Allocating = .init(self.allocator);
            defer request_bytes.deinit();

            try request_bytes.writer.print(
                "GET {s} HTTP/1.1\r\n" ++
                    "Host: {s}\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Key: {s}\r\n" ++
                    "Sec-WebSocket-Version: 13\r\n",
                .{ opts.path, opts.host, key },
            );
            if (opts.protocol) |p| {
                try request_bytes.writer.print("Sec-WebSocket-Protocol: {s}\r\n", .{p});
            }
            for (opts.extra_headers) |h| {
                try request_bytes.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
            }
            try request_bytes.writer.writeAll("\r\n");

            const request = try request_bytes.toOwnedSlice();
            defer self.allocator.free(request);
            try self.writeAllSocketWindows(request);

            const max_head = @min(self.read_buf.len, 16 * 1024);
            var head_len: usize = 0;
            while (true) {
                if (std.mem.indexOf(u8, self.read_buf[0..head_len], "\r\n\r\n")) |idx| {
                    const head_end = idx + 4;
                    try self.validateHandshakeResponse(self.read_buf[0..head_end], key);
                    self.raw_read_start = head_end;
                    self.raw_read_end = head_len;
                    return;
                }
                if (head_len >= max_head) return error.HandshakeFailed;
                head_len += try self.recvSocketWindows(self.read_buf[head_len..max_head]);
            }
        }

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
        if (self.raw_socket != null) {
            // Header byte 0: FIN | RSV1..3=0 | opcode.
            const b0: u8 = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
            try self.writeAllSocketWindows(&[_]u8{b0});

            // Header byte 1: MASK=1 | length code.
            const len = payload.len;
            if (len < 126) {
                try self.writeAllSocketWindows(&[_]u8{0x80 | @as(u8, @intCast(len))});
            } else if (len <= 0xFFFF) {
                var hdr: [3]u8 = undefined;
                hdr[0] = 0x80 | 126;
                std.mem.writeInt(u16, hdr[1..3], @intCast(len), .big);
                try self.writeAllSocketWindows(&hdr);
            } else {
                var hdr: [9]u8 = undefined;
                hdr[0] = 0x80 | 127;
                std.mem.writeInt(u64, hdr[1..9], len, .big);
                try self.writeAllSocketWindows(&hdr);
            }

            var mask: [4]u8 = undefined;
            self.io.random(&mask);
            try self.writeAllSocketWindows(&mask);

            var chunk: [256]u8 = undefined;
            var i: usize = 0;
            while (i < len) {
                const remaining = len - i;
                const n = @min(remaining, chunk.len);
                for (0..n) |j| chunk[j] = payload[i + j] ^ mask[(i + j) & 3];
                try self.writeAllSocketWindows(chunk[0..n]);
                i += n;
            }
            return;
        }

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

    fn readExact(self: *WsClient, dest: []u8) Error!void {
        if (self.raw_socket == null) {
            const r = &self.reader.interface;
            try r.readSliceAll(dest);
            return;
        }

        var filled: usize = 0;
        while (filled < dest.len) {
            const buffered = self.read_buf[self.raw_read_start..self.raw_read_end];
            if (buffered.len > 0) {
                const n = @min(buffered.len, dest.len - filled);
                @memcpy(dest[filled..][0..n], buffered[0..n]);
                self.raw_read_start += n;
                filled += n;
                continue;
            }
            filled += try self.recvSocketWindows(dest[filled..]);
        }
    }

    fn readFrame(self: *WsClient) Error!Frame {
        var hdr2: [2]u8 = undefined;
        try self.readExact(&hdr2);

        const b0 = hdr2[0];
        const b1 = hdr2[1];
        const fin = (b0 & 0x80) != 0;
        const opcode_raw: u4 = @truncate(b0 & 0x0F);
        const opcode: Opcode = @enumFromInt(opcode_raw);
        const masked = (b1 & 0x80) != 0;
        var payload_len: u64 = b1 & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // We never expect a server → client mask, but consume the 4
        // bytes if present so the stream stays aligned and the caller
        // sees the protocol error via `masked`.
        if (masked) {
            var mask: [4]u8 = undefined;
            try self.readExact(&mask);
        }

        // Stash the payload at the END of rx_accum and return a slice
        // that is valid until the next `receive` (which clears the
        // accumulator). For data frames, `receive` will move/concat the
        // bytes into the accumulator anyway; this temporary copy keeps
        // control-frame payloads alive long enough to act on them.
        const start = self.rx_accum.items.len;
        try self.rx_accum.resize(self.allocator, start + @as(usize, @intCast(payload_len)));
        const slot = self.rx_accum.items[start..];
        try self.readExact(slot);
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

fn echoWsRoute(c: *Context) Response {
    return upgradeWebSocket(c.req, echoWsHandler, .{});
}

const WindowsRawEchoFrame = struct {
    opcode: Opcode,
    payload: []u8,
};

const WindowsRawServerHandle = struct {
    port: u16,
    future: Io.Future(anyerror!void),

    fn deinit(self: *WindowsRawServerHandle, io: Io) void {
        if (WsClient.connectWindowsSocket(self.port)) |dummy_socket| {
            _ = winsock_close(dummy_socket);
        } else |_| {}
        var future = self.future;
        _ = future.await(io) catch {};
    }
};

const EchoServerHandle = struct {
    port: u16,
    backend: union(enum) {
        in_process: struct {
            app: *App,
            server: *Server,
            future: Io.Future(anyerror!void),
        },
        raw_windows: WindowsRawServerHandle,
    },

    fn deinit(self: *EchoServerHandle, io: Io) void {
        switch (self.backend) {
            .in_process => |*in_process| {
                var future = in_process.future;
                stopAndJoin(in_process.server, io, &future);
                in_process.app.deinit();
                testing.allocator.destroy(in_process.app);
                testing.allocator.destroy(in_process.server);
            },
            .raw_windows => |*raw_windows| raw_windows.deinit(io),
        }
    }
};

fn bootEchoServer(io: Io) !EchoServerHandle {
    if (builtin.os.tag == .windows) return bootEchoServerWindowsRaw(io);
    return bootEchoServerInProcess(io);
}

fn bootEchoServerInProcess(io: Io) !EchoServerHandle {
    const app = try testing.allocator.create(App);
    errdefer testing.allocator.destroy(app);
    app.* = App.init(testing.allocator);
    errdefer app.deinit();
    try app.get("/ws", echoWsRoute);

    const server = try testing.allocator.create(Server);
    errdefer testing.allocator.destroy(server);
    server.* = Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0"),
        .request_timeout_ms = 5_000,
        .shutdown_drain_ms = 500,
    });

    var serve_future = try Io.concurrent(io, runServe, .{ server, io, app });
    errdefer stopAndJoin(server, io, &serve_future);

    const port = try waitForBind(server, io);
    return .{
        .port = port,
        .backend = .{
            .in_process = .{
                .app = app,
                .server = server,
                .future = serve_future,
            },
        },
    };
}

fn bootEchoServerWindowsRaw(io: Io) !EchoServerHandle {
    try WsClient.ensureWindowsSocketApi();

    const listen_socket = winsock_socket(
        std.os.windows.ws2_32.AF.INET,
        std.os.windows.ws2_32.SOCK.STREAM,
        std.os.windows.ws2_32.IPPROTO.TCP,
    );
    if (listen_socket == invalid_winsock_socket) return error.SocketListenFailed;
    errdefer _ = winsock_close(listen_socket);

    var bind_addr = winsockLoopbackAddress(0);
    if (winsock_bind(
        listen_socket,
        @ptrCast(&bind_addr),
        @as(c_int, @intCast(@sizeOf(@TypeOf(bind_addr)))),
    ) == -1) {
        return error.SocketBindFailed;
    }
    if (winsock_listen(listen_socket, 1) == -1) return error.SocketListenFailed;

    var bound_addr = winsockLoopbackAddress(0);
    var bound_addr_len: c_int = @sizeOf(@TypeOf(bound_addr));
    if (winsock_getsockname(
        listen_socket,
        @ptrCast(&bound_addr),
        &bound_addr_len,
    ) == -1) {
        return error.SocketBindFailed;
    }

    const serve_future = try Io.concurrent(io, runWindowsRawEchoServer, .{listen_socket});
    const port = std.mem.bigToNative(u16, bound_addr.port);
    return .{
        .port = port,
        .backend = .{
            .raw_windows = .{
                .port = port,
                .future = serve_future,
            },
        },
    };
}

fn runWindowsRawEchoServer(listen_socket: WinSockSocket) anyerror!void {
    defer _ = winsock_close(listen_socket);

    const client_socket = winsock_accept(listen_socket, null, null);
    if (client_socket == invalid_winsock_socket) return error.SocketAcceptFailed;
    defer _ = winsock_close(client_socket);

    try runWindowsRawEchoSession(client_socket);
}

fn runWindowsRawEchoSession(client_socket: WinSockSocket) !void {
    try performWindowsRawHandshake(client_socket);

    while (true) {
        const frame = readWindowsRawClientFrame(client_socket) catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => return err,
        };
        defer testing.allocator.free(frame.payload);

        switch (frame.opcode) {
            .text, .binary => try writeWindowsRawServerFrame(client_socket, frame.opcode, frame.payload),
            .ping => try writeWindowsRawServerFrame(client_socket, .pong, frame.payload),
            .close => {
                _ = writeWindowsRawServerFrame(client_socket, .close, frame.payload) catch {};
                return;
            },
            else => return error.UnexpectedOpcode,
        }
    }
}

fn performWindowsRawHandshake(client_socket: WinSockSocket) !void {
    var head_buf: [8 * 1024]u8 = undefined;
    const head = try readWindowsHttpHead(client_socket, &head_buf);

    const key = headerValue(head, "sec-websocket-key") orelse return error.HandshakeFailed;
    var accept: [28]u8 = undefined;
    computeAccept(key, &accept);

    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{&accept},
    );
    try winsockWriteAll(client_socket, response);
}

fn readWindowsHttpHead(client_socket: WinSockSocket, head_buf: []u8) ![]const u8 {
    var head_len: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, head_buf[0..head_len], "\r\n\r\n")) |idx| {
            return head_buf[0 .. idx + 4];
        }
        if (head_len >= head_buf.len) return error.HandshakeFailed;
        head_len += try winsockRecv(client_socket, head_buf[head_len..]);
    }
}

fn headerValue(head: []const u8, wanted_name: []const u8) ?[]const u8 {
    var line_iter = std.mem.splitSequence(u8, head, "\r\n");
    _ = line_iter.next(); // status/request line
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted_name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn readWindowsRawClientFrame(client_socket: WinSockSocket) !WindowsRawEchoFrame {
    var hdr2: [2]u8 = undefined;
    try winsockReadExact(client_socket, &hdr2);

    const b0 = hdr2[0];
    const b1 = hdr2[1];
    if ((b0 & 0x80) == 0) return error.ProtocolError;

    const masked = (b1 & 0x80) != 0;
    if (!masked) return error.ProtocolError;

    var payload_len: u64 = b1 & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try winsockReadExact(client_socket, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try winsockReadExact(client_socket, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }
    if (payload_len > std.math.maxInt(usize)) return error.PayloadTooLarge;

    var mask: [4]u8 = undefined;
    try winsockReadExact(client_socket, &mask);

    const payload = try testing.allocator.alloc(u8, @as(usize, @intCast(payload_len)));
    errdefer testing.allocator.free(payload);
    try winsockReadExact(client_socket, payload);
    for (payload, 0..) |*byte, i| byte.* ^= mask[i & 3];

    return .{
        .opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F))),
        .payload = payload,
    };
}

fn writeWindowsRawServerFrame(client_socket: WinSockSocket, opcode: Opcode, payload: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @intFromEnum(opcode));

    const hdr_len = switch (payload.len) {
        0...125 => blk: {
            hdr[1] = @as(u8, @intCast(payload.len));
            break :blk @as(usize, 2);
        },
        126...0xFFFF => blk: {
            hdr[1] = 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            break :blk @as(usize, 4);
        },
        else => blk: {
            hdr[1] = 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            break :blk @as(usize, 10);
        },
    };

    try winsockWriteAll(client_socket, hdr[0..hdr_len]);
    try winsockWriteAll(client_socket, payload);
}

fn bootWindowsRawHttpErrorServer(io: Io, response: []const u8) !WindowsRawServerHandle {
    try WsClient.ensureWindowsSocketApi();

    const listen_socket = winsock_socket(
        std.os.windows.ws2_32.AF.INET,
        std.os.windows.ws2_32.SOCK.STREAM,
        std.os.windows.ws2_32.IPPROTO.TCP,
    );
    if (listen_socket == invalid_winsock_socket) return error.SocketListenFailed;
    errdefer _ = winsock_close(listen_socket);

    var bind_addr = winsockLoopbackAddress(0);
    if (winsock_bind(
        listen_socket,
        @ptrCast(&bind_addr),
        @as(c_int, @intCast(@sizeOf(@TypeOf(bind_addr)))),
    ) == -1) {
        return error.SocketBindFailed;
    }
    if (winsock_listen(listen_socket, 1) == -1) return error.SocketListenFailed;

    var bound_addr = winsockLoopbackAddress(0);
    var bound_addr_len: c_int = @sizeOf(@TypeOf(bound_addr));
    if (winsock_getsockname(
        listen_socket,
        @ptrCast(&bound_addr),
        &bound_addr_len,
    ) == -1) {
        return error.SocketBindFailed;
    }

    const port = std.mem.bigToNative(u16, bound_addr.port);
    const future = try Io.concurrent(io, runWindowsRawHttpErrorServer, .{ listen_socket, response });
    return .{
        .port = port,
        .future = future,
    };
}

fn runWindowsRawHttpErrorServer(listen_socket: WinSockSocket, response: []const u8) anyerror!void {
    defer _ = winsock_close(listen_socket);

    const client_socket = winsock_accept(listen_socket, null, null);
    if (client_socket == invalid_winsock_socket) return error.SocketAcceptFailed;
    defer _ = winsock_close(client_socket);

    var head_buf: [4 * 1024]u8 = undefined;
    _ = readWindowsHttpHead(client_socket, &head_buf) catch |err| switch (err) {
        error.ConnectionClosed => return,
        else => return err,
    };
    try winsockWriteAll(client_socket, response);
}

test "ws_test_client: handshake + text echo roundtrip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try bootEchoServer(io);
    defer server.deinit(io);

    const client = try WsClient.connect(testing.allocator, io, server.port, .{ .path = "/ws" });
    defer client.close();

    try client.sendText("hello");
    const reply = try client.receive();
    try testing.expectEqual(MessageKind.text, reply.kind);
    try testing.expectEqualStrings("hello", reply.payload);
}

test "ws_test_client: binary roundtrip" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try bootEchoServer(io);
    defer server.deinit(io);

    const client = try WsClient.connect(testing.allocator, io, server.port, .{ .path = "/ws" });
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try bootEchoServer(io);
    defer server.deinit(io);

    // 70 KiB > 0xFFFF so the client emits a 64-bit length frame.
    const big = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*x, i| x.* = @intCast(i & 0xFF);

    const client = try WsClient.connect(
        testing.allocator,
        io,
        server.port,
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
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try bootEchoServer(io);
    defer server.deinit(io);

    const client = try WsClient.connect(testing.allocator, io, server.port, .{ .path = "/ws" });
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

    if (builtin.os.tag == .windows) {
        var server = try bootWindowsRawHttpErrorServer(
            io,
            "HTTP/1.1 404 Not Found\r\n" ++
                "Content-Length: 2\r\n" ++
                "Connection: close\r\n\r\n" ++
                "ok",
        );
        defer server.deinit(io);

        try testing.expectError(
            error.HandshakeFailed,
            WsClient.connect(testing.allocator, io, server.port, .{ .path = "/ws" }),
        );
        return;
    }

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
