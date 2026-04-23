# zono

`zono` is a thin Zig web toolkit with a backend scope close to `merjs`, but an
API shape inspired by `Hono`.

The public root API intentionally focuses on the core surface:

- `App` for routing, composition, middleware, and errors
- `Context` for Hono-style handler ergonomics
- `Request` for params, query, headers, cookies, and body parsing
- `Response` helpers for text, html, json, redirects, cookies, files, streams, SSE
- `Server` for the built-in runtime (HTTP/1.1, no TLS — front it with a proxy)
- `app.request()` for lightweight route testing

## Highlights

- Hono-style context handlers: `fn(c: *zono.Context) zono.Response`
- Route composition with `basePath()`, `route()`, `mount()`, `on()`, `all()`
- Middleware with `use()` / `useAt()`; Hono-style `next.run()` ordering
- App-level hooks: `notFound()` and `onError()` (with reentry guard)
- Exact, optional-param, regex-param, and middle-wildcard routes
- Request helpers for `param()`, `query()`, `header()`, `cookie()`, `.all`
- `parseBody()` for urlencoded and multipart form data
- Streaming responses: chunked + SSE with peer-abort awareness
- Static files: `serveStatic()` with `Range`, ETag, `If-None-Match`, `If-Modified-Since`, `HEAD`
- WebSocket upgrades via `c.upgradeWebSocket()`
- Built-in `requestId()` middleware (X-Request-ID propagation)
- Lightweight testing through `app.request()` and the `WsClient` helper

## Quick Start

Requirements: Zig `0.16.0`

```bash
zig build test
zig build run-benchmark
```

Minimal app:

```zig
const std = @import("std");
const zono = @import("zono");

fn hello(c: *zono.Context) zono.Response {
    return c.text("hi");
}

pub fn main() !void {
    var io = try std.Io.Threaded.init(std.heap.smp_allocator);
    defer io.deinit();

    var app = zono.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/", hello);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080),
    });
    try server.serve(io.io(), &app);
}
```

## Documentation

Topic guides live under [`docs/`](./docs/README.md):

- [Routing & composition](./docs/routing.md)
- [Middleware](./docs/middleware.md)
- [Hooks (`notFound`, `onError`)](./docs/hooks.md)
- [Streaming & SSE](./docs/streaming.md)
- [Static files](./docs/static.md)
- [Server (timeouts, graceful stop)](./docs/server.md)
- [WebSocket](./docs/websocket.md)
- [Request ID middleware](./docs/request-id.md)
- [Testing (`App.request`, `WsClient`)](./docs/testing.md)

## Benchmark

CI benchmarks compare:

- `zono` `examples/benchmark.zig` on `GET /api/json`
- A trimmed `merjs` starter-style baseline on `GET /api/json`
  based on upstream release tag `v0.2.5`
  with the release's shipped threaded runtime fallback on Linux CI

Both targets return the same tiny JSON payload and are warmed once before
running three measured `wrk -t2 -c100 -d10s` samples. The table publishes the
median Requests/sec run together with its matching latency. Build time is
intentionally excluded from the table because the `merjs` row is treated as a
release-tag runtime baseline rather than a source-build comparison.

**CI benchmarks** (GitHub Actions, auto-updated on each push to `main`):

Raw snapshot: [benchmarks/latest.json](./benchmarks/latest.json)

<!-- BENCH:START -->
| Metric | **zono** | **merjs** |
|--------|----------|-----------|
| Requests/sec (wrk median) | **104581.28** | **85338.52** |
| Avg latency | **601.53us 1.87ms** | **695.10us 842.71us** |
| RAM usage (under load) | **473.0 MB** | **3.2 MB** |
<!-- BENCH:END -->

## At a glance

A few common shapes — see the docs above for the full story.

### Route composition

```zig
var users = zono.App.init(allocator);
defer users.deinit();
try users.get("/", listUsers);
try users.get("/:id", showUser);

var app = zono.App.init(allocator);
defer app.deinit();
try app.basePath("/api");
try app.route("/users", &users);     // /api/users, /api/users/:id
```

### Middleware

```zig
fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    next.run();
    _ = c.header("x-powered-by", "zono");
    return c.takeResponse();
}

try app.use(poweredBy);
```

### Error handling

```zig
app.onError(struct {
    fn run(err: anyerror, c: *zono.Context) zono.Response {
        return c.textWithStatus(.bad_request, @errorName(err));
    }
}.run);

try app.get("/posts/:id", struct {
    fn run(_: *zono.Context) !zono.Response {
        return error.InvalidPostId;
    }
}.run);
```

### Static files

```zig
try app.use(zono.serveStatic(.{
    .root = "public",
    .cache_control = "public, max-age=3600",
}));
```

### WebSocket

```zig
fn ws(c: *zono.Context) zono.Response {
    return c.upgradeWebSocket(struct {
        fn run(socket: *zono.WebSocketConnection) !void {
            while (true) {
                const message = try socket.readSmallMessage();
                switch (message.opcode) {
                    .text => try socket.writeText(message.data),
                    .binary => try socket.writeBinary(message.data),
                    .connection_close => { try socket.close(""); return; },
                    .ping => try socket.writePong(message.data),
                    else => {},
                }
            }
        }
    }.run, .{});
}

try app.get("/ws", ws);
```

### Request ID

```zig
try app.use(zono.requestId(.{}));

try app.get("/whoami", struct {
    fn run(c: *zono.Context) zono.Response {
        return c.text(c.requestId() orelse "no-id");
    }
}.run);
```

### Testing

```zig
test "search route" {
    var app = zono.App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("zig", res.body);
}
```

`app.request()` is for ordinary request/response handlers. WebSocket upgrade
routes should be exercised through `zono.Server` plus `zono.WsClient` — see
[`docs/testing.md`](./docs/testing.md).
