const request_mod = @import("request.zig");
const Request = request_mod.Request;
const MatchedRoute = request_mod.MatchedRoute;
const context_mod = @import("context.zig");
const Context = context_mod.Context;

pub fn routePath(value: anytype) ?[]const u8 {
    return switch (@TypeOf(value)) {
        Request => value.routePath(),
        *const Request, *Request => value.*.routePath(),
        Context => value.routePath(),
        *const Context, *Context => value.routePath(),
        else => @compileError("routePath accepts a zono.Request or zono.Context value."),
    };
}

pub fn baseRoutePath(value: anytype) ?[]const u8 {
    return switch (@TypeOf(value)) {
        Request => value.baseRoutePath(),
        *const Request, *Request => value.*.baseRoutePath(),
        Context => value.baseRoutePath(),
        *const Context, *Context => value.baseRoutePath(),
        else => @compileError("baseRoutePath accepts a zono.Request or zono.Context value."),
    };
}

pub fn matchedRoutes(value: anytype) []const MatchedRoute {
    return switch (@TypeOf(value)) {
        Request => value.matchedRoutes(),
        *const Request, *Request => value.*.matchedRoutes(),
        Context => value.matchedRoutes(),
        *const Context, *Context => value.matchedRoutes(),
        else => @compileError("matchedRoutes accepts a zono.Request or zono.Context value."),
    };
}
