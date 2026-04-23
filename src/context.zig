const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const Handler = @import("router.zig").Handler;
const websocket_mod = @import("websocket.zig");

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
    not_found_handler: ?Handler = null,
    on_error_handler: ?*const fn (err: anyerror, req: Request) Response = null,
    last_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) SharedState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SharedState) void {
        self.response.deinit();
        deinitVariableMap(self.allocator, &self.variables);
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

    pub const Next = struct {
        ctx: *Context,
        next_ctx: *const anyopaque,
        run_fn: *const fn (next_ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: Next) void {
            self.ctx.mergeResponse(self.run_fn(self.next_ctx, self.ctx.req));
            self.ctx.err = self.ctx.state.last_error;
        }
    };

    req: Request,
    res: *Response,
    state: *SharedState,
    vars: Var,
    err: ?anyerror = null,

    pub fn init(req: Request) Context {
        const raw_state = req.contextState() orelse @panic("Context requires a request with initialized context state.");
        const state: *SharedState = @ptrCast(@alignCast(raw_state));
        return .{
            .req = req,
            .res = &state.response,
            .state = state,
            .vars = .{ .state = state },
            .err = state.last_error,
        };
    }

    pub fn status(self: *Context, value: std.http.Status) void {
        self.res.setStatus(value);
    }

    /// Returns the live `std.Io` handle bound to the server that is servicing
    /// this request. `null` in unit-test paths that go through `App.handle`
    /// directly without booting a `Server`. Handlers that need to do real
    /// I/O (open files, outbound client calls, sleep, etc.) should use this
    /// instead of spinning up their own `Io.Threaded`, which would escape
    /// the server's scheduling and cancellation.
    pub fn io(self: *Context) ?std.Io {
        return self.req.server_io;
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
        stringify.write(value) catch return response_mod.internalError("json write failed");
        return self.body(out.written(), "application/json; charset=utf-8");
    }

    pub fn jsonWithStatus(self: *Context, status_code: std.http.Status, value: anytype) Response {
        self.status(status_code);
        return self.json(value);
    }

    pub fn notFound(self: *Context) Response {
        const response = if (self.state.not_found_handler) |handler|
            handler(self.req)
        else
            response_mod.notFound();

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

    pub fn upgradeWebSocket(self: *Context, comptime handler: anytype, options: websocket_mod.WebSocketUpgradeOptions) Response {
        return websocket_mod.upgradeWebSocket(self.req, handler, options);
    }

    /// Build a streaming (chunked or content-length) response. The handler is
    /// called once headers are flushed, with a writer that surfaces aborts via
    /// `StreamWriter.isAborted()`.
    ///
    /// The `handler` may be `fn(*StreamWriter) !void` or
    /// `fn(*Context, *StreamWriter) !void`. Captures are not supported; pass
    /// state through `Context.set/get` if needed.
    pub fn stream(
        self: *Context,
        content_type: []const u8,
        comptime handler: anytype,
        options: StreamOptions,
    ) Response {
        return buildStreamResponse(self, content_type, handler, options);
    }

    /// Build a Server-Sent Events response. Sets the appropriate
    /// `text/event-stream` content type and disables buffering caches by
    /// default.
    pub fn sse(self: *Context, comptime handler: anytype) Response {
        return buildSseResponse(self, handler);
    }

    pub fn cookie(
        self: *Context,
        name: []const u8,
        value: []const u8,
        cookie_options: response_mod.CookieOptions,
    ) response_mod.CookieError!void {
        try self.res.cookie(self.req.allocator, name, value, cookie_options);
    }

    pub fn deleteCookie(
        self: *Context,
        name: []const u8,
        delete_options: response_mod.DeleteCookieOptions,
    ) response_mod.CookieError!void {
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

pub const StreamOptions = struct {
    /// When known, the precise body length so the response can use
    /// content-length instead of chunked encoding.
    content_length: ?u64 = null,
};

/// Heap-owned `SharedState`. Used by `App.handle` (and any wrapper that
/// is the first to introduce `SharedState`) so that streaming responses
/// can extend the state's lifetime past the wrapper's stack frame via
/// `Response.attachScope`. Single responsibility: own the `SharedState`
/// and free it (and the bookkeeping wrapper) on deinit.
pub const SharedStateScope = struct {
    allocator: std.mem.Allocator,
    state: *SharedState,

    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*SharedStateScope {
        const scope = try allocator.create(SharedStateScope);
        errdefer allocator.destroy(scope);
        const state = try allocator.create(SharedState);
        state.* = SharedState.init(allocator);
        scope.* = .{ .allocator = allocator, .state = state };
        return scope;
    }

    pub fn deinit(self: *SharedStateScope) void {
        const allocator = self.allocator;
        self.state.deinit();
        allocator.destroy(self.state);
        allocator.destroy(self);
    }

    pub fn deinitOpaque(scope_ptr: *anyopaque) void {
        const self: *SharedStateScope = @ptrCast(@alignCast(scope_ptr));
        self.deinit();
    }
};

/// Heap-owned `Context` plus a duped copy of route params. Borrows the
/// `SharedState` pointer (lifetime is guaranteed by either an inherited
/// outer scope or a sibling `SharedStateScope` attached to the same
/// `Response`). Created by the `wrapContext*` family on entry to each
/// context-aware handler/middleware so that streaming callbacks fired
/// after the wrapper returns still see a valid `*Context`, route params,
/// and `SharedState`.
///
/// The router's `params_storage` is freed shortly after the outer handler
/// returns, so we always dupe params even when state ownership is
/// inherited.
pub const ContextScope = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    params: []request_mod.Param,

    pub fn create(
        allocator: std.mem.Allocator,
        req: Request,
        state: *SharedState,
    ) std.mem.Allocator.Error!*ContextScope {
        const scope = try allocator.create(ContextScope);
        errdefer allocator.destroy(scope);

        const owned_params = try allocator.dupe(request_mod.Param, req.params);
        errdefer allocator.free(owned_params);

        const ctx_ptr = try allocator.create(Context);
        errdefer allocator.destroy(ctx_ptr);

        var scoped_req = req;
        scoped_req.params = owned_params;
        scoped_req.context_state = @ptrCast(state);
        ctx_ptr.* = Context.init(scoped_req);

        scope.* = .{ .allocator = allocator, .ctx = ctx_ptr, .params = owned_params };
        return scope;
    }

    pub fn deinit(self: *ContextScope) void {
        const allocator = self.allocator;
        allocator.destroy(self.ctx);
        allocator.free(self.params);
        allocator.destroy(self);
    }

    pub fn deinitOpaque(scope_ptr: *anyopaque) void {
        const self: *ContextScope = @ptrCast(@alignCast(scope_ptr));
        self.deinit();
    }
};

fn buildStreamResponse(
    self: *Context,
    content_type: []const u8,
    comptime handler: anytype,
    options: StreamOptions,
) Response {
    const Adapter = streamAdapter(@TypeOf(handler), handler);

    return response_mod.stream(content_type, .{
        .ctx = @ptrCast(self),
        .run_fn = Adapter.run,
        .content_length = options.content_length,
    });
}

fn buildSseResponse(self: *Context, comptime handler: anytype) Response {
    const Adapter = sseAdapter(@TypeOf(handler), handler);

    var response = response_mod.sse(.{
        .ctx = @ptrCast(self),
        .run_fn = Adapter.run,
    });
    // Disable proxy buffering (nginx etc.) so events arrive promptly.
    _ = response.appendHeader("cache-control", "no-cache");
    _ = response.appendHeader("x-accel-buffering", "no");
    return response;
}

const StreamHandlerKind = enum { writer_only, with_context };

fn classifyStreamHandler(comptime HandlerType: type, comptime SecondParam: type) StreamHandlerKind {
    const info = streamHandlerFnInfo(HandlerType);
    return switch (info.params.len) {
        1 => blk: {
            const P0 = info.params[0].type orelse @compileError("stream handler params must be concrete types");
            if (P0 != SecondParam) @compileError("single-arg stream handler must take *StreamWriter or *SseWriter");
            break :blk .writer_only;
        },
        2 => blk: {
            const P0 = info.params[0].type orelse @compileError("stream handler params must be concrete types");
            const P1 = info.params[1].type orelse @compileError("stream handler params must be concrete types");
            if (P0 != *Context or P1 != SecondParam) @compileError("two-arg stream handler must be fn(*Context, writer) !void");
            break :blk .with_context;
        },
        else => @compileError("stream handler must take 1 or 2 args"),
    };
}

fn streamHandlerFnInfo(comptime HandlerType: type) std.builtin.Type.Fn {
    return switch (@typeInfo(HandlerType)) {
        .@"fn" => |f| f,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => @compileError("stream handler must be a function"),
        },
        else => @compileError("stream handler must be a function"),
    };
}

fn streamAdapter(comptime HandlerType: type, comptime handler: anytype) type {
    const kind = classifyStreamHandler(HandlerType, *response_mod.StreamWriter);
    return struct {
        // The Adapter is intentionally trivial: it just relays the heap-
        // allocated `*Context` (already kept alive by `StreamingScope` on
        // the outer `Response`) into the user's callback. No per-adapter
        // allocation/dupe is required — the `wrapContextHandler` family
        // owns lifetime management above us.
        fn run(ctx: *const anyopaque, writer: *response_mod.StreamWriter) anyerror!void {
            switch (kind) {
                .writer_only => try handler(writer),
                .with_context => {
                    const c: *Context = @ptrCast(@alignCast(@constCast(ctx)));
                    try handler(c, writer);
                },
            }
        }
    };
}

fn sseAdapter(comptime HandlerType: type, comptime handler: anytype) type {
    const kind = classifyStreamHandler(HandlerType, *response_mod.SseWriter);
    return struct {
        fn run(ctx: *const anyopaque, writer: *response_mod.SseWriter) anyerror!void {
            switch (kind) {
                .writer_only => try handler(writer),
                .with_context => {
                    const c: *Context = @ptrCast(@alignCast(@constCast(ctx)));
                    try handler(c, writer);
                },
            }
        }
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
