const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const MatchedRoute = request_mod.MatchedRoute;
const ValidationTarget = request_mod.ValidationTarget;
const Response = @import("response.zig").Response;
const http_exception_mod = @import("http_exception.zig");
const HTTPException = http_exception_mod.HTTPException;
const StoredHTTPException = http_exception_mod.StoredHTTPException;
const Handler = @import("router.zig").Handler;

const VariableEntry = struct {
    value: *anyopaque,
    type_name: []const u8,
    deinit_fn: *const fn (allocator: std.mem.Allocator, value: *anyopaque) void,
};

const RendererFn = *const fn (ctx: *anyopaque, content: []const u8) Response;

pub const SharedState = struct {
    allocator: std.mem.Allocator,
    response: Response = .{
        .status = .ok,
        .content_type = "",
        .body = "",
    },
    variables: std.StringHashMapUnmanaged(VariableEntry) = .empty,
    validated: std.StringHashMapUnmanaged(VariableEntry) = .empty,
    matched_routes: std.ArrayListUnmanaged(MatchedRoute) = .empty,
    renderer: ?RendererFn = null,
    not_found_handler: ?Handler = null,
    on_error_handler: ?*const fn (err: anyerror, req: Request) Response = null,
    route_path: ?[]const u8 = null,
    base_route_path: ?[]const u8 = null,
    http_exception: ?StoredHTTPException = null,
    last_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) SharedState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedState) void {
        self.response.deinit();
        deinitVariableMap(self.allocator, &self.variables);
        deinitVariableMap(self.allocator, &self.validated);
        self.matched_routes.deinit(self.allocator);
        if (self.http_exception) |*exception| exception.deinit(self.allocator);
    }

    pub fn set(self: *SharedState, key: []const u8, value: anytype) std.mem.Allocator.Error!void {
        try putVariableValue(self.allocator, &self.variables, key, value);
    }

    pub fn get(self: *const SharedState, comptime T: type, key: []const u8) ?T {
        return getVariableValue(&self.variables, T, key);
    }

    pub fn contains(self: *const SharedState, key: []const u8) bool {
        return self.variables.contains(key);
    }

    pub fn setValid(self: *SharedState, comptime target: ValidationTarget, value: anytype) std.mem.Allocator.Error!void {
        try putVariableValue(self.allocator, &self.validated, validationKey(target), value);
    }

    pub fn getValid(self: *const SharedState, comptime T: type, comptime target: ValidationTarget) ?T {
        return getVariableValue(&self.validated, T, validationKey(target));
    }

    pub fn lookupValid(self: *const SharedState, target: ValidationTarget, type_name: []const u8) ?*const anyopaque {
        return lookupVariableValue(&self.validated, validationKey(target), type_name);
    }

    pub fn appendMatchedRoute(self: *SharedState, route: MatchedRoute) std.mem.Allocator.Error!void {
        try self.matched_routes.append(self.allocator, route);
    }

    pub fn setRoutePath(self: *SharedState, path: ?[]const u8) void {
        self.route_path = path;
    }

    pub fn setBaseRoutePath(self: *SharedState, path: ?[]const u8) void {
        self.base_route_path = path;
    }

    pub fn setHttpException(self: *SharedState, exception: HTTPException) std.mem.Allocator.Error!void {
        if (self.http_exception) |*existing| existing.deinit(self.allocator);
        self.http_exception = try StoredHTTPException.init(self.allocator, exception);
    }

    pub fn getHttpException(self: *const SharedState) ?HTTPException {
        return if (self.http_exception) |exception|
            exception.view()
        else
            null;
    }
};

