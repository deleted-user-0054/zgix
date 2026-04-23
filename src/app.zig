const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const path_mod = @import("path.zig");
const router_mod = @import("router.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const Route = router_mod.Route;
const Router = router_mod.Router;
const Handler = router_mod.Handler;
const ErrorHandler = *const fn (err: anyerror, req: Request) Response;

pub const App = struct {
    const Self = @This();
    const MountTarget = union(enum) {
        app: *Self,
        handler: Handler,
    };

    const Mount = struct {
        prefix: []const u8,
        target: MountTarget,
    };

    const MiddlewareEntry = struct {
        prefix: []const u8,
        handler: DispatchMiddleware,
    };

    const DispatchNext = struct {
        ctx: *const anyopaque,
        run_fn: *const fn (ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: DispatchNext, req: Request) Response {
            return self.run_fn(self.ctx, req);
        }
    };

    const DispatchMiddleware = *const fn (req: Request, next: DispatchNext) Response;

    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
        cookies_raw: ?[]const u8 = null,
    };

    pub const Options = struct {
        strict: bool = true,
        redirect_fixed_path: bool = true,
        handle_method_not_allowed: bool = true,
        handle_options: bool = true,
    };

    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    mounts: std.ArrayListUnmanaged(Mount) = .empty,
    middlewares: std.ArrayListUnmanaged(MiddlewareEntry) = .empty,
    router: ?Router = null,
    finalized: bool = false,
    strict: bool = true,
    base_path: []const u8 = "",
    base_path_owned: ?[]const u8 = null,
    redirect_trailing_slash: bool = true,
    redirect_fixed_path: bool = true,
    handle_method_not_allowed: bool = true,
    handle_options: bool = true,
    not_found_handler: ?Handler = null,
    on_error_handler: ?ErrorHandler = null,
    has_context_handlers: bool = false,
    has_context_middlewares: bool = false,
    has_context_not_found: bool = false,
    has_error_handlers: bool = false,
    has_error_middlewares: bool = false,

    pub fn init(allocator: std.mem.Allocator) App {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, app_options: Options) App {
        return .{
            .allocator = allocator,
            .strict = app_options.strict,
            .redirect_trailing_slash = app_options.strict,
            .redirect_fixed_path = app_options.redirect_fixed_path,
            .handle_method_not_allowed = app_options.handle_method_not_allowed,
            .handle_options = app_options.handle_options,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.router) |*router| router.deinit();
        self.clearBasePath();
        for (self.routes.items) |registered_route| {
            self.allocator.free(registered_route.path);
        }
        self.routes.deinit(self.allocator);
        for (self.mounts.items) |mount_entry| {
            self.allocator.free(mount_entry.prefix);
        }
        self.mounts.deinit(self.allocator);
        for (self.middlewares.items) |middleware_entry| {
            self.allocator.free(middleware_entry.prefix);
        }
        self.middlewares.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.GET, path, handler);
    }

    pub fn head(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.HEAD, path, handler);
    }

    pub fn options(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.OPTIONS, path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.POST, path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.PUT, path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.PATCH, path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.DELETE, path, handler);
    }

    pub fn connect(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.CONNECT, path, handler);
    }

    pub fn trace(self: *App, path: []const u8, handler: anytype) !void {
        try self.addRoute(.TRACE, path, handler);
    }

    pub fn all(self: *App, path: []const u8, handler: anytype) !void {
        const methods = [_]std.http.Method{
            .GET,
            .HEAD,
            .POST,
            .PUT,
            .PATCH,
            .DELETE,
            .OPTIONS,
            .CONNECT,
            .TRACE,
        };

        for (methods) |method| {
            try self.addRoute(method, path, handler);
        }
    }

    pub fn on(self: *App, methods: anytype, paths: anytype, handler: anytype) !void {
        try self.registerOn(methods, paths, handler);
    }

    pub fn use(self: *App, middleware: anytype) !void {
        try self.addMiddleware("/", middleware);
    }

    pub fn useAt(self: *App, path: []const u8, middleware: anytype) !void {
        try self.addMiddleware(path, middleware);
    }

    pub fn basePath(self: *App, path: []const u8) !void {
        if (self.finalized) return error.AppFinalized;

        const normalized = try normalizePrefix(self.allocator, path);
        errdefer self.allocator.free(normalized);

        if (self.base_path_owned) |existing| {
            self.allocator.free(existing);
        }

        if (std.mem.eql(u8, normalized, "/")) {
            self.allocator.free(normalized);
            self.base_path = "";
            self.base_path_owned = null;
            return;
        }

        self.base_path = normalized;
        self.base_path_owned = normalized;
    }

    pub fn route(self: *App, prefix: []const u8, other: *const App) !void {
        if (self.finalized) return error.AppFinalized;

        const combined_prefix = try joinPrefixedPath(self.allocator, self.base_path, prefix);
        defer self.allocator.free(combined_prefix);

        const mounted_prefix = try normalizePrefix(self.allocator, combined_prefix);
        defer self.allocator.free(mounted_prefix);

        for (other.routes.items) |nested| {
            const joined_path = try joinPrefixedPath(self.allocator, mounted_prefix, nested.path);
            const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
            errdefer self.allocator.free(full_path);

            try self.routes.append(self.allocator, .{
                .method = nested.method,
                .path = full_path,
                .handler = nested.handler,
                .base_path = if (!std.mem.eql(u8, mounted_prefix, "/")) mounted_prefix else nested.base_path,
            });
        }

        for (other.middlewares.items) |nested| {
            const nested_path = if (nested.prefix.len == 0) "/" else nested.prefix;
            const full_prefix = try scopedMiddlewarePrefix(self.allocator, mounted_prefix, nested_path);
            errdefer self.allocator.free(full_prefix);

            try self.middlewares.append(self.allocator, .{
                .prefix = full_prefix,
                .handler = nested.handler,
            });
        }

        self.has_context_handlers = self.has_context_handlers or other.has_context_handlers;
        self.has_context_middlewares = self.has_context_middlewares or other.has_context_middlewares;
        self.has_error_handlers = self.has_error_handlers or other.has_error_handlers;
        self.has_error_middlewares = self.has_error_middlewares or other.has_error_middlewares;
    }

    pub fn mount(self: *App, prefix: []const u8, target: anytype) !void {
        if (self.finalized) return error.AppFinalized;

        const combined_prefix = try joinPrefixedPath(self.allocator, self.base_path, prefix);
        defer self.allocator.free(combined_prefix);

        const mounted_prefix = try normalizePrefix(self.allocator, combined_prefix);
        errdefer self.allocator.free(mounted_prefix);

        const resolved = resolveMountTarget(target);
        try self.mounts.append(self.allocator, .{
            .prefix = mounted_prefix,
            .target = resolved.target,
        });
        self.has_context_handlers = self.has_context_handlers or resolved.uses_context;
        self.has_error_handlers = self.has_error_handlers or resolved.uses_error;
    }

    pub fn notFound(self: *App, handler: anytype) void {
        const resolved = resolveHandler(handler);
        self.not_found_handler = resolved.handler;
        self.has_context_not_found = resolved.uses_context;
    }

    pub fn onError(self: *App, handler: anytype) void {
        const resolved = resolveErrorHandler(handler);
        self.on_error_handler = resolved.handler;
    }

    pub fn addRoute(self: *App, method: std.http.Method, path: []const u8, handler: anytype) !void {
        if (self.finalized) return error.AppFinalized;
        const resolved = resolveHandler(handler);
        const joined_path = try joinPrefixedPath(self.allocator, self.base_path, path);
        const full_path = try canonicalizeOwnedPath(self.allocator, joined_path, self.strict);
        errdefer self.allocator.free(full_path);

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = full_path,
            .handler = resolved.handler,
            .base_path = if (self.base_path.len > 0) self.base_path else null,
        });
        self.has_context_handlers = self.has_context_handlers or resolved.uses_context;
        self.has_error_handlers = self.has_error_handlers or resolved.uses_error;
    }

    pub fn addMiddleware(self: *App, path: []const u8, middleware: anytype) !void {
        if (self.finalized) return error.AppFinalized;

        const scoped_prefix = try scopedMiddlewarePrefix(self.allocator, self.base_path, path);
        errdefer self.allocator.free(scoped_prefix);

        const resolved = resolveMiddlewareHandler(middleware);

        try self.middlewares.append(self.allocator, .{
            .prefix = scoped_prefix,
            .handler = resolved.handler,
        });
        self.has_context_middlewares = self.has_context_middlewares or resolved.uses_context;
        self.has_error_middlewares = self.has_error_middlewares or resolved.uses_error;
    }

    pub fn finalize(self: *App) !void {
        if (self.finalized) return;
        self.router = try Router.init(self.allocator, self.routes.items);
        self.finalized = true;
    }

    pub fn handle(self: *App, req: Request) Response {
        if (!self.finalized) self.finalize() catch return response_mod.internalError("router init failed");
        if (!self.usesSharedState()) {
            if (self.middlewares.items.len == 0) return self.handleEndpoint(req);
            return self.runMiddlewares(req, 0);
        }

        var handled_req = req;
        const owns_context_state = handled_req.context_state == null;

        // When this App is the first to introduce shared state, allocate it
        // via the same uniform `SharedStateScope` that the wrapper family
        // uses, so that streaming responses can extend its lifetime through
        // `Response.finalizeScope`. For inherited state, the caller already
        // owns it and we must not free it.
        const owned_state_scope: ?*context_mod.SharedStateScope = if (owns_context_state) blk: {
            const s = context_mod.SharedStateScope.create(handled_req.allocator) catch
                return response_mod.internalError("context alloc failed");
            handled_req.context_state = @ptrCast(s.state);
            break :blk s;
        } else null;

        const state: *context_mod.SharedState = @ptrCast(@alignCast(handled_req.context_state.?));
        const previous_not_found_handler = state.not_found_handler;
        const previous_on_error_handler = state.on_error_handler;
        state.not_found_handler = self.not_found_handler;
        state.on_error_handler = self.on_error_handler;

        var response = if (self.middlewares.items.len == 0)
            self.handleEndpoint(handled_req)
        else
            self.runMiddlewares(handled_req, 0);

        if (owned_state_scope) |s| {
            response.finalizeScope(
                handled_req.allocator,
                @ptrCast(s),
                context_mod.SharedStateScope.deinitOpaque,
            );
        } else {
            // Inherited state — restore handler slots we mutated above so
            // the caller observes no side effects.
            state.on_error_handler = previous_on_error_handler;
            state.not_found_handler = previous_not_found_handler;
        }

        return response;
    }

    fn runMiddlewares(self: *App, req: Request, start_index: usize) Response {
        var middleware_index = start_index;
        while (middleware_index < self.middlewares.items.len) : (middleware_index += 1) {
            const middleware_entry = self.middlewares.items[middleware_index];
            if (!middlewareMatches(middleware_entry.prefix, req.path, self.strict)) continue;

            const frame = MiddlewareFrame{
                .app = self,
                .next_index = middleware_index + 1,
            };
            return middleware_entry.handler(req, .{
                .ctx = &frame,
                .run_fn = runMiddlewareNext,
            });
        }

        return self.handleEndpoint(req);
    }

    fn handleEndpoint(self: *App, req: Request) Response {
        const router = &self.router.?;
        var lookup_req = req;
        lookup_req.path = canonicalPath(req.path, self.strict);
        const lookup = router.lookup(lookup_req);
        if (lookup.handler) |handler| {
            defer if (lookup.params_storage) |storage| req.allocator.free(storage);
            var routed_req = req;
            routed_req.params = lookup.params;
            return handler(routed_req);
        }

        if (matchMount(self.mounts.items, req.path)) |matched_mount| {
            var mounted_req = req;
            mounted_req.path = matched_mount.path;
            return dispatchMount(matched_mount.mount.target, mounted_req);
        }

        if (self.redirect_trailing_slash and lookup.tsr and !std.mem.eql(u8, req.path, "/")) {
            if (trailingSlashVariant(req.allocator, req.path) catch null) |redirect_path| {
                const owns_redirect_path = redirect_path.ptr != req.path.ptr;
                const location = appendQuery(req.allocator, redirect_path, req.query_string) catch redirect_path;
                var res = response_mod.redirect(req.method, location);
                if (res.ensureOwned(req.allocator)) {
                    if (owns_redirect_path) req.allocator.free(redirect_path);
                    if (location.ptr != redirect_path.ptr) req.allocator.free(location);
                } else |_| {}
                return res;
            }
        }

        if (self.redirect_fixed_path) {
            const cleaned = path_mod.cleanPath(req.allocator, lookup_req.path) catch lookup_req.path;
            defer if (cleaned.ptr != lookup_req.path.ptr) req.allocator.free(cleaned);
            if (router.findCaseInsensitivePath(req.allocator, req.method, cleaned, true) catch null) |fixed| {
                const location = appendQuery(req.allocator, fixed, req.query_string) catch fixed;
                var res = response_mod.redirect(req.method, location);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(fixed);
                    if (location.ptr != fixed.ptr) req.allocator.free(location);
                } else |_| {}
                return res;
            }
        }

        if (req.method == .OPTIONS and self.handle_options) {
            if (router.allowed(req.allocator, lookup_req.path, req.method, self.handle_options) catch null) |allow| {
                var res = response_mod.options(allow);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(allow);
                } else |_| {}
                return res;
            }
        }

        if (self.handle_method_not_allowed) {
            if (router.allowed(req.allocator, lookup_req.path, req.method, self.handle_options) catch null) |allow| {
                var res = response_mod.methodNotAllowed(allow);
                if (res.ensureOwned(req.allocator)) {
                    req.allocator.free(allow);
                } else |_| {}
                return res;
            }
        }

        if (self.not_found_handler) |handler| {
            return handler(req);
        }

        return response_mod.notFound();
    }

    pub fn fetch(self: *App, req: Request) Response {
        return self.handle(req);
    }

    pub fn request(self: *App, allocator: std.mem.Allocator, input: anytype, req_options: RequestOptions) !Response {
        const InputType = @TypeOf(input);
        if (InputType == Request) {
            return try self.cloneHandledResponse(allocator, input);
        }
        if (InputType == *const Request or InputType == *Request) {
            return try self.cloneHandledResponse(allocator, input.*);
        }
        if (!comptime isStringLike(InputType)) {
            @compileError("App.request input must be a zono.Request, *zono.Request, or a string-like target.");
        }

        const target: []const u8 = input;
        return try self.requestTarget(allocator, target, req_options);
    }

    pub fn showRoutes(self: *const App, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        for (self.middlewares.items) |middleware_entry| {
            try out.writer.print("USE {s}\n", .{middleware_entry.prefix});
        }
        for (self.mounts.items) |mount_entry| {
            const target_kind = switch (mount_entry.target) {
                .app => "app",
                .handler => "handler",
            };
            try out.writer.print("MOUNT {s} [{s}]\n", .{ mount_entry.prefix, target_kind });
        }
        for (self.routes.items) |registered_route| {
            try out.writer.print("{s} {s}\n", .{ @tagName(registered_route.method), registered_route.path });
        }

        return try out.toOwnedSlice();
    }

    fn requestTarget(self: *App, allocator: std.mem.Allocator, target: []const u8, req_options: RequestOptions) !Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const temp_allocator = arena.allocator();
        const split = try splitRequestTarget(temp_allocator, target);

        var req = Request.init(temp_allocator, req_options.method, split.path);
        req.query_string = split.query_string;
        req.header_list = req_options.headers;
        req.body = req_options.body;
        req.cookies_raw = req_options.cookies_raw orelse "";

        var response = self.handle(req);
        defer response.deinit();
        return try materializeResponse(allocator, &response);
    }

    fn cloneHandledResponse(self: *App, allocator: std.mem.Allocator, req: Request) !Response {
        var response = self.handle(req);
        defer response.deinit();
        return try materializeResponse(allocator, &response);
    }

    /// Renders a handled response into an owned, buffered `Response` suitable
    /// for inspection by tests or programmatic callers. Streaming bodies are
    /// drained into memory via `renderStreamingToBuffered`.
    fn materializeResponse(allocator: std.mem.Allocator, response: *response_mod.Response) !Response {
        return switch (response.body_kind) {
            .buffered => try response.clone(allocator),
            .stream, .sse, .file => try response.renderStreamingToBuffered(allocator),
        };
    }

    fn registerOn(self: *App, methods: anytype, paths: anytype, handler: anytype) !void {
        const MethodsType = @TypeOf(methods);
        if (MethodsType == std.http.Method) {
            try self.registerPaths(methods, paths, handler);
            return;
        }

        switch (comptime @typeInfo(MethodsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (methods) |method| {
                        try self.registerPaths(method, paths, handler);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (methods.*) |method| {
                            try self.registerPaths(method, paths, handler);
                        }
                    },
                    else => @compileError("App.on methods pointer must reference an array of std.http.Method values."),
                },
                else => @compileError("App.on methods must be a std.http.Method or an iterable of methods."),
            },
            .array => {
                for (methods) |method| {
                    try self.registerPaths(method, paths, handler);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.on methods must be a std.http.Method or an iterable of methods.");
                }
                inline for (methods) |method| {
                    try self.registerPaths(method, paths, handler);
                }
            },
            else => @compileError("App.on methods must be a std.http.Method or an iterable of methods."),
        }
    }

    fn registerPaths(self: *App, method: std.http.Method, paths: anytype, handler: anytype) !void {
        const PathsType = @TypeOf(paths);
        if (comptime isStringLike(PathsType)) {
            const path_slice: []const u8 = paths;
            try self.addRoute(method, path_slice, handler);
            return;
        }

        switch (comptime @typeInfo(PathsType)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    for (paths) |path| {
                        const path_slice: []const u8 = path;
                        try self.addRoute(method, path_slice, handler);
                    }
                },
                .one => switch (@typeInfo(pointer.child)) {
                    .array => {
                        for (paths.*) |path| {
                            const path_slice: []const u8 = path;
                            try self.addRoute(method, path_slice, handler);
                        }
                    },
                    else => @compileError("App.on paths pointer must reference an array of route paths."),
                },
                else => @compileError("App.on paths must be a route path or an iterable of route paths."),
            },
            .array => {
                for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addRoute(method, path_slice, handler);
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) {
                    @compileError("App.on paths must be a route path or an iterable of route paths.");
                }
                inline for (paths) |path| {
                    const path_slice: []const u8 = path;
                    try self.addRoute(method, path_slice, handler);
                }
            },
            else => @compileError("App.on paths must be a route path or an iterable of route paths."),
        }
    }

    fn clearBasePath(self: *App) void {
        if (self.base_path_owned) |owned| {
            self.allocator.free(owned);
        }
        self.base_path = "";
        self.base_path_owned = null;
    }

    fn usesSharedState(self: *const App) bool {
        return self.has_context_handlers or
            self.has_context_middlewares or
            self.has_context_not_found or
            self.has_error_handlers or
            self.has_error_middlewares;
    }
};

