# Middleware

Middleware in zono is a function that wraps a request, observes or
mutates the response, and decides whether/when to call the next layer.

## Signature

```zig
fn poweredBy(c: *zono.Context, next: zono.Context.Next) zono.Response {
    next.run();                        // run downstream first
    _ = c.header("x-powered-by", "zono");
    return c.takeResponse();           // hand the (possibly modified) response back
}
```

`next.run()` is mandatory if you want downstream handlers to execute.
After it returns, the downstream `Response` lives on the `Context`;
`c.takeResponse()` transfers ownership back to you. You can mutate
headers/status before returning.

To short-circuit, just don't call `next.run()` and return a response
yourself:

```zig
fn requireApiKey(c: *zono.Context, next: zono.Context.Next) zono.Response {
    if (c.req.header("x-api-key") == null) {
        return c.textWithStatus(.unauthorized, "missing key");
    }
    next.run();
    return c.takeResponse();
}
```

## Registering

```zig
try app.use(poweredBy);                // applies to every route
try app.useAt("/admin", requireApiKey);// applies to /admin/*
```

`useAt` matches the prefix as a path segment boundary, so
`useAt("/admin", ...)` runs for `/admin` and `/admin/users` but not
`/administrator`.

## Ordering

Middleware runs in registration order. Within a sub-`App` mounted via
`route()` / `mount()`, the parent's middleware runs first, then the
child's, then the route handler. Returning from `next.run()` unwinds
in reverse order — write logging / timing middleware as a normal
"before + after" pair around `next.run()`.

## Sharing state with handlers

Use `c.set` / `c.get` to pass typed values along the chain:

```zig
fn injectUser(c: *zono.Context, next: zono.Context.Next) zono.Response {
    const user = lookupUser(c.req) orelse return c.textWithStatus(.unauthorized, "no user");
    c.set("user", user) catch return zono.internalError("set failed");
    next.run();
    return c.takeResponse();
}

fn me(c: *zono.Context) zono.Response {
    const user = c.get(User, "user") orelse return c.textWithStatus(.unauthorized, "no user");
    return c.json(user);
}
```

Values stored via `c.set` live in the per-request arena and disappear
once the response is fully sent.

## Built-in middleware

- [`zono.serveStatic`](./static.md) — file serving with ETag/Range.
- [`zono.requestId`](./request-id.md) — `X-Request-ID` propagation.

Both are ordinary middleware values; they sit in the same chain as
your own `use()` registrations.
