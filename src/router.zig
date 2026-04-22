const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const Param = request_mod.Param;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const Handler = *const fn (req: Request) Response;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
};

pub const LookupResult = struct {
    handler: ?Handler = null,
    params: []const Param = &.{},
    params_owned: bool = false,
    tsr: bool = false,
};

pub const InitError = std.mem.Allocator.Error || error{
    DuplicateRoute,
    RouteConflict,
    InvalidWildcard,
    CatchAllNotAtEnd,
    MissingCatchAllSlash,
};

const Wildcard = struct {
    token: []const u8 = "",
    index: usize = 0,
    found: bool = false,
    valid: bool = false,
};

const NodeType = enum {
    static,
    root,
    param,
    catch_all,
};

const Match = struct {
    handler: ?Handler = null,
    param_count: usize = 0,
    tsr: bool = false,
};

const MethodTree = struct {
    method: std.http.Method,
    root: *Node,
    max_params: usize = 0,
};

const Node = struct {
    path: []const u8 = "",
    indices: std.ArrayListUnmanaged(u8) = .empty,
    wild_child: bool = false,
    n_type: NodeType = .static,
    priority: u32 = 0,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    handler: ?Handler = null,

    fn addRoute(self: *Node, allocator: std.mem.Allocator, full_path: []const u8, handler: Handler) InitError!void {
        var n = self;
        var path = full_path;

        n.priority += 1;
        if (n.path.len == 0 and n.indices.items.len == 0 and n.children.items.len == 0) {
            try n.insertChild(allocator, path, handler);
            n.n_type = .root;
            return;
        }

        walk: while (true) {
            const common_prefix = longestCommonPrefix(path, n.path);

            if (common_prefix < n.path.len) {
                const child = try createNode(allocator);
                child.* = .{
                    .path = n.path[common_prefix..],
                    .indices = n.indices,
                    .wild_child = n.wild_child,
                    .n_type = .static,
                    .priority = n.priority - 1,
                    .children = n.children,
                    .handler = n.handler,
                };

                n.children = .empty;
                try n.children.append(allocator, child);

                n.indices = .empty;
                try n.indices.append(allocator, n.path[common_prefix]);

                n.path = n.path[0..common_prefix];
                n.handler = null;
                n.wild_child = false;
            }

            if (common_prefix < path.len) {
                path = path[common_prefix..];

                if (n.wild_child) {
                    n = n.children.items[0];
                    n.priority += 1;

                    if (path.len >= n.path.len and
                        std.mem.eql(u8, n.path, path[0..n.path.len]) and
                        n.n_type != .catch_all and
                        (n.path.len >= path.len or path[n.path.len] == '/'))
                    {
                        continue :walk;
                    }

                    return error.RouteConflict;
                }

                const idxc = path[0];

                if (n.n_type == .param and idxc == '/' and n.children.items.len == 1) {
                    n = n.children.items[0];
                    n.priority += 1;
                    continue :walk;
                }

                for (n.indices.items, 0..) |candidate, child_index| {
                    if (candidate == idxc) {
                        const new_pos = n.incrementChildPrio(child_index);
                        n = n.children.items[new_pos];
                        continue :walk;
                    }
                }

                if (idxc != ':' and idxc != '*') {
                    const child = try createNode(allocator);
                    try n.indices.append(allocator, idxc);
                    try n.children.append(allocator, child);
                    const new_pos = n.incrementChildPrio(n.children.items.len - 1);
                    n = n.children.items[new_pos];
                }

                try n.insertChild(allocator, path, handler);
                return;
            }

            if (n.handler != null) return error.DuplicateRoute;
            n.handler = handler;
            return;
        }
    }

    fn insertChild(self: *Node, allocator: std.mem.Allocator, full_path: []const u8, handler: Handler) InitError!void {
        var n = self;
        var path = full_path;

        while (true) {
            const wildcard = findWildcard(path);
            if (!wildcard.found) break;

            if (!wildcard.valid or wildcard.token.len < 2) {
                return error.InvalidWildcard;
            }

            if (n.children.items.len > 0) {
                return error.RouteConflict;
            }

            if (wildcard.token[0] == ':') {
                if (wildcard.index > 0) {
                    n.path = path[0..wildcard.index];
                    path = path[wildcard.index..];
                }

                n.wild_child = true;
                const child = try createNode(allocator);
                child.* = .{
                    .path = wildcard.token,
                    .n_type = .param,
                };
                try n.children.append(allocator, child);
                n = child;
                n.priority += 1;

                if (wildcard.token.len < path.len) {
                    path = path[wildcard.token.len..];
                    const next = try createNode(allocator);
                    next.priority = 1;
                    try n.children.append(allocator, next);
                    n = next;
                    continue;
                }

                n.handler = handler;
                return;
            }

            if (wildcard.index + wildcard.token.len != path.len) {
                return error.CatchAllNotAtEnd;
            }

            if (wildcard.index == 0 or path[wildcard.index - 1] != '/') {
                return error.MissingCatchAllSlash;
            }

            if (n.path.len > 0 and n.path[n.path.len - 1] == '/') {
                return error.RouteConflict;
            }

            n.path = path[0 .. wildcard.index - 1];
            n.wild_child = true;

            const child = try createNode(allocator);
            child.* = .{
                .path = wildcard.token,
                .n_type = .catch_all,
                .priority = 1,
                .handler = handler,
            };
            try n.children.append(allocator, child);
            return;
        }

        n.path = path;
        n.handler = handler;
    }

    fn getValue(self: *const Node, full_path: []const u8, params: []Param) Match {
        var n = self;
        var path = full_path;
        var param_count: usize = 0;

        walk: while (true) {
            const prefix = n.path;

            if (path.len > prefix.len) {
                if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return .{};
                path = path[prefix.len..];

                if (!n.wild_child) {
                    const idxc = path[0];
                    for (n.indices.items, 0..) |candidate, child_index| {
                        if (candidate == idxc) {
                            n = n.children.items[child_index];
                            continue :walk;
                        }
                    }

                    return .{
                        .tsr = std.mem.eql(u8, path, "/") and n.handler != null,
                    };
                }

                n = n.children.items[0];
                switch (n.n_type) {
                    .param => {
                        var end: usize = 0;
                        while (end < path.len and path[end] != '/') : (end += 1) {}

                        if (param_count < params.len) {
                            params[param_count] = .{
                                .key = n.path[1..],
                                .value = path[0..end],
                            };
                        }
                        param_count += 1;

                        if (end < path.len) {
                            if (n.children.items.len > 0) {
                                path = path[end..];
                                n = n.children.items[0];
                                continue :walk;
                            }

                            return .{
                                .tsr = path.len == end + 1,
                            };
                        }

                        return .{
                            .handler = n.handler,
                            .param_count = param_count,
                            .tsr = n.handler == null and n.children.items.len == 1 and
                                std.mem.eql(u8, n.children.items[0].path, "/") and
                                n.children.items[0].handler != null,
                        };
                    },
                    .catch_all => {
                        if (param_count < params.len) {
                            params[param_count] = .{
                                .key = n.path[1..],
                                .value = path,
                            };
                        }
                        param_count += 1;

                        return .{
                            .handler = n.handler,
                            .param_count = param_count,
                        };
                    },
                    else => unreachable,
                }
            }

            if (!std.mem.eql(u8, path, prefix)) {
                return .{
                    .tsr = path.len + 1 == prefix.len and
                        prefix[path.len] == '/' and
                        std.mem.eql(u8, path, prefix[0..path.len]) and
                        n.handler != null,
                };
            }

            if (n.handler == null) {
                if (std.mem.eql(u8, path, "/") and n.wild_child and n.n_type != .root) {
                    return .{ .tsr = true };
                }

                if (std.mem.eql(u8, path, "/") and n.n_type == .static) {
                    return .{ .tsr = true };
                }

                for (n.indices.items, 0..) |candidate, child_index| {
                    if (candidate != '/') continue;
                    const child = n.children.items[child_index];
                    return .{
                        .tsr = (std.mem.eql(u8, child.path, "/") and child.handler != null) or
                            (child.n_type == .catch_all and child.children.items.len > 0 and child.children.items[0].handler != null),
                    };
                }
            }

            return .{
                .handler = n.handler,
                .param_count = param_count,
            };
        }
    }

    fn findCaseInsensitivePathRec(
        self: *const Node,
        allocator: std.mem.Allocator,
        path: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        fix_trailing_slash: bool,
    ) std.mem.Allocator.Error!bool {
        if (path.len < self.path.len or !std.ascii.eqlIgnoreCase(path[0..self.path.len], self.path)) {
            return false;
        }

        const saved_len = out.items.len;
        errdefer out.shrinkRetainingCapacity(saved_len);
        try out.appendSlice(allocator, self.path);

        const rest = path[self.path.len..];
        if (rest.len > 0) {
            if (!self.wild_child) {
                for (self.indices.items, 0..) |candidate, child_index| {
                    if (std.ascii.toLower(candidate) != std.ascii.toLower(rest[0])) continue;
                    const child_saved_len = out.items.len;
                    if (try self.children.items[child_index].findCaseInsensitivePathRec(allocator, rest, out, fix_trailing_slash)) {
                        return true;
                    }
                    out.shrinkRetainingCapacity(child_saved_len);
                }

                if (fix_trailing_slash and std.mem.eql(u8, rest, "/") and self.handler != null) return true;
                return false;
            }

            const child = self.children.items[0];
            switch (child.n_type) {
                .param => {
                    var end: usize = 0;
                    while (end < rest.len and rest[end] != '/') : (end += 1) {}
                    if (end == 0) return false;

                    try out.appendSlice(allocator, rest[0..end]);

                    if (end < rest.len) {
                        if (child.children.items.len > 0) {
                            return child.children.items[0].findCaseInsensitivePathRec(allocator, rest[end..], out, fix_trailing_slash);
                        }
                        return fix_trailing_slash and rest.len == end + 1;
                    }

                    if (child.handler != null) return true;

                    if (fix_trailing_slash and child.children.items.len == 1) {
                        const next = child.children.items[0];
                        if (std.mem.eql(u8, next.path, "/") and next.handler != null) {
                            try out.append(allocator, '/');
                            return true;
                        }
                    }

                    return false;
                },
                .catch_all => {
                    try out.appendSlice(allocator, rest);
                    return child.handler != null;
                },
                else => return false,
            }
        }

        if (self.handler != null) return true;
        if (!fix_trailing_slash) return false;

        for (self.indices.items, 0..) |candidate, child_index| {
            if (candidate != '/') continue;
            const child = self.children.items[child_index];
            if ((std.mem.eql(u8, child.path, "/") and child.handler != null) or
                (child.n_type == .catch_all and child.children.items.len > 0 and child.children.items[0].handler != null))
            {
                try out.append(allocator, '/');
                return true;
            }
        }

        return false;
    }

    fn incrementChildPrio(self: *Node, pos: usize) usize {
        self.children.items[pos].priority += 1;
        const priority = self.children.items[pos].priority;

        var new_pos = pos;
        while (new_pos > 0 and self.children.items[new_pos - 1].priority < priority) : (new_pos -= 1) {
            std.mem.swap(*Node, &self.children.items[new_pos - 1], &self.children.items[new_pos]);
            std.mem.swap(u8, &self.indices.items[new_pos - 1], &self.indices.items[new_pos]);
        }

        return new_pos;
    }
};

