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
    params_storage: ?[]Param = null,
    tsr: bool = false,
};

pub const InitError = std.mem.Allocator.Error || error{
    DuplicateRoute,
    RouteConflict,
    InvalidWildcard,
    CatchAllNotAtEnd,
    MissingCatchAllSlash,
    InvalidPattern,
    InvalidRegexPattern,
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

const PatternParam = struct {
    name: []const u8,
    regex: ?[]const u8 = null,
    optional: bool = false,
};

const PatternSegment = union(enum) {
    literal: []const u8,
    param: PatternParam,
    wildcard,
};

const PatternRoute = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
    segments: []const PatternSegment,
    max_params: usize = 0,
};

const PatternMatchResult = struct {
    matched: bool = false,
    param_count: usize = 0,
};

const SegmentIterator = struct {
    path: []const u8,
    index: usize,

    fn init(path: []const u8) SegmentIterator {
        return .{
            .path = path,
            .index = if (path.len > 0 and path[0] == '/') 1 else 0,
        };
    }

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.index >= self.path.len) return null;

        const start = self.index;
        while (self.index < self.path.len and self.path[self.index] != '/') : (self.index += 1) {}
        const segment = self.path[start..self.index];
        if (self.index < self.path.len) self.index += 1;
        return segment;
    }
};

const RegexAtom = union(enum) {
    literal: u8,
    any,
    escaped: u8,
    class: []const u8,
};

const RegexToken = struct {
    atom: RegexAtom,
    next_index: usize,
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
    pattern_routes: []PatternRoute,

    pub fn init(allocator: std.mem.Allocator, routes: []const Route) InitError!Router {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var trees_list: std.ArrayListUnmanaged(MethodTree) = .empty;
        var pattern_routes: std.ArrayListUnmanaged(PatternRoute) = .empty;

        for (routes) |route| {
            if (isComplexPattern(route.path)) {
                try appendPatternRoute(&pattern_routes, arena_allocator, route);
                continue;
            }

            const tree = try getOrCreateTree(&trees_list, arena_allocator, route.method);
            try tree.root.addRoute(arena_allocator, route.path, route.handler);
            tree.max_params = @max(tree.max_params, countParams(route.path));
        }

        return .{
            .arena = arena,
            .trees = try trees_list.toOwnedSlice(arena_allocator),
            .pattern_routes = try pattern_routes.toOwnedSlice(arena_allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *const Router, req: Request) LookupResult {
        var simple_result: LookupResult = .{};
        if (self.findTree(req.method)) |tree| {
            if (tree.max_params == 0) {
                const match_without_params = tree.root.getValue(req.path, &.{});
                simple_result = .{
                    .handler = match_without_params.handler,
                    .params = &.{},
                    .params_storage = null,
                    .tsr = match_without_params.tsr,
                };
            } else {
                const params = req.allocator.alloc(Param, tree.max_params) catch return .{};
                const match = tree.root.getValue(req.path, params);
                simple_result = .{
                    .handler = match.handler,
                    .params = params[0..match.param_count],
                    .params_storage = params,
                    .tsr = match.tsr,
                };
                if (simple_result.handler == null) {
                    req.allocator.free(params);
                    simple_result.params = &.{};
                    simple_result.params_storage = null;
                }
            }
        }

        if (simple_result.handler != null) return simple_result;

        if (self.lookupPatternRoute(req.method, req.path, req.allocator)) |pattern_result| {
            return pattern_result;
        }

        return simple_result;
    }

    pub fn dispatch(self: *const Router, req: Request) Response {
        const result = self.lookup(req);
        const handler = result.handler orelse return response_mod.notFound();
        defer if (result.params_storage) |storage| req.allocator.free(storage);
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
            for (self.pattern_routes) |pattern_route| {
                if (pattern_route.method == .OPTIONS) continue;
                try appendAllowedMethod(allocator, &methods, pattern_route.method);
            }
        } else {
            for (self.trees) |tree| {
                if (tree.method == req_method or tree.method == .OPTIONS) continue;
                if (tree.root.getValue(path, &.{}).handler != null) {
                    try appendAllowedMethod(allocator, &methods, tree.method);
                }
            }
            for (self.pattern_routes) |pattern_route| {
                if (pattern_route.method == req_method or pattern_route.method == .OPTIONS) continue;
                if ((try matchPatternRoute(pattern_route, path, allocator, false, null, null)).matched) {
                    try appendAllowedMethod(allocator, &methods, pattern_route.method);
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
        if (self.findTree(method)) |tree| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);

            if (try tree.root.findCaseInsensitivePathRec(allocator, path, &out, fix_trailing_slash)) {
                return try out.toOwnedSlice(allocator);
            }
        }

        for (self.pattern_routes) |pattern_route| {
            if (pattern_route.method != method) continue;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);
            if ((try matchPatternRoute(pattern_route, path, allocator, true, null, &out)).matched) {
                return try out.toOwnedSlice(allocator);
            }

            if (!fix_trailing_slash) continue;
            if (try trailingSlashPatternPath(pattern_route, path, allocator, true)) |fixed| {
                return fixed;
            }
        }

        return null;
    }

    fn lookupPatternRoute(
        self: *const Router,
        method: std.http.Method,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) ?LookupResult {
        var tsr = false;

        for (self.pattern_routes) |pattern_route| {
            if (pattern_route.method != method) continue;

            if (pattern_route.max_params == 0) {
                const match = matchPatternRoute(pattern_route, path, allocator, false, null, null) catch return null;
                if (match.matched) {
                    return .{
                        .handler = pattern_route.handler,
                        .params = &.{},
                        .params_storage = null,
                    };
                }
            } else {
                const params = allocator.alloc(Param, pattern_route.max_params) catch return null;
                const match = matchPatternRoute(pattern_route, path, allocator, false, params, null) catch {
                    allocator.free(params);
                    return null;
                };
                if (match.matched) {
                    if (match.param_count == 0) {
                        allocator.free(params);
                        return .{
                            .handler = pattern_route.handler,
                            .params = &.{},
                            .params_storage = null,
                        };
                    }
                    return .{
                        .handler = pattern_route.handler,
                        .params = params[0..match.param_count],
                        .params_storage = params,
                    };
                }
                allocator.free(params);
            }

            tsr = tsr or patternRouteHasTrailingSlashMatch(pattern_route, path, allocator);
        }

        if (tsr) {
            return .{
                .tsr = true,
            };
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

fn isComplexPattern(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '?') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '{') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '}') != null) return true;

    var iterator = SegmentIterator.init(path);
    while (iterator.next()) |segment| {
        if (std.mem.eql(u8, segment, "*")) return true;
    }

    return false;
}