const MiddlewareFrame = struct {
    app: *App,
    next_index: usize,
};

fn runMiddlewareNext(ctx: *const anyopaque, req: Request) Response {
    const frame: *const MiddlewareFrame = @ptrCast(@alignCast(ctx));
    return frame.app.runMiddlewares(req, frame.next_index);
}

const MountMatch = struct {
    mount: *const App.Mount,
    path: []const u8,
};

fn trailingSlashVariant(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (path.len <= 1) return null;

    if (path[path.len - 1] == '/') return path[0 .. path.len - 1];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, path);
    try out.append(allocator, '/');
    return try out.toOwnedSlice(allocator);
}

fn appendQuery(allocator: std.mem.Allocator, path: []const u8, query_string: []const u8) ![]const u8 {
    if (query_string.len == 0) return path;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, path);
    try out.append(allocator, '?');
    try out.appendSlice(allocator, query_string);
    return try out.toOwnedSlice(allocator);
}

fn normalizePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const cleaned = try path_mod.cleanPath(allocator, prefix);
    errdefer allocator.free(cleaned);

    if (cleaned.len > 1 and cleaned[cleaned.len - 1] == '/') {
        const trimmed = try allocator.dupe(u8, cleaned[0 .. cleaned.len - 1]);
        allocator.free(cleaned);
        return trimmed;
    }

    return cleaned;
}