pub const Context = struct {
    pub const Var = struct {
        state: *const SharedState,

        pub fn get(self: Var, comptime T: type, key: []const u8) ?T {
            return self.state.get(T, key);
        }

        pub fn contains(self: Var, key: []const u8) bool {
            return self.state.contains(key);
        }
    };

    req: Request,
    res: *Response,
    state: *SharedState,
    vars: Var,
    raw: ?*const anyopaque = null,
    env: ?*const anyopaque = null,
    executionCtx: ?*const anyopaque = null,
    event: ?*const anyopaque = null,
    err: ?anyerror = null,

    pub const Next = struct {
        ctx: *Context,
        next_ctx: *const anyopaque,
        run_fn: *const fn (next_ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: Next) void {
            self.ctx.mergeResponse(self.run_fn(self.next_ctx, self.ctx.req));
            self.ctx.err = self.ctx.state.last_error;
        }
    };

    pub fn init(req: Request) Context {
        const raw_state = req.contextState() orelse @panic("Context requires a request with initialized context state.");
        const state: *SharedState = @ptrCast(@alignCast(raw_state));
        return .{
            .req = req,
            .res = &state.response,
            .state = state,
            .vars = .{
                .state = state,
            },
            .raw = req.raw,
            .env = req.env,
            .executionCtx = req.executionCtx,
            .event = req.event,
            .err = state.last_error,
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

    pub fn setValid(self: *Context, comptime target: ValidationTarget, value: anytype) std.mem.Allocator.Error!void {
        try self.state.setValid(target, value);
    }

    pub fn valid(self: *Context, comptime T: type, comptime target: ValidationTarget) ?T {
        return self.req.valid(T, target);
    }

    pub fn routePath(self: *Context) ?[]const u8 {
        return self.req.routePath();
    }

    pub fn baseRoutePath(self: *Context) ?[]const u8 {
        return self.req.baseRoutePath();
    }

    pub fn matchedRoutes(self: *Context) []const MatchedRoute {
        return self.req.matchedRoutes();
    }

    pub fn httpException(self: *Context) ?HTTPException {
        return self.req.httpException();
    }

    pub fn throw(self: *Context, exception: HTTPException) http_exception_mod.ThrowError {
        return self.req.throw(exception);
    }

    pub fn rawAs(self: *Context, comptime T: type) ?*const T {
        return self.req.rawAs(T);
    }

    pub fn envAs(self: *Context, comptime T: type) ?*const T {
        return self.req.envAs(T);
    }

    pub fn executionCtxAs(self: *Context, comptime T: type) ?*const T {
        return self.req.executionCtxAs(T);
    }

    pub fn eventAs(self: *Context, comptime T: type) ?*const T {
        return self.req.eventAs(T);
    }

    pub fn setRenderer(self: *Context, comptime renderer: anytype) void {
        self.state.renderer = resolveRenderer(renderer);
    }

    pub fn body(self: *Context, content: []const u8, content_type: []const u8) Response {
        _ = self.res.setContentType(content_type);
        _ = self.res.setBody(content);
        _ = self.res.setLocation(null);
        _ = self.res.setAllow(null);
        return self.takeResponse();
    }

    pub fn bodyWithStatus(self: *Context, status_code: std.http.Status, content: []const u8, content_type: []const u8) Response {
        self.status(status_code);
        return self.body(content, content_type);
    }

    pub fn text(self: *Context, content: []const u8) Response {
        return self.body(content, "text/plain; charset=utf-8");
    }

    pub fn textWithStatus(self: *Context, status_code: std.http.Status, content: []const u8) Response {
        return self.bodyWithStatus(status_code, content, "text/plain; charset=utf-8");
    }

    pub fn html(self: *Context, content: []const u8) Response {
        return self.body(content, "text/html; charset=utf-8");
    }

    pub fn htmlWithStatus(self: *Context, status_code: std.http.Status, content: []const u8) Response {
        return self.bodyWithStatus(status_code, content, "text/html; charset=utf-8");
    }

    pub fn json(self: *Context, value: anytype) Response {
        const ValueType = @TypeOf(value);
        if (comptime isStringLike(ValueType)) {
            return self.body(value, "application/json; charset=utf-8");
        }

        var out: std.Io.Writer.Allocating = .init(self.req.allocator);
        var stringify: std.json.Stringify = .{ .writer = &out.writer };
        stringify.write(value) catch return @import("response.zig").internalError("json write failed");
        return self.body(out.written(), "application/json; charset=utf-8");
    }

    pub fn jsonWithStatus(self: *Context, status_code: std.http.Status, value: anytype) Response {
        self.status(status_code);
        return self.json(value);
    }

    pub fn render(self: *Context, content: anytype) Response {
        const ContentType = @TypeOf(content);
        if (!comptime isStringLike(ContentType)) {
            @compileError("Context.render accepts string-like content.");
        }

        const content_slice: []const u8 = content;
        const response = if (self.state.renderer) |renderer|
            renderer(@ptrCast(self), content_slice)
        else
            self.html(content_slice);

        self.mergeResponse(response);
        return self.takeResponse();
    }

    pub fn notFound(self: *Context) Response {
        const response = if (self.state.not_found_handler) |handler|
            handler(self.req)
        else
            @import("response.zig").notFound();

        self.mergeResponse(response);
        return self.takeResponse();
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

pub fn lookupValidatedValue(
    ctx: *const anyopaque,
    target: ValidationTarget,
    type_name: []const u8,
) ?*const anyopaque {
    const state: *const SharedState = @ptrCast(@alignCast(ctx));
    return state.lookupValid(target, type_name);
}

pub fn lookupRoutePath(ctx: *const anyopaque) ?[]const u8 {
    const state: *const SharedState = @ptrCast(@alignCast(ctx));
    return state.route_path;
}

pub fn lookupBaseRoutePath(ctx: *const anyopaque) ?[]const u8 {
    const state: *const SharedState = @ptrCast(@alignCast(ctx));
    return state.base_route_path;
}

pub fn lookupMatchedRoutes(ctx: *const anyopaque) []const MatchedRoute {
    const state: *const SharedState = @ptrCast(@alignCast(ctx));
    return state.matched_routes.items;
}

pub fn storeHttpException(ctx: *const anyopaque, exception: HTTPException) std.mem.Allocator.Error!void {
    const state: *SharedState = @ptrCast(@alignCast(@constCast(ctx)));
    try state.setHttpException(exception);
}

pub fn lookupHttpException(ctx: *const anyopaque) ?HTTPException {
    const state: *const SharedState = @ptrCast(@alignCast(ctx));
    return state.getHttpException();
}

fn validationKey(target: ValidationTarget) []const u8 {
    return switch (target) {
        .form => "form",
        .json => "json",
        .query => "query",
        .header => "header",
        .cookie => "cookie",
        .param => "param",
    };
}

fn putVariableValue(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(VariableEntry),
    key: []const u8,
    value: anytype,
) std.mem.Allocator.Error!void {
    const ValueType = @TypeOf(value);
    const T = if (comptime isStringLike(ValueType)) []const u8 else ValueType;
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    const stored_value = try allocator.create(T);
    errdefer allocator.destroy(stored_value);
    stored_value.* = if (comptime isStringLike(ValueType)) value else value;

    const entry: VariableEntry = .{
        .value = @ptrCast(stored_value),
        .type_name = @typeName(T),
        .deinit_fn = deinitValueFn(T),
    };

    const result = try map.getOrPut(allocator, key);
    if (result.found_existing) {
        allocator.free(owned_key);
        result.value_ptr.deinit_fn(allocator, result.value_ptr.value);
        result.value_ptr.* = entry;
        return;
    }

    result.key_ptr.* = owned_key;
    result.value_ptr.* = entry;
}

fn getVariableValue(
    map: *const std.StringHashMapUnmanaged(VariableEntry),
    comptime T: type,
    key: []const u8,
) ?T {
    const entry = map.get(key) orelse return null;
    if (!std.mem.eql(u8, entry.type_name, @typeName(T))) return null;

    const typed_value: *const T = @ptrCast(@alignCast(entry.value));
    return typed_value.*;
}

fn lookupVariableValue(
    map: *const std.StringHashMapUnmanaged(VariableEntry),
    key: []const u8,
    type_name: []const u8,
) ?*const anyopaque {
    const entry = map.get(key) orelse return null;
    if (!std.mem.eql(u8, entry.type_name, type_name)) return null;
    return entry.value;
}

fn deinitVariableMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(VariableEntry),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit_fn(allocator, entry.value_ptr.value);
    }
    map.deinit(allocator);
    map.* = .empty;
}

fn resolveRenderer(comptime target: anytype) RendererFn {
    const TargetType = @TypeOf(target);
    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveRendererFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveRendererFn(target, pointer.child),
            else => @compileError("Context.setRenderer requires fn(content: []const u8) zono.Response or fn(c: *zono.Context, content: []const u8) zono.Response."),
        },
        else => @compileError("Context.setRenderer requires fn(content: []const u8) zono.Response or fn(c: *zono.Context, content: []const u8) zono.Response."),
    };
}

fn resolveRendererFn(comptime target: anytype, comptime FnType: type) RendererFn {
    const info = @typeInfo(FnType).@"fn";
    if (info.return_type == null or info.return_type.? != Response) {
        @compileError("Context renderer functions must return zono.Response.");
    }
    if (info.params.len == 1 and info.params[0].type != null and info.params[0].type.? == []const u8) {
        return wrapPlainRenderer(target);
    }
    if (info.params.len == 2 and info.params[0].type != null and info.params[0].type.? == *Context and info.params[1].type != null and info.params[1].type.? == []const u8) {
        return wrapContextRenderer(target);
    }

    @compileError("Context.setRenderer requires fn(content: []const u8) zono.Response or fn(c: *zono.Context, content: []const u8) zono.Response.");
}

fn wrapPlainRenderer(comptime target: anytype) RendererFn {
    return struct {
        fn run(ctx: *anyopaque, content: []const u8) Response {
            _ = ctx;
            return target(content);
        }
    }.run;
}

fn wrapContextRenderer(comptime target: anytype) RendererFn {
    return struct {
        fn run(ctx: *anyopaque, content: []const u8) Response {
            const context: *Context = @ptrCast(@alignCast(ctx));
            return target(context, content);
        }
    }.run;
}

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
