const std = @import("std");
const Request = @import("request.zig").Request;

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
};

pub fn html(body: []const u8) Response {
    return .{
        .status = .ok,
        .content_type = "text/html; charset=utf-8",
        .body = body,
    };
}

pub fn json(body: []const u8) Response {
    return .{
        .status = .ok,
        .content_type = "application/json; charset=utf-8",
        .body = body,
    };
}

pub fn text(status: std.http.Status, body: []const u8) Response {
    return .{
        .status = status,
        .content_type = "text/plain; charset=utf-8",
        .body = body,
    };
}

pub fn notFound() Response {
    return text(.not_found, "Not Found");
}

pub fn internalError(message: []const u8) Response {
    return text(.internal_server_error, message);
}

pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(value) catch return internalError("json write failed");
    return json(out.written());
}

pub fn parseJson(comptime T: type, req: Request) !?std.json.Parsed(T) {
    if (req.body.len == 0) return null;
    return try std.json.parseFromSlice(T, req.allocator, req.body, .{ .ignore_unknown_fields = true });
}

test "typedJson serializes into response body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = typedJson(arena.allocator(), .{ .ok = true });

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.body);
}