fn appendPatternRoute(
    pattern_routes: *std.ArrayListUnmanaged(PatternRoute),
    allocator: std.mem.Allocator,
    route: Route,
) InitError!void {
    var segments: std.ArrayListUnmanaged(PatternSegment) = .empty;
    errdefer segments.deinit(allocator);

    var iterator = SegmentIterator.init(route.path);
    var max_params: usize = 0;
    while (iterator.next()) |segment| {
        if (segment.len == 0) continue;
        const parsed = try parsePatternSegment(segment);
        switch (parsed) {
            .param => max_params += 1,
            else => {},
        }
        try segments.append(allocator, parsed);
    }

    try pattern_routes.append(allocator, .{
        .method = route.method,
        .path = route.path,
        .handler = route.handler,
        .segments = try segments.toOwnedSlice(allocator),
        .max_params = max_params,
    });
}

fn parsePatternSegment(segment: []const u8) InitError!PatternSegment {
    if (std.mem.eql(u8, segment, "*")) {
        return .wildcard;
    }

    if (segment[0] != ':') {
        if (std.mem.indexOfScalar(u8, segment, '?') != null or
            std.mem.indexOfScalar(u8, segment, '{') != null or
            std.mem.indexOfScalar(u8, segment, '}') != null)
        {
            return error.InvalidPattern;
        }
        return .{ .literal = segment };
    }

    var name_slice = segment[1..];
    var optional = false;
    if (name_slice.len > 0 and name_slice[name_slice.len - 1] == '?') {
        optional = true;
        name_slice = name_slice[0 .. name_slice.len - 1];
    }

    if (name_slice.len == 0) return error.InvalidPattern;

    var regex: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, name_slice, '{')) |open| {
        const close = std.mem.lastIndexOfScalar(u8, name_slice, '}') orelse return error.InvalidPattern;
        if (close != name_slice.len - 1) return error.InvalidPattern;
        if (std.mem.indexOfScalarPos(u8, name_slice, open + 1, '{') != null) return error.InvalidPattern;

        regex = name_slice[open + 1 .. close];
        name_slice = name_slice[0..open];
        if (name_slice.len == 0 or regex.?.len == 0) return error.InvalidPattern;
        if (!validateSegmentRegex(regex.?)) return error.InvalidRegexPattern;
    } else if (std.mem.indexOfScalar(u8, name_slice, '}') != null) {
        return error.InvalidPattern;
    }

    return .{
        .param = .{
            .name = name_slice,
            .regex = regex,
            .optional = optional,
        },
    };
}

