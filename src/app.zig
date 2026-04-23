const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const MatchedRoute = request_mod.MatchedRoute;
const MatchedRouteKind = request_mod.MatchedRouteKind;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const http_exception_mod = @import("http_exception.zig");
const validator_mod = @import("validator.zig");
const route_helper_mod = @import("route_helper.zig");
const path_mod = @import("path.zig");
const router_mod = @import("router.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const Route = router_mod.Route;
const Router = router_mod.Router;
const Handler = router_mod.Handler;
const ErrorHandler = *const fn (err: anyerror, req: Request) Response;

fn RouteOnErrorMarker(comptime handler: ErrorHandler) type {
    return struct {
        pub const is_route_on_error = true;
        pub const route_error_handler = handler;
    };
}

pub fn routeOnError(comptime handler: anytype) RouteOnErrorMarker(resolveErrorHandler(handler).handler) {
    return .{};
}

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
        handler: Middleware,
    };

    pub const Next = struct {
        ctx: *const anyopaque,
        run_fn: *const fn (ctx: *const anyopaque, req: Request) Response,

        pub fn run(self: Next, req: Request) Response {
            return self.run_fn(self.ctx, req);
        }
    };

    pub const Middleware = *const fn (req: Request, next: Next) Response;

    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
        cookies_raw: ?[]const u8 = null,
        raw: ?*const anyopaque = null,
        env: ?*const anyopaque = null,
        executionCtx: ?*const anyopaque = null,
        event: ?*const anyopaque = null,
    };

    pub const RawRequest = struct {
        method: std.http.Method = .GET,
        target: []const u8,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
        cookies_raw: ?[]const u8 = null,
        raw: ?*const anyopaque = null,
    };

    pub const FetchRawOptions = struct {
        env: ?*const anyopaque = null,
        executionCtx: ?*const anyopaque = null,
        event: ?*const anyopaque = null,
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
        var shared_state = context_mod.SharedState.init(handled_req.allocator);
        const owns_context_state = handled_req.context_state == null;
        const state: *context_mod.SharedState = if (owns_context_state) blk: {
            handled_req.context_state = @ptrCast(&shared_state);
            break :blk &shared_state;
        } else @ptrCast(@alignCast(handled_req.context_state.?));
        const previous_not_found_handler = state.not_found_handler;
        const previous_on_error_handler = state.on_error_handler;
        state.not_found_handler = self.not_found_handler;
        state.on_error_handler = self.on_error_handler;
        defer state.not_found_handler = previous_not_found_handler;
        defer state.on_error_handler = previous_on_error_handler;
        defer if (owns_context_state) shared_state.deinit();
        attachSharedStateBindings(&handled_req, state);

        var response = if (self.middlewares.items.len == 0)
            self.handleEndpoint(handled_req)
        else
            self.runMiddlewares(handled_req, 0);

        if (owns_context_state and state.http_exception != null) {
            const cloned = response.clone(handled_req.allocator) catch response_mod.internalError("http exception response clone failed");
            response.deinit();
            response = cloned;
        }

        return response;
    }

    fn runMiddlewares(self: *App, req: Request, start_index: usize) Response {
        var middleware_index = start_index;
        while (middleware_index < self.middlewares.items.len) : (middleware_index += 1) {
            const middleware_entry = self.middlewares.items[middleware_index];
            if (!middlewareMatches(middleware_entry.prefix, req.path, self.strict)) continue;

            recordMatchedRoute(req, .middleware, matchedRoutePath(middleware_entry.prefix));

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
            routed_req.route_path_value = lookup.route_path;
            routed_req.base_route_path_value = lookup.base_route_path orelse req.baseRoutePath();
            setRouteMetadata(routed_req, lookup.route_path, routed_req.base_route_path_value);
            if (lookup.route_path) |route_path| {
                recordMatchedRoute(routed_req, .route, route_path);
            }
            if (routed_req.route_lookup_ctx == null) {
                if (lookup.route_path) |route_path| {
                    const matched = [1]MatchedRoute{
                        .{
                            .path = route_path,
                            .kind = .route,
                        },
                    };
                    routed_req.matched_route_list = matched[0..];
                    return handler(routed_req);
                }
            }
            return handler(routed_req);
        }

        if (matchMount(self.mounts.items, req.path)) |matched_mount| {
            var mounted_req = req;
            mounted_req.path = matched_mount.path;
            mounted_req.base_route_path_value = matchedRoutePath(matched_mount.mount.prefix);
            setBaseRoutePath(mounted_req, mounted_req.base_route_path_value);
            recordMatchedRoute(mounted_req, .mount, matchedRoutePath(matched_mount.mount.prefix));
            return dispatchMount(matched_mount.mount.target, mounted_req);
        }

        if (self.redirect_trailing_slash and lookup.tsr and !std.mem.eql(u8, req.path, "/")) {
            if (trailingSlashVariant(req.allocator, req.path) catch null) |redirect_path| {
                const location = appendQuery(req.allocator, redirect_path, req.query_string) catch redirect_path;
                return response_mod.redirect(req.method, location);
            }
        }

        if (self.redirect_fixed_path) {
            const cleaned = path_mod.cleanPath(req.allocator, lookup_req.path) catch lookup_req.path;
            if (router.findCaseInsensitivePath(req.allocator, req.method, cleaned, true) catch null) |fixed| {
                const location = appendQuery(req.allocator, fixed, req.query_string) catch fixed;
                return response_mod.redirect(req.method, location);
            }
        }

        if (req.method == .OPTIONS and self.handle_options) {
            if (router.allowed(req.allocator, lookup_req.path, req.method, self.handle_options) catch null) |allow| {
                return response_mod.options(allow);
            }
        }

        if (self.handle_method_not_allowed) {
            if (router.allowed(req.allocator, lookup_req.path, req.method, self.handle_options) catch null) |allow| {
                return response_mod.methodNotAllowed(allow);
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

    pub fn fetchRaw(self: *App, allocator: std.mem.Allocator, raw_request: RawRequest, fetch_options: FetchRawOptions) !Response {
        return try self.request(allocator, raw_request.target, .{
            .method = raw_request.method,
            .headers = raw_request.headers,
            .body = raw_request.body,
            .cookies_raw = raw_request.cookies_raw,
            .raw = raw_request.raw,
            .env = fetch_options.env,
            .executionCtx = fetch_options.executionCtx,
            .event = fetch_options.event,
        });
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
        req.raw = req_options.raw;
        req.env = req_options.env;
        req.executionCtx = req_options.executionCtx;
        req.event = req_options.event;

        var response = self.handle(req);
        defer response.deinit();
        return try response.clone(allocator);
    }

    fn cloneHandledResponse(self: *App, allocator: std.mem.Allocator, req: Request) !Response {
        var response = self.handle(req);
        defer response.deinit();
        return try response.clone(allocator);
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

fn attachSharedStateBindings(req: *Request, state: *context_mod.SharedState) void {
    req.validation_lookup_ctx = @ptrCast(state);
    req.validation_lookup_fn = context_mod.lookupValidatedValue;
    req.route_lookup_ctx = @ptrCast(state);
    req.route_path_lookup_fn = context_mod.lookupRoutePath;
    req.base_route_path_lookup_fn = context_mod.lookupBaseRoutePath;
    req.matched_routes_lookup_fn = context_mod.lookupMatchedRoutes;
    req.http_exception_ctx = @ptrCast(state);
    req.http_exception_store_fn = context_mod.storeHttpException;
    req.http_exception_load_fn = context_mod.lookupHttpException;
}

fn sharedState(req: Request) ?*context_mod.SharedState {
    const raw_state = req.route_lookup_ctx orelse req.validation_lookup_ctx orelse req.http_exception_ctx orelse return null;
    return @ptrCast(@alignCast(@constCast(raw_state)));
}

fn matchedRoutePath(path: []const u8) []const u8 {
    return if (path.len == 0) "/" else path;
}

fn setRouteMetadata(req: Request, route_path: ?[]const u8, base_route_path: ?[]const u8) void {
    const state = sharedState(req) orelse return;
    state.setRoutePath(route_path);
    state.setBaseRoutePath(base_route_path);
}

fn setBaseRoutePath(req: Request, base_route_path: ?[]const u8) void {
    const state = sharedState(req) orelse return;
    state.setBaseRoutePath(base_route_path);
}

fn recordMatchedRoute(req: Request, kind: MatchedRouteKind, path: []const u8) void {
    const state = sharedState(req) orelse return;
    state.appendMatchedRoute(.{
        .path = path,
        .kind = kind,
    }) catch {};
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
    handler: App.Middleware,
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
            else => @compileError("Route handlers must be fn(req: zono.Request) zono.Response, fn(req: zono.Request) !zono.Response, fn(c: *zono.Context) zono.Response, or fn(c: *zono.Context) !zono.Response."),
        },
        else => @compileError("Route handlers must be fn(req: zono.Request) zono.Response, fn(req: zono.Request) !zono.Response, fn(c: *zono.Context) zono.Response, fn(c: *zono.Context) !zono.Response, or a tuple like .{ middleware, handler }."),
    };
}

fn resolveHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedHandler {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Route handlers");
    if (info.params.len != 1 or info.params[0].type == null) {
        @compileError("Route handlers must accept exactly one parameter.");
    }

    const ParamType = info.params[0].type.?;
    if (ParamType == Request) {
        if (returns_error) {
            return .{
                .handler = wrapErrorHandler(target),
                .uses_context = false,
                .uses_error = true,
            };
        }
        return .{
            .handler = target,
            .uses_context = false,
            .uses_error = false,
        };
    }
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

    @compileError("Route handlers must be fn(req: zono.Request) zono.Response, fn(req: zono.Request) !zono.Response, fn(c: *zono.Context) zono.Response, or fn(c: *zono.Context) !zono.Response.");
}

fn isRouteOnErrorMarker(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .@"struct" or info == .@"enum" or info == .@"union") {
        return @hasDecl(T, "is_route_on_error") and @hasDecl(T, "route_error_handler");
    }
    return false;
}

fn resolveHandlerChain(target: anytype, comptime TargetType: type) ResolvedHandler {
    const fields = std.meta.fields(TargetType);
    if (fields.len == 0) {
        @compileError("Route handler tuples must contain at least one handler.");
    }

    comptime var uses_context = false;
    comptime var uses_error = false;

    if (fields.len == 1) {
        const resolved = resolveHandler(@field(target, fields[0].name));
        return resolved;
    }

    comptime var route_error_handler: ?ErrorHandler = null;
    comptime var middleware_count: usize = 0;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        if (comptime isRouteOnErrorMarker(@TypeOf(item))) {
            if (route_error_handler != null) {
                @compileError("Route handler tuples may include only one zono.routeOnError(...) marker.");
            }
            route_error_handler = @TypeOf(item).route_error_handler;
            uses_error = true;
            continue;
        }

        const resolved = comptime resolveMiddlewareHandler(item);
        middleware_count += 1;
        uses_context = uses_context or resolved.uses_context;
        uses_error = uses_error or resolved.uses_error;
    }

    comptime var middlewares: [middleware_count]App.Middleware = undefined;
    comptime var middleware_index: usize = 0;
    inline for (fields[0 .. fields.len - 1]) |field| {
        const item = @field(target, field.name);
        if (comptime isRouteOnErrorMarker(@TypeOf(item))) continue;

        const resolved = comptime resolveMiddlewareHandler(item);
        middlewares[middleware_index] = resolved.handler;
        middleware_index += 1;
    }

    const final_resolved = comptime resolveHandler(@field(target, fields[fields.len - 1].name));
    uses_context = uses_context or final_resolved.uses_context;
    uses_error = uses_error or final_resolved.uses_error;

    const chained_handler = if (route_error_handler) |handler|
        wrapRouteOnError(handler, wrapRouteChain(middlewares, final_resolved.handler))
    else
        wrapRouteChain(middlewares, final_resolved.handler);

    return .{
        .handler = chained_handler,
        .uses_context = uses_context,
        .uses_error = uses_error,
    };
}

