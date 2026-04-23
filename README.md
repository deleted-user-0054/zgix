# zono

`zono` is a thin Zig web toolkit with a backend scope close to `merjs`, but an
API shape inspired by `Hono`.

The public root API intentionally focuses on the core surface:

- `App` for routing, composition, middleware, and errors
- `Context` for Hono-style handler ergonomics
- `Request` for params, query, headers, cookies, and body parsing
- `Response` helpers for text, html, json, redirects, and cookies
- `app.request()` for lightweight route testing

## Highlights

- Hono-style context handlers: `fn(c: *zono.Context) zono.Response`
- Route composition with `basePath()`, `route()`, `mount()`, `on()`, and `all()`
- Middleware with `use()` and `useAt()`
- App-level error handling with `onError()`
- Exact, optional-param, regex-param, and middle-wildcard routes
- Request helpers for `param()`, `query()`, `header()`, `cookie()`, and `.all`
- `parseBody()` for urlencoded and multipart form data
- Lightweight testing through `app.request()`
- Minimal built-in server runtime under `zono.Server`
- Optional `serveStatic()` middleware for simple asset serving
- Optional `upgradeWebSocket()` support for route-level WebSocket upgrades

## Quick Start

Requirements: Zig `0.16.0`

```bash
zig build test
zig build run-benchmark
```

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
| Requests/sec (wrk median) | **158891.55** | **80478.98** |
| Avg latency | **359.01us 255.54us** | **715.51us 526.58us** |
| RAM usage (under load) | **50.5 MB** | **3.2 MB** |
<!-- BENCH:END -->

## Core API

### Route Composition

```zig
const std = @import("std");
const zono = @import("zono");

fn listUsers(c: *zono.Context) zono.Response {
    return c.text("users");
}

fn showUser(c: *zono.Context) zono.Response {
    return c.text(c.req.param("id") orelse "missing");
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    var users = zono.App.init(std.heap.page_allocator);
    defer users.deinit();

    try app.basePath("/api");
    try users.get("/", listUsers);
    try users.get("/:id", showUser);
    try app.route("/users", &users);
}
```

### Advanced Routes

```zig
const std = @import("std");
const zono = @import("zono");

fn show(c: *zono.Context) zono.Response {
    return c.text(c.req.param("id") orelse "index");
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/posts/:id?", show);
    try app.get("/assets/:version{[0-9]+}", show);
    try app.get("/docs/*/edit", show);
}
```

### Middleware

```zig
const std = @import("std");
const zono = @import("zono");

fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    next.run();
    _ = c.header("x-powered-by", "zono");
    return c.takeResponse();
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(poweredBy);
}
```

### Context

```zig
const std = @import("std");
const zono = @import("zono");

fn middleware(c: *zono.Context, next: zono.Context.Next) zono.Response {
    c.set("framework", "zono") catch return zono.internalError("set failed");
    _ = c.header("x-powered-by", "zono");
    next.run();
    return c.takeResponse();
}

fn hello(c: *zono.Context) zono.Response {
    const framework = c.vars.get([]const u8, "framework") orelse "unknown";
    return c.json(.{
        .message = "hello",
        .framework = framework,
    });
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(middleware);
    try app.get("/hello", hello);
}
```

### Error Handling

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

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
}
```

### Static Files

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(zono.serveStatic(.{
        .root = "public",
        .cache_control = "public, max-age=3600",
    }));
}
```

### WebSocket

```zig
const std = @import("std");
const zono = @import("zono");

fn ws(c: *zono.Context) zono.Response {
    return c.upgradeWebSocket(struct {
        fn run(socket: *zono.WebSocketConnection) !void {
            while (true) {
                const message = try socket.readSmallMessage();
                switch (message.opcode) {
                    .text => try socket.writeText(message.data),
                    .binary => try socket.writeBinary(message.data),
                    .connection_close => {
                        try socket.close("");
                        return;
                    },
                    .ping => try socket.writePong(message.data),
                    else => {},
                }
            }
        }
    }.run, .{});
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/ws", ws);
}
```

### Request Helpers

```zig
const zono = @import("zono");

fn search(c: *zono.Context) zono.Response {
    const q = c.req.query("q") orelse "missing";
    const mode = c.req.header("x-mode") orelse "default";
    const theme = c.req.cookie("theme") orelse "light";

    _ = mode;
    _ = theme;
    return c.text(q);
}
```

### Body Parsing

```zig
const zono = @import("zono");

fn createPost(c: *zono.Context) zono.Response {
    var form = c.req.parseBody(.{ .all = true, .dot = true }) catch {
        return c.textWithStatus(.bad_request, "invalid body");
    };
    defer form.deinit();

    const title = form.value("title") orelse "untitled";
    return c.text(title);
}
```

### Request Testing

```zig
const std = @import("std");
const zono = @import("zono");

fn search(c: *zono.Context) zono.Response {
    return c.text(c.req.query("q") orelse "missing");
}

test "search route" {
    var app = zono.App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/search", search);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("zig", res.body);
}
```

`app.request()` is meant for ordinary request/response handlers. WebSocket upgrade
routes should be exercised through `zono.Server` or an integration test client.
