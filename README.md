# zono

A thin Zig web toolkit built around a merjs-style request -> route -> response pipeline.

## Highlights

- Thin request/response handlers: `fn(req: zono.Request) zono.Response`
- Explicit route registration through `zono.App`
- Exact-path, optional params, regex params, and middle-wildcard routing through `zono.Router`
- Hono-inspired route composition and middleware with `basePath()`, `route()`, `mount()`, `use()`, `useAt()`, `on()`, and `all()`
- Minimal Hono-style `Context` handlers and middleware through `fn(c: *zono.Context) zono.Response`
- App-level and route-level error handling through `app.onError()`, `zono.routeOnError()`, and `!zono.Response` handlers
- Route metadata helpers through `req.routePath()`, `req.baseRoutePath()`, `req.matchedRoutes()`, and `zono.routePath(...)`
- Configurable `strict`, automatic `OPTIONS`, and `405 Method Not Allowed` behavior through `App.initWithOptions()`
- Minimal server runtime under `zono.Server`
- Request helpers for params, parsed params/query/cookie/header views, `.all` aggregate access, cookies, and typed JSON parsing
- `application/x-www-form-urlencoded` parsing, Hono-style `multipart/form-data` body/file parsing, and dotted-key grouping through `Request.parseBody()`, `Response.cookie()`, and a low-level `zono.body()` response helper
- Thin platform context hooks through `req.raw`, `c.env`, `c.executionCtx`, and `c.event`
- Web-style request body helpers through `req.arrayBuffer()`, `req.blob()`, and `req.formData()`
- Context rendering and validated-data hooks through `c.setRenderer()`, `c.render()`, `c.setValid()`, `req.valid()`, and `zono.validator(...)`
- Built-in helpers for `zono.serveStatic()`, `zono.cors()`, `zono.logger()`, `zono.secureHeaders()`, `zono.bodyLimit()`, `zono.etag()`, `zono.compress()`, `zono.requestId()`, `zono.basicAuth()`, `c.stream()`, `c.streamSSE()`, `c.sse()`, `c.upgradeWebSocket()`, and target-specific validator sugar such as `zono.validatorQuery(...)`
- Lightweight `HTTPException` handling through `c.throw()` / `req.throw()`
- `app.request()`, `app.fetchRaw()`, `app.fetchRawResponse()`, and response adapters such as `zono.toRawResponse()` for lightweight route testing and raw adapter entry points without the server runtime

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
- A generated Bun + Hono baseline on `GET /api/json`
- A generated Next.js baseline on `GET /api/json`

The four benchmarks run as isolated GitHub Actions jobs. All four baselines
return the same tiny JSON payload and are warmed once before running three
measured `wrk -t2 -c100 -d10s` samples. The table publishes the median
Requests/sec run together with its matching latency. Build time is intentionally
excluded from the table because the `merjs` row is treated as a release-tag
runtime baseline rather than a source-build comparison.

**CI benchmarks** (GitHub Actions, auto-updated on each push to `main`):

Raw snapshot: [benchmarks/latest.json](./benchmarks/latest.json)

<!-- BENCH:START -->
| Metric | **zono** | **merjs** | **Hono** | **Next.js** |
|--------|----------|-----------|----------|-------------|
| Requests/sec (wrk median) | **99635.41** | **84275.30** | **44673.96** | **1508.77** |
| Requests/sec (context route) | **95011.68** | - | - | - |
| Avg latency | **551.54us 305.58us** | **681.94us 478.54us** | **2.24ms 656.65us** | **88.01ms 163.80ms** |
| Avg latency (context route) | **582.34us 336.44us** | - | - | - |
| RAM usage (under load) | **58.5 MB** | **3.2 MB** | **51.7 MB** | **9.6 MB** |
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

### Advanced Route Patterns

```zig
const std = @import("std");
const zono = @import("zono");

fn show(req: zono.Request) zono.Response {
    return zono.text(.ok, req.param("id") orelse "index");
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

### Built-In Middleware

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(zono.cors(.{
        .allow_origin = .mirror,
        .allow_credentials = true,
    }));
    try app.use(zono.logger(.{}));
    try app.use(zono.secureHeaders(.{}));
    try app.use(zono.bodyLimit(1024 * 1024));
    try app.use(zono.etag(.{}));
    try app.use(zono.compress(.{
        .min_bytes = 128,
    }));
    try app.use(zono.requestId(.{
        .prefix = "req_",
    }));
    try app.use(zono.basicAuth(.{
        .username = "admin",
        .password = "secret",
    }));
}
```

