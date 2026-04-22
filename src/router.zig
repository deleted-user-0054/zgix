const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const Param = request_mod.Param;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const Handler = *const fn (req: Request) Response;

pub const Route = struct {
    path: []const u8,
    handler: Handler,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: []const Route,
    exact_map: std.StringHashMapUnmanaged(usize) = .{},
    dynamic_routes: []const Route = &.{},

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) Router {
        var router = Router{
            .allocator = allocator,
            .routes = routes,
        };

        var dynamic_list: std.ArrayListUnmanaged(Route) = .empty;
        for (routes, 0..) |route, index| {
            if (std.mem.indexOfScalar(u8, route.path, ':') != null) {
                dynamic_list.append(allocator, route) catch {};
            } else {
                router.exact_map.put(allocator, route.path, index) catch {};
            }
        }
        router.dynamic_routes = dynamic_list.toOwnedSlice(allocator) catch &.{};
        return router;
    }

    pub fn deinit(self: *Router) void {
        self.exact_map.deinit(self.allocator);
        self.allocator.free(self.dynamic_routes);
    }

    pub fn dispatch(self: Router, req: Request) Response {
        var params_buf: [8]Param = undefined;

        if (self.exact_map.get(req.path)) |index| {
            return self.routes[index].handler(req);
        }

        for (self.dynamic_routes) |route| {
            if (matchRoute(route.path, req.path, &params_buf)) |count| {
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(Param, params_buf[0..count]) catch &.{};
                return route.handler(dyn_req);
            }
        }

        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            if (self.exact_map.get(trimmed)) |index| {
                return self.routes[index].handler(req);
            }
            for (self.dynamic_routes) |route| {
                if (matchRoute(route.path, trimmed, &params_buf)) |count| {
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(Param, params_buf[0..count]) catch &.{};
                    return route.handler(dyn_req);
                }
            }
        }

        return response_mod.notFound();
    }
};

pub fn matchRoute(route_path: []const u8, req_path: []const u8, out: []Param) ?usize {
    var route_it = std.mem.splitScalar(u8, route_path, '/');
    var path_it = std.mem.splitScalar(u8, req_path, '/');
    var count: usize = 0;

    while (true) {
        const route_seg = route_it.next();
        const path_seg = path_it.next();
        if (route_seg == null and path_seg == null) return count;
        if (route_seg == null or path_seg == null) return null;

        const route_value = route_seg.?;
        const path_value = path_seg.?;
        if (route_value.len > 0 and route_value[0] == ':') {
            if (path_value.len == 0 or count >= out.len) return null;
            out[count] = .{
                .key = route_value[1..],
                .value = path_value,
            };
            count += 1;
            continue;
        }

        if (!std.mem.eql(u8, route_value, path_value)) return null;
    }
}

fn ok(_: Request) Response {
    return response_mod.text(.ok, "ok");
}

test "router exact route dispatches directly" {
    const routes = [_]Route{
        .{ .path = "/health", .handler = ok },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const res = router.dispatch(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "router dynamic route injects params" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .path = "/users/:id", .handler = handler },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = Request.init(arena.allocator(), .GET, "/users/42");
    const res = router.dispatch(req);
    try std.testing.expectEqualStrings("42", res.body);
}
