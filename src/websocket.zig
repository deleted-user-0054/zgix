const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const WebSocketUpgradeOptions = response_mod.WebSocketUpgradeOptions;
pub const WebSocketConnection = response_mod.WebSocketConnection;

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

pub fn upgradeWebSocket(req: Request, comptime handler: anytype, websocket_options: WebSocketUpgradeOptions) Response {
    if (!isWebSocketUpgrade(req)) {
        return response_mod.text(.bad_request, "Invalid WebSocket upgrade");
    }

    const Builder = struct {
        const Data = struct {
            req: Request,
            protocol: ?[]const u8,
        };

        fn run(ctx: *const anyopaque, socket: *response_mod.WebSocketConnection) anyerror!void {
            const data: *const Data = @ptrCast(@alignCast(ctx));
            const mode = comptime webSocketHandlerMode(@TypeOf(handler));
            if (comptime mode == .request) {
                try handler(data.req, socket);
            } else {
                try handler(socket);
            }
        }

        /// Type-erased deinit installed via `Response.attachScope`. Owns the
        /// heap-allocated `Data` and frees it after the websocket lifecycle
        /// completes.
        fn scopeDeinit(scope_ptr: *anyopaque) void {
            const data: *Data = @ptrCast(@alignCast(scope_ptr));
            const allocator = data.req.allocator;
            allocator.destroy(data);
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
    });
    // Tie the heap `Data` lifetime to the response via the uniform scope
    // mechanism; on attach failure we free the data and surface an error.
    response.finalizeScope(req.allocator, @ptrCast(data), Builder.scopeDeinit);
    return response;
}

const WebSocketHandlerMode = enum {
    socket,
    request,
};

fn webSocketHandlerMode(comptime HandlerType: type) WebSocketHandlerMode {
    const info = switch (@typeInfo(HandlerType)) {
        .@"fn" => |function_info| function_info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |function_info| function_info,
            else => @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void."),
        },
        else => @compileError("zono.upgradeWebSocket handlers must be functions or function pointers."),
    };

    if (info.return_type == null) {
        @compileError("zono.upgradeWebSocket handlers must return !void.");
    }
    switch (@typeInfo(info.return_type.?)) {
        .error_union => |payload| {
            if (payload.payload != void) {
                @compileError("zono.upgradeWebSocket handlers must return !void.");
            }
        },
        else => @compileError("zono.upgradeWebSocket handlers must return !void."),
    }

    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
        if (Param != *response_mod.WebSocketConnection) {
            @compileError("zono.upgradeWebSocket handlers must accept *zono.WebSocketConnection.");
        }
        return .socket;
    }

    if (info.params.len != 2) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }

    const First = info.params[0].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    const Second = info.params[1].type orelse @compileError("zono.upgradeWebSocket handlers require concrete parameter types.");
    if (First != Request or Second != *response_mod.WebSocketConnection) {
        @compileError("zono.upgradeWebSocket handlers must be fn(*zono.WebSocketConnection) !void or fn(zono.Request, *zono.WebSocketConnection) !void.");
    }
    return .request;
}

fn headerContainsToken(header_value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (eqIgnoreCase(trimmed, token)) return true;
    }
    return false;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "websocket helper validates upgrade requests" {
    var req = Request.init(std.testing.allocator, .GET, "/ws");
    req.header_list = &.{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "sec-websocket-version", .value = "13" },
    };

    try std.testing.expect(isWebSocketUpgrade(req));

    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{
        .protocol = "chat",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expect(res.runtime == .websocket);
    try std.testing.expectEqualStrings("chat", res.runtime.websocket.protocol.?);
}

test "websocket helper rejects plain requests" {
    const req = Request.init(std.testing.allocator, .GET, "/ws");
    var res = upgradeWebSocket(req, struct {
        fn run(_: *response_mod.WebSocketConnection) !void {}
    }.run, .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("Invalid WebSocket upgrade", res.body);
}
