const std = @import("std");
const EpochSeconds = std.time.epoch.EpochSeconds;
const Request = @import("request.zig").Request;

pub const SameSite = enum {
    strict,
    lax,
    none,
};

pub const CookiePriority = enum {
    low,
    medium,
    high,
};

pub const CookiePrefix = enum {
    secure,
    host,
};

pub const CookieOptions = struct {
    domain: ?[]const u8 = null,
    expires: ?EpochSeconds = null,
    http_only: bool = false,
    max_age: ?u64 = null,
    path: ?[]const u8 = "/",
    secure: bool = false,
    same_site: ?SameSite = null,
    priority: ?CookiePriority = null,
    prefix: ?CookiePrefix = null,
    partitioned: bool = false,
};

pub const DeleteCookieOptions = struct {
    domain: ?[]const u8 = null,
    path: ?[]const u8 = "/",
    secure: bool = false,
    prefix: ?CookiePrefix = null,
};

pub const CookieError = std.mem.Allocator.Error || error{
    InvalidCookieName,
    InvalidCookieValue,
    SecurePrefixRequiresSecure,
    HostPrefixRequiresSecure,
    HostPrefixRequiresPathRoot,
    HostPrefixDisallowsDomain,
};

pub const WebSocketConnection = struct {
    socket: *std.http.Server.WebSocket,

    pub const SmallMessage = std.http.Server.WebSocket.SmallMessage;
    pub const ReadSmallMessageError = std.http.Server.WebSocket.ReadSmallTextMessageError;

    pub fn readSmallMessage(self: *WebSocketConnection) ReadSmallMessageError!SmallMessage {
        return self.socket.readSmallMessage();
    }

    pub fn writeText(self: *WebSocketConnection, data: []const u8) std.http.Server.WebSocket.Writer.Error!void {
        try self.socket.writeMessage(data, .text);
    }

    pub fn writeBinary(self: *WebSocketConnection, data: []const u8) std.http.Server.WebSocket.Writer.Error!void {
        try self.socket.writeMessage(data, .binary);
    }

    pub fn writePong(self: *WebSocketConnection, data: []const u8) std.http.Server.WebSocket.Writer.Error!void {
        try self.socket.writeMessage(data, .pong);
    }

    pub fn close(self: *WebSocketConnection, data: []const u8) std.http.Server.WebSocket.Writer.Error!void {
        try self.socket.writeMessage(data, .connection_close);
    }

    pub fn flush(self: *WebSocketConnection) std.http.Server.WebSocket.Writer.Error!void {
        try self.socket.flush();
    }
};

pub const WebSocketUpgradeOptions = struct {
    protocol: ?[]const u8 = null,
};

pub const WebSocketRunFn = *const fn (ctx: *const anyopaque, socket: *WebSocketConnection) anyerror!void;

pub const WebSocketRuntime = struct {
    ctx: *const anyopaque,
    run_fn: WebSocketRunFn,
    protocol: ?[]const u8 = null,
};

pub const Runtime = union(enum) {
    none,
    websocket: WebSocketRuntime,
};

/// A streaming-aware writer handed to user code.
///
/// `write/writeAll/print/flush` are thin wrappers over the underlying
/// `std.http.BodyWriter`. `isAborted()` becomes true once the peer is gone or
/// the server is shutting down, allowing handlers to stop producing data
/// without surfacing transport errors.
pub const StreamWriter = struct {
    /// Underlying writer. In production this is `&body_writer.writer` from a
    /// `std.http.BodyWriter` returned by `respondStreaming` (so chunked /
    /// content-length framing is handled by the writer's vtable). In tests
    /// `App.request` substitutes an in-memory `std.Io.Writer.Allocating`.
    inner: *std.Io.Writer,
    aborted: *const std.atomic.Value(bool),

    pub const Error = std.Io.Writer.Error;

    pub fn writer(self: *StreamWriter) *std.Io.Writer {
        return self.inner;
    }

    pub fn writeAll(self: *StreamWriter, bytes: []const u8) Error!void {
        try self.inner.writeAll(bytes);
    }

    pub fn write(self: *StreamWriter, bytes: []const u8) Error!usize {
        return try self.inner.write(bytes);
    }

    pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) Error!void {
        try self.inner.print(fmt, args);
    }

    /// Flushes buffered bytes onto the wire so the client receives them now.
    pub fn flush(self: *StreamWriter) Error!void {
        try self.inner.flush();
    }

    /// True once the connection is no longer usable (peer closed, server
    /// shutdown, etc). Stream handlers should poll this between chunks.
    pub fn isAborted(self: *const StreamWriter) bool {
        return self.aborted.load(.acquire);
    }
};

pub const StreamRunFn = *const fn (ctx: *const anyopaque, stream: *StreamWriter) anyerror!void;

pub const StreamRuntime = struct {
    ctx: *const anyopaque,
    run_fn: StreamRunFn,
    /// Optional content length. When null, transfer-encoding: chunked is used.
    content_length: ?u64 = null,
};

