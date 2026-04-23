# Request ID

`zono.requestId` is middleware that propagates an `X-Request-ID` header
across the request lifecycle. It mirrors hono's [requestId
middleware](https://hono.dev/docs/middleware/builtin/request-id) so
you get the same observability story without rolling your own.

## Quick start

```zig
try app.use(zono.requestId(.{}));

try app.get("/whoami", struct {
    fn run(c: *zono.Context) zono.Response {
        return c.text(c.requestId() orelse "no-id");
    }
}.run);
```

Behavior:

1. If the request carries `X-Request-ID` and the value passes
   validation (`[A-Za-z0-9_+/=-]{1..255}` by default), it's reused.
2. Otherwise a fresh id is generated — 32 lowercase hex chars from
   16 random bytes.
3. The id is stashed on the per-request shared state so downstream
   middleware/handlers can read it via `c.requestId()`.
4. The same id is echoed back as the response header.

## Options

```zig
pub const RequestIdOptions = struct {
    /// Header name read from the request and written to the response.
    header: []const u8 = "x-request-id",

    /// Maximum accepted length of an incoming id. Longer values are
    /// treated as missing and a fresh id is generated.
    limit: usize = 255,

    /// Optional custom generator. Receives the per-request `Io` (for
    /// entropy) and the per-request arena allocator. When `null`,
    /// falls back to `generateHex` (32 lowercase hex chars).
    generator: ?*const fn (
        io: std.Io,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const u8 = null,
};
```

`limit` follows hono's default of 255 to avoid log-amplification with
hostile upstream clients. The validator is intentionally strict — it
blocks CRLF and other control characters that would otherwise corrupt
log pipelines and downstream tools.

## Custom generator

```zig
fn shortId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(
        allocator,
        "req-{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ raw[0], raw[1], raw[2], raw[3] },
    );
}

try app.use(zono.requestId(.{ .generator = shortId }));
```

The returned slice must be allocated from the supplied allocator —
the middleware does not free it (the per-request arena does).

## Reading the id

```zig
fn handler(c: *zono.Context) zono.Response {
    if (c.requestId()) |id| {
        std.log.info("processing request {s}", .{id});
    }
    return c.text("ok");
}
```

`c.requestId()` returns `?[]const u8`; it is `null` when the
middleware is not installed or when allocation failed during the
generator call (an extremely rare edge case the middleware silently
recovers from).