pub const Router = struct {
    arena: std.heap.ArenaAllocator,
    trees: []MethodTree,

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) InitError!Router {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var trees_list: std.ArrayListUnmanaged(MethodTree) = .empty;

        for (routes) |route| {
            const tree = try getOrCreateTree(&trees_list, arena_allocator, route.method);
            try tree.root.addRoute(arena_allocator, route.path, route.handler);
            tree.max_params = @max(tree.max_params, countParams(route.path));
        }

        return .{
            .arena = arena,
            .trees = try trees_list.toOwnedSlice(arena_allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *const Router, req: Request) LookupResult {
        const tree = self.findTree(req.method) orelse return .{};
        if (tree.max_params == 0) {
            const match_without_params = tree.root.getValue(req.path, &.{});
            return .{
                .handler = match_without_params.handler,
                .params = &.{},
                .params_owned = false,
                .tsr = match_without_params.tsr,
            };
        }

        const params = req.allocator.alloc(Param, tree.max_params) catch return .{};

        const match = tree.root.getValue(req.path, params);
        return .{
            .handler = match.handler,
            .params = params[0..match.param_count],
            .params_owned = true,
            .tsr = match.tsr,
        };
    }

    pub fn dispatch(self: *const Router, req: Request) Response {
        const result = self.lookup(req);
        const handler = result.handler orelse return response_mod.notFound();
        defer if (result.params_owned and result.params.len > 0) req.allocator.free(result.params);
        var routed_req = req;
        routed_req.params = result.params;
        return handler(routed_req);
    }

    pub fn allowed(
        self: *const Router,
        allocator: std.mem.Allocator,
        path: []const u8,
        req_method: std.http.Method,
        include_options: bool,
    ) !?[]const u8 {
        var methods: std.ArrayListUnmanaged(std.http.Method) = .empty;
        defer methods.deinit(allocator);

        if (std.mem.eql(u8, path, "*")) {
            for (self.trees) |tree| {
                if (tree.method == .OPTIONS) continue;
                try appendAllowedMethod(allocator, &methods, tree.method);
            }
        } else {
            for (self.trees) |tree| {
                if (tree.method == req_method or tree.method == .OPTIONS) continue;
                if (tree.root.getValue(path, &.{}).handler != null) {
                    try appendAllowedMethod(allocator, &methods, tree.method);
                }
            }
        }

        if (methods.items.len == 0) return null;
        if (include_options) try appendAllowedMethod(allocator, &methods, .OPTIONS);

        sortMethods(methods.items);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (methods.items, 0..) |method, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, methodName(method));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn findCaseInsensitivePath(
        self: *const Router,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        fix_trailing_slash: bool,
    ) !?[]const u8 {
        const tree = self.findTree(method) orelse return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        if (try tree.root.findCaseInsensitivePathRec(allocator, path, &out, fix_trailing_slash)) {
            return try out.toOwnedSlice(allocator);
        }
        return null;
    }

    fn findTree(self: *const Router, method: std.http.Method) ?*const MethodTree {
        for (self.trees) |*tree| {
            if (tree.method == method) return tree;
        }
        return null;
    }
};

fn createNode(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Node {
    const node = try allocator.create(Node);
    node.* = .{};
    return node;
}

fn getOrCreateTree(
    trees: *std.ArrayListUnmanaged(MethodTree),
    allocator: std.mem.Allocator,
    method: std.http.Method,
) std.mem.Allocator.Error!*MethodTree {
    for (trees.items) |*tree| {
        if (tree.method == method) return tree;
    }

    const root = try createNode(allocator);
    root.n_type = .root;

    try trees.append(allocator, .{
        .method = method,
        .root = root,
    });
    return &trees.items[trees.items.len - 1];
}

fn longestCommonPrefix(a: []const u8, b: []const u8) usize {
    const max = @min(a.len, b.len);
    var index: usize = 0;
    while (index < max and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn findWildcard(path: []const u8) Wildcard {
    for (path, 0..) |c, start| {
        if (c != ':' and c != '*') continue;

        var valid = true;
        var end = start + 1;
        while (end < path.len and path[end] != '/') : (end += 1) {
            if (path[end] == ':' or path[end] == '*') valid = false;
        }

        return .{
            .token = path[start..end],
            .index = start,
            .found = true,
            .valid = valid,
        };
    }

    return .{};
}

fn countParams(path: []const u8) usize {
    var count: usize = 0;
    for (path) |c| {
        if (c == ':' or c == '*') count += 1;
    }
    return count;
}

fn appendAllowedMethod(
    allocator: std.mem.Allocator,
    methods: *std.ArrayListUnmanaged(std.http.Method),
    method: std.http.Method,
) !void {
    for (methods.items) |existing| {
        if (existing == method) return;
    }
    try methods.append(allocator, method);
}

fn sortMethods(methods: []std.http.Method) void {
    if (methods.len < 2) return;
    var i: usize = 1;
    while (i < methods.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, methodName(methods[j]), methodName(methods[j - 1]))) : (j -= 1) {
            std.mem.swap(std.http.Method, &methods[j], &methods[j - 1]);
        }
    }
}

fn methodName(method: std.http.Method) []const u8 {
    return @tagName(method);
}

fn ok(_: Request) Response {
    return response_mod.text(.ok, "ok");
}

test "router exact route dispatches directly" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/health", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const res = router.dispatch(Request.init(std.testing.allocator, .GET, "/health"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "router dispatches by method" {
    const get_handler = struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "get");
        }
    }.run;
    const post_handler = struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "post");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/users", .handler = get_handler },
        .{ .method = .POST, .path = "/users", .handler = post_handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const get_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/users"));
    try std.testing.expectEqualStrings("get", get_res.body);

    const post_res = router.dispatch(Request.init(std.testing.allocator, .POST, "/users"));
    try std.testing.expectEqualStrings("post", post_res.body);
}

