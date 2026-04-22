const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const VariableEntry = struct {
    value: *anyopaque,
    type_name: []const u8,
    deinit_fn: *const fn (allocator: std.mem.Allocator, value: *anyopaque) void,
};

pub const SharedState = struct {
    allocator: std.mem.Allocator,
    response: Response = .{
        .status = .ok,
        .content_type = "",
        .body = "",
    },
    variables: std.StringHashMapUnmanaged(VariableEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) SharedState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedState) void {
        self.response.deinit();
        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit_fn(self.allocator, entry.value_ptr.value);
        }
        self.variables.deinit(self.allocator);
        self.variables = .empty;
    }

    pub fn set(self: *SharedState, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        const ValueType = @TypeOf(value);
        const T = if (comptime isStringLike(ValueType)) []const u8 else ValueType;
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const stored_value = try self.allocator.create(T);
        errdefer self.allocator.destroy(stored_value);
        stored_value.* = if (comptime isStringLike(ValueType)) value else value;

        const entry: VariableEntry = .{
            .value = @ptrCast(stored_value),
            .type_name = @typeName(T),
            .deinit_fn = deinitValueFn(T),
        };

        const result = try self.variables.getOrPut(self.allocator, key);
        if (result.found_existing) {
            self.allocator.free(owned_key);
            result.value_ptr.deinit_fn(self.allocator, result.value_ptr.value);
            result.value_ptr.* = entry;
            return;
        }

        result.key_ptr.* = owned_key;
        result.value_ptr.* = entry;
    }

    pub fn get(self: *const SharedState, comptime T: type, key: []const u8) ?T {
        const entry = self.variables.get(key) orelse return null;
        if (!std.mem.eql(u8, entry.type_name, @typeName(T))) return null;

        const typed_value: *const T = @ptrCast(@alignCast(entry.value));
        return typed_value.*;
    }
};

pub const Context = struct {
    req: Request,
    res: *Response,
    state: *SharedState,

    pub const Next = struct {
        ctx: *Context,
        next_ctx: *const anyopaque,
        run_fn: *const fn (next_ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: Next) void {
            self.ctx.mergeResponse(self.run_fn(self.next_ctx, self.ctx.req));
        }
    };

    pub fn init(req: Request) Context {
        const raw_state = req.contextState() orelse @panic("Context requires a request with initialized context state.");
        const state: *SharedState = @ptrCast(@alignCast(raw_state));
        return .{
            .req = req,
            .res = &state.response,
            .state = state,
        };
    }

    pub fn status(self: *Context, value: std.http.Status) void {
        self.res.setStatus(value);
    }

    pub fn header(self: *Context, name: []const u8, value: []const u8) bool {
        return self.res.header(name, value);
    }

    pub fn deleteHeader(self: *Context, name: []const u8) bool {
        return self.res.deleteHeader(name);
    }

    pub fn set(self: *Context, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        try self.state.set(key, value);
    }

    pub fn get(self: *Context, comptime T: type, key: []const u8) ?T {
        return self.state.get(T, key);
    }

    pub fn body(self: *Context, content: []const u8, content_type: []const u8) Response {
        _ = self.res.setContentType(content_type);
        _ = self.res.setBody(content);
        _ = self.res.setLocation(null);
        _ = self.res.setAllow(null);
        return self.takeResponse();
    }

    pub fn text(self: *Context, content: []const u8) Response {
        return self.body(content, "text/plain; charset=utf-8");
    }

    pub fn html(self: *Context, content: []const u8) Response {
        return self.body(content, "text/html; charset=utf-8");
    }

    pub fn json(self: *Context, content: []const u8) Response {
        return self.body(content, "application/json; charset=utf-8");
    }

    pub fn redirect(self: *Context, location: []const u8, status_code: ?std.http.Status) Response {
        self.res.setStatus(status_code orelse .found);
        _ = self.res.setContentType("");
        _ = self.res.setBody("");
        _ = self.res.setAllow(null);
        _ = self.res.setLocation(location);
        return self.takeResponse();
    }

    pub fn cookie(
        self: *Context,
        name: []const u8,
        value: []const u8,
        cookie_options: @import("response.zig").CookieOptions,
    ) @import("response.zig").CookieError!void {
        try self.res.cookie(self.req.allocator, name, value, cookie_options);
    }

    pub fn deleteCookie(
        self: *Context,
        name: []const u8,
        delete_options: @import("response.zig").DeleteCookieOptions,
    ) @import("response.zig").CookieError!void {
        try self.res.deleteCookie(self.req.allocator, name, delete_options);
    }

    pub fn takeResponse(self: *Context) Response {
        const response = self.state.response;
        self.state.response = .{
            .status = .ok,
            .content_type = "",
            .body = "",
        };
        self.res = &self.state.response;
        return response;
    }

    fn mergeResponse(self: *Context, response: Response) void {
        var merged = response;
        if (self.res.owned_allocator != null and merged.owned_allocator == null) {
            merged = merged.clone(self.req.allocator) catch merged;
        }
        if (self.res.status != .ok and merged.status == .ok) {
            merged.setStatus(self.res.status);
        }
        if (self.res.content_type.len > 0 and merged.content_type.len == 0) {
            _ = merged.setContentType(self.res.content_type);
        }
        if (self.res.location != null and merged.location == null) {
            _ = merged.setLocation(self.res.location);
        }
        if (self.res.allow != null and merged.allow == null) {
            _ = merged.setAllow(self.res.allow);
        }
        for (self.res.extraHeaders()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "set-cookie")) {
                _ = merged.appendHeader(entry.name, entry.value);
            } else {
                _ = merged.header(entry.name, entry.value);
            }
        }

        self.state.response.deinit();
        self.state.response = merged;
        self.res = &self.state.response;
    }
};

fn deinitValueFn(comptime T: type) *const fn (allocator: std.mem.Allocator, value: *anyopaque) void {
    return struct {
        fn run(allocator: std.mem.Allocator, value: *anyopaque) void {
            const typed_value: *T = @ptrCast(@alignCast(value));
            allocator.destroy(typed_value);
        }
    }.run;
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}
