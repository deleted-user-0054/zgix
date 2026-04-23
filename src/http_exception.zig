const std = @import("std");

pub const ThrowError = std.mem.Allocator.Error || error{
    HTTPException,
};

pub const ThrowErrorValue = HTTPException;

pub const HTTPException = struct {
    status: std.http.Status,
    message: []const u8 = "",
    headers: []const std.http.Header = &.{},
    content_type: []const u8 = "text/plain; charset=utf-8",

    pub fn init(status: std.http.Status, message: []const u8) HTTPException {
        return .{
            .status = status,
            .message = message,
        };
    }

    pub fn withHeaders(self: HTTPException, headers: []const std.http.Header) HTTPException {
        var updated = self;
        updated.headers = headers;
        return updated;
    }

    pub fn withContentType(self: HTTPException, content_type: []const u8) HTTPException {
        var updated = self;
        updated.content_type = content_type;
        return updated;
    }
};

pub const StoredHTTPException = struct {
    status: std.http.Status,
    message: []const u8,
    headers: []std.http.Header = &.{},
    content_type: []const u8,

    pub fn init(allocator: std.mem.Allocator, exception: HTTPException) std.mem.Allocator.Error!StoredHTTPException {
        var headers = try allocator.alloc(std.http.Header, exception.headers.len);
        errdefer {
            for (headers[0..exception.headers.len]) |header| {
                if (header.name.len > 0) allocator.free(header.name);
                if (header.value.len > 0) allocator.free(header.value);
            }
            allocator.free(headers);
        }

        for (headers) |*header| {
            header.* = .{
                .name = "",
                .value = "",
            };
        }

        for (exception.headers, headers) |header, *stored| {
            stored.* = .{
                .name = try allocator.dupe(u8, header.name),
                .value = try allocator.dupe(u8, header.value),
            };
        }

        return .{
            .status = exception.status,
            .message = try allocator.dupe(u8, exception.message),
            .headers = headers,
            .content_type = try allocator.dupe(u8, exception.content_type),
        };
    }

    pub fn deinit(self: *StoredHTTPException, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.content_type);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        self.* = undefined;
    }

    pub fn view(self: *const StoredHTTPException) HTTPException {
        return .{
            .status = self.status,
            .message = self.message,
            .headers = self.headers,
            .content_type = self.content_type,
        };
    }
};
