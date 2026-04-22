const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

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

        const cookies_raw: []const u8 = blk: {
            var headers = raw_req.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "cookie")) break :blk header.value;
            }
            break :blk "";
        };

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
        req.cookies_raw = cookies_raw;
        req.body = body;

        const response = app.handle(req);
        sendResponse(&raw_req, response) catch break;
    }
}

fn sendResponse(raw_req: *std.http.Server.Request, response: Response) !void {
    if (response.content_type.len == 0) {
        try raw_req.respond(response.body, .{
            .status = response.status,
        });
        return;
    }

    const extra_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = response.content_type },
    };
    try raw_req.respond(response.body, .{
        .status = response.status,
        .extra_headers = &extra_headers,
    });
}