fn resolveMiddlewareHandler(target: anytype) ResolvedMiddleware {
    const TargetType = @TypeOf(target);
    if (TargetType == App.Middleware) {
        return .{
            .handler = target,
            .uses_context = false,
            .uses_error = false,
        };
    }

    if (comptime isValidatorMarker(TargetType)) {
        const wrapped = comptime validator_mod.wrapValidator(TargetType.validator_target, TargetType.validator_parser);
        return resolveMiddlewareFn(wrapped, @typeInfo(@TypeOf(wrapped)).pointer.child);
    }

    return switch (comptime @typeInfo(TargetType)) {
        .@"fn" => resolveMiddlewareFn(target, TargetType),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => resolveMiddlewareFn(target, pointer.child),
            else => @compileError("App.use middleware must be fn(req: zono.Request, next: zono.App.Next) zono.Response, fn(req: zono.Request, next: zono.App.Next) !zono.Response, fn(c: *zono.Context, next: zono.Context.Next) zono.Response, or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
        },
        else => @compileError("App.use middleware must be fn(req: zono.Request, next: zono.App.Next) zono.Response, fn(req: zono.Request, next: zono.App.Next) !zono.Response, fn(c: *zono.Context, next: zono.Context.Next) zono.Response, or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response."),
    };
}

