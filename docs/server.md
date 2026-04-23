# Server

`zono.Server` is the built-in runtime. It binds a listening socket,
accepts connections, drives the request/response loop, and hands each
request through your `App`.

## Lifecycle

```zig
const std = @import("std");
const zono = @import("zono");

pub fn main() !void {
    var io = try std.Io.Threaded.init(std.heap.smp_allocator);
    defer io.deinit();

    var app = zono.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.get("/", struct {
        fn run(c: *zono.Context) zono.Response { return c.text("hi"); }
    }.run);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080),
    });
    try server.serve(io.io(), &app);
}
```

`serve` runs until either the accept loop fails or `stop` is observed
across an accept iteration.

## Options

```zig
pub const Options = struct {
    address: std.Io.net.IpAddress,
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 64 * 1024,

    /// Maximum bytes accepted in a single request body. Requests
    /// exceeding this limit receive `413 Payload Too Large` and the
    /// connection is closed (no follow-up keep-alive request).
    max_body_bytes: usize = 4 * 1024 * 1024,

    /// Buffer handed to streaming/SSE writers. Larger values reduce
    /// syscalls; smaller values lower latency for chatty event streams.
    stream_buffer_size: usize = 8 * 1024,

    /// Per-request wall-clock deadline (milliseconds). Includes header
    /// parse, body read, handler execution, and body write. `0` disables.
    request_timeout_ms: u64 = 30_000,

    /// On `Server.stop`, wait this long for in-flight connections to
    /// finish before forcibly canceling them. `0` cancels immediately.
    shutdown_drain_ms: u64 = 5_000,
};
```

### `request_timeout_ms` and long-lived handlers

The default deadline (30s) is fine for ordinary request/response.
Streaming, SSE, and WebSocket handlers can run for minutes or hours
and **must** be configured explicitly:

- For long streams set `request_timeout_ms = 0` and rely on the
  writer's `isAborted()` to drop work when the peer goes away (see
  [streaming.md](./streaming.md)).
- For WebSocket-heavy services set `request_timeout_ms = 0` and
  enforce per-connection deadlines inside your handler.

If you need both short HTTP timeouts and long-lived WebSocket sessions,
run two `Server` instances bound to different ports, each with their
own deadline.

## Stopping cleanly

`Server.stop` is signal-handler safe — it just flips an atomic flag.
**It does not wake an `accept` blocked in the kernel.** To return from
`serve` you have to make one more connection arrive (the loop sees the
flag and breaks out cleanly without dispatching the dummy connection).

The recommended pattern for shutdown on POSIX is:

```zig
// In a SIGINT/SIGTERM handler.
server.stop(io);
// Open a throwaway connection so the accept loop wakes up.
var s = try addr.connect(io);
s.close(io);
```

`shutdown_drain_ms` controls how long `serve` waits for in-flight
handlers after the loop breaks. After the budget elapses, remaining
handlers are canceled.

## Reading the bound port

When you bind to port `0` (ephemeral), use `server.bound_port` after
`serve` has had a moment to bind:

```zig
// On a worker thread that's running `serve`.
const port = server.bound_port.load(.acquire);
```

Useful for tests that need to know which port to connect to.
