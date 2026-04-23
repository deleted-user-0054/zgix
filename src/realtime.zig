const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const SSEEvent = struct {
    data: []const u8,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
    comment: ?[]const u8 = null,
};

pub const WebSocketAcceptOptions = struct {
    protocol: ?[]const u8 = null,
};

pub const UpgradeWebSocketOptions = response_mod.WebSocketUpgradeOptions;
pub const StreamOptions = response_mod.StreamOptions;

pub const WebSocketUpgradeError = error{
    InvalidWebSocketUpgrade,
};

pub fn stream(req: Request, comptime handler: anytype, stream_options: StreamOptions) Response {
    const Builder = struct {
        const Data = struct {
            req: Request,
        };

        fn deinit(allocator: std.mem.Allocator, ctx: *const anyopaque) void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            allocator.destroy(@constCast(data));
        }

        fn run(ctx: *const anyopaque, writer: *response_mod.StreamWriter) anyerror!void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            const mode = comptime streamHandlerMode(@TypeOf(handler));
            if (comptime mode == .request) {
                try handler(data.req, writer);
            } else {
                try handler(writer);
            }
        }
    };

    const data = req.allocator.create(Builder.Data) catch return response_mod.internalError("stream alloc failed");
    data.* = .{ .req = req };
    var response = response_mod.streamRuntime(stream_options, .{
        .ctx = data,
        .run_fn = Builder.run,
        .content_length = stream_options.content_length,
        .deinit_fn = Builder.deinit,
    });
    response.runtime_allocator = req.allocator;
    return response;
}

pub fn streamSSE(req: Request, comptime handler: anytype) Response {
    var res = stream(req, handler, .{
        .content_type = "text/event-stream; charset=utf-8",
    });
    _ = res.header("cache-control", "no-cache");
    _ = res.header("connection", "keep-alive");
    return res;
}

pub fn upgradeWebSocket(req: Request, comptime handler: anytype, websocket_options: UpgradeWebSocketOptions) Response {
    const Builder = struct {
        const Data = struct {
            req: Request,
            protocol: ?[]const u8,
        };

        fn deinit(allocator: std.mem.Allocator, ctx: *const anyopaque) void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            allocator.destroy(@constCast(data));
        }

        fn run(ctx: *const anyopaque, socket: *response_mod.WebSocketConnection) anyerror!void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            const mode = comptime webSocketHandlerMode(@TypeOf(handler));
            if (comptime mode == .request) {
                try handler(data.req, socket);
            } else {
                try handler(socket);
            }
        }
    };

    const data = req.allocator.create(Builder.Data) catch return response_mod.internalError("websocket alloc failed");
    data.* = .{
        .req = req,
        .protocol = websocket_options.protocol,
    };
    var response = response_mod.websocketRuntime(.{
        .ctx = data,
        .run_fn = Builder.run,
        .protocol = websocket_options.protocol,
        .deinit_fn = Builder.deinit,
    });
    response.runtime_allocator = req.allocator;
    return response;
}

pub fn sse(allocator: std.mem.Allocator, events: anytype) !Response {
    const payload = try formatSSE(allocator, events);
    defer allocator.free(payload);
    var res = try response_mod.body(.ok, "text/event-stream; charset=utf-8", payload).clone(allocator);
    _ = res.header("cache-control", "no-cache");
    _ = res.header("connection", "keep-alive");
    return res;
}

pub fn formatSSE(allocator: std.mem.Allocator, events: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendEvents(allocator, &out, events);

    return try out.toOwnedSlice(allocator);
}

pub fn isWebSocketUpgrade(req: Request) bool {
    if (req.method != .GET) return false;
    const upgrade = req.header("upgrade") orelse return false;
    if (!eqIgnoreCase(upgrade, "websocket")) return false;
    if (!headerContainsToken(req.header("connection") orelse return false, "upgrade")) return false;
    if (req.header("sec-websocket-key") == null) return false;
    const version = req.header("sec-websocket-version") orelse return false;
    if (!eqIgnoreCase(version, "13")) return false;
    return true;
}

pub fn acceptWebSocket(req: Request, websocket_options: WebSocketAcceptOptions) WebSocketUpgradeError!Response {
    if (!isWebSocketUpgrade(req)) return error.InvalidWebSocketUpgrade;

    const key = req.header("sec-websocket-key").?;
    const accept_value = computeAcceptValue(req.allocator, key) catch return response_mod.internalError("websocket accept generation failed");
    defer req.allocator.free(accept_value);
    var res = response_mod.body(.switching_protocols, "", "").clone(req.allocator) catch {
        return response_mod.internalError("websocket response allocation failed");
    };
    _ = res.header("upgrade", "websocket");
    _ = res.header("connection", "Upgrade");
    _ = res.header("sec-websocket-accept", accept_value);
    if (websocket_options.protocol) |protocol| {
        _ = res.header("sec-websocket-protocol", protocol);
    }
    return res;
}