fn isValidatorMarker(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .@"struct" or info == .@"enum" or info == .@"union") {
        return @hasDecl(T, "is_validator") and @hasDecl(T, "validator_target") and @hasDecl(T, "validator_parser");
    }
    return false;
}

fn resolveMiddlewareFn(comptime target: anytype, comptime FnType: type) ResolvedMiddleware {
    const info = @typeInfo(FnType).@"fn";
    const returns_error = comptime returnsErrorResponse(info.return_type, "Middleware handlers");
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("Middleware handlers must accept exactly two parameters.");
    }

    const FirstParam = info.params[0].type.?;
    const SecondParam = info.params[1].type.?;
    if (FirstParam == Request and SecondParam == App.Next) {
        if (returns_error) {
            return .{
                .handler = wrapErrorMiddleware(target),
                .uses_context = false,
                .uses_error = true,
            };
        }
        return .{
            .handler = target,
            .uses_context = false,
            .uses_error = false,
        };
    }
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

    @compileError("App.use middleware must be fn(req: zono.Request, next: zono.App.Next) zono.Response, fn(req: zono.Request, next: zono.App.Next) !zono.Response, fn(c: *zono.Context, next: zono.Context.Next) zono.Response, or fn(c: *zono.Context, next: zono.Context.Next) !zono.Response.");
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
            else => @compileError("App.onError handlers must be fn(err: anyerror, req: zono.Request) zono.Response or fn(err: anyerror, c: *zono.Context) zono.Response."),
        },
        else => @compileError("App.onError handlers must be fn(err: anyerror, req: zono.Request) zono.Response or fn(err: anyerror, c: *zono.Context) zono.Response."),
    };
}

