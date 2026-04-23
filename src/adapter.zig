const std = @import("std");
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const RawResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    headers: []const std.http.Header = &.{},
    body: []const u8,

    pub fn header(self: RawResponse, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn deinit(self: *RawResponse) void {
        for (self.headers) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        if (self.headers.len > 0) self.allocator.free(self.headers);
        self.allocator.free(self.body);
        self.headers = &.{};
        self.body = "";
    }
};

pub fn fromResponse(allocator: std.mem.Allocator, response: Response) !RawResponse {
    if (response.runtime != .none) return error.UnsupportedRuntimeResponse;

    const extra_count: usize =
        @as(usize, @intFromBool(response.content_type.len > 0)) +
        @as(usize, @intFromBool(response.location != null)) +
        @as(usize, @intFromBool(response.allow != null)) +
        response.extraHeaders().len;

    var headers = try allocator.alloc(std.http.Header, extra_count);
    errdefer allocator.free(headers);

    var index: usize = 0;
    if (response.content_type.len > 0) {
        headers[index] = .{
            .name = try allocator.dupe(u8, "content-type"),
            .value = try allocator.dupe(u8, response.content_type),
        };
        index += 1;
    }
    if (response.location) |location| {
        headers[index] = .{
            .name = try allocator.dupe(u8, "location"),
            .value = try allocator.dupe(u8, location),
        };
        index += 1;
    }
    if (response.allow) |allow| {
        headers[index] = .{
            .name = try allocator.dupe(u8, "allow"),
            .value = try allocator.dupe(u8, allow),
        };
        index += 1;
    }
    for (response.extraHeaders()) |entry| {
        headers[index] = .{
            .name = try allocator.dupe(u8, entry.name),
            .value = try allocator.dupe(u8, entry.value),
        };
        index += 1;
    }

    return .{
        .allocator = allocator,
        .status = response.status,
        .headers = headers,
        .body = try allocator.dupe(u8, response.body),
    };
}

pub fn toResponse(allocator: std.mem.Allocator, raw_response: RawResponse) !Response {
    var response = try response_mod.body(raw_response.status, "", raw_response.body).clone(allocator);
    errdefer response.deinit();

    for (raw_response.headers) |entry| {
        _ = response.header(entry.name, entry.value);
    }

    return response;
}

test "adapter converts regular responses to raw responses" {
    var res = response_mod.text(.created, "adapter");
    _ = res.header("x-test", "1");

    var raw = try fromResponse(std.testing.allocator, res);
    defer raw.deinit();

    try std.testing.expectEqual(std.http.Status.created, raw.status);
    try std.testing.expectEqualStrings("adapter", raw.body);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", raw.header("content-type").?);
    try std.testing.expectEqualStrings("1", raw.header("x-test").?);
}
