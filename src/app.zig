const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const path_mod = @import("path.zig");
const router_mod = @import("router.zig");
const Route = router_mod.Route;
const Router = router_mod.Router;
const Handler = router_mod.Handler;

pub const App = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    router: ?Router = null,
    finalized: bool = false,
    base_path: []const u8 = "",
    base_path_owned: ?[]const u8 = null,
    redirect_trailing_slash: bool = true,
    redirect_fixed_path: bool = true,
    handle_method_not_allowed: bool = true,
    handle_options: bool = true,
    not_found_handler: ?Handler = null,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        if (self.router) |*router| router.deinit();
        self.clearBasePath();
        for (self.routes.items) |registered_route| {
            self.allocator.free(registered_route.path);
        }
        self.routes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, path, handler);
    }

    pub fn head(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.HEAD, path, handler);
    }

    pub fn options(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.OPTIONS, path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.PATCH, path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, path, handler);
    }

    pub fn connect(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.CONNECT, path, handler);
    }

    pub fn trace(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(.TRACE, path, handler);
    }

    pub fn all(self: *App, path: []const u8, handler: Handler) !void {
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

    pub fn on(self: *App, methods: anytype, paths: anytype, handler: Handler) !void {
        try self.registerOn(methods, paths, handler);
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
            const full_path = try joinPrefixedPath(self.allocator, mounted_prefix, nested.path);
            errdefer self.allocator.free(full_path);

            try self.routes.append(self.allocator, .{
                .method = nested.method,
                .path = full_path,
                .handler = nested.handler,
            });
        }
    }

    pub fn notFound(self: *App, handler: Handler) void {
        self.not_found_handler = handler;
    }

    pub fn addRoute(self: *App, method: std.http.Method, path: []const u8, handler: Handler) !void {
        if (self.finalized) return error.AppFinalized;
        const full_path = try joinPrefixedPath(self.allocator, self.base_path, path);
        errdefer self.allocator.free(full_path);

        try self.routes.append(self.allocator, .{
            .method = method,
            .path = full_path,
            .handler = handler,
        });
    }

    pub fn finalize(self: *App) !void {
        if (self.finalized) return;
        self.router = try Router.init(self.allocator, self.routes.items);
        self.finalized = true;
    }

    pub fn handle(self: *App, req: Request) Response {
        if (!self.finalized) self.finalize() catch return response_mod.internalError("router init failed");
        const router = &self.router.?;
        const lookup = router.lookup(req);
        if (lookup.handler) |handler| {
            defer if (lookup.params_owned and lookup.params.len > 0) req.allocator.free(lookup.params);
            var routed_req = req;
            routed_req.params = lookup.params;
            return handler(routed_req);
        }

        if (self.redirect_trailing_slash and lookup.tsr and !std.mem.eql(u8, req.path, "/")) {
            if (trailingSlashVariant(req.allocator, req.path) catch null) |redirect_path| {
                const location = appendQuery(req.allocator, redirect_path, req.query_string) catch redirect_path;
                return response_mod.redirect(req.method, location);
            }
        }

        if (self.redirect_fixed_path) {
            const cleaned = path_mod.cleanPath(req.allocator, req.path) catch req.path;
            if (router.findCaseInsensitivePath(req.allocator, req.method, cleaned, true) catch null) |fixed| {
                const location = appendQuery(req.allocator, fixed, req.query_string) catch fixed;
                return response_mod.redirect(req.method, location);
            }
        }

        if (req.method == .OPTIONS and self.handle_options) {
            if (router.allowed(req.allocator, req.path, req.method, self.handle_options) catch null) |allow| {
                return response_mod.options(allow);
            }
        }

        if (self.handle_method_not_allowed) {
            if (router.allowed(req.allocator, req.path, req.method, self.handle_options) catch null) |allow| {
                return response_mod.methodNotAllowed(allow);
            }
        }

        if (self.not_found_handler) |handler| {
            return handler(req);
        }

        return response_mod.notFound();
    }

    fn registerOn(self: *App, methods: anytype, paths: anytype, handler: Handler) !void {
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

    fn registerPaths(self: *App, method: std.http.Method, paths: anytype, handler: Handler) !void {
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