fn appendEvents(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    events: anytype,
) std.mem.Allocator.Error!void {
    const Events = @TypeOf(events);
    switch (@typeInfo(Events)) {
        .@"struct" => {
            if (Events != SSEEvent) {
                @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data.");
            }
            try appendEvent(allocator, out, events);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    try appendEvent(allocator, out, .{ .data = events });
                    return;
                }
                if (pointer.child == SSEEvent) {
                    for (events) |event| try appendEvent(allocator, out, event);
                    return;
                }
                @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data.");
            },
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.child == u8) {
                        try appendEvent(allocator, out, .{ .data = events });
                        return;
                    }
                    if (array.child == SSEEvent) {
                        for (events.*) |event| try appendEvent(allocator, out, event);
                        return;
                    }
                    @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data.");
                },
                else => @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data."),
            },
            else => @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data."),
        },
        .array => |array| {
            if (array.child == u8) {
                try appendEvent(allocator, out, .{ .data = events[0..] });
                return;
            }
            if (array.child == SSEEvent) {
                for (events) |event| try appendEvent(allocator, out, event);
                return;
            }
            @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data.");
        },
        else => @compileError("zono.sse accepts an SSEEvent, []const SSEEvent, or string-like data."),
    }
}

fn appendEvent(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    event: SSEEvent,
) std.mem.Allocator.Error!void {
    if (event.comment) |comment| {
        try out.append(allocator, ':');
        try out.appendSlice(allocator, comment);
        try out.append(allocator, '\n');
    }
    if (event.event) |name| {
        try out.appendSlice(allocator, "event: ");
        try out.appendSlice(allocator, name);
        try out.append(allocator, '\n');
    }
    if (event.id) |id| {
        try out.appendSlice(allocator, "id: ");
        try out.appendSlice(allocator, id);
        try out.append(allocator, '\n');
    }
    if (event.retry_ms) |retry_ms| {
        try out.print(allocator, "retry: {d}\n", .{retry_ms});
    }

    var line_iter = std.mem.splitScalar(u8, event.data, '\n');
    while (line_iter.next()) |line| {
        try out.appendSlice(allocator, "data: ");
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try out.append(allocator, '\n');
}

fn computeAcceptValue(allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![]u8 {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, guid });
    defer allocator.free(combined);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});

    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, &digest);
    return encoded;
}

fn headerContainsToken(header_value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (eqIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

fn eqIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

const StreamHandlerMode = enum {
    request,
    writer,
};

fn streamHandlerMode(comptime HandlerType: type) StreamHandlerMode {
    const info = functionInfo(HandlerType);
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("zono.stream handlers must be fn(*zono.StreamWriter) !void or fn(zono.Request, *zono.StreamWriter) !void.");
    }
    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zono.stream handlers require concrete parameter types.");
        if (Param != *response_mod.StreamWriter) {
            @compileError("zono.stream handlers must accept *zono.StreamWriter.");
        }
        return .writer;
    }

    const First = info.params[0].type orelse @compileError("zono.stream handlers require concrete parameter types.");
    const Second = info.params[1].type orelse @compileError("zono.stream handlers require concrete parameter types.");
    if (First != Request or Second != *response_mod.StreamWriter) {
        @compileError("zono.stream handlers must be fn(*zono.StreamWriter) !void or fn(zono.Request, *zono.StreamWriter) !void.");
    }
    return .request;
}

const WebSocketHandlerMode = enum {
    request,
    socket,
};

fn webSocketHandlerMode(comptime HandlerType: type) WebSocketHandlerMode {
    const info = functionInfo(HandlerType);
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }
    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
        if (Param != *response_mod.WebSocketConnection) {
            @compileError("zono.upgradeWebSocket handlers must accept *zono.WebSocketConnection.");
        }
        return .socket;
    }

    const First = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    const Second = info.params[1].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    if (First != Request or Second != *response_mod.WebSocketConnection) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }
    return .request;
}

fn functionInfo(comptime T: type) std.builtin.Type.Fn {
    return switch (@typeInfo(T)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("zono realtime handlers must be functions or function pointers."),
        },
        else => @compileError("zono realtime handlers must be functions or function pointers."),
    };
}

test "sse helper formats event streams" {
    var res = try sse(std.testing.allocator, &[_]SSEEvent{
        .{
            .event = "message",
            .id = "1",
            .data = "hello\nworld",
        },
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("text/event-stream; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("event: message\nid: 1\ndata: hello\ndata: world\n\n", res.body);
}

test "stream runtime helper marks responses as streaming" {
    const req = Request.init(std.testing.allocator, .GET, "/stream");
    var res = stream(req, struct {
        fn run(_: *response_mod.StreamWriter) !void {}
    }.run, .{
        .content_type = "text/plain; charset=utf-8",
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type);
    try std.testing.expect(res.runtime == .stream);
}

test "upgradeWebSocket runtime helper marks responses as websocket upgrades" {
    const req = Request.init(std.testing.allocator, .GET, "/ws");
    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{
        .protocol = "chat",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expect(res.runtime == .websocket);
}

test "websocket helper validates and accepts upgrade requests" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
    };

    try std.testing.expect(isWebSocketUpgrade(req));
    var res = try acceptWebSocket(req, .{
        .protocol = "chat",
    });
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", responseHeaderValue(res, "sec-websocket-accept").?);
    try std.testing.expectEqualStrings("chat", responseHeaderValue(res, "sec-websocket-protocol").?);
}

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "content-type")) return if (res.content_type.len > 0) res.content_type else null;
    for (res.extraHeaders()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