/// Server-Sent Events runtime. Specialization of streaming for the
/// `text/event-stream` content type that frames messages for the user.
pub const SseEvent = struct {
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
    data: []const u8 = "",
};

pub const SseWriter = struct {
    stream: *StreamWriter,

    pub const Error = StreamWriter.Error;

    pub fn isAborted(self: *const SseWriter) bool {
        return self.stream.isAborted();
    }

    pub fn flush(self: *SseWriter) Error!void {
        try self.stream.flush();
    }

    /// Sends a comment line. Useful as a keep-alive when no real data is due.
    pub fn comment(self: *SseWriter, text_value: []const u8) Error!void {
        try writeMultiline(self.stream, ": ", text_value);
        try self.stream.writeAll("\n");
    }

    pub fn send(self: *SseWriter, event: SseEvent) Error!void {
        if (event.id) |id| {
            try self.stream.writeAll("id: ");
            try self.stream.writeAll(id);
            try self.stream.writeAll("\n");
        }
        if (event.event) |name| {
            try self.stream.writeAll("event: ");
            try self.stream.writeAll(name);
            try self.stream.writeAll("\n");
        }
        if (event.retry_ms) |retry| {
            try self.stream.print("retry: {d}\n", .{retry});
        }
        if (event.data.len > 0) {
            try writeMultiline(self.stream, "data: ", event.data);
        }
        try self.stream.writeAll("\n");
    }

    fn writeMultiline(sw: *StreamWriter, prefix: []const u8, value: []const u8) Error!void {
        var iter = std.mem.splitScalar(u8, value, '\n');
        while (iter.next()) |line| {
            try sw.writeAll(prefix);
            try sw.writeAll(line);
            try sw.writeAll("\n");
        }
    }
};

pub const SseRunFn = *const fn (ctx: *const anyopaque, sse: *SseWriter) anyerror!void;

pub const SseRuntime = struct {
    ctx: *const anyopaque,
    run_fn: SseRunFn,
};

/// Runtime description for a streaming file response. The server opens
/// `path` (relative to `std.Io.Dir.cwd()`), stats it to populate the
/// `Content-Length` header, and pumps file bytes into the response body
/// writer without materializing the whole file in memory.
///
/// `head_only` lets handlers (e.g. `serveStatic` for `HEAD`) emit the same
/// headers without a body. `max_bytes` caps the response when stat reports
/// a larger file (server returns 500 in that case to avoid truncation).
/// `Content-Type` lives on the enclosing `Response` struct and is not
/// duplicated here.
pub const FileRuntime = struct {
    path: []const u8,
    max_bytes: u64 = std.math.maxInt(u64),
    head_only: bool = false,
    /// When set, `Response.deinit` frees `path` via this allocator. Handlers
    /// that dupe the path into the request allocator (e.g. `serveStatic`)
    /// should set this so the response owns the string. Constructors that
    /// borrow a caller-owned path should leave it `null`.
    path_owner: ?std.mem.Allocator = null,
};

/// Discriminates how the response body is delivered. Most code paths produce
/// `.buffered`, but `.stream`/`.sse` allow chunked/streaming output and
/// `.file` hands off to the server for zero-copy file delivery (PR4a: open +
/// stat + `streamRemaining` into the `BodyWriter`).
pub const Body = union(enum) {
    buffered: []const u8,
    stream: StreamRuntime,
    sse: SseRuntime,
    file: FileRuntime,
};

