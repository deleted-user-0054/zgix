# Static files

`zono.serveStatic` is middleware that maps a URL path onto a directory
and streams matching files with `sendfile`-style zero-copy delivery.
It also implements the conditional-GET and `Range` features that
browsers and CDNs expect.

## Quick start

```zig
try app.use(zono.serveStatic(.{
    .root = "public",
    .cache_control = "public, max-age=3600",
}));
```

That's enough to serve `public/index.html` at `/`, `public/app.js` at
`/app.js`, etc. When no file matches the request, `serveStatic` calls
`next.run()` so a downstream route (or `notFound` handler) can respond.

## Options

```zig
pub const ServeStaticOptions = struct {
    root: []const u8,
    /// URL prefix to strip before resolving against `root`. When null,
    /// the request path is used as-is (relative to `/`).
    path: ?[]const u8 = null,
    /// Filename served for directory requests. Set to `null` to disable.
    index: ?[]const u8 = "index.html",
    /// Optional `Cache-Control` header value.
    cache_control: ?[]const u8 = null,
    /// Override the auto-detected `Content-Type`.
    content_type: ?[]const u8 = null,
    /// Hard cap on file size; larger files return 500 to avoid surprises.
    max_bytes: u64 = 16 * 1024 * 1024,
};
```

Common shape: mount a directory at a non-root URL prefix.

```zig
try app.use(zono.serveStatic(.{
    .root = "public/assets",
    .path = "/assets",   // /assets/foo.png -> public/assets/foo.png
    .cache_control = "public, max-age=31536000, immutable",
}));
```

## Conditional GET

Each response carries:

- `ETag` — weak, derived from `size-mtime` (`W/"<size>-<mtime>"`).
- `Last-Modified` — RFC 1123 from the file mtime.

Incoming `If-None-Match` and `If-Modified-Since` headers short-circuit
to `304 Not Modified` (no body) when they match. `If-Match` and
`If-Unmodified-Since` follow the same rules with `412 Precondition
Failed` on mismatch.

## Range / 206

Single-range `Range: bytes=START-END` requests are honored with
`206 Partial Content`, the appropriate `Content-Range` header, and a
sliced body. Missing endpoints (`bytes=100-`, `bytes=-500`) work as
specified.

`If-Range` is honored: if the validator (ETag or HTTP-date) matches,
the server returns the requested 206; otherwise the full file is
returned with 200.

Unsatisfiable ranges produce `416 Range Not Satisfiable` with a
`Content-Range: bytes */<size>` header.

Multi-range requests are intentionally not supported and are downgraded
to a 200 full-body response.

## `HEAD`

`HEAD` requests share the same code path as `GET` but skip the body —
all headers (size, ETag, Range support, etc.) are emitted as on a real
`GET`.

## Direct file responses

If you need to serve a file from inside a regular handler (rather than
catching it with the middleware), use `Response.file`:

```zig
fn download(c: *zono.Context) zono.Response {
    return zono.Response.file(
        "exports/report.csv",
        "text/csv; charset=utf-8",
        .{ .max_bytes = 50 * 1024 * 1024 },
    );
}
```

`FileRuntime` (the embedded payload) supports the same `offset`,
`length`, `head_only`, and `path_owner` fields used internally by
`serveStatic`. See [`response.zig`](../src/response.zig) for the full
struct.
