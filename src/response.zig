const std = @import("std");
const Request = @import("request.zig").Request;

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    location: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    extra_headers: std.ArrayListUnmanaged(std.http.Header) = .empty,
    extra_headers_allocator: ?std.mem.Allocator = null,
    owned_allocator: ?std.mem.Allocator = null,

    pub fn header(self: *Response, name: []const u8, value: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            self.content_type = value;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            self.location = value;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "allow")) {
            self.allow = value;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "set-cookie")) {
            return self.appendHeader(name, value);
        }

        for (self.extra_headers.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                entry.* = .{ .name = name, .value = value };
                return true;
            }
        }

        return self.appendHeader(name, value);
    }

    pub fn appendHeader(self: *Response, name: []const u8, value: []const u8) bool {
        const allocator = self.extra_headers_allocator orelse std.heap.smp_allocator;
        self.extra_headers.append(allocator, .{
            .name = name,
            .value = value,
        }) catch return false;
        self.extra_headers_allocator = allocator;
        return true;
    }

    pub fn extraHeaders(self: *const Response) []const std.http.Header {
        return self.extra_headers.items;
    }

    pub fn clone(self: Response, allocator: std.mem.Allocator) !Response {
        var cloned: Response = .{
            .status = self.status,
            .content_type = try allocator.dupe(u8, self.content_type),
            .body = try allocator.dupe(u8, self.body),
            .location = if (self.location) |location| try allocator.dupe(u8, location) else null,
            .allow = if (self.allow) |allow| try allocator.dupe(u8, allow) else null,
            .extra_headers_allocator = allocator,
            .owned_allocator = allocator,
        };
        errdefer cloned.deinit();

        for (self.extra_headers.items) |extra_header| {
            try cloned.extra_headers.append(allocator, .{
                .name = try allocator.dupe(u8, extra_header.name),
                .value = try allocator.dupe(u8, extra_header.value),
            });
        }

        return cloned;
    }

    pub fn deinit(self: *Response) void {
        if (self.owned_allocator) |allocator| {
            allocator.free(self.content_type);
            allocator.free(self.body);
            if (self.location) |location| allocator.free(location);
            if (self.allow) |allow| allocator.free(allow);
            for (self.extra_headers.items) |extra_header| {
                allocator.free(extra_header.name);
                allocator.free(extra_header.value);
            }
        }

        if (self.extra_headers_allocator) |allocator| {
            self.extra_headers.deinit(allocator);
        }
        self.extra_headers = .empty;
        self.extra_headers_allocator = null;
        self.owned_allocator = null;
    }
};

pub fn body(status: std.http.Status, content_type: []const u8, content: []const u8) Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body = content,
    };
}

pub fn html(content: []const u8) Response {
    return @This().body(.ok, "text/html; charset=utf-8", content);
}

pub fn json(content: []const u8) Response {
    return @This().body(.ok, "application/json; charset=utf-8", content);
}

pub fn text(status: std.http.Status, content: []const u8) Response {
    return @This().body(status, "text/plain; charset=utf-8", content);
}

pub fn notFound() Response {
    return text(.not_found, "Not Found");
}

pub fn redirect(method: std.http.Method, location: []const u8) Response {
    return .{
        .status = if (method == .GET) .moved_permanently else .permanent_redirect,
        .content_type = "",
        .body = "",
        .location = location,
    };
}

pub fn options(allow: []const u8) Response {
    return .{
        .status = .no_content,
        .content_type = "",
        .body = "",
        .allow = allow,
    };
}

pub fn methodNotAllowed(allow: []const u8) Response {
    return .{
        .status = .method_not_allowed,
        .content_type = "text/plain; charset=utf-8",
        .body = "Method Not Allowed",
        .allow = allow,
    };
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
    return try req.json(T);
}

test "typedJson serializes into response body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = typedJson(arena.allocator(), .{ .ok = true });

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.body);
}

test "redirect chooses 301 for GET and 308 otherwise" {
    const get_res = redirect(.GET, "/users");
    const post_res = redirect(.POST, "/users");

    try std.testing.expectEqual(std.http.Status.moved_permanently, get_res.status);
    try std.testing.expectEqual(std.http.Status.permanent_redirect, post_res.status);
    try std.testing.expectEqualStrings("/users", get_res.location.?);
}

test "response inline headers support overwrite and append" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("cache-control", "max-age=60"));
    try std.testing.expect(res.header("Cache-Control", "no-store"));
    try std.testing.expect(res.header("content-type", "application/problem+json"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));
    try std.testing.expect(res.appendHeader("set-cookie", "b=2"));

    const headers = res.extraHeaders();
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("no-store", headers[0].value);
    try std.testing.expectEqualStrings("a=1", headers[1].value);
    try std.testing.expectEqualStrings("b=2", headers[2].value);
}

test "response body helper builds arbitrary content types" {
    const res = body(.created, "application/problem+json", "{\"ok\":false}");

    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":false}", res.body);
}

test "response clone owns duplicated data" {
    var res = text(.accepted, "ok");
    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.accepted, cloned.status);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", cloned.content_type);
    try std.testing.expectEqualStrings("ok", cloned.body);
    try std.testing.expectEqual(@as(usize, 2), cloned.extraHeaders().len);
    try std.testing.expectEqualStrings("no-store", cloned.extraHeaders()[0].value);
    try std.testing.expectEqualStrings("a=1", cloned.extraHeaders()[1].value);
}
