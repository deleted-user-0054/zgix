# zgix

A thin Zig web toolkit built around a merjs-style request -> route -> response pipeline.

## Highlights

- Thin request/response handlers: `fn(req: zgix.Request) zgix.Response`
- Explicit route registration through `zgix.App`
- Exact-path plus dynamic-parameter routing through `zgix.Router`
- Hono-inspired route composition with `basePath()`, `route()`, `mount()`, `on()`, and `all()`
- Configurable `strict`, automatic `OPTIONS`, and `405 Method Not Allowed` behavior through `App.initWithOptions()`
- Minimal server runtime under `zgix.Server`
- Request helpers for params, query strings, headers, cookies, and typed JSON parsing
- `application/x-www-form-urlencoded` parsing, text-only `multipart/form-data` `Request.parseBody()`, `Response.cookie()`, and a low-level `zgix.body()` response helper
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

- `zgix` `examples/benchmark.zig` on `GET /api/json`
- A trimmed `merjs` starter-style baseline on `GET /api/json`
  based on upstream release tag `v0.2.5`
  with the release's shipped threaded runtime fallback on Linux CI
- A generated Next.js baseline on `GET /api/json`

The three benchmarks run as isolated GitHub Actions jobs. All three baselines
return the same tiny JSON payload and are load-tested with `wrk -t2 -c100 -d10s`.
Build time is intentionally excluded from the table because the `merjs` row is
treated as a release-tag runtime baseline rather than a source-build comparison.

**CI benchmarks** (GitHub Actions, auto-updated on each push to `main`):

Raw snapshot: [benchmarks/latest.json](./benchmarks/latest.json)

<!-- BENCH:START -->
| Metric | **zgix** | **merjs** | **Next.js** |
|--------|----------|-----------|-------------|
| Requests/sec (wrk) | **120450.17** | **87279.59** | **1360.60** |
| Avg latency | **508.73us 1.39ms** | **671.87us 630.57us** | **88.02ms 159.41ms** |
| RAM usage (under load) | **48.0 MB** | **3.2 MB** | **9.6 MB** |
<!-- BENCH:END -->

## Examples

- `zig build run-benchmark`

### Route Composition

```zig
const std = @import("std");
const zgix = @import("zgix");

fn listUsers(_: zgix.Request) zgix.Response {
    return zgix.text(.ok, "users");
}

fn notFound(req: zgix.Request) zgix.Response {
    return zgix.text(.not_found, req.path);
}

pub fn main() !void {
    var app = zgix.App.init(std.heap.page_allocator);
    defer app.deinit();

    var users = zgix.App.init(std.heap.page_allocator);
    defer users.deinit();

    try app.basePath("/api");
    try users.get("/", listUsers);
    try app.route("/users", &users);
    app.notFound(notFound);
}
```

### Request Testing

```zig
const std = @import("std");
const zgix = @import("zgix");

fn search(req: zgix.Request) zgix.Response {
    return zgix.text(.ok, req.query("q") orelse "missing");
}

test "search route" {
    var app = zgix.App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/search", search);

    var res = try app.request(std.testing.allocator, "/search?q=zig", .{});
    defer res.deinit();

    try std.testing.expectEqualStrings("zig", res.body);
}
```

### Mounting Prefixed Handlers

```zig
const std = @import("std");
const zgix = @import("zgix");

fn legacy(req: zgix.Request) zgix.Response {
    return zgix.text(.ok, req.path);
}

pub fn main() !void {
    var app = zgix.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.mount("/legacy", legacy);
}
```

### Configuring Strict Routing

```zig
const std = @import("std");
const zgix = @import("zgix");

pub fn main() !void {
    var app = zgix.App.initWithOptions(std.heap.page_allocator, .{
        .strict = false,
        .handle_options = false,
    });
    defer app.deinit();
}
```

### Setting Cookies

```zig
const zgix = @import("zgix");

fn login(req: zgix.Request) zgix.Response {
    var res = zgix.text(.ok, "ok");
    res.cookie(req.allocator, "session", "abc123", .{
        .http_only = true,
        .secure = true,
        .same_site = .lax,
    }) catch return zgix.internalError("cookie write failed");
    return res;
}
```

### Parsing Form Bodies

```zig
const zgix = @import("zgix");

fn submit(req: zgix.Request) zgix.Response {
    var body = req.parseBody(.{
        .all = true,
    }) catch return zgix.text(.bad_request, "invalid form body");
    defer body.deinit();

    const tags = body.values("tag") orelse &.{};
    _ = tags;

    return zgix.text(.ok, body.value("title") orelse "missing");
}
```
