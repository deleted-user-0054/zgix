const std = @import("std");
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
var request_id_counter: std.atomic.Value(u64) = .init(1);

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

pub const SecureHeadersOptions = struct {
    content_security_policy: ?[]const u8 = "default-src 'self'",
    frame_options: []const u8 = "DENY",
    referrer_policy: []const u8 = "no-referrer",
    cross_origin_opener_policy: ?[]const u8 = "same-origin",
};

pub const ETagOptions = struct {
    weak: bool = true,
};

pub const CompressOptions = struct {
    min_bytes: usize = 256,
};

pub const RequestIdOptions = struct {
    header_name: []const u8 = "x-request-id",
    prefer_incoming: bool = true,
    bytes_len: usize = 16,
    prefix: ?[]const u8 = null,
};

pub const BasicAuthOptions = struct {
    username: []const u8,
    password: []const u8,
    realm: []const u8 = "Restricted",
    charset_utf8: bool = true,
    unauthorized_body: []const u8 = "Unauthorized",
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

pub fn secureHeaders(comptime secure_headers_options: SecureHeadersOptions) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var res = next.run(req);
            _ = res.header("x-content-type-options", "nosniff");
            _ = res.header("x-frame-options", secure_headers_options.frame_options);
            _ = res.header("referrer-policy", secure_headers_options.referrer_policy);
            if (secure_headers_options.content_security_policy) |policy| {
                _ = res.header("content-security-policy", policy);
            }
            if (secure_headers_options.cross_origin_opener_policy) |policy| {
                _ = res.header("cross-origin-opener-policy", policy);
            }
            return res;
        }
    }.run;
}

pub fn bodyLimit(comptime max_bytes: usize) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            if (req.body.len > max_bytes) {
                return response_mod.text(.payload_too_large, "Payload Too Large");
            }
            return next.run(req);
        }
    }.run;
}

pub fn etag(comptime etag_options: ETagOptions) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var res = next.run(req);
            if (res.runtime != .none) return res;
            if (res.body.len == 0) return res;
            if (responseHeaderValue(res, "etag") != null) return res;
            if (res.status != .ok) return res;

            const tag = formatETag(req.allocator, res.body, etag_options.weak) catch return res;
            res.ensureOwned(req.allocator) catch return res;
            _ = res.header("etag", tag);
            if (req.header("if-none-match")) |header| {
                if (std.mem.eql(u8, std.mem.trim(u8, header, " \t"), tag)) {
                    res.setStatus(.not_modified);
                    _ = res.setBody("");
                }
            }
            req.allocator.free(tag);
            return res;
        }
    }.run;
}

pub fn compress(comptime compress_options: CompressOptions) App.Middleware {
    return struct {
        fn run(req: Request, next: App.Next) Response {
            var res = next.run(req);
            if (res.runtime != .none) return res;
            if (res.body.len < compress_options.min_bytes) return res;
            if (responseHeaderValue(res, "content-encoding") != null) return res;
            if (!acceptsEncoding(req, "gzip")) return res;
            if (!isCompressibleContentType(res.content_type)) return res;

            const compressed = gzipEncode(req.allocator, res.body) catch return res;
            var owned = res.clone(req.allocator) catch {
                req.allocator.free(compressed);
                return res;
            };
            res.deinit();

            owned.owned_allocator.?.free(owned.body);
            owned.body = compressed;
            _ = owned.header("content-encoding", "gzip");
            _ = appendVary(req.allocator, &owned, "accept-encoding");
            return owned;
        }
    }.run;
}

pub fn requestId(comptime request_id_options: RequestIdOptions) App.Middleware {
    comptime {
        if (request_id_options.bytes_len == 0) {
            @compileError("zono.requestId requires RequestIdOptions.bytes_len > 0.");
        }
    }

    return struct {
        fn run(req: Request, next: App.Next) Response {
            const ResolvedId = struct {
                id: []const u8,
                owned: bool,
            };

            const resolved: ResolvedId = blk: {
                if (request_id_options.prefer_incoming) {
                    if (req.header(request_id_options.header_name)) |existing| {
                        break :blk ResolvedId{
                            .id = existing,
                            .owned = false,
                        };
                    }
                }
                break :blk ResolvedId{
                    .id = generateRequestId(req.allocator, request_id_options) catch {
                        return response_mod.internalError("request id generation failed");
                    },
                    .owned = true,
                };
            };
            defer if (resolved.owned) req.allocator.free(resolved.id);

            var res = next.run(req);
            res.ensureOwned(req.allocator) catch return res;
            _ = res.header(request_id_options.header_name, resolved.id);
            return res;
        }
    }.run;
}