fn matchPatternRoute(
    route: PatternRoute,
    path: []const u8,
    allocator: std.mem.Allocator,
    case_insensitive: bool,
    params_out: ?[]Param,
    canonical_out: ?*std.ArrayListUnmanaged(u8),
) std.mem.Allocator.Error!PatternMatchResult {
    const path_segments = try splitPathSegments(allocator, path);
    defer allocator.free(path_segments);

    var param_count: usize = 0;
    if (!matchPatternSegments(
        allocator,
        route.segments,
        0,
        path_segments,
        0,
        case_insensitive,
        params_out,
        &param_count,
        canonical_out,
    )) {
        return .{};
    }

    if (canonical_out) |out| {
        if (out.items.len == 0) {
            try out.append(allocator, '/');
        }
    }

    return .{
        .matched = true,
        .param_count = param_count,
    };
}

fn splitPathSegments(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer segments.deinit(allocator);

    var iterator = SegmentIterator.init(path);
    while (iterator.next()) |segment| {
        if (segment.len == 0) continue;
        try segments.append(allocator, segment);
    }

    return try segments.toOwnedSlice(allocator);
}

fn matchPatternSegments(
    allocator: std.mem.Allocator,
    route_segments: []const PatternSegment,
    route_index: usize,
    path_segments: []const []const u8,
    path_index: usize,
    case_insensitive: bool,
    params_out: ?[]Param,
    param_count: *usize,
    canonical_out: ?*std.ArrayListUnmanaged(u8),
) bool {
    if (route_index >= route_segments.len) {
        return path_index == path_segments.len;
    }

    const saved_param_count = param_count.*;
    const saved_out_len = if (canonical_out) |out| out.items.len else 0;

    switch (route_segments[route_index]) {
        .literal => |literal| {
            if (path_index >= path_segments.len) return false;
            const segment = path_segments[path_index];
            const matches = if (case_insensitive)
                std.ascii.eqlIgnoreCase(literal, segment)
            else
                std.mem.eql(u8, literal, segment);
            if (!matches) return false;

            if (canonical_out) |out| {
                appendCanonicalSegment(allocator, out, literal) catch return false;
            }
            if (matchPatternSegments(allocator, route_segments, route_index + 1, path_segments, path_index + 1, case_insensitive, params_out, param_count, canonical_out)) {
                return true;
            }
        },
        .param => |param| {
            if (path_index < path_segments.len) {
                const segment = path_segments[path_index];
                if (patternParamMatches(param, segment)) {
                    if (params_out) |params| {
                        if (saved_param_count < params.len) {
                            params[saved_param_count] = .{
                                .key = param.name,
                                .value = segment,
                            };
                        }
                    }
                    param_count.* = saved_param_count + 1;
                    if (canonical_out) |out| {
                        appendCanonicalSegment(allocator, out, segment) catch return false;
                    }
                    if (matchPatternSegments(allocator, route_segments, route_index + 1, path_segments, path_index + 1, case_insensitive, params_out, param_count, canonical_out)) {
                        return true;
                    }
                }
            }

            if (param.optional and matchPatternSegments(allocator, route_segments, route_index + 1, path_segments, path_index, case_insensitive, params_out, param_count, canonical_out)) {
                return true;
            }
        },
        .wildcard => {
            var consume = path_segments.len;
            while (true) {
                if (canonical_out) |out| {
                    var index = path_index;
                    while (index < consume) : (index += 1) {
                        appendCanonicalSegment(allocator, out, path_segments[index]) catch return false;
                    }
                }
                if (matchPatternSegments(allocator, route_segments, route_index + 1, path_segments, consume, case_insensitive, params_out, param_count, canonical_out)) {
                    return true;
                }
                if (consume == path_index) break;
                consume -= 1;
            }
        },
    }

    param_count.* = saved_param_count;
    if (canonical_out) |out| out.shrinkRetainingCapacity(saved_out_len);
    return false;
}

fn appendCanonicalSegment(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    segment: []const u8,
) std.mem.Allocator.Error!void {
    try out.append(allocator, '/');
    try out.appendSlice(allocator, segment);
}

fn patternParamMatches(param: PatternParam, segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (param.regex) |regex| {
        return matchSegmentRegex(regex, segment);
    }
    return true;
}