/// Linked list node describing a heap-allocated "scope" whose lifetime is
/// tied to a `Response`. The framework uses this so that streaming
/// responses can keep their handler context (and any wrapping middleware
/// contexts) alive across the boundary between the handler returning and
/// the body actually being produced. See `Response.attachScope`.
pub const ScopeNode = struct {
    /// Allocator that backs `self` (the node itself). Other heap state
    /// owned by the scope is freed by `deinit_fn`.
    allocator: std.mem.Allocator,
    /// User pointer, type-erased.
    ptr: *anyopaque,
    /// Frees `ptr`. Called once when the response (or a transferred
    /// successor) is deinit'd. Must NOT free the `ScopeNode` itself.
    deinit_fn: *const fn (scope: *anyopaque) void,
    /// Next scope further out in attach order; freed after this one.
    next: ?*ScopeNode = null,
};

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    /// Buffered body bytes. Kept as a top-level field for backwards
    /// compatibility; for streaming responses this stays empty and `body_kind`
    /// drives delivery instead.
    body: []const u8,
    body_kind: Body = .{ .buffered = "" },
    location: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    extra_headers: std.ArrayListUnmanaged(std.http.Header) = .empty,
    extra_headers_allocator: ?std.mem.Allocator = null,
    owned_allocator: ?std.mem.Allocator = null,
    runtime: Runtime = .none,
    /// Optional chain of scopes whose lifetime is tied to this Response.
    /// Used by the framework to keep things like a heap-allocated `Context`
    /// (with its `SharedState` and route params) alive across the boundary
    /// between the outer handler returning and the streaming body actually
    /// being produced. Stored as a linked list so nested wrappers can each
    /// attach their own scope without disturbing inner ones. Freed in
    /// `deinit` in attach order (newest first). This is the single, uniform
    /// ownership-extension slot — works for any body kind (`.buffered`,
    /// `.stream`, `.sse`) and any runtime (`.websocket`, etc.).
    scope_head: ?*ScopeNode = null,

    pub fn header(self: *Response, name: []const u8, value: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            self.replaceSlice(&self.content_type, value) catch return false;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            self.replaceOptionalSlice(&self.location, value) catch return false;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "allow")) {
            self.replaceOptionalSlice(&self.allow, value) catch return false;
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "set-cookie")) {
            return self.appendHeader(name, value);
        }

        for (self.extra_headers.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                self.replaceHeader(entry, name, value) catch return false;
                return true;
            }
        }

        return self.appendHeader(name, value);
    }

    pub fn setStatus(self: *Response, status: std.http.Status) void {
        self.status = status;
    }

    pub fn setContentType(self: *Response, content_type: []const u8) bool {
        self.replaceSlice(&self.content_type, content_type) catch return false;
        return true;
    }

    pub fn setBody(self: *Response, content: []const u8) bool {
        self.replaceSlice(&self.body, content) catch return false;
        self.body_kind = .{ .buffered = self.body };
        return true;
    }

    pub fn setLocation(self: *Response, location: ?[]const u8) bool {
        if (location) |value| {
            self.replaceOptionalSlice(&self.location, value) catch return false;
        } else {
            self.clearOptionalSlice(&self.location);
        }
        return true;
    }

    pub fn setAllow(self: *Response, allow: ?[]const u8) bool {
        if (allow) |value| {
            self.replaceOptionalSlice(&self.allow, value) catch return false;
        } else {
            self.clearOptionalSlice(&self.allow);
        }
        return true;
    }

    pub fn deleteHeader(self: *Response, name: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            self.clearSlice(&self.content_type);
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            self.clearOptionalSlice(&self.location);
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "allow")) {
            self.clearOptionalSlice(&self.allow);
            return true;
        }

        var removed = false;
        var index: usize = 0;
        while (index < self.extra_headers.items.len) {
            const entry = self.extra_headers.items[index];
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) {
                index += 1;
                continue;
            }

            if (self.owned_allocator) |allocator| {
                allocator.free(entry.name);
                allocator.free(entry.value);
            }

            _ = self.extra_headers.swapRemove(index);
            removed = true;
        }

        return removed;
    }

    pub fn appendHeader(self: *Response, name: []const u8, value: []const u8) bool {
        if (self.owned_allocator) |allocator| {
            const owned_name = allocator.dupe(u8, name) catch return false;
            errdefer allocator.free(owned_name);
            const owned_value = allocator.dupe(u8, value) catch return false;
            errdefer allocator.free(owned_value);

            const list_allocator = self.extra_headers_allocator orelse allocator;
            self.extra_headers.append(list_allocator, .{
                .name = owned_name,
                .value = owned_value,
            }) catch return false;
            self.extra_headers_allocator = list_allocator;
            return true;
        }

        const list_allocator = self.extra_headers_allocator orelse std.heap.smp_allocator;
        self.extra_headers.append(list_allocator, .{
            .name = name,
            .value = value,
        }) catch return false;
        self.extra_headers_allocator = list_allocator;
        return true;
    }

    pub fn extraHeaders(self: *const Response) []const std.http.Header {
        return self.extra_headers.items;
    }

    pub fn cookie(
        self: *Response,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        cookie_options: CookieOptions,
    ) CookieError!void {
        try self.ensureOwned(allocator);

        const owned_name = try allocator.dupe(u8, "set-cookie");
        errdefer allocator.free(owned_name);
        const owned_value = try generateCookie(allocator, name, value, cookie_options);
        errdefer allocator.free(owned_value);

        const list_allocator = self.extra_headers_allocator orelse allocator;
        try self.extra_headers.append(list_allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
        self.extra_headers_allocator = list_allocator;
    }

    pub fn deleteCookie(
        self: *Response,
        allocator: std.mem.Allocator,
        name: []const u8,
        delete_options: DeleteCookieOptions,
    ) CookieError!void {
        try self.ensureOwned(allocator);

        const owned_name = try allocator.dupe(u8, "set-cookie");
        errdefer allocator.free(owned_name);
        const owned_value = try generateDeleteCookie(allocator, name, delete_options);
        errdefer allocator.free(owned_value);

        const list_allocator = self.extra_headers_allocator orelse allocator;
        try self.extra_headers.append(list_allocator, .{
            .name = owned_name,
            .value = owned_value,
        });
        self.extra_headers_allocator = list_allocator;
    }

    pub fn clone(self: Response, allocator: std.mem.Allocator) !Response {
        if (self.runtime != .none) return error.UnsupportedRuntimeClone;
        switch (self.body_kind) {
            .buffered => {},
            .stream, .sse, .file => return error.UnsupportedRuntimeClone,
        }

        var cloned: Response = .{
            .status = self.status,
            .content_type = try allocator.dupe(u8, self.content_type),
            .body = try allocator.dupe(u8, self.body),
            .location = if (self.location) |location| try allocator.dupe(u8, location) else null,
            .allow = if (self.allow) |allow| try allocator.dupe(u8, allow) else null,
            .extra_headers_allocator = allocator,
            .owned_allocator = allocator,
        };
        errdefer cloned.deinit();

        for (self.extra_headers.items) |extra_header| {
            try cloned.extra_headers.append(allocator, .{
                .name = try allocator.dupe(u8, extra_header.name),
                .value = try allocator.dupe(u8, extra_header.value),
            });
        }

        cloned.body_kind = .{ .buffered = cloned.body };
        return cloned;
    }

    /// Attaches an opaque "scope" whose lifetime is tied to this Response.
    /// `scope_deinit` is invoked exactly once when the Response is `deinit`ed
    /// (or transferred to a successor Response that itself is deinit'd).
    ///
    /// Multiple scopes may be attached (e.g. nested middleware): they form
    /// a linked list and are freed in reverse-attach order on `deinit`. The
    /// `node_allocator` is used to allocate the bookkeeping `ScopeNode` and
    /// is also used to free that node on deinit.
    pub fn attachScope(
        self: *Response,
        node_allocator: std.mem.Allocator,
        scope_ptr: *anyopaque,
        scope_deinit: *const fn (scope: *anyopaque) void,
    ) std.mem.Allocator.Error!void {
        const node = try node_allocator.create(ScopeNode);
        node.* = .{
            .allocator = node_allocator,
            .ptr = scope_ptr,
            .deinit_fn = scope_deinit,
            .next = self.scope_head,
        };
        self.scope_head = node;
    }

    /// Single, uniform ownership-finalization for scopes whose lifetime
    /// must extend until the Response is fully delivered. The framework
    /// calls this after a user handler returns, for both buffered and
    /// streaming bodies — the scope is either attached to the response
    /// (so it lives until delivery completes) or freed immediately.
    ///
    /// On attach failure for a streaming body the scope is freed and the
    /// response is replaced with an internal-error response, because we
    /// cannot let the streaming callback fire against a dangling scope.
    pub fn finalizeScope(
        self: *Response,
        node_allocator: std.mem.Allocator,
        scope_ptr: *anyopaque,
        scope_deinit: *const fn (scope: *anyopaque) void,
    ) void {
        const needs_extension = switch (self.body_kind) {
            .stream, .sse, .file => true,
            .buffered => self.runtime != .none, // websocket etc. also need extension
        };

        if (!needs_extension) {
            scope_deinit(scope_ptr);
            return;
        }

        self.attachScope(node_allocator, scope_ptr, scope_deinit) catch {
            scope_deinit(scope_ptr);
            self.deinit();
            self.* = internalError("scope attach failed");
        };
    }

    pub fn deinit(self: *Response) void {
        var scope_iter = self.scope_head;
        self.scope_head = null;
        while (scope_iter) |node| {
            const next = node.next;
            node.deinit_fn(node.ptr);
            node.allocator.destroy(node);
            scope_iter = next;
        }

        // Free response-owned runtime state BEFORE clearing body_kind below.
        // Currently only `.file` may carry an owned path; other runtimes have
        // their state freed via the scope chain above.
        switch (self.body_kind) {
            .file => |runtime| {
                if (runtime.path_owner) |allocator| allocator.free(runtime.path);
            },
            else => {},
        }

        if (self.owned_allocator) |allocator| {
            allocator.free(self.content_type);
            allocator.free(self.body);
            if (self.location) |location| allocator.free(location);
            if (self.allow) |allow| allocator.free(allow);
            for (self.extra_headers.items) |extra_header| {
                allocator.free(extra_header.name);
                allocator.free(extra_header.value);
            }
        }

        if (self.extra_headers_allocator) |allocator| {
            self.extra_headers.deinit(allocator);
        }
        self.extra_headers = .empty;
        self.extra_headers_allocator = null;
        self.owned_allocator = null;
        self.runtime = .none;
        self.body_kind = .{ .buffered = "" };
    }

    /// Renders a streaming (`.stream` / `.sse`) response into an owned buffered
    /// `Response` by running the user handler against an in-memory writer.
    /// Used by `App.request` so tests can inspect streaming handlers without
    /// going through the network. For `.buffered` bodies, behaves like `clone`.
    /// On return, the original `self` retains ownership of its runtime context.
    pub fn renderStreamingToBuffered(
        self: *const Response,
        allocator: std.mem.Allocator,
    ) !Response {
        switch (self.body_kind) {
            .buffered => return try self.clone(allocator),
            .stream => |runtime| {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                errdefer aw.deinit();
                var aborted: std.atomic.Value(bool) = .init(false);
                var sw = StreamWriter{
                    .inner = &aw.writer,
                    .aborted = &aborted,
                };
                try runtime.run_fn(runtime.ctx, &sw);
                try aw.writer.flush();
                const bytes = try aw.toOwnedSlice();
                return try buildBufferedClone(self, allocator, bytes);
            },
            .sse => |runtime| {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                errdefer aw.deinit();
                var aborted: std.atomic.Value(bool) = .init(false);
                var sw = StreamWriter{
                    .inner = &aw.writer,
                    .aborted = &aborted,
                };
                var sse_writer = SseWriter{ .stream = &sw };
                try runtime.run_fn(runtime.ctx, &sse_writer);
                try aw.writer.flush();
                const bytes = try aw.toOwnedSlice();
                return try buildBufferedClone(self, allocator, bytes);
            },
            .file => |runtime| {
                // `App.handle`/`App.request` tests route through here: no live
                // server io exists, so we spin up a local `Io.Threaded` just
                // long enough to read the file. Production delivery never hits
                // this branch because the server has its own `.file` path in
                // `sendBody`.
                var io_impl = std.Io.Threaded.init_single_threaded;
                const io = io_impl.io();

                const bytes = std.Io.Dir.cwd().readFileAlloc(io, runtime.path, allocator, .limited(runtime.max_bytes)) catch {
                    const empty = try allocator.dupe(u8, "");
                    return try buildBufferedClone(self, allocator, empty);
                };

                const payload = if (runtime.head_only) blk: {
                    allocator.free(bytes);
                    break :blk try allocator.dupe(u8, "");
                } else bytes;

                return try buildBufferedClone(self, allocator, payload);
            },
        }
    }

    /// Builds an owned buffered `Response` carrying `body_bytes` (already
    /// allocator-owned). Headers/content-type/location/allow are duped from
    /// `source`. Takes ownership of `body_bytes` on success; frees on error.
    fn buildBufferedClone(
        source: *const Response,
        allocator: std.mem.Allocator,
        body_bytes: []u8,
    ) !Response {
        errdefer allocator.free(body_bytes);

        var cloned: Response = .{
            .status = source.status,
            .content_type = try allocator.dupe(u8, source.content_type),
            .body = body_bytes,
            .location = if (source.location) |location| try allocator.dupe(u8, location) else null,
            .allow = if (source.allow) |allow| try allocator.dupe(u8, allow) else null,
            .extra_headers_allocator = allocator,
            .owned_allocator = allocator,
        };
        errdefer cloned.deinit();

        cloned.body_kind = .{ .buffered = cloned.body };

        for (source.extra_headers.items) |extra_header| {
            try cloned.extra_headers.append(allocator, .{
                .name = try allocator.dupe(u8, extra_header.name),
                .value = try allocator.dupe(u8, extra_header.value),
            });
        }

        return cloned;
    }

    pub fn ensureOwned(self: *Response, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.owned_allocator != null) return;

        const owned_content_type = try allocator.dupe(u8, self.content_type);
        errdefer allocator.free(owned_content_type);
        const owned_body = try allocator.dupe(u8, self.body);
        errdefer allocator.free(owned_body);
        const owned_location = if (self.location) |location| try allocator.dupe(u8, location) else null;
        errdefer if (owned_location) |location| allocator.free(location);
        const owned_allow = if (self.allow) |allow| try allocator.dupe(u8, allow) else null;
        errdefer if (owned_allow) |allow| allocator.free(allow);

        var owned_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        errdefer {
            for (owned_headers.items) |owned_header| {
                allocator.free(owned_header.name);
                allocator.free(owned_header.value);
            }
            owned_headers.deinit(allocator);
        }

        for (self.extra_headers.items) |extra_header| {
            const owned_name = try allocator.dupe(u8, extra_header.name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, extra_header.value);
            errdefer allocator.free(owned_value);
            try owned_headers.append(allocator, .{
                .name = owned_name,
                .value = owned_value,
            });
        }

        if (self.extra_headers_allocator) |list_allocator| {
            self.extra_headers.deinit(list_allocator);
        }

        self.content_type = owned_content_type;
        self.body = owned_body;
        self.location = owned_location;
        self.allow = owned_allow;
        self.extra_headers = owned_headers;
        self.extra_headers_allocator = allocator;
        self.owned_allocator = allocator;
        if (self.body_kind == .buffered) self.body_kind = .{ .buffered = self.body };
    }

    fn replaceSlice(self: *Response, field: *[]const u8, value: []const u8) std.mem.Allocator.Error!void {
        if (self.owned_allocator) |allocator| {
            const owned_value = try allocator.dupe(u8, value);
            allocator.free(field.*);
            field.* = owned_value;
            return;
        }
        field.* = value;
    }

    fn replaceOptionalSlice(self: *Response, field: *?[]const u8, value: []const u8) std.mem.Allocator.Error!void {
        if (self.owned_allocator) |allocator| {
            const owned_value = try allocator.dupe(u8, value);
            if (field.*) |existing| allocator.free(existing);
            field.* = owned_value;
            return;
        }
        field.* = value;
    }

    fn clearSlice(self: *Response, field: *[]const u8) void {
        if (self.owned_allocator) |allocator| {
            allocator.free(field.*);
        }
        field.* = "";
    }

    fn clearOptionalSlice(self: *Response, field: *?[]const u8) void {
        if (self.owned_allocator) |allocator| {
            if (field.*) |existing| allocator.free(existing);
        }
        field.* = null;
    }

    fn replaceHeader(
        self: *Response,
        entry: *std.http.Header,
        name: []const u8,
        value: []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.owned_allocator) |allocator| {
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);

            allocator.free(entry.name);
            allocator.free(entry.value);
            entry.* = .{
                .name = owned_name,
                .value = owned_value,
            };
            return;
        }

        entry.* = .{
            .name = name,
            .value = value,
        };
    }
};