pub fn basicAuth(comptime basic_auth_options: BasicAuthOptions) App.Middleware {
    comptime {
        if (basic_auth_options.username.len == 0) {
            @compileError("zono.basicAuth requires a non-empty username.");
        }
    }

    const challenge = comptime std.fmt.comptimePrint("Basic realm=\"{s}\"{s}", .{
        basic_auth_options.realm,
        if (basic_auth_options.charset_utf8) ", charset=\"UTF-8\"" else "",
    });

    return struct {
        fn run(req: Request, next: App.Next) Response {
            if (hasValidBasicCredentials(req, basic_auth_options)) {
                return next.run(req);
            }

            var res = response_mod.text(.unauthorized, basic_auth_options.unauthorized_body);
            _ = res.header("www-authenticate", challenge);
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

fn formatETag(allocator: std.mem.Allocator, body: []const u8, weak: bool) std.mem.Allocator.Error![]const u8 {
    const hash = std.hash.Wyhash.hash(0, body);
    return if (weak)
        try std.fmt.allocPrint(allocator, "W/\"{x}-{x}\"", .{ body.len, hash })
    else
        try std.fmt.allocPrint(allocator, "\"{x}-{x}\"", .{ body.len, hash });
}

fn acceptsEncoding(req: Request, encoding: []const u8) bool {
    const header = req.header("accept-encoding") orelse return false;
    var iter = std.mem.splitScalar(u8, header, ',');
    while (iter.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, token, encoding)) return true;
        if (std.mem.eql(u8, token, "*")) return true;
    }
    return false;
}

fn isCompressibleContentType(content_type: []const u8) bool {
    if (content_type.len == 0) return false;
    return std.mem.startsWith(u8, content_type, "text/") or
        std.mem.indexOf(u8, content_type, "json") != null or
        std.mem.indexOf(u8, content_type, "javascript") != null or
        std.mem.indexOf(u8, content_type, "xml") != null or
        std.mem.indexOf(u8, content_type, "svg") != null;
}

fn gzipEncode(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @max(body.len / 2, 64));
    errdefer out.deinit();

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &buffer, .gzip, .default);
    try compressor.writer.writeAll(body);
    try compressor.finish();
    return try out.toOwnedSlice();
}

fn generateRequestId(allocator: std.mem.Allocator, comptime request_id_options: RequestIdOptions) ![]const u8 {
    var bytes: [request_id_options.bytes_len]u8 = undefined;
    @memset(&bytes, 0);

    const counter = request_id_counter.fetchAdd(1, .monotonic);
    const hash = std.hash.Wyhash.hash(counter, std.mem.asBytes(&counter));
    const mixed = [_]u64{ counter, hash };
    const source_len = @min(bytes.len, @sizeOf(@TypeOf(mixed)));
    @memcpy(bytes[0..source_len], std.mem.asBytes(&mixed)[0..source_len]);

    const hex = std.fmt.bytesToHex(bytes, .lower);
    if (request_id_options.prefix) |prefix| {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..] });
    }
    return try allocator.dupe(u8, hex[0..]);
}

fn hasValidBasicCredentials(req: Request, comptime basic_auth_options: BasicAuthOptions) bool {
    const authorization = req.header("authorization") orelse return false;
    if (!std.ascii.startsWithIgnoreCase(authorization, "Basic ")) return false;

    const encoded = std.mem.trim(u8, authorization["Basic ".len..], " \t");
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
    const decoded = req.allocator.alloc(u8, decoded_len) catch return false;
    defer req.allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, encoded) catch return false;
    const separator = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
    const username = decoded[0..separator];
    const password = decoded[separator + 1 ..];
    return std.mem.eql(u8, username, basic_auth_options.username) and
        std.mem.eql(u8, password, basic_auth_options.password);
}

fn appendVary(allocator: std.mem.Allocator, res: *Response, value: []const u8) bool {
    if (responseHeaderValue(res.*, "vary")) |existing| {
        if (containsHeaderToken(existing, value)) return true;
        const merged = std.fmt.allocPrint(allocator, "{s}, {s}", .{ existing, value }) catch return false;
        defer allocator.free(merged);
        return res.header("vary", merged);
    }
    return res.header("vary", value);
}

