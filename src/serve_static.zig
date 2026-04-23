const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const path_mod = @import("path.zig");

pub const ServeStaticOptions = struct {
    root: []const u8,
    path: ?[]const u8 = null,
    wildcard_param: ?[]const u8 = null,
    index: ?[]const u8 = "index.html",
    cache_control: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    etag: bool = true,
    last_modified: bool = true,
    prefer_precompressed_gzip: bool = true,
    max_bytes: usize = 16 * 1024 * 1024,
};

pub fn serveStatic(comptime static_options: ServeStaticOptions) *const fn (Request) Response {
    return struct {
        fn run(req: Request) Response {
            const relative_path = resolveRelativePath(req, static_options) catch |err| switch (err) {
                error.InvalidStaticPath => return response_mod.notFound(),
                else => return response_mod.internalError("static path resolve failed"),
            };
            defer req.allocator.free(relative_path);

            const full_path = std.fs.path.join(req.allocator, &.{ static_options.root, relative_path }) catch {
                return response_mod.internalError("static path join failed");
            };
            defer req.allocator.free(full_path);

            var io_impl = std.Io.Threaded.init_single_threaded;
            const io = io_impl.io();
            const selected = selectStaticAsset(req, req.allocator, io, full_path, relative_path, static_options) catch |err| switch (err) {
                error.FileNotFound, error.IsDir, error.NotDir => return response_mod.notFound(),
                else => return response_mod.internalError("static file read failed"),
            };
            defer if (selected.path.ptr != full_path.ptr) req.allocator.free(selected.path);

            if (static_options.last_modified) {
                const formatted = formatHttpDate(req.allocator, selected.stat.mtime) catch null;
                if (formatted) |last_modified| {
                    defer req.allocator.free(last_modified);
                    if (req.header("if-modified-since")) |if_modified_since| {
                        if (std.mem.eql(u8, std.mem.trim(u8, if_modified_since, " \t"), last_modified)) {
                            var not_modified = response_mod.body(.not_modified, "", "").clone(req.allocator) catch {
                                return response_mod.internalError("static response alloc failed");
                            };
                            _ = not_modified.header("last-modified", last_modified);
                            if (static_options.etag) {
                                const tag = formatStatETag(req.allocator, selected.stat) catch null;
                                if (tag) |etag| {
                                    _ = not_modified.header("etag", etag);
                                    req.allocator.free(etag);
                                }
                            }
                            return not_modified;
                        }
                    }
                }
            }

            if (static_options.etag) {
                const tag = formatStatETag(req.allocator, selected.stat) catch null;
                if (tag) |etag| {
                    if (req.header("if-none-match")) |if_none_match| {
                        if (std.mem.eql(u8, std.mem.trim(u8, if_none_match, " \t"), etag)) {
                            var not_modified = response_mod.body(.not_modified, "", "").clone(req.allocator) catch {
                                return response_mod.internalError("static response alloc failed");
                            };
                            _ = not_modified.header("etag", etag);
                            req.allocator.free(etag);
                            if (static_options.last_modified) {
                                if (formatHttpDate(req.allocator, selected.stat.mtime) catch null) |last_modified| {
                                    _ = not_modified.header("last-modified", last_modified);
                                    req.allocator.free(last_modified);
                                }
                            }
                            return not_modified;
                        }
                    }
                    req.allocator.free(etag);
                }
            }

            const file = std.Io.Dir.cwd().readFileAlloc(io, selected.path, req.allocator, .limited(static_options.max_bytes)) catch |err| switch (err) {
                error.FileNotFound, error.IsDir, error.NotDir => return response_mod.notFound(),
                else => return response_mod.internalError("static file read failed"),
            };

            var res = response_mod.body(.ok, static_options.content_type orelse contentTypeForPath(relative_path), file).clone(req.allocator) catch {
                req.allocator.free(file);
                return response_mod.internalError("static response alloc failed");
            };
            req.allocator.free(file);
            if (static_options.cache_control) |cache_control| {
                _ = res.header("cache-control", cache_control);
            }
            if (selected.gzip_encoded) {
                _ = res.header("content-encoding", "gzip");
                _ = res.header("vary", "accept-encoding");
            }
            if (static_options.etag) {
                if (formatStatETag(req.allocator, selected.stat) catch null) |etag| {
                    _ = res.header("etag", etag);
                    req.allocator.free(etag);
                }
            }
            if (static_options.last_modified) {
                if (formatHttpDate(req.allocator, selected.stat.mtime) catch null) |last_modified| {
                    _ = res.header("last-modified", last_modified);
                    req.allocator.free(last_modified);
                }
            }
            return res;
        }
    }.run;
}

const SelectedAsset = struct {
    path: []const u8,
    stat: std.Io.File.Stat,
    gzip_encoded: bool = false,
};

fn resolveRelativePath(req: Request, static_options: ServeStaticOptions) ![]u8 {
    if (static_options.path) |fixed_path| {
        return try sanitizeRelativePath(req.allocator, fixed_path, static_options.index);
    }

    const source = if (static_options.wildcard_param) |param_name|
        req.param(param_name) orelse req.path
    else if (req.paramsSlice().len > 0)
        req.paramsSlice()[req.paramsSlice().len - 1].value
    else
        req.path;

    return try sanitizeRelativePath(req.allocator, source, static_options.index);
}

