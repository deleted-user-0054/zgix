const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const Options = struct {
    address: std.Io.net.IpAddress,
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 64 * 1024,
    max_body_bytes: usize = 4 * 1024 * 1024,
};

pub const Server = struct {
    options: Options,

    pub fn init(options: Options) Server {
        return .{ .options = options };
    }

    pub fn serve(self: *const Server, io: Io, app: *App) !void {
        try app.finalize();

        var listener = try self.options.address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        var group: Io.Group = .init;
        defer group.cancel(io);

        while (true) {
            const stream = listener.accept(io) catch |err| switch (err) {
                error.Canceled => break,
                error.ConnectionAborted => continue,
                else => return err,
            };
            group.concurrent(io, handleConn, .{ io, stream, app, self.options }) catch {
                stream.close(io);
            };
        }
    }
};

fn handleConn(io: Io, stream: Io.net.Stream, app: *App, options: Options) Io.Cancelable!void {
    defer stream.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const read_buffer = std.heap.smp_allocator.alloc(u8, options.read_buffer_size) catch return;
    defer std.heap.smp_allocator.free(read_buffer);
    const write_buffer = std.heap.smp_allocator.alloc(u8, options.write_buffer_size) catch return;
    defer std.heap.smp_allocator.free(write_buffer);

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

        const body: []const u8 = blk: {
            const content_length = raw_req.head.content_length orelse break :blk "";
            if (content_length == 0) break :blk "";
            var transfer_buffer: [4096]u8 = undefined;
            var body_reader = raw_req.server.reader.bodyReader(
                &transfer_buffer,
                raw_req.head.transfer_encoding,
                raw_req.head.content_length,
            );
            break :blk body_reader.allocRemaining(alloc, .limited(options.max_body_bytes)) catch "";
        };

        var req = Request.init(alloc, raw_req.head.method, path);
        req.query_string = query_string;
        req.header_lookup_ctx = @ptrCast(&raw_req);
        req.header_lookup_fn = lookupHeader;
        req.headers_collect_fn = collectHeaders;
        req.body = body;

        var response = app.handle(req);
        defer response.deinit();
        const outcome = sendResponse(&raw_req, &response) catch break;
        if (outcome == .upgraded) break;
    }
}

const SendOutcome = enum {
    keep_alive,
    upgraded,
};

fn sendResponse(raw_req: *std.http.Server.Request, response: *const Response) !SendOutcome {
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
            try raw_req.respond(response.body, .{
                .status = response.status,
                .extra_headers = combined_headers,
            });
            return .keep_alive;
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
