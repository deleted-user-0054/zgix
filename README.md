# zgix

A thin Zig web toolkit built around a merjs-style request -> route -> response pipeline.

## Highlights

- Thin request/response handlers: `fn(req: zgix.Request) zgix.Response`
- Explicit route registration through `zgix.App`
- Exact-path plus dynamic-parameter routing through `zgix.Router`
- Minimal server runtime under `zgix.Server`
- JSON parsing and typed JSON responses without the old context/middleware stack

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
| Requests/sec (wrk) | **110165.64** | **86907.92** | **1317.93** |
| Avg latency | **530.82us 1.03ms** | **679.81us 787.30us** | **88.68ms 155.32ms** |
| RAM usage (under load) | **52.7 MB** | **3.2 MB** | **72.3 MB** |
<!-- BENCH:END -->

## Examples

- `zig build run-benchmark`