fn containsHeaderToken(header_value: []const u8, token: []const u8) bool {
    var iter = std.mem.splitScalar(u8, header_value, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, token)) return true;
    }
    return false;
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

test "etag middleware returns 304 on matching if-none-match" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(etag(.{}));
    try app.get("/etag", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "cached");
        }
    }.run);

    const first_req = Request.init(std.testing.allocator, .GET, "/etag");
    var first_res = app.handle(first_req);
    defer first_res.deinit();
    const tag = responseHeaderValue(first_res, "etag").?;

    var second_req = Request.init(std.testing.allocator, .GET, "/etag");
    second_req.header_list = &.{
        .{ .name = "if-none-match", .value = tag },
    };
    var second_res = app.handle(second_req);
    defer second_res.deinit();

    try std.testing.expectEqual(std.http.Status.not_modified, second_res.status);
    try std.testing.expectEqualStrings("", second_res.body);
}

test "secureHeaders and bodyLimit middleware decorate and reject" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(bodyLimit(3));
    try app.use(secureHeaders(.{}));
    try app.post("/submit", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    var rejected = Request.init(std.testing.allocator, .POST, "/submit");
    rejected.body = "toolong";
    var rejected_res = app.handle(rejected);
    defer rejected_res.deinit();
    try std.testing.expectEqual(std.http.Status.payload_too_large, rejected_res.status);

    var accepted = Request.init(std.testing.allocator, .POST, "/submit");
    accepted.body = "ok";
    var accepted_res = app.handle(accepted);
    defer accepted_res.deinit();
    try std.testing.expectEqualStrings("nosniff", responseHeaderValue(accepted_res, "x-content-type-options").?);
}

test "compress middleware gzip encodes compressible responses" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(compress(.{ .min_bytes = 4 }));
    try app.get("/compress", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "compress me");
        }
    }.run);

    var req = Request.init(std.testing.allocator, .GET, "/compress");
    req.header_list = &.{
        .{ .name = "accept-encoding", .value = "gzip, deflate" },
    };
    var res = app.handle(req);
    defer res.deinit();

    try std.testing.expectEqualStrings("gzip", responseHeaderValue(res, "content-encoding").?);
    try std.testing.expect(responseHeaderValue(res, "vary") != null);
}

test "requestId middleware sets response headers and preserves incoming ids" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(requestId(.{
        .prefix = "req_",
    }));
    try app.get("/request-id", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "ok");
        }
    }.run);

    var generated_res = app.handle(Request.init(std.testing.allocator, .GET, "/request-id"));
    defer generated_res.deinit();
    try std.testing.expect(std.mem.startsWith(u8, responseHeaderValue(generated_res, "x-request-id").?, "req_"));

    var forwarded_req = Request.init(std.testing.allocator, .GET, "/request-id");
    forwarded_req.header_list = &.{
        .{ .name = "x-request-id", .value = "incoming-id" },
    };
    var forwarded_res = app.handle(forwarded_req);
    defer forwarded_res.deinit();
    try std.testing.expectEqualStrings("incoming-id", responseHeaderValue(forwarded_res, "x-request-id").?);
}

test "basicAuth middleware challenges invalid requests and allows valid ones" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(basicAuth(.{
        .username = "zono",
        .password = "secret",
        .realm = "admin",
    }));
    try app.get("/protected", struct {
        fn run(_: Request) Response {
            return response_mod.text(.ok, "welcome");
        }
    }.run);

    var unauthorized_res = app.handle(Request.init(std.testing.allocator, .GET, "/protected"));
    defer unauthorized_res.deinit();
    try std.testing.expectEqual(std.http.Status.unauthorized, unauthorized_res.status);
    try std.testing.expectEqualStrings("Basic realm=\"admin\", charset=\"UTF-8\"", responseHeaderValue(unauthorized_res, "www-authenticate").?);

    var encoded_buffer: [std.base64.standard.Encoder.calcSize("zono:secret".len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, "zono:secret");
    const header_value = try std.fmt.allocPrint(std.testing.allocator, "Basic {s}", .{encoded});
    defer std.testing.allocator.free(header_value);

    var authorized_req = Request.init(std.testing.allocator, .GET, "/protected");
    authorized_req.header_list = &.{
        .{ .name = "authorization", .value = header_value },
    };
    var authorized_res = app.handle(authorized_req);
    defer authorized_res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, authorized_res.status);
    try std.testing.expectEqualStrings("welcome", authorized_res.body);
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