fn patternRouteHasTrailingSlashMatch(route: PatternRoute, path: []const u8, allocator: std.mem.Allocator) bool {
    if (std.mem.eql(u8, path, "/")) return false;

    if (path.len > 1 and path[path.len - 1] == '/') {
        return (matchPatternRoute(route, path[0 .. path.len - 1], allocator, false, null, null) catch PatternMatchResult{}).matched;
    }

    var variant: std.ArrayListUnmanaged(u8) = .empty;
    defer variant.deinit(allocator);
    variant.appendSlice(allocator, path) catch return false;
    variant.append(allocator, '/') catch return false;
    return (matchPatternRoute(route, variant.items, allocator, false, null, null) catch PatternMatchResult{}).matched;
}

fn trailingSlashPatternPath(
    route: PatternRoute,
    path: []const u8,
    allocator: std.mem.Allocator,
    case_insensitive: bool,
) std.mem.Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return null;

    if (path.len > 1 and path[path.len - 1] == '/') {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        if ((try matchPatternRoute(route, path[0 .. path.len - 1], allocator, case_insensitive, null, &out)).matched) {
            return try out.toOwnedSlice(allocator);
        }
        return null;
    }

    var variant: std.ArrayListUnmanaged(u8) = .empty;
    defer variant.deinit(allocator);
    try variant.appendSlice(allocator, path);
    try variant.append(allocator, '/');

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if ((try matchPatternRoute(route, variant.items, allocator, case_insensitive, null, &out)).matched) {
        return try out.toOwnedSlice(allocator);
    }

    return null;
}

fn normalizeRegexPattern(pattern: []const u8) []const u8 {
    var normalized = pattern;
    if (normalized.len > 0 and normalized[0] == '^') normalized = normalized[1..];
    if (normalized.len > 0 and normalized[normalized.len - 1] == '$') normalized = normalized[0 .. normalized.len - 1];
    return normalized;
}

fn validateSegmentRegex(pattern: []const u8) bool {
    const normalized = normalizeRegexPattern(pattern);
    var index: usize = 0;
    while (index < normalized.len) {
        const token = parseRegexToken(normalized, index) orelse return false;
        index = token.next_index;
        if (index < normalized.len and isRegexQuantifier(normalized[index])) index += 1;
    }
    return true;
}

fn matchSegmentRegex(pattern: []const u8, segment: []const u8) bool {
    return matchRegexFrom(normalizeRegexPattern(pattern), 0, segment, 0);
}

fn matchRegexFrom(pattern: []const u8, pattern_index: usize, segment: []const u8, segment_index: usize) bool {
    if (pattern_index >= pattern.len) return segment_index == segment.len;

    const token = parseRegexToken(pattern, pattern_index) orelse return false;
    const quantifier: ?u8 = if (token.next_index < pattern.len and isRegexQuantifier(pattern[token.next_index]))
        pattern[token.next_index]
    else
        null;
    const next_pattern_index = if (quantifier != null) token.next_index + 1 else token.next_index;

    switch (quantifier orelse 0) {
        '+' => {
            if (segment_index >= segment.len or !regexAtomMatches(token.atom, segment[segment_index])) return false;

            var consume = segment_index + 1;
            while (consume < segment.len and regexAtomMatches(token.atom, segment[consume])) : (consume += 1) {}

            var candidate = consume;
            while (candidate > segment_index) : (candidate -= 1) {
                if (matchRegexFrom(pattern, next_pattern_index, segment, candidate)) return true;
            }
            return false;
        },
        '*' => {
            var consume = segment_index;
            while (consume < segment.len and regexAtomMatches(token.atom, segment[consume])) : (consume += 1) {}

            var candidate = consume;
            while (true) {
                if (matchRegexFrom(pattern, next_pattern_index, segment, candidate)) return true;
                if (candidate == segment_index) break;
                candidate -= 1;
            }
            return false;
        },
        '?' => {
            if (matchRegexFrom(pattern, next_pattern_index, segment, segment_index)) return true;
            return segment_index < segment.len and
                regexAtomMatches(token.atom, segment[segment_index]) and
                matchRegexFrom(pattern, next_pattern_index, segment, segment_index + 1);
        },
        else => {
            if (segment_index >= segment.len or !regexAtomMatches(token.atom, segment[segment_index])) return false;
            return matchRegexFrom(pattern, next_pattern_index, segment, segment_index + 1);
        },
    }
}

