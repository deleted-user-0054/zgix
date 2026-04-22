# zono

A thin Zig web toolkit built around a merjs-style request -> route -> response pipeline.

## Highlights

- Thin request/response handlers: `fn(req: zono.Request) zono.Response`
- Explicit route registration through `zono.App`
- Exact-path plus dynamic-parameter routing through `zono.Router`
- Hono-inspired route composition and middleware with `basePath()`, `route()`, `mount()`, `use()`, `useAt()`, `on()`, and `all()`
- Minimal Hono-style `Context` handlers and middleware through `fn(c: *zono.Context) zono.Response`
- App-level error handling through `app.onError()` and `!zono.Response` handlers
- Configurable `strict`, automatic `OPTIONS`, and `405 Method Not Allowed` behavior through `App.initWithOptions()`
- Minimal server runtime under `zono.Server`
- Request helpers for params, parsed params/query/cookie/header views, header lookup, cookies, and typed JSON parsing
- `application/x-www-form-urlencoded` parsing, Hono-style `multipart/form-data` body/file parsing through `Request.parseBody()`, `Response.cookie()`, and a low-level `zono.body()` response helper
- `app.request()` for lightweight route testing without the server runtime

## Quick Start

Requirements: Zig 0.16.0

Build and run the benchmark example:

```bash
zig build run-benchmark
```

Build the benchmark example without running it:

```bash
zig build example-benchmark
```

Run library tests:

```bash
zig build test
```

## Benchmark

CI benchmarks compare:

- `zono` `examples/benchmark.zig` on `GET /api/json`
- `zono` `examples/benchmark.zig` on `GET /api/context-json` through a `Context` handler
- A trimmed `merjs` starter-style baseline on `GET /api/json`
  based on upstream release tag `v0.2.5`
  with the release's shipped threaded runtime fallback on Linux CI
- A generated Next.js baseline on `GET /api/json`

The three benchmarks run as isolated GitHub Actions jobs. All three baselines
return the same tiny JSON payload and are warmed once before running three
measured `wrk -t2 -c100 -d10s` samples. The table publishes the median
Requests/sec run together with its matching latency. Build time is intentionally
excluded from the table because the `merjs` row is treated as a release-tag
runtime baseline rather than a source-build comparison.

**CI benchmarks** (GitHub Actions, auto-updated on each push to `main`):

Raw snapshot: [benchmarks/latest.json](./benchmarks/latest.json)

<!-- BENCH:START -->
| Metric | **zono** | **merjs** | **Next.js** |
|--------|----------|-----------|-------------|
| Requests/sec (wrk median) | **167310.02** | **84118.65** | **1454.38** |
| Requests/sec (context route) | **163117.34** | - | - |
| Avg latency | **343.85us 260.75us** | **704.31us 755.42us** | **86.86ms 154.48ms** |
| Avg latency (context route) | **359.17us 284.51us** | - | - |
| RAM usage (under load) | **48.4 MB** | **3.2 MB** | **9.7 MB** |
<!-- BENCH:END -->

## Examples

- `zig build run-benchmark`

### Route Composition

```zig
const std = @import("std");
const zono = @import("zono");

fn listUsers(_: zono.Request) zono.Response {
    return zono.text(.ok, "users");
}

fn notFound(req: zono.Request) zono.Response {
    return zono.text(.not_found, req.path);
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    var users = zono.App.init(std.heap.page_allocator);
    defer users.deinit();

    try app.basePath("/api");
    try users.get("/", listUsers);
    try app.route("/users", &users);
    app.notFound(notFound);
}
```

### Middleware

```zig
const std = @import("std");
const zono = @import("zono");

fn logger(req: zono.Request, next: zono.App.Next) zono.Response {
    var res = next.run(req);
    _ = res.header("x-middleware", req.path);
    return res;
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(logger);
}
```

### Route-Level Middleware

```zig
const std = @import("std");
const zono = @import("zono");

fn auth(req: zono.Request, next: zono.App.Next) zono.Response {
    var res = next.run(req);
    _ = res.header("x-auth", "1");
    return res;
}

fn showPost(_: zono.Request) zono.Response {
    return zono.text(.ok, "post");
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/posts/:id", .{ auth, showPost });
}
```

### Context

```zig
const std = @import("std");
const zono = @import("zono");

fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    c.set("framework", "zono") catch return zono.internalError("set failed");
    _ = c.header("x-powered-by", "zono");
    next.run();
    return c.takeResponse();
}

fn hello(c: *zono.Context) zono.Response {
    const framework = c.vars.get([]const u8, "framework") orelse "unknown";
    c.status(.created);
    return c.json(.{
        .message = "hello",
        .framework = framework,
    });
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *zono.Context) zono.Response {
            c.status(.bad_request);
            return c.text(@errorName(err));
        }
    }.run);
    try app.use(poweredBy);
    try app.get("/hello", hello);
}
```

### Request Testing

```zig
const std = @import("std");
const zono = @import("zono");

fn search(req: zono.Request) zono.Response {
    return zono.text(.ok, req.query("q") orelse "missing");
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

### Aggregating Path Params

```zig
const zono = @import("zono");

fn showPost(req: zono.Request) zono.Response {
    var params = req.parseParams(.{}) catch return zono.internalError("invalid params");
    defer params.deinit();

    const slug = params.value("slug") orelse "missing";
    const body = req.allocator.dupe(u8, slug) catch return zono.internalError("alloc failed");
    return zono.text(.ok, body);
}
```

### Aggregating Headers

```zig
const zono = @import("zono");

fn guarded(req: zono.Request) zono.Response {
    var headers = req.header(.all) catch return zono.internalError("invalid headers");
    defer headers.deinit();

    if (headers.value("x-mode") == null) {
        return zono.text(.bad_request, "missing x-mode");
    }

    return zono.text(.ok, "ok");
}
```

### Parsing Multipart Files

```zig
const zono = @import("zono");

fn upload(req: zono.Request) zono.Response {
    var body = req.parseBody(.{}) catch return zono.text(.bad_request, "invalid multipart body");
    defer body.deinit();

    const avatar = body.file("avatar") orelse return zono.text(.bad_request, "missing avatar");
    _ = avatar;

    return zono.text(.ok, body.value("display_name") orelse "ok");
}
```

### Mounting Prefixed Handlers

```zig
const std = @import("std");
const zono = @import("zono");

fn legacy(req: zono.Request) zono.Response {
    return zono.text(.ok, req.path);
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.mount("/legacy", legacy);
}
```

### Configuring Strict Routing

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.initWithOptions(std.heap.page_allocator, .{
        .strict = false,
        .handle_options = false,
    });
    defer app.deinit();
}
```

### Setting Cookies

```zig
const zono = @import("zono");

fn login(req: zono.Request) zono.Response {
    var res = zono.text(.ok, "ok");
    res.cookie(req.allocator, "session", "abc123", .{
        .http_only = true,
        .secure = true,
        .same_site = .lax,
    }) catch return zono.internalError("cookie write failed");
    return res;
}
```

### Parsing Form Bodies

```zig
const zono = @import("zono");

fn submit(req: zono.Request) zono.Response {
    var body = req.parseBody(.{
        .all = true,
    }) catch return zono.text(.bad_request, "invalid form body");
    defer body.deinit();

    const tags = body.values("tag") orelse &.{};
    _ = tags;

    return zono.text(.ok, body.value("title") orelse "missing");
}
```
