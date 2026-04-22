const std = @import("std");

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    query_string: []const u8 = "",
    body: []const u8 = "",
    cookies_raw: []const u8 = "",
    params: []const Param = &.{},

    pub fn init(allocator: std.mem.Allocator, method: std.http.Method, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .path = path,
        };
    }

    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        for (self.params) |entry| {
            if (std.mem.eql(u8, entry.key, name)) return entry.value;
        }
        return null;
    }

    pub fn queryParam(self: Request, name: []const u8) ?[]const u8 {
        var rest = self.query_string;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const kv = rest[0..amp];
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
            } else if (std.mem.eql(u8, kv, name)) {
                return "";
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }
        return null;
    }

    pub fn cookie(self: Request, name: []const u8) ?[]const u8 {
        var rest = self.cookies_raw;
        while (rest.len > 0) {
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            const pair = rest[0..semi];
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
            rest = if (semi < rest.len) rest[semi + 1 ..] else "";
        }
        return null;
    }
};

test "request queryParam returns first matching value" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=zig&page=2&q=ignored";

    try std.testing.expectEqualStrings("zig", req.queryParam("q").?);
    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
    try std.testing.expect(req.queryParam("missing") == null);
}

test "request cookie parses raw cookie header" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.cookies_raw = "session=abc; theme=dark";

    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}