pub fn generateCookie(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    cookie_options: CookieOptions,
) CookieError![]const u8 {
    try validateCookieName(name);
    try validateCookieValue(value);
    try validateCookieOptions(name, cookie_options);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try appendCookieName(&out, name, cookie_options.prefix);
    try writeByteAllocating(&out, '=');
    try writeAllAllocating(&out, value);

    if (cookie_options.path) |path| {
        try writeAllAllocating(&out, "; Path=");
        try writeAllAllocating(&out, path);
    }
    if (cookie_options.domain) |domain| {
        try writeAllAllocating(&out, "; Domain=");
        try writeAllAllocating(&out, domain);
    }
    if (cookie_options.max_age) |max_age| {
        try printAllocating(&out, "; Max-Age={d}", .{max_age});
    }
    if (cookie_options.expires) |expires| {
        const formatted = try formatCookieExpires(allocator, expires);
        defer allocator.free(formatted);
        try writeAllAllocating(&out, "; Expires=");
        try writeAllAllocating(&out, formatted);
    }
    if (cookie_options.http_only) {
        try writeAllAllocating(&out, "; HttpOnly");
    }
    if (cookie_options.secure) {
        try writeAllAllocating(&out, "; Secure");
    }
    if (cookie_options.same_site) |same_site| {
        try writeAllAllocating(&out, "; SameSite=");
        try writeAllAllocating(&out, sameSiteName(same_site));
    }
    if (cookie_options.priority) |priority| {
        try writeAllAllocating(&out, "; Priority=");
        try writeAllAllocating(&out, priorityName(priority));
    }
    if (cookie_options.partitioned) {
        try writeAllAllocating(&out, "; Partitioned");
    }

    return try out.toOwnedSlice();
}