fn resolveErrorHandlerFn(comptime target: anytype, comptime FnType: type) ResolvedErrorHandler {
    const info = @typeInfo(FnType).@"fn";
    if (info.return_type == null or info.return_type.? != Response) {
        @compileError("App.onError handlers must return zono.Response.");
    }
    if (info.params.len != 2 or info.params[0].type == null or info.params[1].type == null) {
        @compileError("App.onError handlers must accept exactly two parameters.");
    }
    if (info.params[0].type.? != anyerror) {
        @compileError("App.onError handlers must accept err: anyerror as the first parameter.");
    }

    const ParamType = info.params[1].type.?;
    if (ParamType == Request) {
        return .{
            .handler = target,
        };
    }
    if (ParamType == *Context) {
        return .{
            .handler = wrapContextErrorResponder(target),
        };
    }

    @compileError("App.onError handlers must be fn(err: anyerror, req: zono.Request) zono.Response or fn(err: anyerror, c: *zono.Context) zono.Response.");
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

fn wrapContextHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var ctx_req = req;
            const owns_context_state = ctx_req.context_state == null;
            if (owns_context_state) ctx_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&ctx_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(ctx_req.context_state.?)));

            var ctx = Context.init(ctx_req);
            return target(&ctx);
        }
    }.run;
}

fn wrapErrorHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            return target(req) catch |err| dispatchHandlerError(req, err);
        }
    }.run;
}

fn wrapContextErrorHandler(comptime target: anytype) Handler {
    return struct {
        fn run(req: Request) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var ctx_req = req;
            const owns_context_state = ctx_req.context_state == null;
            if (owns_context_state) ctx_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&ctx_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(ctx_req.context_state.?)));

            var ctx = Context.init(ctx_req);
            return target(&ctx) catch |err| dispatchHandlerError(ctx_req, err);
        }
    }.run;
}

fn wrapContextMiddleware(comptime target: anytype) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var ctx_req = req;
            const owns_context_state = ctx_req.context_state == null;
            if (owns_context_state) ctx_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&ctx_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(ctx_req.context_state.?)));

            var ctx = Context.init(ctx_req);
            return target(&ctx, .{
                .ctx = &ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            });
        }
    }.run;
}

fn wrapErrorMiddleware(comptime target: anytype) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            return target(req, next) catch |err| dispatchHandlerError(req, err);
        }
    }.run;
}

fn wrapContextErrorMiddleware(comptime target: anytype) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var ctx_req = req;
            const owns_context_state = ctx_req.context_state == null;
            if (owns_context_state) ctx_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&ctx_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(ctx_req.context_state.?)));

            var ctx = Context.init(ctx_req);
            return target(&ctx, .{
                .ctx = &ctx,
                .next_ctx = &next,
                .run_fn = runContextMiddlewareNext,
            }) catch |err| dispatchHandlerError(ctx_req, err);
        }
    }.run;
}

fn wrapContextErrorResponder(comptime target: anytype) ErrorHandler {
    return struct {
        fn run(err: anyerror, req: Request) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var ctx_req = req;
            const owns_context_state = ctx_req.context_state == null;
            if (owns_context_state) ctx_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&ctx_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(ctx_req.context_state.?)));

            if (ctx_req.context_state) |raw_state| {
                const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
                state.last_error = err;
            }

            var ctx = Context.init(ctx_req);
            return target(err, &ctx);
        }
    }.run;
}

fn runContextMiddlewareNext(next_ctx: *const anyopaque, req: Request) Response {
    const next: *const App.Next = @ptrCast(@alignCast(next_ctx));
    return next.run(req);
}

fn dispatchHandlerError(req: Request, err: anyerror) Response {
    if (req.context_state) |raw_state| {
        const state: *context_mod.SharedState = @ptrCast(@alignCast(raw_state));
        state.last_error = err;
        if (err == error.HTTPException) {
            if (state.on_error_handler) |handler| {
                return handler(err, req);
            }
            if (state.http_exception) |*exception| {
                return responseFromHttpException(req.allocator, exception.view()) catch response_mod.internalError("http exception response clone failed");
            }
        }
        if (state.on_error_handler) |handler| {
            return handler(err, req);
        }
    }

    return response_mod.text(.internal_server_error, "Internal Server Error");
}

fn responseFromHttpException(allocator: std.mem.Allocator, exception: http_exception_mod.HTTPException) std.mem.Allocator.Error!Response {
    var borrowed = response_mod.body(exception.status, exception.content_type, exception.message);
    for (exception.headers) |header| {
        _ = borrowed.appendHeader(header.name, header.value);
    }
    defer borrowed.deinit();
    return try borrowed.clone(allocator);
}

fn wrapRouteOnError(comptime route_error_handler: ErrorHandler, comptime inner_handler: Handler) Handler {
    return struct {
        fn run(req: Request) Response {
            var local_state = context_mod.SharedState.init(req.allocator);
            var handled_req = req;
            const owns_context_state = handled_req.context_state == null;
            if (owns_context_state) handled_req.context_state = @ptrCast(&local_state);
            defer if (owns_context_state) local_state.deinit();
            attachSharedStateBindings(&handled_req, if (owns_context_state) &local_state else @ptrCast(@alignCast(handled_req.context_state.?)));

            const state: *context_mod.SharedState = @ptrCast(@alignCast(handled_req.context_state.?));
            const previous_on_error_handler = state.on_error_handler;
            state.on_error_handler = route_error_handler;
            defer state.on_error_handler = previous_on_error_handler;

            return inner_handler(handled_req);
        }
    }.run;
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
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
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
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
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
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    const options_res = app.handle(Request.init(arena.allocator(), .OPTIONS, "/users"));
    try std.testing.expectEqual(std.http.Status.no_content, options_res.status);
    try std.testing.expectEqualStrings("GET, OPTIONS", options_res.allow.?);

    const post_res = app.handle(Request.init(arena.allocator(), .POST, "/users"));
    try std.testing.expectEqual(std.http.Status.method_not_allowed, post_res.status);
    try std.testing.expectEqualStrings("GET, OPTIONS", post_res.allow.?);
}

