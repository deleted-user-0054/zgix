# Hooks

Two app-level hooks let you customise the unhappy paths:

- `app.notFound(handler)` — when no route matches.
- `app.onError(handler)` — when a fallible handler returns an error
  (handler signature `fn(...) !Response`) **or** when an error escapes
  middleware.

Both are optional. Without them you get framework defaults: a plain
404 and a plain 500 respectively.

## `notFound`

```zig
app.notFound(struct {
    fn run(c: *zono.Context) zono.Response {
        return c.jsonWithStatus(.not_found, .{ .error = "no such route" });
    }
}.run);
```

The handler receives the same `*Context` your normal handlers do, so
you can read headers, set custom status codes, or return JSON — exactly
like a regular route.

## `onError`

```zig
app.onError(struct {
    fn run(err: anyerror, c: *zono.Context) zono.Response {
        return c.textWithStatus(.bad_request, @errorName(err));
    }
}.run);

try app.get("/posts/:id", struct {
    fn run(_: *zono.Context) !zono.Response {
        return error.InvalidPostId;     // -> onError -> 400 InvalidPostId
    }
}.run);
```

Two signatures are accepted:

- `fn(anyerror, *zono.Context) zono.Response` — total. Most common.
- `fn(anyerror, *zono.Context) !zono.Response` — fallible. If your
  error handler itself fails, the framework falls back to a static
  `500 Internal Server Error` body.

### Reentry guard

If your `onError` handler itself errors, zono will **not** call it
again recursively. A flag on the per-request shared state short-circuits
nested errors to the static 500 fallback. This means you can return
`error.Foo` from inside `onError` without worrying about an infinite
loop — but the response the client sees won't be the one you tried to
build.

In practice you almost always want the total signature; reserve the
`!Response` form for cases where the response builder allocates and
allocation failure is meaningful to the caller.

## What counts as an error

- Handlers declared as `fn(...) !zono.Response` returning `error.X`.
- Middleware returning `zono.internalError(...)` will go through
  `onError` only if you wire it that way; the helper itself returns a
  500 response directly.

`onError` is invoked once per request at most. It cannot intercept
errors from streaming bodies after headers have been sent — at that
point the connection is best-effort and the writer's `isAborted()`
becomes true.