pub fn generateDeleteCookie(
    allocator: std.mem.Allocator,
    name: []const u8,
    delete_options: DeleteCookieOptions,
) CookieError![]const u8 {
    return try generateCookie(allocator, name, "", .{
        .domain = delete_options.domain,
        .expires = .{ .secs = 0 },
        .max_age = 0,
        .path = delete_options.path,
        .secure = delete_options.secure,
        .prefix = delete_options.prefix,
    });
}

pub fn body(status: std.http.Status, content_type: []const u8, content: []const u8) Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body = content,
    };
}

pub fn html(content: []const u8) Response {
    return @This().body(.ok, "text/html; charset=utf-8", content);
}

pub fn json(content: []const u8) Response {
    return @This().body(.ok, "application/json; charset=utf-8", content);
}

pub fn text(status: std.http.Status, content: []const u8) Response {
    return @This().body(status, "text/plain; charset=utf-8", content);
}

pub fn notFound() Response {
    return text(.not_found, "Not Found");
}

pub fn redirect(method: std.http.Method, location: []const u8) Response {
    return .{
        .status = if (method == .GET) .moved_permanently else .permanent_redirect,
        .content_type = "",
        .body = "",
        .location = location,
    };
}

pub fn options(allow: []const u8) Response {
    return .{
        .status = .no_content,
        .content_type = "",
        .body = "",
        .allow = allow,
    };
}

