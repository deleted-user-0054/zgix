const std = @import("std");

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Header = std.http.Header;
pub const FormError = std.mem.Allocator.Error || error{
    InvalidPercentEncoding,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    query_string: []const u8 = "",
    body: []const u8 = "",
    cookies_raw: []const u8 = "",
    headers: []const Header = &.{},
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

    pub fn paramsSlice(self: Request) []const Param {
        return self.params;
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

    pub fn query(self: Request, name: []const u8) ?[]const u8 {
        return self.queryParam(name);
    }

    pub fn queries(self: Request, name: []const u8) ![]const []const u8 {
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        var rest = self.query_string;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const kv = rest[0..amp];
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                if (std.mem.eql(u8, kv[0..eq], name)) {
                    try values.append(self.allocator, kv[eq + 1 ..]);
                }
            } else if (std.mem.eql(u8, kv, name)) {
                try values.append(self.allocator, "");
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn headersSlice(self: Request) []const Header {
        return self.headers;
    }

    pub fn contentType(self: Request) ?[]const u8 {
        const raw = self.header("content-type") orelse return null;
        const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
        return std.mem.trim(u8, raw[0..semi], " \t");
    }

    pub fn hasContentType(self: Request, value: []const u8) bool {
        const content_type = self.contentType() orelse return false;
        return std.ascii.eqlIgnoreCase(content_type, value);
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

    pub fn text(self: Request) []const u8 {
        return self.body;
    }

    pub fn json(self: Request, comptime T: type) !?std.json.Parsed(T) {
        if (self.body.len == 0) return null;
        return try std.json.parseFromSlice(T, self.allocator, self.body, .{
            .ignore_unknown_fields = true,
        });
    }

    pub fn formValue(self: Request, name: []const u8) FormError!?[]const u8 {
        if (!self.hasContentType("application/x-www-form-urlencoded") or self.body.len == 0) return null;

        var rest = self.body;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const pair = rest[0..amp];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key_raw = pair[0..eq];
            const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            const decoded_key = try decodeFormComponent(self.allocator, key_raw);
            if (std.mem.eql(u8, decoded_key, name)) {
                return try decodeFormComponent(self.allocator, value_raw);
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        return null;
    }

    pub fn formValues(self: Request, name: []const u8) FormError![]const []const u8 {
        if (!self.hasContentType("application/x-www-form-urlencoded") or self.body.len == 0) return &.{};

        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        var rest = self.body;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const pair = rest[0..amp];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key_raw = pair[0..eq];
            const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            const decoded_key = try decodeFormComponent(self.allocator, key_raw);
            if (std.mem.eql(u8, decoded_key, name)) {
                try values.append(self.allocator, try decodeFormComponent(self.allocator, value_raw));
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }
};

fn decodeFormComponent(allocator: std.mem.Allocator, input: []const u8) FormError![]const u8 {
    if (input.len == 0) return "";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const c = input[index];
        switch (c) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (index + 2 >= input.len) return error.InvalidPercentEncoding;
                const hi = std.fmt.charToDigit(input[index + 1], 16) catch return error.InvalidPercentEncoding;
                const lo = std.fmt.charToDigit(input[index + 2], 16) catch return error.InvalidPercentEncoding;
                try out.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
                index += 2;
            },
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

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

test "request header lookup is case-insensitive" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-request-id", .value = "req-123" },
    };

    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("req-123", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("missing") == null);
}

test "request queries returns all matching values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "tag=zig&tag=web&tag&tag=router";

    const values = try req.queries("tag");
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web", values[1]);
    try std.testing.expectEqualStrings("", values[2]);
    try std.testing.expectEqualStrings("router", values[3]);
}

test "request json parses typed payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.body = "{\"title\":\"hello\"}";

    const parsed = (try req.json(struct { title: []const u8 })).?;
    try std.testing.expectEqualStrings("hello", parsed.value.title);
}

test "request contentType ignores parameters" {
    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.headers = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };

    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", req.contentType().?);
    try std.testing.expect(req.hasContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(!req.hasContentType("application/json"));
}

test "request formValue decodes urlencoded bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/submit");
    req.headers = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    req.body = "title=hello+world&note=zig%2Bweb&empty";

    try std.testing.expectEqualStrings("hello world", (try req.formValue("title")).?);
    try std.testing.expectEqualStrings("zig+web", (try req.formValue("note")).?);
    try std.testing.expectEqualStrings("", (try req.formValue("empty")).?);
    try std.testing.expect((try req.formValue("missing")) == null);
}

test "request formValues collects repeated fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/submit");
    req.headers = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };
    req.body = "tag=zig&tag=web+toolkit&tag=router";

    const values = try req.formValues("tag");
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web toolkit", values[1]);
    try std.testing.expectEqualStrings("router", values[2]);
}