fn normalizeMiddlewarePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const normalized = try normalizePrefix(allocator, prefix);
    errdefer allocator.free(normalized);

    if (normalized.len == 0 or std.mem.eql(u8, normalized, "/")) {
        allocator.free(normalized);
        return try allocator.dupe(u8, "");
    }

    return normalized;
}

fn scopedMiddlewarePrefix(allocator: std.mem.Allocator, base_path: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "*") or std.mem.eql(u8, path, "/*")) {
        if (base_path.len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, base_path);
    }

    const joined_path = try joinPrefixedPath(allocator, base_path, path);
    defer allocator.free(joined_path);
    return try normalizeMiddlewarePrefix(allocator, joined_path);
}

fn middlewareMatches(prefix: []const u8, path: []const u8, strict: bool) bool {
    if (prefix.len == 0) return true;

    const candidate_path = canonicalPath(path, strict);
    if (std.mem.eql(u8, candidate_path, prefix)) return true;

    return candidate_path.len > prefix.len and
        std.mem.startsWith(u8, candidate_path, prefix) and
        candidate_path[prefix.len] == '/';
}

fn joinPrefixedPath(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    const normalized_prefix = if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) "" else prefix;
    const route_path = if (path.len == 0) "/" else path;

    if (normalized_prefix.len == 0) {
        if (route_path[0] == '/') return try allocator.dupe(u8, route_path);

        var root_prefixed: std.ArrayListUnmanaged(u8) = .empty;
        errdefer root_prefixed.deinit(allocator);
        try root_prefixed.append(allocator, '/');
        try root_prefixed.appendSlice(allocator, route_path);
        return try root_prefixed.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, route_path, "/")) {
        return try allocator.dupe(u8, normalized_prefix);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, normalized_prefix);
    if (route_path[0] != '/') try out.append(allocator, '/');
    try out.appendSlice(allocator, route_path);
    return try out.toOwnedSlice(allocator);
}

