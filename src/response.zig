const std = @import("std");
const Request = @import("request.zig").Request;
const EpochSeconds = std.time.epoch.EpochSeconds;

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

pub const StreamOptions = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/octet-stream",
    content_length: ?u64 = null,
};

pub const StreamWriter = struct {
    body_writer: *std.http.BodyWriter,

    pub fn writeAll(self: *StreamWriter, bytes: []const u8) std.http.BodyWriter.Error!void {
        try self.body_writer.writer.writeAll(bytes);
    }

    pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) std.http.BodyWriter.Error!void {
        try self.body_writer.writer.print(fmt, args);
    }

    pub fn flush(self: *StreamWriter) std.http.BodyWriter.Error!void {
        try self.body_writer.flush();
    }
};

pub const StreamRunFn = *const fn (ctx: *const anyopaque, writer: *StreamWriter) anyerror!void;

pub const StreamRuntime = struct {
    ctx: *const anyopaque,
    run_fn: StreamRunFn,
    content_length: ?u64 = null,
    deinit_fn: ?*const fn (allocator: std.mem.Allocator, ctx: *const anyopaque) void = null,
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
    deinit_fn: ?*const fn (allocator: std.mem.Allocator, ctx: *const anyopaque) void = null,
};

pub const Runtime = union(enum) {
    none,
    stream: StreamRuntime,
    websocket: WebSocketRuntime,
};

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    location: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    extra_headers: std.ArrayListUnmanaged(std.http.Header) = .empty,
    extra_headers_allocator: ?std.mem.Allocator = null,
    owned_allocator: ?std.mem.Allocator = null,
    runtime: Runtime = .none,
    runtime_allocator: ?std.mem.Allocator = null,

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

        return cloned;
    }

    pub fn deinit(self: *Response) void {
        if (self.runtime_allocator) |allocator| switch (self.runtime) {
            .stream => |runtime| if (runtime.deinit_fn) |deinit_fn| deinit_fn(allocator, runtime.ctx),
            .websocket => |runtime| if (runtime.deinit_fn) |deinit_fn| deinit_fn(allocator, runtime.ctx),
            .none => {},
        };

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
        self.runtime_allocator = null;
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

pub fn streamRuntime(stream_options: StreamOptions, runtime: StreamRuntime) Response {
    return .{
        .status = stream_options.status,
        .content_type = stream_options.content_type,
        .body = "",
        .runtime = .{ .stream = runtime },
    };
}

pub fn websocketRuntime(runtime: WebSocketRuntime) Response {
    return .{
        .status = .switching_protocols,
        .content_type = "",
        .body = "",
        .runtime = .{ .websocket = runtime },
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
