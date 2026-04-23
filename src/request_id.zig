const std = @import("std");
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;

/// Storage key used to stash the resolved id on `SharedState`.
/// Exposed so middleware/tests can read directly via `c.get([]const u8, REQUEST_ID_KEY)`,
/// but `Context.requestId()` is the preferred API.
pub const REQUEST_ID_KEY = "request_id";

/// Default header name. Lowercased to match the framework's normalized header
/// lookup (zono normalizes incoming/outgoing header names to lowercase).
pub const DEFAULT_HEADER = "x-request-id";

/// Default cap on accepted upstream id length. Hono uses 255; larger values
/// open up log-amplification and storage abuse.
pub const DEFAULT_LIMIT: usize = 255;

/// Length of an auto-generated id in bytes (32 hex chars from 16 random bytes).
pub const GENERATED_HEX_LEN: usize = 32;

pub const RequestIdOptions = struct {
    /// Header name read from the request and written to the response.
    /// Compared case-insensitively against incoming headers.
    header: []const u8 = DEFAULT_HEADER,
    /// Maximum accepted length of an incoming id. IDs longer than this are
    /// treated as missing and a fresh id is generated.
    limit: usize = DEFAULT_LIMIT,
    /// Optional custom generator. Receives the per-request `Io` (for
    /// entropy) and the per-request arena allocator. Must allocate from
    /// the supplied allocator — middleware does not free the returned
    /// slice. When `null`, falls back to `generateHex`.
    generator: ?*const fn (io: std.Io, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 = null,
};

/// Validate an incoming request id. Restricting the alphabet protects log
/// pipelines and downstream tools from injection (CRLF, control chars, etc.).
/// Allowed: `[A-Za-z0-9_+/=-]`. Empty strings and over-long values are
/// rejected. Mirrors hono's default validator.
pub fn isValidId(id: []const u8, limit: usize) bool {
    if (id.len == 0 or id.len > limit) return false;
    for (id) |b| {
        const ok = (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '_' or b == '+' or b == '/' or b == '=' or b == '-';
        if (!ok) return false;
    }
    return true;
}

/// Generate a 32-char lowercase hex id from 16 random bytes pulled from
/// the supplied `Io`. The `Io` is required because Zig 0.16 routes all
/// entropy through the `Io` vtable; pass `c.io() orelse fallback` from a
/// caller that has a context.
pub fn generateHex(io: std.Io, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const out = try allocator.alloc(u8, GENERATED_HEX_LEN);
    const hex_chars = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Returns a middleware that ensures every request has an id available via
/// `c.requestId()` and echoed back in the response header.
///
/// Behavior:
/// - If the incoming request carries `options.header` and the value passes
///   `isValidId`, that value is reused.
/// - Otherwise a fresh id is generated (via `options.generator` if set,
///   else `generateHex`).
/// - The id is stashed on `SharedState` under `REQUEST_ID_KEY` so downstream
///   handlers/middleware see it.
/// - The same id is set on the outgoing response header.
///
/// Allocations use the per-request arena (`c.req.allocator`); callers do not
/// free the id.
pub fn requestId(comptime opts: RequestIdOptions) fn (*Context, Context.Next) Response {
    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            const id = resolveId(c, opts) catch {
                // Allocation failure — skip annotation, continue dispatch.
                // We don't 500 because the rest of the pipeline may still
                // succeed; the id is observability sugar, not load-bearing.
                next.run();
                return c.takeResponse();
            };

            // Stash for downstream consumers. Errors here are also non-fatal:
            // failing to record the id should not break the request.
            c.set(REQUEST_ID_KEY, id) catch {};

            // Echo to the client. `header` returns false on alloc failure;
            // that's fine — the request still proceeds.
            _ = c.header(opts.header, id);

            next.run();
            return c.takeResponse();
        }
    }.run;
}

fn resolveId(c: *Context, comptime opts: RequestIdOptions) std.mem.Allocator.Error![]const u8 {
    if (c.req.header(opts.header)) |incoming| {
        if (isValidId(incoming, opts.limit)) {
            // Dupe into the per-request arena: incoming header storage may
            // be reused by the parser between requests on a kept-alive
            // connection.
            return try c.req.allocator.dupe(u8, incoming);
        }
    }

    // Pick an `Io`: prefer the live server's; fall back to a single-threaded
    // implementation when the app is being driven by `App.handle` directly
    // (unit tests). The fallback `Threaded` value lives only for this call,
    // which is fine — `random` reads from it synchronously.
    if (c.io()) |io| {
        if (opts.generator) |gen| return try gen(io, c.req.allocator);
        return try generateHex(io, c.req.allocator);
    }
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    if (opts.generator) |gen| return try gen(io, c.req.allocator);
    return try generateHex(io, c.req.allocator);
}

const testing = std.testing;
const App = @import("app.zig").App;
const Request = @import("request.zig").Request;

test "isValidId accepts the documented alphabet" {
    try testing.expect(isValidId("abc123", 255));
    try testing.expect(isValidId("A_b-c=d+e/f", 255));
    try testing.expect(isValidId("0", 255));
}

test "isValidId rejects empty, oversize, and disallowed bytes" {
    try testing.expect(!isValidId("", 255));
    try testing.expect(!isValidId("aaaa", 3));
    try testing.expect(!isValidId("bad value", 255)); // space
    try testing.expect(!isValidId("bad\nvalue", 255)); // newline
    try testing.expect(!isValidId("bad\rvalue", 255)); // CR
    try testing.expect(!isValidId("bad;value", 255)); // semicolon
}

test "generateHex returns 32 lowercase hex chars and is non-deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();
    const a = try generateHex(io, arena.allocator());
    const b = try generateHex(io, arena.allocator());
    try testing.expectEqual(@as(usize, GENERATED_HEX_LEN), a.len);
    try testing.expectEqual(@as(usize, GENERATED_HEX_LEN), b.len);
    for (a) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        try testing.expect(ok);
    }
    // Probabilistically distinct (collision odds: 2^-128).
    try testing.expect(!std.mem.eql(u8, a, b));
}

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    for (res.extraHeaders()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

test "requestId middleware generates an id when header is absent" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{}));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            const id = c.requestId() orelse return c.text("missing");
            return c.text(id);
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/"));
    try testing.expectEqual(@as(usize, GENERATED_HEX_LEN), res.body.len);
    const header_val = responseHeaderValue(res, DEFAULT_HEADER) orelse return error.MissingHeader;
    try testing.expectEqualStrings(res.body, header_val);
}