test "app redirects cleaned and case-corrected paths" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/Users/:id", struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/..//users/42"));
    try std.testing.expectEqual(std.http.Status.moved_permanently, res.status);
    try std.testing.expectEqualStrings("/Users/42", res.location.?);
}

test "app strict false treats trailing slash variants as the same route" {
    var app = App.initWithOptions(std.testing.allocator, .{
        .strict = false,
    });
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/health/", struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.path);
        }
    }.run);

    const no_slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, no_slash_res.status);
    try std.testing.expectEqualStrings("/health", no_slash_res.body);
    try std.testing.expect(no_slash_res.location == null);

    const slash_res = app.handle(Request.init(arena.allocator(), .GET, "/health/"));
    try std.testing.expectEqual(std.http.Status.ok, slash_res.status);
    try std.testing.expectEqualStrings("/health/", slash_res.body);
    try std.testing.expect(slash_res.location == null);
}

test "app options can disable automatic options and 405 handling" {
    var app = App.initWithOptions(std.testing.allocator, .{
        .handle_options = false,
        .handle_method_not_allowed = false,
    });
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/users", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "users");
        }
    }.run);

    const options_res = app.handle(Request.init(arena.allocator(), .OPTIONS, "/users"));
    try std.testing.expectEqual(std.http.Status.not_found, options_res.status);

    const post_res = app.handle(Request.init(arena.allocator(), .POST, "/users"));
    try std.testing.expectEqual(std.http.Status.not_found, post_res.status);
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
        fn list(_: Request) Response {
            return response_mod.text(.ok, "users");
        }
    }.list);
    try users.get("/:id", struct {
        fn detail(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.detail);
    try app.route("/users/", &users);

    const list_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users"));
    try std.testing.expectEqualStrings("users", list_res.body);

    const detail_res = app.handle(Request.init(arena.allocator(), .GET, "/api/users/42"));
    try std.testing.expectEqualStrings("42", detail_res.body);
}

test "app routes expose aggregated params views" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/users/:id/posts/:slug", struct {
        fn run(req: Request) Response {
            var params = req.parseParams(.{}) catch return response_mod.internalError("params parse failed");
            defer params.deinit();

            const slug = params.value("slug") orelse "missing";
            const body = req.allocator.dupe(u8, slug) catch return response_mod.internalError("params alloc failed");
            return response_mod.text(.ok, body);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/users/42/posts/hello-zig"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("hello-zig", res.body);
}

test "app use wraps downstream responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(req: Request, next: App.Next) Response {
            var res = next.run(req);
            _ = res.header("x-middleware", "yes");
            return res;
        }
    }.run);
    try app.get("/health", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
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
        fn run(req: Request, next: App.Next) Response {
            if (!std.mem.eql(u8, req.header("x-admin") orelse "", "1")) {
                return response_mod.text(.unauthorized, "denied");
            }
            return next.run(req);
        }
    }.run);
    try app.get("/admin/panel", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "secret");
        }
    }.run);
    try app.get("/health", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    const denied = app.handle(Request.init(arena.allocator(), .GET, "/admin/panel"));
    try std.testing.expectEqual(std.http.Status.unauthorized, denied.status);
    try std.testing.expectEqualStrings("denied", denied.body);

    const public = app.handle(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, public.status);
    try std.testing.expectEqualStrings("ok", public.body);
}

test "app route carries sub-app middleware" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var child = App.init(std.testing.allocator);
    defer child.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try child.use(struct {
        fn run(req: Request, next: App.Next) Response {
            var res = next.run(req);
            _ = res.header("x-child", req.path);
            return res;
        }
    }.run);
    try child.get("/hello", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "hello");
        }
    }.run);
    try app.route("/api", &child);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/api/hello"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("hello", res.body);
    try std.testing.expectEqualStrings("/api/hello", responseHeaderValue(res, "x-child").?);
}

test "app context handlers can build responses" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/ctx", struct {
        fn run(c: *Context) Response {
            c.status(.created);
            _ = c.header("x-handler", "context");
            return c.text("hello");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx"));
    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("hello", res.body);
    try std.testing.expectEqualStrings("context", responseHeaderValue(res, "x-handler").?);
}

test "app context middleware preserves pre-next headers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            _ = c.header("x-before", "1");
            next.run();
            _ = c.res.header("x-after", "1");
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx", struct {
        fn run(c: *Context) Response {
            return c.text("ok");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-before").?);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-after").?);
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

test "app context json serializes zig values" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/ctx-json", struct {
        fn run(c: *Context) Response {
            c.status(.accepted);
            return c.json(.{
                .ok = true,
                .framework = "zono",
            });
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-json"));
    try std.testing.expectEqual(std.http.Status.accepted, res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framework\":\"zono\"}", res.body);
}

test "app context vars exposes request scoped values" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.set("message", "hello from var") catch return response_mod.internalError("set failed");
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/ctx-var", struct {
        fn run(c: *Context) Response {
            if (!c.vars.contains("message")) return response_mod.internalError("missing message");
            const message = c.vars.get([]const u8, "message") orelse return response_mod.internalError("missing typed message");
            return c.text(message);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-var"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("hello from var", res.body);
}