fn canonicalPath(path: []const u8, strict: bool) []const u8 {
    if (strict or path.len <= 1 or path[path.len - 1] != '/') return path;
    return path[0 .. path.len - 1];
}

fn canonicalizeOwnedPath(allocator: std.mem.Allocator, path: []const u8, strict: bool) ![]const u8 {
    const canonical = canonicalPath(path, strict);
    if (canonical.len == path.len) return path;

    const owned = try allocator.dupe(u8, canonical);
    allocator.free(path);
    return owned;
}

const ResolvedMountTarget = struct {
    target: App.MountTarget,
    uses_context: bool = false,
    uses_error: bool = false,
};

fn resolveMountTarget(target: anytype) ResolvedMountTarget {
    const TargetType = @TypeOf(target);
    if (TargetType == *App) return .{ .target = .{ .app = target } };
    if (TargetType == *const App) return .{ .target = .{ .app = @constCast(target) } };
    if (TargetType == Handler) return .{ .target = .{ .handler = target } };

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => blk: {
            const resolved = resolveHandler(target);
            break :blk .{
                .target = .{ .handler = resolved.handler },
                .uses_context = resolved.uses_context,
                .uses_error = resolved.uses_error,
            };
        },
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => blk: {
                const resolved = resolveHandler(target);
                break :blk .{
                    .target = .{ .handler = resolved.handler },
                    .uses_context = resolved.uses_context,
                    .uses_error = resolved.uses_error,
                };
            },
            else => @compileError("App.mount target must be a *zono.App or a compatible handler."),
        },
        else => @compileError("App.mount target must be a *zono.App or a compatible handler."),
    };
}

const ResolvedHandler = struct {
    handler: Handler,
    uses_context: bool,
    uses_error: bool,
};

const ResolvedMiddleware = struct {
    handler: App.DispatchMiddleware,
    uses_context: bool,
    uses_error: bool,
};

const ResolvedErrorHandler = struct {
    handler: ErrorHandler,
};

fn resolveHandler(target: anytype) ResolvedHandler {
    const TargetType = @TypeOf(target);
    if (TargetType == Handler) {
        return .{
            .handler = target,
            .uses_context = false,
            .uses_error = false,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"struct" => |struct_info| switch (struct_info.is_tuple) {
            true => resolveHandlerChain(target, TargetType),
            false => @compileError("Route handlers must be a compatible handler or a tuple like .{ middleware, handler }."),
        },
        .@"fn" => resolveHandlerFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveHandlerFn(target, pointer.child),
            else => @compileError("Route handlers must be fn(c: *zono.Context) zono.Response or fn(c: *zono.Context) !zono.Response."),
        },
        else => @compileError("Route handlers must be fn(c: *zono.Context) zono.Response, fn(c: *zono.Context) !zono.Response, or a tuple like .{ middleware, handler }."),
    };
}

fn resolveHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedHandler {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Route handlers");
    if (info.params.len != 1 or info.params[0].type == null) {
        @compileError("Route handlers must accept exactly one parameter.");
    }

    const ParamType = info.params[0].type.?;
    if (ParamType == *Context) {
        if (returns_error) {
            return .{
                .handler = wrapContextErrorHandler(target),
                .uses_context = true,
                .uses_error = true,
            };
        }
        return .{
            .handler = wrapContextHandler(target),
            .uses_context = true,
            .uses_error = false,
        };
    }

    @compileError("Route handlers must be fn(c: *zono.Context) zono.Response or fn(c: *zono.Context) !zono.Response.");
}