pub fn methodNotAllowed(allow: []const u8) Response {
    return .{
        .status = .method_not_allowed,
        .content_type = "text/plain; charset=utf-8",
        .body = "Method Not Allowed",
        .allow = allow,
    };
}

pub fn internalError(message: []const u8) Response {
    return text(.internal_server_error, message);
}

pub fn websocketRuntime(runtime: WebSocketRuntime) Response {
    return .{
        .status = .switching_protocols,
        .content_type = "",
        .body = "",
        .runtime = .{ .websocket = runtime },
    };
}

/// Build a streaming response. Pass an explicit `content_length` if you know
/// the body size up front; otherwise the server will use chunked encoding.
pub fn stream(content_type: []const u8, runtime: StreamRuntime) Response {
    return .{
        .status = .ok,
        .content_type = content_type,
        .body = "",
        .body_kind = .{ .stream = runtime },
    };
}

/// Build a Server-Sent Events response. Sets `text/event-stream` and arranges
/// for chunked delivery of framed events.
pub fn sse(runtime: SseRuntime) Response {
    return .{
        .status = .ok,
        .content_type = "text/event-stream; charset=utf-8",
        .body = "",
        .body_kind = .{ .sse = runtime },
    };
}

/// Build a streaming file response. The server opens `path` (relative to
/// `std.Io.Dir.cwd()`), stats it for `Content-Length`, and pumps bytes from
/// the file into the body writer — no full read into memory. `content_type`
/// sets the response's `Content-Type`; pass `"application/octet-stream"` as a
/// safe default when you don't know.
///
/// `max_bytes` caps the response when the file is larger than expected (the
/// server returns 500 in that case). Set `head_only = true` to emit the same
/// headers for `HEAD` with no body.
pub fn file(path: []const u8, content_type: []const u8, file_options: FileOptions) Response {
    return .{
        .status = file_options.status,
        .content_type = content_type,
        .body = "",
        .body_kind = .{ .file = .{
            .path = path,
            .max_bytes = file_options.max_bytes,
            .head_only = file_options.head_only,
        } },
    };
}