test "app context notFound uses custom app notFound handler" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.notFound(struct {
        fn run(req: Request) Response {
            return response_mod.text(.not_found, req.path);
        }
    }.run);
    try app.get("/ctx-miss", struct {
        fn run(c: *Context) Response {
            _ = c.header("x-before", "1");
            return c.notFound();
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-miss"));
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqualStrings("/ctx-miss", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-before").?);
}

test "app onError handles request handler errors" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(err: anyerror, req: Request) Response {
            if (err == error.Boom) {
                return response_mod.text(.bad_request, req.path);
            }
            return response_mod.text(.internal_server_error, "unexpected");
        }
    }.run);
    try app.get("/boom", struct {
        fn run(_: Request) !Response {
            return error.Boom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/boom"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("/boom", res.body);
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
        fn run(_: Request) !Response {
            return error.Boom;
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-error"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("Boom", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-error-seen").?);
}

test "app route tuples support route-level middleware" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/tuple", .{
        struct {
            fn run(req: Request, next: App.Next) Response {
                var res = next.run(req);
                _ = res.header("x-route", req.path);
                return res;
            }
        }.run,
        struct {
            fn run(_: Request) Response {
                return response_mod.text(.ok, "tuple");
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/tuple"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("tuple", res.body);
    try std.testing.expectEqualStrings("/tuple", responseHeaderValue(res, "x-route").?);
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

test "app route tuples work with onError and c.err" {
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
    try app.get("/tuple-error", .{
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                next.run();
                if (c.err != null) {
                    _ = c.header("x-route-error", "1");
                }
                return c.takeResponse();
            }
        }.run,
        struct {
            fn run(_: Request) !Response {
                return error.TupleBoom;
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/tuple-error"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("TupleBoom", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-route-error").?);
}

test "app routeOnError overrides app onError for a single route" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(_: anyerror, _: Request) Response {
            return response_mod.text(.internal_server_error, "app");
        }
    }.run);
    try app.get("/route-error", .{
        routeOnError(struct {
            fn run(err: anyerror, c: *Context) Response {
                return c.textWithStatus(if (err == error.RouteBoom) .unprocessable_entity else .internal_server_error, @errorName(err));
            }
        }.run),
        struct {
            fn run(_: Request) !Response {
                return error.RouteBoom;
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/route-error"));
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, res.status);
    try std.testing.expectEqualStrings("RouteBoom", res.body);
}

test "app routeOnError works with route middleware and context sugar" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/route-error-ctx", .{
        routeOnError(struct {
            fn run(err: anyerror, c: *Context) Response {
                const Payload = struct {
                    @"error": []const u8,
                };
                _ = c.header("x-route-level", "1");
                const status_code: std.http.Status = if (err == error.RouteCtxBoom) .bad_request else .internal_server_error;
                const payload: Payload = .{
                    .@"error" = @errorName(err),
                };
                return c.jsonWithStatus(status_code, payload);
            }
        }.run),
        struct {
            fn run(c: *Context, next: Context.Next) Response {
                next.run();
                if (c.err != null) {
                    _ = c.header("x-route-error", "1");
                }
                return c.takeResponse();
            }
        }.run,
        struct {
            fn run(_: Request) !Response {
                return error.RouteCtxBoom;
            }
        }.run,
    });

    const res = app.handle(Request.init(arena.allocator(), .GET, "/route-error-ctx"));
    try std.testing.expectEqual(std.http.Status.bad_request, res.status);
    try std.testing.expectEqualStrings("{\"error\":\"RouteCtxBoom\"}", res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-route-level").?);
    try std.testing.expectEqualStrings("1", responseHeaderValue(res, "x-route-error").?);
}

test "app context sugar can set status inline" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.get("/ctx-sugar", struct {
        fn run(c: *Context) Response {
            return c.textWithStatus(.created, "created");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/ctx-sugar"));
    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("created", res.body);
}

test "app request options expose env executionCtx event and raw through context" {
    const RawValue = struct { code: u32 };
    const EnvValue = struct { name: []const u8 };
    const EventValue = struct { id: u32 };
    const ExecValue = struct { ready: bool };

    const raw_value = RawValue{ .code = 7 };
    const env_value = EnvValue{ .name = "prod" };
    const event_value = EventValue{ .id = 42 };
    const exec_value = ExecValue{ .ready = true };

    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/platform", struct {
        fn run(c: *Context) Response {
            const payload = struct {
                env: []const u8,
                event: u32,
                raw: u32,
                ready: bool,
            }{
                .env = c.envAs(EnvValue).?.name,
                .event = c.eventAs(EventValue).?.id,
                .raw = c.rawAs(RawValue).?.code,
                .ready = c.executionCtxAs(ExecValue).?.ready,
            };
            return c.json(payload);
        }
    }.run);

    var res = try app.request(std.testing.allocator, "/platform", .{
        .raw = @ptrCast(&raw_value),
        .env = @ptrCast(&env_value),
        .event = @ptrCast(&event_value),
        .executionCtx = @ptrCast(&exec_value),
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("{\"env\":\"prod\",\"event\":42,\"raw\":7,\"ready\":true}", res.body);
}

test "app context renderer wraps downstream content" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.setRenderer(struct {
                fn render(ctx: *Context, content: []const u8) Response {
                    const wrapped = std.fmt.allocPrint(ctx.req.allocator, "<main>{s}</main>", .{content}) catch {
                        return response_mod.internalError("alloc failed");
                    };
                    _ = ctx.header("x-renderer", "context");
                    return ctx.html(wrapped);
                }
            }.render);
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/render", struct {
        fn run(c: *Context) Response {
            return c.render("hello");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/render"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("<main>hello</main>", res.body);
    try std.testing.expectEqualStrings("context", responseHeaderValue(res, "x-renderer").?);
}

test "app plain renderer functions are supported" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.setRenderer(struct {
                fn render(content: []const u8) Response {
                    return response_mod.html(content);
                }
            }.render);
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/render-plain", struct {
        fn run(c: *Context) Response {
            return c.render("<strong>ok</strong>");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/render-plain"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("<strong>ok</strong>", res.body);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", res.content_type);
}

test "app validated values flow from context middleware into request handlers" {
    const Claims = struct {
        user_id: u32,
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.setValid(.json, Claims{
                .user_id = 42,
            }) catch return response_mod.internalError("valid failed");
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/valid-request", struct {
        fn run(req: Request) Response {
            const claims = req.valid(Claims, .json) orelse return response_mod.internalError("missing claims");
            return response_mod.text(.ok, if (claims.user_id == 42) "ok" else "bad");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/valid-request"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "app validated values flow into context handlers" {
    const QueryValue = struct {
        page: u32,
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.use(struct {
        fn run(c: *Context, next: Context.Next) Response {
            c.setValid(.query, QueryValue{
                .page = 3,
            }) catch return response_mod.internalError("valid failed");
            next.run();
            return c.takeResponse();
        }
    }.run);
    try app.get("/valid-context", struct {
        fn run(c: *Context) Response {
            const query = c.valid(QueryValue, .query) orelse return response_mod.internalError("missing query");
            return c.textWithStatus(.ok, if (query.page == 3) "page-3" else "bad");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/valid-context"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("page-3", res.body);
}

test "app route helpers expose route metadata after middleware next" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.basePath("/api");
    try app.useAt("/posts", struct {
        fn run(c: *Context, next: Context.Next) Response {
            next.run();

            const matched = c.matchedRoutes();
            const route_path = route_helper_mod.routePath(c) orelse return response_mod.internalError("missing route path");
            const base_route_path = route_helper_mod.baseRoutePath(c) orelse return response_mod.internalError("missing base route path");
            const middleware_path = if (matched.len > 0) matched[0].path else "missing";
            const route_path_match = if (matched.len > 1) matched[1].path else "missing";
            const middleware_kind = if (matched.len > 0 and matched[0].kind == .middleware) "middleware" else "missing";
            const route_kind = if (matched.len > 1 and matched[1].kind == .route) "route" else "missing";
            const body_text = std.fmt.allocPrint(c.req.allocator, "{s}|{s}|{d}|{s}|{s}|{s}|{s}", .{
                route_path,
                base_route_path,
                matched.len,
                middleware_kind,
                middleware_path,
                route_kind,
                route_path_match,
            }) catch return response_mod.internalError("alloc failed");
            return c.text(body_text);
        }
    }.run);
    try app.get("/posts/:id", struct {
        fn run(c: *Context) Response {
            return c.text("ignored");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/api/posts/42"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("/api/posts/:id|/api|2|middleware|/api/posts|route|/api/posts/:id", res.body);
}

test "app validator helper populates valid data and surfaces parser errors" {
    const Query = struct {
        page: u32,
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            if (err == error.MissingPage or err == error.InvalidPage) {
                return c.textWithStatus(.bad_request, @errorName(err));
            }
            return c.textWithStatus(.internal_server_error, @errorName(err));
        }
    }.run);
    try app.use(validator_mod.validator(.query, struct {
        fn run(req: Request) !Query {
            var query = try req.parseQuery(.{});
            defer query.deinit();

            const raw_page = query.value("page") orelse return error.MissingPage;
            return .{
                .page = std.fmt.parseInt(u32, raw_page, 10) catch return error.InvalidPage,
            };
        }
    }.run));
    try app.get("/search", struct {
        fn run(req: Request) Response {
            const query = req.valid(Query, .query) orelse return response_mod.internalError("missing validated query");
            return response_mod.text(.ok, if (query.page == 7) "page-7" else "bad");
        }
    }.run);

    var ok_req = Request.init(arena.allocator(), .GET, "/search");
    ok_req.query_string = "page=7";
    const ok_res = app.handle(ok_req);
    try std.testing.expectEqual(std.http.Status.ok, ok_res.status);
    try std.testing.expectEqualStrings("page-7", ok_res.body);

    const missing_res = app.handle(Request.init(arena.allocator(), .GET, "/search"));
    try std.testing.expectEqual(std.http.Status.bad_request, missing_res.status);
    try std.testing.expectEqualStrings("MissingPage", missing_res.body);
}

test "app http exception defaults and onError both see stored exception data" {
    var default_app = App.init(std.testing.allocator);
    defer default_app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try default_app.get("/default-http-exception", struct {
        fn run(c: *Context) !Response {
            return c.throw(http_exception_mod.HTTPException.init(.gone, "gone").withHeaders(&.{
                .{ .name = "x-http-exception", .value = "1" },
            }));
        }
    }.run);

    const default_res = default_app.handle(Request.init(arena.allocator(), .GET, "/default-http-exception"));
    try std.testing.expectEqual(std.http.Status.gone, default_res.status);
    try std.testing.expectEqualStrings("gone", default_res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(default_res, "x-http-exception").?);

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.onError(struct {
        fn run(err: anyerror, c: *Context) Response {
            if (err != error.HTTPException) return c.textWithStatus(.internal_server_error, @errorName(err));

            const exception = c.httpException() orelse return c.textWithStatus(.internal_server_error, "missing exception");
            _ = c.header("x-http-caught", "1");
            return c.textWithStatus(exception.status, exception.message);
        }
    }.run);
    try app.get("/caught-http-exception", struct {
        fn run(req: Request) !Response {
            return req.throw(http_exception_mod.HTTPException.init(.unprocessable_entity, "bad input"));
        }
    }.run);

    const caught_res = app.handle(Request.init(arena.allocator(), .GET, "/caught-http-exception"));
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, caught_res.status);
    try std.testing.expectEqualStrings("bad input", caught_res.body);
    try std.testing.expectEqualStrings("1", responseHeaderValue(caught_res, "x-http-caught").?);
}

test "app mount delegates prefixed requests to mounted apps" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var mounted = App.init(std.testing.allocator);
    defer mounted.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try mounted.get("/", struct {
        fn root(_: Request) Response {
            return response_mod.text(.ok, "mounted root");
        }
    }.root);
    try mounted.get("/hello", struct {
        fn hello(_: Request) Response {
            return response_mod.text(.ok, "mounted hello");
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

test "app mount prefers the longest matching prefix" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.mount("/api", struct {
        fn api(req: Request) Response {
            return response_mod.text(.ok, req.path);
        }
    }.api);
    try app.mount("/api/admin", struct {
        fn admin(req: Request) Response {
            return response_mod.text(.ok, req.path);
        }
    }.admin);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/api/admin/users"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("/users", res.body);
}

test "app on registers multiple methods and paths" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try app.on(.{ .PUT, .DELETE }, .{ "/posts", "/authors" }, struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "multi");
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
        fn run(req: Request) Response {
            return response_mod.text(.ok, @tagName(req.method));
        }
    }.run);

    const get_res = app.handle(Request.init(arena.allocator(), .GET, "/echo"));
    const trace_res = app.handle(Request.init(arena.allocator(), .TRACE, "/echo"));

    try std.testing.expectEqualStrings("GET", get_res.body);
    try std.testing.expectEqualStrings("TRACE", trace_res.body);
}

test "app custom notFound handler overrides default miss response" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    app.notFound(struct {
        fn run(req: Request) Response {
            return response_mod.text(.not_found, req.path);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/missing"));
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
    try std.testing.expectEqualStrings("/missing", res.body);
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
        fn run(req: Request) Response {
            if (!std.mem.eql(u8, req.query("q") orelse "", "zig")) return response_mod.text(.bad_request, "bad query");
            if (!std.mem.eql(u8, req.header("x-mode") orelse "", "test")) return response_mod.text(.bad_request, "bad header");
            if (!std.mem.eql(u8, req.text(), "payload")) return response_mod.text(.bad_request, "bad body");
            return response_mod.text(.ok, "ok");
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
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.query("name") orelse "missing");
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
        fn run(req: Request) Response {
            if (!std.mem.eql(u8, req.query("draft") orelse "", "1")) return response_mod.text(.bad_request, "bad query");
            return response_mod.text(.created, req.text());
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

test "app fetchRaw adapts target raw env executionCtx and event" {
    const RawValue = struct { code: u32 };
    const EnvValue = struct { name: []const u8 };
    const EventValue = struct { id: u32 };
    const ExecValue = struct { ready: bool };

    const raw_value = RawValue{ .code = 9 };
    const env_value = EnvValue{ .name = "edge" };
    const event_value = EventValue{ .id = 88 };
    const exec_value = ExecValue{ .ready = true };

    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/fetch-raw", struct {
        fn run(c: *Context) Response {
            return c.json(.{
                .mode = c.req.query("mode") orelse "",
                .env = c.envAs(EnvValue).?.name,
                .event = c.eventAs(EventValue).?.id,
                .raw = c.rawAs(RawValue).?.code,
                .ready = c.executionCtxAs(ExecValue).?.ready,
            });
        }
    }.run);

    var res = try app.fetchRaw(std.testing.allocator, .{
        .target = "https://example.com/fetch-raw?mode=edge",
        .raw = @ptrCast(&raw_value),
    }, .{
        .env = @ptrCast(&env_value),
        .event = @ptrCast(&event_value),
        .executionCtx = @ptrCast(&exec_value),
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("{\"mode\":\"edge\",\"env\":\"edge\",\"event\":88,\"raw\":9,\"ready\":true}", res.body);
}

test "app fetch aliases handle" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/health", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.fetch(Request.init(arena.allocator(), .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}
