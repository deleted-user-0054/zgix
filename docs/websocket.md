# WebSocket

zono routes WebSocket upgrades through the same router as HTTP. A
handler returns `c.upgradeWebSocket(...)`; the framework completes the
RFC 6455 handshake and hands you a `*WebSocketConnection` to read and
write frames on.

```zig
fn ws(c: *zono.Context) zono.Response {
    return c.upgradeWebSocket(struct {
        fn run(socket: *zono.WebSocketConnection) !void {
            while (true) {
                const message = try socket.readSmallMessage();
                switch (message.opcode) {
                    .text => try socket.writeText(message.data),
                    .binary => try socket.writeBinary(message.data),
                    .ping => try socket.writePong(message.data),
                    .connection_close => {
                        try socket.close("");
                        return;
                    },
                    else => {},
                }
            }
        }
    }.run, .{});
}
```

## Handler signatures

`upgradeWebSocket` accepts either:

- `fn(socket: *WebSocketConnection) !void`
- `fn(req: zono.Request, socket: *WebSocketConnection) !void`

Use the second form when you need access to the original request
(headers, cookies, query params).

## Connection API

`WebSocketConnection` is a thin wrapper over `std.http.Server.WebSocket`:

```zig
pub fn readSmallMessage(self: *WebSocketConnection) !SmallMessage;
pub fn writeText(self: *WebSocketConnection, data: []const u8) !void;
pub fn writeBinary(self: *WebSocketConnection, data: []const u8) !void;
pub fn writePing(self: *WebSocketConnection, data: []const u8) !void;
pub fn writePong(self: *WebSocketConnection, data: []const u8) !void;
pub fn close(self: *WebSocketConnection, payload: []const u8) !void;
```

`SmallMessage.opcode` is one of `text`, `binary`, `ping`, `pong`,
`connection_close`, `continuation`. `SmallMessage.data` is borrowed
from the connection's read buffer and is valid until the next
`readSmallMessage` call.

The `close` payload is the close-frame body (status code as 2 big-endian
bytes followed by an optional UTF-8 reason). Pass `""` for a bare close
frame without a code.

## Upgrade options

```zig
pub const WebSocketUpgradeOptions = struct {
    /// Optional subprotocol to negotiate. When the client offers a
    /// `Sec-WebSocket-Protocol` header containing this value, it is
    /// echoed back; otherwise the upgrade still proceeds without it.
    subprotocol: ?[]const u8 = null,
};
```

## Server configuration

WebSocket handlers are long-lived and must opt out of the per-request
deadline. Configure your server with `request_timeout_ms = 0`:

```zig
var server = zono.Server.init(.{
    .address = addr,
    .request_timeout_ms = 0,
});
```

If you need to mix short HTTP timeouts with long-lived sockets, run
two server instances on different ports.

## Testing

See [testing.md](./testing.md) for `zono.WsClient`, the in-process
WebSocket client used by zono's own tests.
