# zgix

A thin Zig web toolkit built around a merjs-style request -> route -> response pipeline.

## Highlights

- Thin request/response handlers: `fn(req: zgix.Request) zgix.Response`
- Explicit route registration through `zgix.App`
- Exact-path plus dynamic-parameter routing through `zgix.Router`
- Hono-inspired route composition with `basePath()`, `route()`, `on()`, and `all()`
- Minimal server runtime under `zgix.Server`
- Request helpers for params, query strings, headers, cookies, and typed JSON parsing
- Inline response headers without a middleware/context allocation layer

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
| Requests/sec (wrk) | **114649.39** | **86694.25** | **1324.28** |
| Avg latency | **525.70us 1.20ms** | **681.24us 772.79us** | **88.44ms 155.47ms** |
| RAM usage (under load) | **57.6 MB** | **3.2 MB** | **71.7 MB** |
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
