# Routing & composition

zono's router supports the same shapes you'd expect from `Hono`:

- exact paths (`/users`)
- named params (`/users/:id`)
- optional params (`/posts/:id?`)
- regex-constrained params (`/assets/:version{[0-9]+}`)
- middle wildcards (`/docs/*/edit`)

Routes are registered on an `App`. Apps can be nested with `route()`,
mounted with `mount()`, and prefixed with `basePath()`. Calls become
const after `App.finalize()` (which `Server.serve` does for you).

## Methods

```zig
try app.get("/users", listUsers);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.patch("/users/:id", patchUser);
try app.delete("/users/:id", deleteUser);
try app.head("/users/:id", showUser);
try app.options("/users/:id", showUser);

// Multi-method / multi-path. Either argument may be a single value or
// an array literal.
try app.on(.{ .GET, .POST }, .{ "/a", "/b" }, handler);

// Match every method on a path (handler decides what to do).
try app.all("/raw", rawHandler);
```

## Path patterns

```zig
// Required param.
try app.get("/users/:id", show);

// Optional trailing param. `c.req.param("id")` is `null` when omitted.
try app.get("/posts/:id?", show);

// Regex constraint. The `:version` segment must match `[0-9]+`.
try app.get("/assets/:version{[0-9]+}", show);

// Middle wildcard. Matches one segment.
try app.get("/docs/*/edit", show);
```

## `basePath` + `route`

```zig
var api = zono.App.init(allocator);
defer api.deinit();
try api.basePath("/v1");
try api.get("/users", listUsers);   // routed at /v1/users

var app = zono.App.init(allocator);
defer app.deinit();
try app.basePath("/api");
try app.route("/", &api);           // /api -> /api/v1/users
```

`route()` copies the child's routes/middleware into the parent under
the given prefix; the child can be deinit'd or left alive — either
works.

## `mount`

`mount` accepts either a child `*App` or a bare `Handler` for a glob
catch-all. Useful for serving a sub-tree handled by a third-party
component or a single SPA fallback:

```zig
try app.mount("/admin", &admin_app);
try app.mount("/spa/*", spaHandler);
```

## App options

```zig
var app = zono.App.initWithOptions(allocator, .{
    .strict = false,                  // disable trailing-slash redirect
    .redirect_fixed_path = true,      // case/clean-path redirect
    .handle_method_not_allowed = true,// auto 405 with Allow header
    .handle_options = true,           // auto OPTIONS responder
});
```

`strict = true` (the default) makes `/users` and `/users/` distinct and
issues a 308 redirect to the canonical form.

## Inspecting routes

```zig
const dump = try app.showRoutes(allocator);
defer allocator.free(dump);
std.debug.print("{s}\n", .{dump});
```

Writes one line per registered route in `METHOD path` form.