pub const FileOptions = struct {
    status: std.http.Status = .ok,
    max_bytes: u64 = std.math.maxInt(u64),
    head_only: bool = false,
};

pub fn typedJson(allocator: std.mem.Allocator, value: anytype) Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(value) catch return internalError("json write failed");
    return json(out.written());
}

pub fn parseJson(comptime T: type, req: Request) !?std.json.Parsed(T) {
    return try req.json(T);
}

fn validateCookieOptions(name: []const u8, cookie_options: CookieOptions) CookieError!void {
    switch (cookie_options.prefix orelse return) {
        .secure => {
            if (!cookie_options.secure) return error.SecurePrefixRequiresSecure;
        },
        .host => {
            if (!cookie_options.secure) return error.HostPrefixRequiresSecure;
            if (cookie_options.domain != null) return error.HostPrefixDisallowsDomain;
            if (!std.mem.eql(u8, cookie_options.path orelse "", "/")) return error.HostPrefixRequiresPathRoot;
        },
    }

    _ = name;
}

fn validateCookieName(name: []const u8) CookieError!void {
    if (name.len == 0) return error.InvalidCookieName;

    for (name) |byte| {
        switch (byte) {
            0...32, 127 => return error.InvalidCookieName,
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return error.InvalidCookieName,
            else => {},
        }
    }
}

fn validateCookieValue(value: []const u8) CookieError!void {
    for (value) |byte| {
        switch (byte) {
            0...32, 127, ';', ',', '"', '\\' => return error.InvalidCookieValue,
            else => {},
        }
    }
}

fn appendCookieName(
    out: *std.Io.Writer.Allocating,
    name: []const u8,
    prefix: ?CookiePrefix,
) std.mem.Allocator.Error!void {
    switch (prefix orelse {
        try writeAllAllocating(out, name);
        return;
    }) {
        .secure => try writeAllAllocating(out, "__Secure-"),
        .host => try writeAllAllocating(out, "__Host-"),
    }
    try writeAllAllocating(out, name);
}

fn writeAllAllocating(out: *std.Io.Writer.Allocating, bytes: []const u8) std.mem.Allocator.Error!void {
    out.writer.writeAll(bytes) catch unreachable;
}

fn writeByteAllocating(out: *std.Io.Writer.Allocating, byte: u8) std.mem.Allocator.Error!void {
    out.writer.writeByte(byte) catch unreachable;
}

fn printAllocating(
    out: *std.Io.Writer.Allocating,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    out.writer.print(fmt, args) catch unreachable;
}

fn formatCookieExpires(allocator: std.mem.Allocator, expires: EpochSeconds) std.mem.Allocator.Error![]const u8 {
    const weekday_names = [_][]const u8{
        "Sun",
        "Mon",
        "Tue",
        "Wed",
        "Thu",
        "Fri",
        "Sat",
    };
    const month_names = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };

    const epoch_day = expires.getEpochDay();
    const day_seconds = expires.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekday_index: usize = @intCast((epoch_day.day + 4) % 7);

    return try std.fmt.allocPrint(
        allocator,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekday_names[weekday_index],
            month_day.day_index + 1,
            month_names[@intFromEnum(month_day.month) - 1],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn sameSiteName(same_site: SameSite) []const u8 {
    return switch (same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
    };
}

fn priorityName(priority: CookiePriority) []const u8 {
    return switch (priority) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
    };
}

test "typedJson serializes into response body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = typedJson(arena.allocator(), .{ .ok = true });

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":true}", res.body);
}

test "redirect chooses 301 for GET and 308 otherwise" {
    const get_res = redirect(.GET, "/users");
    const post_res = redirect(.POST, "/users");

    try std.testing.expectEqual(std.http.Status.moved_permanently, get_res.status);
    try std.testing.expectEqual(std.http.Status.permanent_redirect, post_res.status);
    try std.testing.expectEqualStrings("/users", get_res.location.?);
}

