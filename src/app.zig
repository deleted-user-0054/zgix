const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");
const Route = router_mod.Route;
const Router = router_mod.Router;
const Handler = router_mod.Handler;

pub const App = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    router: ?Router = null,
    finalized: bool = false,

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
        try self.addRoute(path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: Handler) !void {
        try self.addRoute(path, handler);
    }

    pub fn addRoute(self: *App, path: []const u8, handler: Handler) !void {
        if (self.finalized) return error.AppFinalized;
        try self.routes.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .handler = handler,
        });
    }

    pub fn finalize(self: *App) !void {
        if (self.finalized) return;
        self.router = Router.init(self.allocator, self.routes.items);
        self.finalized = true;
    }

    pub fn handle(self: *App, req: Request) Response {
        if (!self.finalized) self.finalize() catch return response_mod.internalError("router init failed");
        return self.router.?.dispatch(req);
    }
};

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