### Route Listing

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.useAt("/api", struct {
        fn run(req: zono.Request, next: zono.App.Next) zono.Response {
            return next.run(req);
        }
    }.run);
    try app.get("/posts/:id", struct {
        fn run(_: zono.Request) zono.Response {
            return zono.text(.ok, "post");
        }
    }.run);

    const listing = try app.showRoutes(std.heap.page_allocator);
    defer std.heap.page_allocator.free(listing);
    std.debug.print("{s}", .{listing});
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

### Route-Level Error Handling

```zig
const std = @import("std");
const zono = @import("zono");

fn auth(req: zono.Request, next: zono.App.Next) zono.Response {
    return next.run(req);
}

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/posts/:id", .{
        zono.routeOnError(struct {
            fn run(err: anyerror, c: *zono.Context) zono.Response {
                return c.textWithStatus(.bad_request, @errorName(err));
            }
        }.run),
        auth,
        struct {
            fn run(_: zono.Request) !zono.Response {
                return error.InvalidPostId;
            }
        }.run,
    });
}
```

### Route Helpers

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.basePath("/api");
    try app.useAt("/posts", struct {
        fn run(c: *zono.Context, next: zono.Context.Next) zono.Response {
            next.run();
            const route_path = zono.routePath(c) orelse "missing";
            const base_route_path = zono.baseRoutePath(c) orelse "";
            const matched = zono.matchedRoutes(c);
            _ = c.header("x-route", route_path);
            return c.textWithStatus(.ok, if (matched.len > 0) base_route_path else "missing");
        }
    }.run);
    try app.get("/posts/:id", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.text(c.req.param("id") orelse "missing");
        }
    }.run);
}
```

### Validator

```zig
const std = @import("std");
const zono = @import("zono");

const Query = struct {
    page: u32,
};

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(zono.validatorQuery(struct {
        fn run(req: zono.Request) !Query {
            var query = try req.parseQuery(.{});
            defer query.deinit();

            const raw_page = query.value("page") orelse return error.MissingPage;
            return .{
                .page = try std.fmt.parseInt(u32, raw_page, 10),
            };
        }
    }.run));
    try app.get("/posts", struct {
        fn run(req: zono.Request) zono.Response {
            const query = req.valid(Query, .query) orelse return zono.internalError("missing query");
            return zono.text(.ok, if (query.page == 1) "page-1" else "other");
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

    try app.get("/assets/*path", zono.serveStatic(.{
        .root = "public",
        .cache_control = "public, max-age=3600",
        .etag = true,
        .last_modified = true,
        .prefer_precompressed_gzip = true,
    }));
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
    return c.jsonWithStatus(.created, .{
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

### HTTPException

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    app.onError(struct {
        fn run(err: anyerror, c: *zono.Context) zono.Response {
            if (err == error.HTTPException) {
                const exception = c.httpException() orelse return c.textWithStatus(.internal_server_error, "missing");
                return c.textWithStatus(exception.status, exception.message);
            }
            return c.textWithStatus(.internal_server_error, @errorName(err));
        }
    }.run);
    try app.get("/teapot", struct {
        fn run(c: *zono.Context) !zono.Response {
            return c.throw(zono.HTTPException.init(.im_a_teapot, "tea"));
        }
    }.run);
}
```

### Rendering

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(struct {
        fn run(c: *zono.Context, next: zono.Context.Next) zono.Response {
            c.setRenderer(struct {
                fn render(ctx: *zono.Context, content: []const u8) zono.Response {
                    const page = std.fmt.allocPrint(ctx.req.allocator, "<main>{s}</main>", .{content}) catch {
                        return zono.internalError("alloc failed");
                    };
                    return ctx.html(page);
                }
            }.render);
            next.run();
            return c.takeResponse();
        }
    }.run);

    try app.get("/render", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.render("hello");
        }
    }.run);
}
```

### SSE And WebSocket Handshakes

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/events", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.sse(&[_]zono.SSEEvent{
                .{ .event = "ready", .data = "hello" },
            });
        }
    }.run);

    try app.get("/ws", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.acceptWebSocket(.{
                .protocol = "chat",
            }) catch zono.text(.bad_request, "upgrade required");
        }
    }.run);
}
```

### Streaming Runtime

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/stream", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.stream(struct {
                fn write(writer: *zono.StreamWriter) !void {
                    try writer.writeAll("hello ");
                    try writer.writeAll("stream");
                }
            }.write, .{
                .content_type = "text/plain; charset=utf-8",
            });
        }
    }.run);

    try app.get("/events-live", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.streamSSE(struct {
                fn write(writer: *zono.StreamWriter) !void {
                    try writer.writeAll("event: ready\n");
                    try writer.writeAll("data: hello\n\n");
                }
            }.write);
        }
    }.run);

    try app.get("/ws-runtime", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.upgradeWebSocket(struct {
                fn handle(socket: *zono.WebSocketConnection) !void {
                    try socket.writeText("connected");
                    try socket.flush();
                    try socket.close("");
                }
            }.handle, .{});
        }
    }.run);
}
```

