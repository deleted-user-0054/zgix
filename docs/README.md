# zono docs

The top-level [README](../README.md) covers install, quick start, and the
core API at a glance. The pages here go deeper on individual subsystems.

Each page is intentionally small so you can read just the one you need.

## Contents

- [Routing & composition](./routing.md) — `App`, `route()`, `mount()`,
  `basePath()`, advanced path patterns.
- [Middleware](./middleware.md) — `use()` / `useAt()`, ordering, the
  `next.run()` contract, scoped middleware.
- [Hooks](./hooks.md) — `notFound()` and `onError()`, the reentry guard,
  fallible error handlers (`!Response`).
- [Streaming & SSE](./streaming.md) — `c.stream()`, `c.sse()`,
  `StreamWriter.isAborted()`, deciding between chunked and
  `Content-Length`.
- [Static files](./static.md) — `serveStatic()`, `c.fileResponse` /
  `Response.file`, `Range` / `If-None-Match` / `If-Modified-Since`,
  `HEAD`.
- [Server](./server.md) — `Server.Options`, timeouts, graceful stop,
  `request_timeout_ms` for long-lived handlers.
- [WebSocket](./websocket.md) — `c.upgradeWebSocket()`, frame helpers,
  closing.
- [Request ID](./request-id.md) — `requestId()` middleware,
  `c.requestId()`, custom generators.
- [Testing](./testing.md) — `App.request()` for unary handlers,
  `WsClient` for WebSocket roundtrips.