test "router dynamic route injects params" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/users/:id", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = Request.init(arena.allocator(), .GET, "/users/42");
    const res = router.dispatch(req);
    try std.testing.expectEqualStrings("42", res.body);
}

test "router catch all matches the tail" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("filepath") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/src/*filepath", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const req = Request.init(std.testing.allocator, .GET, "/src/subdir/file.zig");
    const res = router.dispatch(req);
    try std.testing.expectEqualStrings("/subdir/file.zig", res.body);
}

test "router rejects static and param conflicts on the same segment" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/user/new", .handler = ok },
        .{ .method = .GET, .path = "/user/:user", .handler = ok },
    };

    try std.testing.expectError(error.RouteConflict, Router.init(std.testing.allocator, &routes));
}

test "router rejects catch all that is not at the end" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/src/*filepath/edit", .handler = ok },
    };

    try std.testing.expectError(error.CatchAllNotAtEnd, Router.init(std.testing.allocator, &routes));
}

test "router allowed returns methods plus OPTIONS" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/users", .handler = ok },
        .{ .method = .POST, .path = "/users", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const allow = (try router.allowed(std.testing.allocator, "/users", .DELETE, true)).?;
    defer std.testing.allocator.free(allow);

    try std.testing.expectEqualStrings("GET, OPTIONS, POST", allow);
}

test "router finds case-insensitive canonical path" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/Users/:id", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const fixed = (try router.findCaseInsensitivePath(std.testing.allocator, .GET, "/users/42", true)).?;
    defer std.testing.allocator.free(fixed);

    try std.testing.expectEqualStrings("/Users/42", fixed);
}
