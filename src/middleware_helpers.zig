const std = @import("std");
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");

pub const CORSOrigin = union(enum) {
    any,
    fixed: []const u8,
    mirror,
};

pub const CORSOptions = struct {
    allow_origin: CORSOrigin = .any,
    allow_methods: []const u8 = "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
    allow_headers: ?[]const u8 = null,
    expose_headers: ?[]const u8 = null,
    max_age: ?u64 = null,
    allow_credentials: bool = false,
};

pub const LoggerEvent = struct {
    method: std.http.Method,
    path: []const u8,
    status: std.http.Status,
    duration_ns: u64,
};

pub const LoggerSink = *const fn (event: LoggerEvent) void;

pub const LoggerOptions = struct {
    label: []const u8 = "zono",
    sink: ?LoggerSink = null,
};

pub fn cors(comptime cors_options: CORSOptions) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            if (isPreflight(req)) {
                var res = response_mod.body(.no_content, "", "");
                applyCORSHeaders(req, &res, cors_options, true);
                return res;
            }

            var res = next.run(req);
            applyCORSHeaders(req, &res, cors_options, false);
            return res;
        }
    }.run;
}

pub fn logger(comptime logger_options: LoggerOptions) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var io_impl = std.Io.Threaded.init_single_threaded;
            const io = io_impl.io();
            const start = std.Io.Clock.awake.now(io);
            const res = next.run(req);
            const end = std.Io.Clock.awake.now(io);
            const duration_ns: u64 = @intCast(@max(start.durationTo(end).toNanoseconds(), 0));
            const event: LoggerEvent = .{
                .method = req.method,
                .path = req.path,
                .status = res.status,
                .duration_ns = duration_ns,
            };

            if (logger_options.sink) |sink| {
                sink(event);
            } else {
                std.debug.print("[{s}] {s} {s} -> {d} ({d}ns)\n", .{
                    logger_options.label,
                    @tagName(req.method),
                    req.path,
                    @intFromEnum(res.status),
                    duration_ns,
                });
            }

            return res;
        }
    }.run;
}

fn isPreflight(req: Request) bool {
    return req.method == .OPTIONS and req.header("access-control-request-method") != null;
}

fn applyCORSHeaders(req: Request, res: *Response, cors_options: CORSOptions, preflight: bool) void {
    switch (cors_options.allow_origin) {
        .any => _ = res.header("access-control-allow-origin", "*"),
        .fixed => |origin| _ = res.header("access-control-allow-origin", origin),
        .mirror => {
            const origin = req.header("origin") orelse return;
            _ = res.header("access-control-allow-origin", origin);
            _ = res.header("vary", "Origin");
        },
    }

    if (cors_options.allow_credentials) {
        _ = res.header("access-control-allow-credentials", "true");
    }
    if (cors_options.expose_headers) |headers| {
        _ = res.header("access-control-expose-headers", headers);
    }

    if (!preflight) return;

    _ = res.header("access-control-allow-methods", cors_options.allow_methods);

    if (cors_options.allow_headers) |headers| {
        _ = res.header("access-control-allow-headers", headers);
    } else if (req.header("access-control-request-headers")) |headers| {
        _ = res.header("access-control-allow-headers", headers);
    }

    if (cors_options.max_age) |max_age| {
        var buffer: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "{d}", .{max_age}) catch return;
        _ = res.header("access-control-max-age", formatted);
    }
}

test "cors middleware handles preflight requests" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(cors(.{
        .allow_origin = .mirror,
        .allow_credentials = true,
        .max_age = 600,
    }));

    var req = Request.init(std.testing.allocator, .OPTIONS, "/api/posts");
    req.header_list = &.{
        .{ .name = "origin", .value = "https://example.com" },
        .{ .name = "access-control-request-method", .value = "POST" },
        .{ .name = "access-control-request-headers", .value = "content-type, authorization" },
    };

    const res = app.handle(req);
    try std.testing.expectEqual(std.http.Status.no_content, res.status);
    try std.testing.expectEqualStrings("https://example.com", responseHeaderValue(res, "access-control-allow-origin").?);
    try std.testing.expectEqualStrings("POST", req.header("access-control-request-method").?);
    try std.testing.expectEqualStrings("content-type, authorization", responseHeaderValue(res, "access-control-allow-headers").?);
    try std.testing.expectEqualStrings("600", responseHeaderValue(res, "access-control-max-age").?);
}

test "cors middleware decorates normal responses" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(cors(.{
        .allow_origin = .{ .fixed = "https://app.example.com" },
        .expose_headers = "x-trace-id",
    }));
    try app.get("/hello", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    const res = app.handle(Request.init(std.testing.allocator, .GET, "/hello"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("https://app.example.com", responseHeaderValue(res, "access-control-allow-origin").?);
    try std.testing.expectEqualStrings("x-trace-id", responseHeaderValue(res, "access-control-expose-headers").?);
}

test "logger middleware emits structured events" {
    const Capture = struct {
        var last: ?LoggerEvent = null;

        fn sink(event: LoggerEvent) void {
            last = event;
        }
    };

    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(logger(.{
        .sink = Capture.sink,
    }));
    try app.get("/logs", struct {
        fn run(_: Request) Response {
            return response_mod.text(.created, "logged");
        }
    }.run);

    const res = app.handle(Request.init(std.testing.allocator, .GET, "/logs"));
    _ = res;

    try std.testing.expect(Capture.last != null);
    try std.testing.expectEqual(std.http.Method.GET, Capture.last.?.method);
    try std.testing.expectEqual(std.http.Status.created, Capture.last.?.status);
    try std.testing.expectEqualStrings("/logs", Capture.last.?.path);
}

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "content-type")) return if (res.content_type.len > 0) res.content_type else null;
    if (std.ascii.eqlIgnoreCase(name, "location")) return res.location;
    if (std.ascii.eqlIgnoreCase(name, "allow")) return res.allow;

    for (res.extraHeaders()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