### Raw Fetch Adapter

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/hello", struct {
        fn run(c: *zono.Context) zono.Response {
            return c.json(.{
                .mode = c.req.query("mode") orelse "",
            });
        }
    }.run);

    var res = try app.fetchRaw(std.heap.page_allocator, .{
        .target = "https://example.com/hello?mode=edge",
    }, .{});
    defer res.deinit();

    var raw_res = try app.fetchRawResponse(std.heap.page_allocator, .{
        .target = "https://example.com/hello?mode=edge",
    }, .{});
    defer raw_res.deinit();
}
```

### Validator With Custom Errors

```zig
const std = @import("std");
const zono = @import("zono");

const Query = struct {
    page: u32,
};

pub fn main() !void {
    var app = zono.App.init(std.heap.page_allocator);
    defer app.deinit();

    try app.use(zono.validatorQueryWithOptions(struct {
        fn run(req: zono.Request) !Query {
            var query = try req.query(.all);
            defer query.deinit();

            const raw_page = query.value("page") orelse return error.MissingPage;
            return .{
                .page = try std.fmt.parseInt(u32, raw_page, 10),
            };
        }
    }.run, .{
        .on_error = struct {
            fn run(err: anyerror, c: *zono.Context) zono.Response {
                return c.jsonWithStatus(.bad_request, .{
                    .error = @errorName(err),
                });
            }
        }.run,
    }));
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

### Platform Context

```zig
const std = @import("std");
const zono = @import("zono");

const Env = struct {
    mode: []const u8,
};

fn showPlatform(c: *zono.Context) zono.Response {
    const env = c.envAs(Env) orelse return zono.text(.internal_server_error, "missing env");
    return c.text(env.mode);
}

test "platform values" {
    var app = zono.App.init(std.testing.allocator);
    defer app.deinit();

    try app.get("/platform", showPlatform);

    const env = Env{ .mode = "test" };
    var res = try app.request(std.testing.allocator, "/platform", .{
        .env = @ptrCast(&env),
    });
    defer res.deinit();

    try std.testing.expectEqualStrings("test", res.body);
}
```

### Aggregating Path Params

```zig
const zono = @import("zono");

fn showPost(req: zono.Request) zono.Response {
    var params = req.param(.all) catch return zono.internalError("invalid params");
    defer params.deinit();

    const slug = params.value("slug") orelse "missing";
    const body = req.allocator.dupe(u8, slug) catch return zono.internalError("alloc failed");
    return zono.text(.ok, body);
}
```

### Aggregating Query And Cookies

```zig
const zono = @import("zono");

fn search(req: zono.Request) zono.Response {
    var query = req.query(.all) catch return zono.text(.bad_request, "invalid query");
    defer query.deinit();

    var cookies = req.cookie(.all) catch return zono.internalError("invalid cookies");
    defer cookies.deinit();

    _ = cookies.value("theme");
    return zono.text(.ok, query.value("q") orelse "missing");
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

### Web-Style Body Helpers

```zig
const zono = @import("zono");

fn upload(req: zono.Request) zono.Response {
    const bytes = req.arrayBuffer();
    const blob = req.blob();
    _ = bytes;
    _ = blob;

    var form = req.formData() catch return zono.text(.bad_request, "invalid form data");
    defer form.deinit();

    return zono.text(.ok, form.value("title") orelse "ok");
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
        .dot = true,
    }) catch return zono.text(.bad_request, "invalid form body");
    defer body.deinit();

    var user = body.group("user") catch return zono.internalError("group failed");
    defer user.deinit();

    const avatar = user.file("avatar") orelse return zono.text(.bad_request, "missing avatar");
    _ = avatar;

    return zono.text(.ok, user.value("name") orelse "missing");
}
```

### Validated Data

```zig
const zono = @import("zono");

const Query = struct {
    page: u32,
};

fn validator(c: *zono.Context, next: zono.Context.Next) zono.Response {
    c.setValid(.query, Query{ .page = 3 }) catch return zono.internalError("valid failed");
    next.run();
    return c.takeResponse();
}

fn list(req: zono.Request) zono.Response {
    const query = req.valid(Query, .query) orelse return zono.text(.bad_request, "missing query");
    return zono.text(.ok, if (query.page == 3) "page-3" else "bad");
}
```