fn resolveHandlerChain(target: anytype, comptime TargetType: type) ResolvedHandler {
    const fields = std.meta.fields(TargetType);
    if (fields.len == 0) {
        @compileError("Route handler tuples must contain at least one handler.");
    }

    comptime var uses_error = false;

    if (fields.len == 1) {
        const resolved = resolveHandler(@field(target, fields[0].name));
        return resolved;
    }

    const middleware_count = fields.len - 1;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        const resolved = comptime resolveMiddlewareHandler(item);
        uses_error = uses_error or resolved.uses_error;
    }

    comptime var middlewares: [middleware_count]App.DispatchMiddleware = undefined;
    comptime var middleware_index: usize = 0;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        const resolved = comptime resolveMiddlewareHandler(item);
        middlewares[middleware_index] = resolved.handler;
        middleware_index += 1;
    }

    const final_resolved = comptime resolveHandler(@field(target, fields[fields.len - 1].name));
    uses_error = uses_error or final_resolved.uses_error;

    return .{
        .handler = wrapRouteChain(middlewares, final_resolved.handler),
        .uses_context = true,
        .uses_error = uses_error,
    };
}

fn resolveMiddlewareHandler(target: anytype) ResolvedMiddleware {
    const TargetType = @TypeOf(target);
    if (TargetType == App.DispatchMiddleware) {
        return .{
            .handler = target,
            .uses_context = true,
            .uses_error = false,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveMiddlewareFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveMiddlewareFn(target, pointer.child),
            else => @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
        },
        else => @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
    };
}

fn resolveMiddlewareFn(comptime target: anytype, comptime FnType: type) ResolvedMiddleware {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Middleware handlers");
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("Middleware handlers must accept exactly two parameters.");
    }

    const FirstParam = info.params[0].type.?;
    const SecondParam = info.params[1].type.?;
    if (FirstParam == *Context and SecondParam == Context.Next) {
        if (returns_error) {
            return .{
                .handler = wrapContextErrorMiddleware(target),
                .uses_context = true,
                .uses_error = true,
            };
        }
        return .{
            .handler = wrapContextMiddleware(target),
            .uses_context = true,
            .uses_error = false,
        };
    }

    @compileError("App.use middleware must be fn(c: *zono.Context, next: zono.Context.Next) zono.Response or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response.");
}

fn resolveErrorHandler(target: anytype) ResolvedErrorHandler {
    const TargetType = @TypeOf(target);
    if (TargetType == ErrorHandler) {
        return .{
            .handler = target,
        };
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveErrorHandlerFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveErrorHandlerFn(target, pointer.child),
            else => @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response."),
        },
        else => @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response."),
    };
}

fn resolveErrorHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedErrorHandler {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "App.onError handlers");
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("App.onError handlers must accept exactly two parameters.");
    }
    if (info.params[0].type.? != anyerror) {
        @compileError("App.onError handlers must accept err: anyerror as the first parameter.");
    }

    const ParamType = info.params[1].type.?;
    if (ParamType == *Context) {
        return .{
            .handler = wrapContextErrorResponder(target, returns_error),
        };
    }

    @compileError("App.onError handlers must be fn(err: anyerror, c: *zono.Context) zono.Response or fn(err: anyerror, c: *zono.Context) !zono.Response.");
}

fn returnsErrorResponse(comptime return_type: ?type, comptime owner: []const u8) bool {
    if (return_type == null) {
        @compileError(owner ++ " must return zono.Response or !zono.Response.");
    }

    const ReturnType = return_type.?;
    if (ReturnType == Response) return false;

    return switch (@typeInfo(ReturnType)) {
        .error_union => |error_union| blk: {
            if (error_union.payload != Response) {
                @compileError(owner ++ " must return zono.Response or !zono.Response.");
            }
            break :blk true;
        },
        else => @compileError(owner ++ " must return zono.Response or !zono.Response."),
    };
}

/// Per-handler/middleware scope bundle. Always carries a `ContextScope`
/// (the heap `Context` + duped params). When this wrapper is the first to
/// introduce `SharedState` (i.e. nothing in the outer chain provided
/// one), it also carries a `SharedStateScope` that owns that state. The
/// two scopes are attached to the response in order so that on deinit the
/// `Context` is freed before the `SharedState` it borrows from.
const HandlerScope = struct {
    state_scope: ?*context_mod.SharedStateScope,
    ctx_scope: *context_mod.ContextScope,
};

/// Heap-allocates the scope bundle for a context-aware handler. If the
/// inbound request already has a `context_state`, the scope inherits it;
/// otherwise a fresh `SharedState` is owned by `state_scope`. Returns
/// `null` on allocation failure.
fn createHandlerScope(req: Request) ?HandlerScope {
    const inherited_state: ?*context_mod.SharedState = if (req.context_state) |raw|
        @ptrCast(@alignCast(raw))
    else
        null;

    var owned_state_scope: ?*context_mod.SharedStateScope = null;
    if (inherited_state == null) {
        owned_state_scope = context_mod.SharedStateScope.create(req.allocator) catch return null;
    }
    errdefer if (owned_state_scope) |s| s.deinit();

    const state = inherited_state orelse owned_state_scope.?.state;

    const ctx_scope = context_mod.ContextScope.create(req.allocator, req, state) catch {
        if (owned_state_scope) |s| s.deinit();
        return null;
    };

    return .{ .state_scope = owned_state_scope, .ctx_scope = ctx_scope };
}

/// Finalizes a `HandlerScope` after the user handler returns: each scope
/// is either attached to the response (extending its lifetime past this
/// frame) or freed immediately, via `Response.finalizeScope`.
///
/// Attach order matters: the state scope goes on first so that on deinit
/// the `Context` (which borrows the state) is freed before the state.
fn finalizeHandlerScope(scope: HandlerScope, response: *Response) void {
    const allocator = scope.ctx_scope.allocator;
    if (scope.state_scope) |s| {
        response.finalizeScope(allocator, @ptrCast(s), context_mod.SharedStateScope.deinitOpaque);
    }
    response.finalizeScope(allocator, @ptrCast(scope.ctx_scope), context_mod.ContextScope.deinitOpaque);
}