test "requestId middleware reuses a valid incoming id" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{}));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.requestId() orelse "none");
        }
    }.run);

    var req = Request.init(arena.allocator(), .GET, "/");
    req.header_list = &.{.{ .name = DEFAULT_HEADER, .value = "incoming-id-123" }};
    const res = app.handle(req);
    try testing.expectEqualStrings("incoming-id-123", res.body);
    try testing.expectEqualStrings("incoming-id-123", responseHeaderValue(res, DEFAULT_HEADER).?);
}

test "requestId middleware regenerates when incoming id is invalid" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{}));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.requestId() orelse "none");
        }
    }.run);

    var req = Request.init(arena.allocator(), .GET, "/");
    // Contains a space => fails isValidId, so a fresh hex id is generated.
    req.header_list = &.{.{ .name = DEFAULT_HEADER, .value = "bad id with spaces" }};
    const res = app.handle(req);
    try testing.expectEqual(@as(usize, GENERATED_HEX_LEN), res.body.len);
    try testing.expect(!std.mem.eql(u8, res.body, "bad id with spaces"));
}

test "requestId middleware honors a custom header name" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{ .header = "x-trace-id" }));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.requestId() orelse "none");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/"));
    try testing.expect(responseHeaderValue(res, "x-trace-id") != null);
    try testing.expect(responseHeaderValue(res, DEFAULT_HEADER) == null);
}

test "requestId middleware honors a custom generator" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const gen = struct {
        fn run(_: std.Io, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            return allocator.dupe(u8, "fixed-id-from-generator");
        }
    }.run;

    try app.use(requestId(.{ .generator = gen }));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.requestId() orelse "none");
        }
    }.run);

    const res = app.handle(Request.init(arena.allocator(), .GET, "/"));
    try testing.expectEqualStrings("fixed-id-from-generator", res.body);
}

test "requestId middleware enforces the limit option" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{ .limit = 5 }));
    try app.get("/", struct {
        fn run(c: *Context) Response {
            return c.text(c.requestId() orelse "none");
        }
    }.run);

    var req = Request.init(arena.allocator(), .GET, "/");
    // 6 chars > limit of 5 => regenerated.
    req.header_list = &.{.{ .name = DEFAULT_HEADER, .value = "abcdef" }};
    const res = app.handle(req);
    try testing.expect(!std.mem.eql(u8, res.body, "abcdef"));
    try testing.expectEqual(@as(usize, GENERATED_HEX_LEN), res.body.len);
}

test "requestId is visible to onError handlers" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try app.use(requestId(.{}));
    app.onError(struct {
        fn run(_: anyerror, c: *Context) Response {
            return c.text(c.requestId() orelse "missing");
        }
    }.run);
    try app.get("/boom", struct {
        fn run(_: *Context) !Response {
            return error.Boom;
        }
    }.run);

    var req = Request.init(arena.allocator(), .GET, "/boom");
    req.header_list = &.{.{ .name = DEFAULT_HEADER, .value = "trace-abc" }};
    const res = app.handle(req);
    try testing.expectEqualStrings("trace-abc", res.body);
}
