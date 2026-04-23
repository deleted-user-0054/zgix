# Testing

Two layers of testing helpers ship with zono:

- `App.request` — drives a route through the same handler stack the
  server uses, but in-memory. Best for ordinary handlers.
- `WsClient` — opens a real WebSocket connection over loopback to a
  `Server` running in the same process. Best for upgrade routes.

## `App.request` (HTTP-style)

```zig
const std = @import("std");
const zono = @import("zono");

fn search(c: *zono.Context) zono.Response {
    return c.text(c.req.query("q") orelse "missing");
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

`request()` accepts either:

- a string path (`"/search?q=zig"`), or
- a `RequestOptions` struct with `.method`, `.headers`, `.body`,
  `.cookies_raw`.

Returns a `Response` value with `.status`, `.body` (decoded), and
helpers like `headerValue("name")`. `body` is allocated via the
allocator you pass; call `res.deinit()` to free.

`request()` is **not** suitable for WebSocket upgrade routes — the
upgrade returns a `.websocket` body that the in-memory transport can't
realise. Use `WsClient` for those.

## `WsClient` (WebSocket roundtrips)

```zig
const std = @import("std");
const zono = @import("zono");

test "ws echo" {
    const alloc = std.testing.allocator;

    var io_impl = try std.Io.Threaded.init(alloc);
    defer io_impl.deinit();
    const io = io_impl.io();

    var app = zono.App.init(alloc);
    defer app.deinit();
    try app.get("/ws", echoRoute);

    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0),
        .request_timeout_ms = 0,   // long-lived
    });

    // Run the server on a worker task and wait for it to bind.
    var serve_group: std.Io.Group = .init;
    defer serve_group.cancel(io);
    try serve_group.concurrent(io, runServe, .{ &server, io, &app });
    const port = waitForBind(&server);

    var client = try zono.WsClient.connect(alloc, io, port, .{ .path = "/ws" });
    defer client.close();

    try client.sendText("hello");
    const reply = try client.receive();
    try std.testing.expect(reply.kind == .text);
    try std.testing.expectEqualStrings("hello", reply.payload);
}
```

### API surface

```zig
pub fn connect(
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    opts: ConnectOptions,
) !*WsClient;

pub fn sendText(self: *WsClient, payload: []const u8) !void;
pub fn sendBinary(self: *WsClient, payload: []const u8) !void;
pub fn sendPing(self: *WsClient, payload: []const u8) !void;
pub fn sendPong(self: *WsClient, payload: []const u8) !void;
pub fn sendCloseFrame(self: *WsClient, code: u16, reason: []const u8) !void;
pub fn receive(self: *WsClient) !Message;
pub fn close(self: *WsClient) void;
```

`receive()` transparently:

- reassembles fragments into a single `Message`
- auto-pongs inbound pings between data frames
- surfaces close frames as `Message{ .kind = .close, .close_code = .., .payload = reason }`

`Message.payload` lives in the client's receive buffer and is only
valid until the next `receive` / `close` call. Copy it if you need
to keep it.

### `ConnectOptions`

```zig
pub const ConnectOptions = struct {
    protocol: ?[]const u8 = null,            // Sec-WebSocket-Protocol
    extra_headers: []const std.http.Header = &.{},
    path: []const u8 = "/",                  // request URI
    host: []const u8 = "127.0.0.1",          // Host header
    read_buf_len: usize = 8 * 1024,
    write_buf_len: usize = 64 * 1024,
};
```

`extra_headers` excludes the standard handshake headers (Host,
Upgrade, Connection, `Sec-WebSocket-Key`, `Sec-WebSocket-Version`),
which are filled in for you.

### Platform notes

zono's own WS test suite skips four roundtrip tests on Windows due to
a known IOCP edge case in `std.Io.Threaded` where same-process
client/server reads occasionally surface a spurious
`LOCAL_DISCONNECT`. The protocol code itself is exercised on POSIX.
If you write tests around `WsClient`, consider gating with
`if (builtin.os.tag == .windows) return error.SkipZigTest;` for
roundtrip-heavy cases until upstream stabilises.

See `src/ws_test_client.zig` for the full source — it's small (<800
lines) and uncontroversial; copy or adapt it if your needs diverge.