fn wrapContextHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextErrorHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx) catch |err| dispatchHandlerError(scope.ctx_scope.ctx.req, err);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextMiddleware(comptime target: anytype) App.DispatchMiddleware {
    return struct {
        fn run(req: Request, next: App.DispatchNext) Response {
            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx, .{
                .ctx = scope.ctx_scope.ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            });
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextErrorMiddleware(comptime target: anytype) App.DispatchMiddleware {
    return struct {
        fn run(req: Request, next: App.DispatchNext) Response {
            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            var response = target(scope.ctx_scope.ctx, .{
                .ctx = scope.ctx_scope.ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            }) catch |err| dispatchHandlerError(scope.ctx_scope.ctx.req, err);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn wrapContextErrorResponder(comptime target: anytype, comptime returns_error: bool) ErrorHandler {
    return struct {
        fn run(err: anyerror, req: Request) Response {
            const scope = createHandlerScope(req) orelse
                return response_mod.internalError("context alloc failed");
            scope.ctx_scope.ctx.state.last_error = err;
            scope.ctx_scope.ctx.err = err;
            var response = if (returns_error)
                target(err, scope.ctx_scope.ctx) catch |hook_err|
                    dispatchHandlerError(scope.ctx_scope.ctx.req, hook_err)
            else
                target(err, scope.ctx_scope.ctx);
            finalizeHandlerScope(scope, &response);
            return response;
        }
    }.run;
}

fn runContextMiddlewareNext(next_ctx: *const anyopaque, req: Request) Response {
    const next: *const App.DispatchNext = @ptrCast(@alignCast(next_ctx));
    return next.run(req);
}

fn dispatchHandlerError(req: Request, err: anyerror) Response {
    if (req.context_state) |raw_state| {
        const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
        state.last_error = err;
        // Reentry guard: if we're already inside the user's onError, do NOT
        // call it again — fall through to the static 500. Otherwise we'd
        // recurse forever when the hook itself returns/throws an error.
        if (state.in_error_handler) {
            return response_mod.text(.internal_server_error, "Internal Server Error");
        }
        if (state.on_error_handler) |handler| {
            state.in_error_handler = true;
            defer state.in_error_handler = false;
            return handler(err, req);
        }
    }

    return response_mod.text(.internal_server_error, "Internal Server Error");
}

fn wrapRouteChain(comptime middlewares: anytype, comptime final_handler: Handler) Handler {
    return struct {
        const chain_middlewares = middlewares;
        const chain_final_handler = final_handler;

        const Frame = struct {
            next_index: usize,
        };

        fn run(req: Request) Response {
            return runFrom(req, 0);
        }

        fn runFrom(req: Request, index: usize) Response {
            if (index >= chain_middlewares.len) {
                return chain_final_handler(req);
            }

            const frame = Frame{
                .next_index = index + 1,
            };
            return chain_middlewares[index](req, .{
                .ctx = &frame,
                .run_fn = runNext,
            });
        }

        fn runNext(ctx: *const anyopaque, req: Request) Response {
            const frame: *const Frame = @ptrCast(@alignCast(ctx));
            return runFrom(req, frame.next_index);
        }
    }.run;
}

fn dispatchMount(target: App.MountTarget, req: Request) Response {
    return switch (target) {
        .app => |mounted_app| mounted_app.handle(req),
        .handler => |handler| handler(req),
    };
}

fn matchMount(mounts: []const App.Mount, path: []const u8) ?MountMatch {
    var best: ?MountMatch = null;

    for (mounts) |*mount_entry| {
        const mounted_path = stripMountPrefix(path, mount_entry.prefix) orelse continue;
        if (best == null or mount_entry.prefix.len > best.?.mount.prefix.len) {
            best = .{
                .mount = mount_entry,
                .path = mounted_path,
            };
        }
    }

    return best;
}

fn stripMountPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "/")) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return "/";
    if (path[prefix.len] != '/') return null;
    return path[prefix.len..];
}

const SplitTarget = struct {
    path: []const u8,
    query_string: []const u8,
};

fn splitRequestTarget(allocator: std.mem.Allocator, target: []const u8) !SplitTarget {
    var path_and_query = target;

    if (std.mem.indexOf(u8, target, "://")) |scheme_index| {
        const authority_start = scheme_index + 3;
        const path_index = std.mem.indexOfScalarPos(u8, target, authority_start, '/') orelse target.len;
        const query_index = std.mem.indexOfScalarPos(u8, target, authority_start, '?') orelse target.len;
        const first_index = @min(path_index, query_index);

        if (first_index == target.len) {
            path_and_query = "/";
        } else {
            path_and_query = target[first_index..];
        }
    }

    const query_index = std.mem.indexOfScalar(u8, path_and_query, '?');
    const raw_path = if (query_index) |index|
        if (index == 0) "/" else path_and_query[0..index]
    else if (path_and_query.len == 0)
        "/"
    else
        path_and_query;

    const path = if (raw_path.len > 0 and raw_path[0] == '/')
        raw_path
    else blk: {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.append(allocator, '/');
        try out.appendSlice(allocator, raw_path);
        break :blk try out.toOwnedSlice(allocator);
    };

    return .{
        .path = path,
        .query_string = if (query_index) |index|
            if (index + 1 < path_and_query.len) path_and_query[index + 1 ..] else ""
        else
            "",
    };
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

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "content-type")) return res.content_type;
    if (std.ascii.eqlIgnoreCase(name, "location")) return res.location;
    if (std.ascii.eqlIgnoreCase(name, "allow")) return res.allow;

    for (res.extraHeaders()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }

    return null;
}

test "app dispatches through finalized router" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "app redirects trailing slash misses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/health/"));
    try std.testing.expectEqual(std.http.Status.moved_permanently, res.status);
    try std.testing.expectEqualStrings("/health", res.location.?);
}

test "app automatically answers OPTIONS and 405" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/users", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const options_res = app.handle(Request.init(arena.allocator(), .OPTIONS, "/users"));
    try std.testing.expectEqual(std.http.Status.no_content, options_res.status);
    try std.testing.expectEqualStrings("GET, OPTIONS", options_res.allow.?);

    const post_res = app.handle(Request.init(arena.allocator(), .POST, "/users"));
    try std.testing.expectEqual(std.http.Status.method_not_allowed, post_res.status);
    try std.testing.expectEqualStrings("GET, OPTIONS", post_res.allow.?);
}