fn parseRegexToken(pattern: []const u8, index: usize) ?RegexToken {
    if (index >= pattern.len) return null;

    return switch (pattern[index]) {
        '.' => .{ .atom = .any, .next_index = index + 1 },
        '\\' => if (index + 1 < pattern.len)
            .{ .atom = .{ .escaped = pattern[index + 1] }, .next_index = index + 2 }
        else
            null,
        '[' => blk: {
            const end = scanRegexClass(pattern, index) orelse break :blk null;
            break :blk .{
                .atom = .{ .class = pattern[index..end] },
                .next_index = end,
            };
        },
        '*', '+', '?', '(', ')', '|' => null,
        else => .{
            .atom = .{ .literal = pattern[index] },
            .next_index = index + 1,
        },
    };
}

fn scanRegexClass(pattern: []const u8, start: usize) ?usize {
    if (start + 1 >= pattern.len) return null;

    var index = start + 1;
    var has_content = false;
    if (pattern[index] == '^') index += 1;

    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '\\') {
            if (index + 1 >= pattern.len) return null;
            has_content = true;
            index += 1;
            continue;
        }
        if (pattern[index] == ']') {
            if (!has_content) return null;
            return index + 1;
        }
        has_content = true;
    }

    return null;
}

fn regexAtomMatches(atom: RegexAtom, value: u8) bool {
    return switch (atom) {
        .literal => |literal| literal == value,
        .any => true,
        .escaped => |escaped| matchEscapedRegexChar(escaped, value),
        .class => |class| matchRegexClass(class, value),
    };
}

fn matchEscapedRegexChar(escaped: u8, value: u8) bool {
    return switch (escaped) {
        'd' => std.ascii.isDigit(value),
        'D' => !std.ascii.isDigit(value),
        'w' => std.ascii.isAlphanumeric(value) or value == '_',
        'W' => !(std.ascii.isAlphanumeric(value) or value == '_'),
        's' => value == ' ' or value == '\t' or value == '\r' or value == '\n',
        'S' => !(value == ' ' or value == '\t' or value == '\r' or value == '\n'),
        else => escaped == value,
    };
}

fn matchRegexClass(class: []const u8, value: u8) bool {
    var index: usize = 1;
    var negated = false;
    if (class[index] == '^') {
        negated = true;
        index += 1;
    }

    var matched = false;
    while (index < class.len - 1) {
        if (class[index] == '\\') {
            if (index + 1 >= class.len - 1) break;
            matched = matched or matchEscapedRegexChar(class[index + 1], value);
            index += 2;
            continue;
        }

        if (index + 2 < class.len - 1 and class[index + 1] == '-' and class[index + 2] != ']') {
            const start = class[index];
            const end = class[index + 2];
            matched = matched or (value >= start and value <= end);
            index += 3;
            continue;
        }

        matched = matched or class[index] == value;
        index += 1;
    }

    return if (negated) !matched else matched;
}

fn isRegexQuantifier(value: u8) bool {
    return value == '*' or value == '+' or value == '?';
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

test "router optional params match with and without a segment" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "index");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/posts/:id?", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const index_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/posts"));
    try std.testing.expectEqualStrings("index", index_res.body);

    const show_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/posts/42"));
    try std.testing.expectEqualStrings("42", show_res.body);
}

test "router regex params only match valid segments" {
    const handler = struct {
        fn run(req: Request) Response {
            return response_mod.text(.ok, req.param("id") orelse "missing");
        }
    }.run;

    const routes = [_]Route{
        .{ .method = .GET, .path = "/items/:id{[0-9]+}", .handler = handler },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const ok_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/items/42"));
    try std.testing.expectEqualStrings("42", ok_res.body);

    const miss_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/items/nope"));
    try std.testing.expectEqual(std.http.Status.not_found, miss_res.status);
}

test "router middle wildcards match zero or more segments" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/docs/*/edit", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const zero_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/docs/edit"));
    try std.testing.expectEqual(std.http.Status.ok, zero_res.status);

    const nested_res = router.dispatch(Request.init(std.testing.allocator, .GET, "/docs/v1/guides/edit"));
    try std.testing.expectEqual(std.http.Status.ok, nested_res.status);
}

test "router finds case-insensitive canonical path for complex routes" {
    const routes = [_]Route{
        .{ .method = .GET, .path = "/Users/:id{[0-9]+}", .handler = ok },
    };
    var router = try Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const fixed = (try router.findCaseInsensitivePath(std.testing.allocator, .GET, "/users/42", true)).?;
    defer std.testing.allocator.free(fixed);

    try std.testing.expectEqualStrings("/Users/42", fixed);
}