test "response inline headers support overwrite and append" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("cache-control", "max-age=60"));
    try std.testing.expect(res.header("Cache-Control", "no-store"));
    try std.testing.expect(res.header("content-type", "application/problem+json"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));
    try std.testing.expect(res.appendHeader("set-cookie", "b=2"));

    const headers = res.extraHeaders();
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("no-store", headers[0].value);
    try std.testing.expectEqualStrings("a=1", headers[1].value);
    try std.testing.expectEqualStrings("b=2", headers[2].value);
}

test "response deleteHeader removes special and extra headers" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.header("content-type", "application/problem+json"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));
    try std.testing.expect(res.appendHeader("set-cookie", "b=2"));

    try std.testing.expect(res.deleteHeader("cache-control"));
    try std.testing.expect(res.deleteHeader("content-type"));
    try std.testing.expect(res.deleteHeader("set-cookie"));
    try std.testing.expect(!res.deleteHeader("missing"));

    try std.testing.expectEqualStrings("", res.content_type);
    try std.testing.expectEqual(@as(usize, 0), res.extraHeaders().len);
}

test "response body helper builds arbitrary content types" {
    const res = body(.created, "application/problem+json", "{\"ok\":false}");

    try std.testing.expectEqual(std.http.Status.created, res.status);
    try std.testing.expectEqualStrings("application/problem+json", res.content_type);
    try std.testing.expectEqualStrings("{\"ok\":false}", res.body);
}

test "generateCookie formats common attributes" {
    const cookie = try generateCookie(std.testing.allocator, "session", "abc123", .{
        .domain = "example.com",
        .http_only = true,
        .max_age = 3600,
        .path = "/",
        .priority = .high,
        .same_site = .strict,
        .secure = true,
        .partitioned = true,
    });
    defer std.testing.allocator.free(cookie);

    try std.testing.expectEqualStrings(
        "session=abc123; Path=/; Domain=example.com; Max-Age=3600; HttpOnly; Secure; SameSite=Strict; Priority=High; Partitioned",
        cookie,
    );
}

test "generateDeleteCookie emits an expired cookie header value" {
    const cookie = try generateDeleteCookie(std.testing.allocator, "session", .{});
    defer std.testing.allocator.free(cookie);

    try std.testing.expectEqualStrings(
        "session=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
        cookie,
    );
}

test "generateCookie validates host prefix requirements" {
    try std.testing.expectError(
        error.HostPrefixRequiresSecure,
        generateCookie(std.testing.allocator, "session", "abc123", .{
            .prefix = .host,
        }),
    );
}

test "response cookie helpers append set-cookie headers" {
    var res = text(.ok, "ok");
    defer res.deinit();

    try res.cookie(std.testing.allocator, "session", "abc123", .{
        .http_only = true,
        .secure = true,
    });
    try res.deleteCookie(std.testing.allocator, "theme", .{});

    const headers = res.extraHeaders();
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("set-cookie", headers[0].name);
    try std.testing.expectEqualStrings(
        "session=abc123; Path=/; HttpOnly; Secure",
        headers[0].value,
    );
    try std.testing.expectEqualStrings(
        "theme=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
        headers[1].value,
    );
}

test "response clone owns duplicated data" {
    var res = text(.accepted, "ok");
    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.appendHeader("set-cookie", "a=1"));

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.accepted, cloned.status);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", cloned.content_type);
    try std.testing.expectEqualStrings("ok", cloned.body);
    try std.testing.expectEqual(@as(usize, 2), cloned.extraHeaders().len);
    try std.testing.expectEqualStrings("no-store", cloned.extraHeaders()[0].value);
    try std.testing.expectEqualStrings("a=1", cloned.extraHeaders()[1].value);
}

test "response clone stays safe to mutate after cloning" {
    var res = text(.ok, "ok");
    defer res.deinit();

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expect(cloned.header("content-type", "application/problem+json"));
    try std.testing.expect(cloned.header("cache-control", "no-store"));
    try cloned.cookie(std.testing.allocator, "session", "abc123", .{
        .http_only = true,
    });

    try std.testing.expectEqualStrings("application/problem+json", cloned.content_type);
    try std.testing.expectEqual(@as(usize, 2), cloned.extraHeaders().len);
    try std.testing.expectEqualStrings("no-store", cloned.extraHeaders()[0].value);
    try std.testing.expectEqualStrings(
        "session=abc123; Path=/; HttpOnly",
        cloned.extraHeaders()[1].value,
    );
}

test "response clone stays safe to delete headers after cloning" {
    var res = text(.ok, "ok");
    try std.testing.expect(res.header("cache-control", "no-store"));
    try std.testing.expect(res.header("location", "/next"));

    var cloned = try res.clone(std.testing.allocator);
    defer cloned.deinit();
    defer res.deinit();

    cloned.setStatus(.created);
    try std.testing.expect(cloned.deleteHeader("cache-control"));
    try std.testing.expect(cloned.deleteHeader("location"));

    try std.testing.expectEqual(std.http.Status.created, cloned.status);
    try std.testing.expectEqual(@as(usize, 0), cloned.extraHeaders().len);
    try std.testing.expect(cloned.location == null);
}