test "app strict false treats trailing slash variants as the same route" {
    var app = App.initWithOptions(std.testing.allocator, .{
        .strict = false,
    });
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/health/", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.path);
        }
    }.run);

    const no_slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, no_slash_res.status);
    try std.testing.expectEqualStrings("/health", no_slash_res.body);

    const slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health/"));
    try std.testing.expectEqual(std.http.Status.ok, slash_res.status);
    try std.testing.expectEqualStrings("/health/", slash_res.body);
}

test "app basePath and route compose prefixed sub-apps" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var users = App.init(std.testing.allocator);
    defer users.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.basePath("/api/");
    try users.get("/", struct {
        fn list(c: *Context) Response {
            return c.text("users");
        }
    }.list);
    try users.get("/:id", struct {
        fn detail(c: *Context) Response {
            return c.text(c.req.param("id") orelse "missing");
        }
    }.detail);
    try app.route("/users/", &users);

    const list_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users"));
    try std.testing.expectEqualStrings("users", list_res.body);

    const detail_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users/42"));
    try std.testing.expectEqualStrings("42", detail_res.body);
}

test "app use wraps downstream responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            _ = c.header("x-middleware", "yes");
            return c.takeResponse();
        }
    }.run);
    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("yes", responseHeaderValue(res, "x-middleware").?);
}

test "app useAt applies middleware to matching prefixes only" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.useAt("/admin", struct {
        fn run(c: *Context, next: Context.Next) Response {
            if (!std.mem.eql(u8, c.req.header("x-admin") orelse "", "1")) {
                return c.textWithStatus(.unauthorized, "denied");
            }
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/admin/panel", struct {
        fn run(c: *Context) Response {
            return c.text("secret");
        }
    }.run);
    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const denied = app.handle(Request.init(arena.allocator(), .GET, "/admin/panel"));
    try std.testing.expectEqual(std.http.Status.unauthorized, denied.status);
    try std.testing.expectEqualStrings("denied", denied.body);

    const public = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, public.status);
    try std.testing.expectEqualStrings("ok", public.body);
}

test "app context middleware can set values for context handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.set("message", "hello from context") catch return response_mod.internalError("set failed");
            c.set("status_code", std.http.Status.accepted) catch return response_mod.internalError("set failed");
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx", struct {
        fn run(c: *Context) Response {
            const message = c.get([]const u8, "message") orelse return response_mod.internalError("missing message");
            const status_code = c.get(std.http.Status, "status_code") orelse return response_mod.internalError("missing status");
            c.status(status_code);
            return c.text(message);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx"));
    try std.testing.expectEqual(std.http.Status.accepted, res.status);
    try std.testing.expectEqualStrings("hello from context", res.body);
}

test "app onError handles context handler errors" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            c.status(if (err == error.Forbidden) .forbidden else .internal_server_error);
            _ = c.header("x-error", @errorName(err));
            return c.text(c.req.path);
        }
    }.run);
    try app.get("/ctx-boom", struct {
        fn run(c: *Context) !Response {
            _ = c.header("x-before", "1");
            return error.Forbidden;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-boom"));
    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
    try std.testing.expectEqualStrings("/ctx-boom", res.body);
    try std.testing.expectEqualStrings("Forbidden", responseHeaderValue(res, "x-error").?);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-before").?);
}

test "app context middleware can inspect c.err after next.run" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            c.status(.bad_request);
            return c.text(@errorName(err));
        }
    }.run);
    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            if (c.err != null) {
                _ = c.header("x-error-seen", "1");
            }
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx-error", struct {
        fn run(_: *Context) !Response {
            return error.Boom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-error"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("Boom", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-error-seen").?);
}

test "app route tuples support context middleware and handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/tuple-ctx", .{
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                c.set("message", "from tuple") catch return response_mod.internalError("set failed");
                next.run();
                _ = c.header("x-context-route", "1");
                return c.takeResponse();
            }
        }.run,
        struct {
            fn run(c: *Context) Response {
                return c.text(c.vars.get([]const u8, "message") orelse "missing");
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/tuple-ctx"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("from tuple", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-context-route").?);
}

test "app mount delegates prefixed requests to mounted apps" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var mounted = App.init(std.testing.allocator);
    defer mounted.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mounted.get("/", struct {
        fn root(c: *Context) Response {
            return c.text("mounted root");
        }
    }.root);
    try mounted.get("/hello", struct {
        fn hello(c: *Context) Response {
            return c.text("mounted hello");
        }
    }.hello);
    try app.mount("/nested", &mounted);

    const root_res = app.handle(Request.init(arena.allocator(), .GET, "/nested"));
    try std.testing.expectEqual(std.http.Status.ok, root_res.status);
    try std.testing.expectEqualStrings("mounted root", root_res.body);

    const hello_res = app.handle(Request.init(arena.allocator(), .GET, "/nested/hello"));
    try std.testing.expectEqual(std.http.Status.ok, hello_res.status);
    try std.testing.expectEqualStrings("mounted hello", hello_res.body);
}

test "app on registers multiple methods and paths" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.on(.{ .PUT, .DELETE }, .{ "/posts", "/authors" }, struct {
        fn run(c: *Context) Response {
            return c.text("multi");
        }
    }.run);

    const put_res = app.handle(Request.init(arena.allocator(), .PUT, "/posts"));
    const delete_res = app.handle(Request.init(arena.allocator(), .DELETE, "/authors"));
    try std.testing.expectEqualStrings("multi", put_res.body);
    try std.testing.expectEqualStrings("multi", delete_res.body);
}

test "app all registers all common methods" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.all("/echo", struct {
        fn run(c: *Context) Response {
            return c.text(@tagName(c.req.method));
        }
    }.run);

    const get_res = app.handle(Request.init(arena.allocator(), .GET, "/echo"));
    const trace_res = app.handle(Request.init(arena.allocator(), .TRACE, "/echo"));

    try std.testing.expectEqualStrings("GET", get_res.body);
    try std.testing.expectEqualStrings("TRACE", trace_res.body);
}