fn sanitizeRelativePath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    index_path: ?[]const u8,
) error{ OutOfMemory, InvalidStaticPath }![]u8 {
    const trimmed = std.mem.trim(u8, input_path, " \t");
    var raw_iter = std.mem.splitScalar(u8, trimmed, '/');
    while (raw_iter.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InvalidStaticPath;
    }

    const rooted_input = if (trimmed.len == 0 or trimmed[0] != '/')
        try std.fmt.allocPrint(allocator, "/{s}", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(rooted_input);

    const cleaned = try path_mod.cleanPath(allocator, rooted_input);
    defer allocator.free(cleaned);

    const relative = std.mem.trimStart(u8, cleaned, "/");
    if (relative.len == 0 or cleaned[cleaned.len - 1] == '/') {
        if (index_path) |index| {
            return try allocator.dupe(u8, index);
        }
        return try allocator.dupe(u8, relative);
    }

    return try allocator.dupe(u8, relative);
}

fn contentTypeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return "application/octet-stream";

    if (std.ascii.eqlIgnoreCase(extension, ".html")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(extension, ".woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(extension, ".woff2")) return "font/woff2";
    if (std.ascii.eqlIgnoreCase(extension, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(extension, ".map")) return "application/json; charset=utf-8";
    return "application/octet-stream";
}

fn selectStaticAsset(
    req: Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    full_path: []const u8,
    relative_path: []const u8,
    static_options: ServeStaticOptions,
) !SelectedAsset {
    if (static_options.prefer_precompressed_gzip and acceptsEncoding(req, "gzip")) {
        const gzip_relative = try std.fmt.allocPrint(allocator, "{s}.gz", .{relative_path});
        defer allocator.free(gzip_relative);
        const gzip_full = try std.fmt.allocPrint(allocator, "{s}.gz", .{full_path});
        errdefer allocator.free(gzip_full);

        const gzip_stat = std.Io.Dir.cwd().statFile(io, gzip_full, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (gzip_stat) |stat| {
            return .{
                .path = gzip_full,
                .stat = stat,
                .gzip_encoded = true,
            };
        }
    }

    return .{
        .path = full_path,
        .stat = try std.Io.Dir.cwd().statFile(io, full_path, .{}),
    };
}

fn acceptsEncoding(req: Request, encoding: []const u8) bool {
    const header = req.header("accept-encoding") orelse return false;
    var iter = std.mem.splitScalar(u8, header, ',');
    while (iter.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, token, encoding)) return true;
        if (std.mem.eql(u8, token, "*")) return true;
    }
    return false;
}

fn formatStatETag(allocator: std.mem.Allocator, stat: std.Io.File.Stat) std.mem.Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(allocator, "W/\"{x}-{x}\"", .{
        stat.size,
        stat.mtime.toNanoseconds(),
    });
}

fn formatHttpDate(allocator: std.mem.Allocator, timestamp: std.Io.Timestamp) std.mem.Allocator.Error![]const u8 {
    const EpochSeconds = std.time.epoch.EpochSeconds;
    const expires: EpochSeconds = .{ .secs = @intCast(@max(timestamp.toSeconds(), 0)) };
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

    return try std.fmt.allocPrint(allocator, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekday_names[weekday_index],
        month_day.day_index + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "serveStatic serves files from a catch-all route" {
    const root = ".zig-cache/test-static-assets";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/app.js",
        .data = "console.log('zono');",
    });

    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/assets/*path", serveStatic(.{
        .root = root,
        .cache_control = "public, max-age=60",
    }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.handle(Request.init(arena.allocator(), .GET, "/assets/app.js"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("console.log('zono');", res.body);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("public, max-age=60", responseHeaderValue(res, "cache-control").?);
}

test "serveStatic serves index files for directory-like requests" {
    const root = ".zig-cache/test-static-index";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/index.html",
        .data = "<h1>home</h1>",
    });

    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/*path", serveStatic(.{
        .root = root,
    }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.handle(Request.init(arena.allocator(), .GET, "/"));
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("<h1>home</h1>", res.body);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", res.content_type);
}

test "serveStatic prevents path traversal and returns not found" {
    const root = ".zig-cache/test-static-safe";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/assets/*path", serveStatic(.{
        .root = root,
    }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = app.handle(Request.init(arena.allocator(), .GET, "/assets/../../secret.txt"));
    try std.testing.expectEqual(std.http.Status.not_found, res.status);
}

test "serveStatic emits etag and returns 304 for matching if-none-match" {
    const root = ".zig-cache/test-static-etag";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/asset.txt",
        .data = "etag",
    });

    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/assets/*path", serveStatic(.{
        .root = root,
    }));

    const first = Request.init(std.testing.allocator, .GET, "/assets/asset.txt");
    var first_res = app.handle(first);
    defer first_res.deinit();
    const tag = responseHeaderValue(first_res, "etag").?;

    var second = Request.init(std.testing.allocator, .GET, "/assets/asset.txt");
    second.header_list = &.{
        .{ .name = "if-none-match", .value = tag },
    };
    var second_res = app.handle(second);
    defer second_res.deinit();

    try std.testing.expectEqual(std.http.Status.not_modified, second_res.status);
}

fn responseHeaderValue(res: Response, name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "content-type")) return if (res.content_type.len > 0) res.content_type else null;

    for (res.extraHeaders()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
