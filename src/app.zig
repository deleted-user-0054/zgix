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
    redirect_trailing_slash: bool = true,
    redirect_fixed_path: bool = true,
    handle_method_not_allowed: bool = true,
    handle_options: bool = true,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        if (self.router) |*router| router.deinit();
        for (self.routes.items) |route| {
            self.allocator.free(route.path);
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

    pub fn addRoute(self: *App, method: std.http.Method, path: []const u8, handler: Handler) !void {
        if (self.finalized) return error.AppFinalized;
        try self.routes.append(self.allocator, .{
            .method = method,
            .path = try self.allocator.dupe(u8, path),
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

        return response_mod.notFound();
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