test "app custom notFound handler accepts context handlers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.notFound(struct {
        fn run(c: *Context) Response {
            c.status(.not_found);
            _ = c.header("x-miss", "1");
            return c.text(c.req.path);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/missing"));
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqualStrings("/missing", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-miss").?);
}

test "app request helper dispatches with query headers and body" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.post("/search", struct {
        fn run(c: *Context) Response {
            if (!std.mem.eql(u8, c.req.query("q") orelse "", "zig")) return c.textWithStatus(.bad_request, "bad query");
            if (!std.mem.eql(u8, c.req.header("x-mode") orelse "", "test")) return c.textWithStatus(.bad_request, "bad header");
            if (!std.mem.eql(u8, c.req.text(), "payload")) return c.textWithStatus(.bad_request, "bad body");
            return c.text("ok");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{
        .method = .POST,
        .headers = &.{.{ .name = "x-mode", .value = "test" }},
        .body = "payload",
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "app request helper accepts absolute urls" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/hello", struct {
        fn run(c: *Context) Response {
            return c.text(c.req.query("name") orelse "missing");
        }
    }.run);

    var res = try app.request(std.testing.allocator, "https://example.com/hello?name=zono", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("zono", res.body);
}

test "app request helper accepts zono request values" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.post("/submit", struct {
        fn run(c: *Context) Response {
            if (!std.mem.eql(u8, c.req.query("draft") orelse "", "1")) return c.textWithStatus(.bad_request, "bad query");
            return c.textWithStatus(.created, c.req.text());
        }
    }.run);

    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.query_string = "draft=1";
    req.body = "payload";

    var res = try app.request(std.testing.allocator, req, .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("payload", res.body);
}

test "app request helper rejects websocket upgrade responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/ws", struct {
        fn run(c: *Context) Response {
            return c.upgradeWebSocket(struct {
                fn socket(_: *response_mod.WebSocketConnection) !void {}
            }.socket, .{});
        }
    }.run);

    try std.testing.expectError(error.UnsupportedRuntimeClone, app.request(std.testing.allocator, "/ws", .{
        .headers = &.{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "connection", .value = "Upgrade" },
            .{ .name = "sec-websocket-key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
            .{ .name = "sec-websocket-version", .value = "13" },
        },
    }));
}

test "app request helper renders chunked stream handler into buffered body" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/stream", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("hello ");
                    try w.writeAll("world");
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/stream", .{});
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("text/plain", res.content_type);
    try std.testing.expectEqualStrings("hello world", res.body);
    try std.testing.expect(res.body_kind == .buffered);
}

test "app request helper supports content-length stream variant" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/sized", struct {
        fn run(c: *Context) Response {
            return c.stream("application/octet-stream", struct {
                fn write(w: *response_mod.StreamWriter) !void {
                    try w.writeAll("12345");
                }
            }.write, .{ .content_length = 5 });
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/sized", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("12345", res.body);
}

test "app request helper renders sse handler with multi-line data" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/events", struct {
        fn run(c: *Context) Response {
            return c.sse(struct {
                fn write(w: *response_mod.SseWriter) !void {
                    try w.send(.{ .event = "tick", .id = "1", .data = "first" });
                    try w.send(.{ .data = "line1\nline2" });
                }
            }.write);
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/events", .{});
    defer res.deinit();

    try std.testing.expect(std.mem.startsWith(u8, res.content_type, "text/event-stream"));

    var saw_cache_header = false;
    var saw_accel_header = false;
    for (res.extraHeaders()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cache-control") and
            std.mem.eql(u8, h.value, "no-cache")) saw_cache_header = true;
        if (std.ascii.eqlIgnoreCase(h.name, "x-accel-buffering") and
            std.mem.eql(u8, h.value, "no")) saw_accel_header = true;
    }
    try std.testing.expect(saw_cache_header);
    try std.testing.expect(saw_accel_header);

    const expected =
        "id: 1\nevent: tick\ndata: first\n\n" ++
        "data: line1\ndata: line2\n\n";
    try std.testing.expectEqualStrings(expected, res.body);
}

test "app request helper passes context to two-arg stream handler" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/greet/:name", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const name = ctx.req.param("name") orelse "world";
                    try w.print("hi {s}", .{name});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/greet/zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("hi zig", res.body);
}

test "app showRoutes lists middleware mounts and routes" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.useAt("/api", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.mount("/legacy", struct {
        fn run(c: *Context) Response {
            return c.text("legacy");
        }
    }.run);
    try app.get("/posts/:id", struct {
        fn run(c: *Context) Response {
            return c.text("post");
        }
    }.run);

    const rendered = try app.showRoutes(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "USE /api") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "MOUNT /legacy [handler]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "GET /posts/:id") != null);
}

test "app fetch aliases handle" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.fetch(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

// Regression: prior to the StreamingScope refactor, a streaming handler's
// captured Context was a detached snapshot — values written via
// `c.set` in outer middleware were invisible inside the streaming
// callback (the API silently lied). With heap-allocated context state
// transferred to the response on streaming, the inner callback now sees
// the same SharedState as the outer middleware that ran it.
test "streaming with_context inherits outer middleware shared state" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.set("user", @as([]const u8, "alice")) catch
                return response_mod.internalError("set failed");
            next.run();
            return c.takeResponse();
        }
    }.run);

    try app.get("/who", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const user = ctx.get([]const u8, "user") orelse "anonymous";
                    try w.print("hello {s}", .{user});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/who", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("hello alice", res.body);
}

// Regression: route params previously had to be duped inside the stream
// adapter because the router freed `params_storage` after the outer
// handler returned. With StreamingScope owning a duped copy installed on
// `req.params` from the start, params remain valid during streaming
// without per-adapter dupe logic.
test "streaming with_context can read route params after outer return" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/items/:id", struct {
        fn run(c: *Context) Response {
            return c.stream("text/plain", struct {
                fn write(ctx: *Context, w: *response_mod.StreamWriter) !void {
                    const id = ctx.req.param("id") orelse "?";
                    try w.print("item={s}", .{id});
                }
            }.write, .{});
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/items/42", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("item=42", res.body);
}

test "app onError reentry guard prevents recursion when hook itself errors" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Hook itself returns an error. The reentry guard must catch the second
    // dispatch and serve the static 500 instead of looping forever.
    app.onError(struct {
        fn run(_: anyerror, _: *Context) !Response {
            return error.HookExploded;
        }
    }.run);
    try app.get("/boom", struct {
        fn run(_: *Context) !Response {
            return error.OriginalBoom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/boom"));
    try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try std.testing.expectEqualStrings("Internal Server Error", res.body);
}

test "app onError accepts the error-returning context signature" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *Context) !Response {
            c.status(.bad_gateway);
            return c.text(@errorName(err));
        }
    }.run);
    try app.get("/err-ctx", struct {
        fn run(_: *Context) !Response {
            return error.GatewayDown;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/err-ctx"));
    try std.testing.expectEqual(std.http.Status.bad_gateway, res.status);
    try std.testing.expectEqualStrings("GatewayDown", res.body);
}
