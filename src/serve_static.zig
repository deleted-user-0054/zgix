const std = @import("std");
const Context = @import("context.zig").Context;
const Response = @import("response.zig").Response;
const response_mod = @import("response.zig");
const path_mod = @import("path.zig");

pub const ServeStaticOptions = struct {
    root: []const u8,
    path: ?[]const u8 = null,
    index: ?[]const u8 = "index.html",
    cache_control: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    max_bytes: u64 = 16 * 1024 * 1024,
};

/// `serveStatic` hands file delivery off to the server's `sendFileBody` path
/// (open + stat + `streamRemaining`), so large files never land in memory.
///
/// Pre-flight stat lets us:
/// - preserve "fall through when missing" semantics by calling `next.run()`
/// - compute `ETag` (weak: size-mtime) and `Last-Modified`
/// - short-circuit to 304 when `If-None-Match` / `If-Modified-Since` matches
/// - honor `Range` with 206 / 416 (single-range only; multi-range is ignored
///   and we fall back to 200 full)
///
/// The stat happens on the live server `Io` when available (`Context.io`),
/// otherwise a short-lived `Io.Threaded` — so unit tests that call `App.handle`
/// without a running server still work.
pub fn serveStatic(comptime static_options: ServeStaticOptions) fn (*Context, Context.Next) Response {
    return struct {
        fn run(c: *Context, next: Context.Next) Response {
            if (c.req.method != .GET and c.req.method != .HEAD) {
                next.run();
                return c.takeResponse();
            }

            const relative_path = resolveRelativePath(c.req.allocator, c.req.path, static_options) catch {
                next.run();
                return c.takeResponse();
            };
            defer c.req.allocator.free(relative_path);

            const full_path = std.fs.path.join(c.req.allocator, &.{ static_options.root, relative_path }) catch {
                return response_mod.internalError("static path join failed");
            };

            const meta_opt = if (c.io()) |io|
                statFile(io, full_path)
            else blk: {
                var io_impl = std.Io.Threaded.init_single_threaded;
                break :blk statFile(io_impl.io(), full_path);
            };

            const meta = meta_opt orelse {
                c.req.allocator.free(full_path);
                next.run();
                return c.takeResponse();
            };

            const owned_path = c.req.allocator.dupe(u8, full_path) catch {
                c.req.allocator.free(full_path);
                return response_mod.internalError("static path dupe failed");
            };
            c.req.allocator.free(full_path);

            const content_type = static_options.content_type orelse contentTypeForPath(relative_path);

            return buildResponse(c, static_options, owned_path, content_type, meta);
        }
    }.run;
}

const FileMeta = struct {
    size: u64,
    mtime_ns: i128,
};

fn statFile(io: std.Io, full_path: []const u8) ?FileMeta {
    var f = std.Io.Dir.cwd().openFile(io, full_path, .{ .allow_directory = false }) catch return null;
    defer f.close(io);
    const s = f.stat(io) catch return null;
    return .{
        .size = s.size,
        .mtime_ns = s.mtime.toNanoseconds(),
    };
}

/// Build the final `Response` based on request headers and file metadata.
/// Owns `owned_path` on all return paths: on 304 (no body delivery) we free
/// it immediately; otherwise ownership is handed to the `.file` FileRuntime.
fn buildResponse(
    c: *Context,
    comptime static_options: ServeStaticOptions,
    owned_path: []u8,
    content_type: []const u8,
    meta: FileMeta,
) Response {
    // Pre-compute etag + last-modified for every path (304, 206, 200).
    // These must outlive this stack frame (headers stored in `built` point
    // at them until `clone()` dupes them into the caller's allocator), so
    // we stash them in the per-request allocator.
    var etag_buf: [64]u8 = undefined;
    const etag_tmp = std.fmt.bufPrint(&etag_buf, "W/\"{x}-{x}\"", .{ meta.size, meta.mtime_ns }) catch {
        c.req.allocator.free(owned_path);
        return response_mod.internalError("static etag fmt failed");
    };
    const etag = c.req.allocator.dupe(u8, etag_tmp) catch {
        c.req.allocator.free(owned_path);
        return response_mod.internalError("static etag dupe failed");
    };

    var lm_buf: [40]u8 = undefined;
    const lm_tmp = formatHttpDate(&lm_buf, @divTrunc(meta.mtime_ns, std.time.ns_per_s)) catch {
        c.req.allocator.free(owned_path);
        return response_mod.internalError("static date fmt failed");
    };
    const last_modified = c.req.allocator.dupe(u8, lm_tmp) catch {
        c.req.allocator.free(owned_path);
        return response_mod.internalError("static date dupe failed");
    };

    // ---- Conditional GET: 304 if the client's cached copy still matches ----
    const if_none_match = c.req.header("if-none-match");
    const if_modified_since = c.req.header("if-modified-since");

    const not_modified = blk: {
        if (if_none_match) |inm| {
            if (etagMatches(inm, etag)) break :blk true;
        } else if (if_modified_since) |ims| {
            if (parseHttpDate(ims)) |client_secs| {
                const file_secs = @divTrunc(meta.mtime_ns, std.time.ns_per_s);
                // 304 when the file has not been modified *after* the
                // timestamp the client saw. HTTP dates are second-precision.
                if (file_secs <= client_secs) break :blk true;
            }
        }
        break :blk false;
    };

    if (not_modified) {
        c.req.allocator.free(owned_path);
        var built: Response = .{
            .status = .not_modified,
            .content_type = content_type,
            .body = "",
        };
        _ = built.header("etag", etag);
        _ = built.header("last-modified", last_modified);
        if (static_options.cache_control) |cache_control| {
            _ = built.header("cache-control", cache_control);
        }
        return built;
    }

    // ---- Range handling ----
    var offset: u64 = 0;
    var length: ?u64 = null;
    var is_partial = false;

    if (c.req.header("range")) |range_header| {
        // If-Range gate: when present and it doesn't match the current
        // representation, serve the full body instead of a partial.
        const range_valid_for_resource = if (c.req.header("if-range")) |ir|
            ifRangeMatches(ir, etag, last_modified)
        else
            true;

        if (range_valid_for_resource) {
            switch (parseRange(range_header, meta.size)) {
                .ok => |r| {
                    offset = r.start;
                    length = r.end - r.start + 1;
                    is_partial = true;
                },
                .unsatisfiable => {
                    c.req.allocator.free(owned_path);
                    var built: Response = .{
                        .status = .range_not_satisfiable,
                        .content_type = "text/plain; charset=utf-8",
                        .body = "Range Not Satisfiable",
                    };
                    var cr_buf: [48]u8 = undefined;
                    const cr_tmp = std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{meta.size}) catch {
                        return response_mod.internalError("content-range fmt failed");
                    };
                    const cr = c.req.allocator.dupe(u8, cr_tmp) catch {
                        return response_mod.internalError("content-range dupe failed");
                    };
                    _ = built.header("content-range", cr);
                    _ = built.header("accept-ranges", "bytes");
                    return built;
                },
                .ignore => {}, // multi-range / syntax → fall back to 200 full
            }
        }
    }

    // ---- 200 OK or 206 Partial Content ----
    var built: Response = .{
        .status = if (is_partial) .partial_content else .ok,
        .content_type = content_type,
        .body = "",
        .body_kind = .{ .file = .{
            .path = owned_path,
            .max_bytes = static_options.max_bytes,
            .head_only = c.req.method == .HEAD,
            .path_owner = c.req.allocator,
            .offset = offset,
            .length = length,
        } },
    };
    _ = built.header("etag", etag);
    _ = built.header("last-modified", last_modified);
    _ = built.header("accept-ranges", "bytes");
    if (static_options.cache_control) |cache_control| {
        _ = built.header("cache-control", cache_control);
    }
    if (is_partial) {
        var cr_buf: [64]u8 = undefined;
        const end_inclusive = offset + length.? - 1;
        const cr_tmp = std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ offset, end_inclusive, meta.size }) catch {
            return response_mod.internalError("content-range fmt failed");
        };
        const cr = c.req.allocator.dupe(u8, cr_tmp) catch {
            return response_mod.internalError("content-range dupe failed");
        };
        _ = built.header("content-range", cr);
    }
    return built;
}

fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    // "*" matches any representation; otherwise tokenize by comma and
    // compare. We treat weak/strong variants of the same tag as matching
    // (W/"x" ~ "x") since we only serve weak etags anyway.
    const trimmed_header = std.mem.trim(u8, if_none_match, " \t");
    if (std.mem.eql(u8, trimmed_header, "*")) return true;

    const our_core = stripEtagWeakness(etag);
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        const candidate = std.mem.trim(u8, raw, " \t");
        if (candidate.len == 0) continue;
        const candidate_core = stripEtagWeakness(candidate);
        if (std.mem.eql(u8, candidate_core, our_core)) return true;
    }
    return false;
}

fn stripEtagWeakness(tag: []const u8) []const u8 {
    if (tag.len >= 2 and tag[0] == 'W' and tag[1] == '/') return tag[2..];
    return tag;
}

fn ifRangeMatches(if_range: []const u8, etag: []const u8, last_modified: []const u8) bool {
    const trimmed = std.mem.trim(u8, if_range, " \t");
    // Strong etag comparison: per RFC, If-Range must not match a weak etag
    // with partial semantics. Since our etags are weak, If-Range with an
    // etag-shaped value should never match — safer to serve the full body.
    if (trimmed.len >= 1 and (trimmed[0] == '"' or (trimmed.len >= 3 and trimmed[0] == 'W' and trimmed[1] == '/'))) {
        if (trimmed.len >= 2 and trimmed[0] == 'W' and trimmed[1] == '/') return false;
        return std.mem.eql(u8, trimmed, etag);
    }
    // Otherwise treat it as an HTTP-date and compare exactly against ours.
    return std.mem.eql(u8, trimmed, last_modified);
}

const RangeResult = union(enum) {
    ok: struct { start: u64, end: u64 }, // inclusive [start, end]
    unsatisfiable,
    ignore,
};

/// Parses an RFC 7233 `Range` header. Only single-range requests are
/// supported; anything else (`,`, syntax errors) returns `.ignore` so the
/// caller serves the full body.
fn parseRange(header: []const u8, file_size: u64) RangeResult {
    const trimmed = std.mem.trim(u8, header, " \t");
    const prefix = "bytes=";
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) return .ignore;
    const spec = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .ignore;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;

    const start_str = std.mem.trim(u8, spec[0..dash], " \t");
    const end_str = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    if (start_str.len == 0) {
        // Suffix range: `bytes=-N` means "last N bytes".
        if (end_str.len == 0) return .ignore;
        const n = std.fmt.parseInt(u64, end_str, 10) catch return .ignore;
        if (n == 0) return .unsatisfiable;
        if (file_size == 0) return .unsatisfiable;
        const take = @min(n, file_size);
        return .{ .ok = .{ .start = file_size - take, .end = file_size - 1 } };
    }

    const start = std.fmt.parseInt(u64, start_str, 10) catch return .ignore;
    if (start >= file_size) return .unsatisfiable;

    const end: u64 = if (end_str.len == 0)
        file_size - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_str, 10) catch return .ignore;
        if (e < start) return .ignore;
        break :blk @min(e, file_size - 1);
    };

    return .{ .ok = .{ .start = start, .end = end } };
}

/// Formats a Unix timestamp (seconds since epoch) as an RFC 7231 IMF-fixdate:
/// `Sun, 06 Nov 1994 08:49:37 GMT`. Writes into `buf` (needs at least 29
/// bytes) and returns the populated slice.
fn formatHttpDate(buf: []u8, unix_secs: i128) ![]u8 {
    // Reject negative timestamps (pre-1970) rather than underflow u64.
    const secs_u64: u64 = if (unix_secs < 0) 0 else @intCast(unix_secs);

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs_u64 };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    // 1970-01-01 is a Thursday (index 4 in the Sun-first week used above).
    const weekday_index: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)) + 4, 7));

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekday_names[weekday_index],
        month_day.day_index + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        @as(u32, year_day.year),
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Parses an HTTP date string back to Unix seconds. Accepts the preferred
/// IMF-fixdate form (`Sun, 06 Nov 1994 08:49:37 GMT`). Rather than support
/// every obsolete form, we only accept what we emit: If-Modified-Since from
/// real clients may use legacy formats, but we return `null` for those and
/// the caller falls back to serving the file.
fn parseHttpDate(s: []const u8) ?i128 {
    const trimmed = std.mem.trim(u8, s, " \t");
    // "Sun, 06 Nov 1994 08:49:37 GMT" is 29 chars; be strict.
    if (trimmed.len != 29) return null;
    if (trimmed[3] != ',' or trimmed[4] != ' ') return null;

    const day = std.fmt.parseInt(u32, trimmed[5..7], 10) catch return null;
    const month = parseMonthAbbrev(trimmed[8..11]) orelse return null;
    const year = std.fmt.parseInt(u32, trimmed[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u32, trimmed[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u32, trimmed[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u32, trimmed[23..25], 10) catch return null;
    if (!std.mem.eql(u8, trimmed[26..29], "GMT")) return null;

    if (year < 1970) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;

    // Days from 1970 to `year-01-01`, then advance by full months within
    // the current year, then the day offset within the month.
    var total_days: u64 = 0;
    var y: u32 = 1970;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) 366 else 365;
    }
    const month_lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        total_days += month_lengths[m - 1];
        if (m == 2 and isLeapYear(year)) total_days += 1;
    }
    total_days += day - 1;

    return @as(i128, total_days) * std.time.s_per_day +
        @as(i128, hour) * std.time.s_per_hour +
        @as(i128, minute) * std.time.s_per_min +
        @as(i128, second);
}

fn parseMonthAbbrev(s: []const u8) ?u32 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, s, name)) return @intCast(i + 1);
    }
    return null;
}

fn isLeapYear(year: u32) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}

fn resolveRelativePath(
    allocator: std.mem.Allocator,
    request_path: []const u8,
    static_options: ServeStaticOptions,
) error{ OutOfMemory, InvalidStaticPath }![]const u8 {
    const source = static_options.path orelse request_path;
    return try sanitizeRelativePath(allocator, source, static_options.index);
}

fn sanitizeRelativePath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    index_path: ?[]const u8,
) error{ OutOfMemory, InvalidStaticPath }![]const u8 {
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
        if (index_path) |index| return try allocator.dupe(u8, index);
        return try allocator.dupe(u8, relative);
    }

    return try allocator.dupe(u8, relative);
}

fn contentTypeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return "application/octet-stream";

    if (std.ascii.eqlIgnoreCase(extension, ".htm") or std.ascii.eqlIgnoreCase(extension, ".html")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs") or std.ascii.eqlIgnoreCase(extension, ".cjs")) return "application/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".map")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".webmanifest")) return "application/manifest+json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".xml") or std.ascii.eqlIgnoreCase(extension, ".xsl") or std.ascii.eqlIgnoreCase(extension, ".xsd")) return "application/xml; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".csv")) return "text/csv; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".tsv")) return "text/tab-separated-values; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".md")) return "text/markdown; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".toml")) return "application/toml; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".yaml") or std.ascii.eqlIgnoreCase(extension, ".yml")) return "application/yaml; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".avif")) return "image/avif";
    if (std.ascii.eqlIgnoreCase(extension, ".apng")) return "image/apng";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(extension, ".ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) return "image/tiff";
    if (std.ascii.eqlIgnoreCase(extension, ".mp3")) return "audio/mpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".wav")) return "audio/wav";
    if (std.ascii.eqlIgnoreCase(extension, ".ogg") or std.ascii.eqlIgnoreCase(extension, ".oga")) return "audio/ogg";
    if (std.ascii.eqlIgnoreCase(extension, ".opus")) return "audio/opus";
    if (std.ascii.eqlIgnoreCase(extension, ".aac")) return "audio/aac";
    if (std.ascii.eqlIgnoreCase(extension, ".flac")) return "audio/flac";
    if (std.ascii.eqlIgnoreCase(extension, ".m4a")) return "audio/mp4";
    if (std.ascii.eqlIgnoreCase(extension, ".mp4")) return "video/mp4";
    if (std.ascii.eqlIgnoreCase(extension, ".webm")) return "video/webm";
    if (std.ascii.eqlIgnoreCase(extension, ".ogv")) return "video/ogg";
    if (std.ascii.eqlIgnoreCase(extension, ".woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(extension, ".woff2")) return "font/woff2";
    if (std.ascii.eqlIgnoreCase(extension, ".ttf")) return "font/ttf";
    if (std.ascii.eqlIgnoreCase(extension, ".otf")) return "font/otf";
    if (std.ascii.eqlIgnoreCase(extension, ".eot")) return "application/vnd.ms-fontobject";
    if (std.ascii.eqlIgnoreCase(extension, ".wasm")) return "application/wasm";
    if (std.ascii.eqlIgnoreCase(extension, ".zip")) return "application/zip";
    if (std.ascii.eqlIgnoreCase(extension, ".gz")) return "application/gzip";
    if (std.ascii.eqlIgnoreCase(extension, ".br")) return "application/x-brotli";
    if (std.ascii.eqlIgnoreCase(extension, ".bz2")) return "application/x-bzip2";
    if (std.ascii.eqlIgnoreCase(extension, ".7z")) return "application/x-7z-compressed";
    if (std.ascii.eqlIgnoreCase(extension, ".rar")) return "application/vnd.rar";
    if (std.ascii.eqlIgnoreCase(extension, ".tar")) return "application/x-tar";
    if (std.ascii.eqlIgnoreCase(extension, ".tgz")) return "application/gzip";
    return "application/octet-stream";
}

test "serveStatic serves files from the configured root" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    var res = try app.request(std.testing.allocator, "/hello.txt", .{ .method = .GET });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("hello\n", res.body);

    // Always emit metadata for cache revalidation.
    try std.testing.expect(findHeader(&res, "etag") != null);
    try std.testing.expect(findHeader(&res, "last-modified") != null);
    try std.testing.expectEqualStrings("bytes", findHeader(&res, "accept-ranges").?);
}

test "serveStatic falls through when the file is missing" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));
    try app.get("/missing.txt", struct {
        fn run(c: *Context) Response {
            return c.text("fallback");
        }
    }.run);

    var res = app.handle(@import("request.zig").Request.init(std.testing.allocator, .GET, "/missing.txt"));
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("fallback", res.body);
}

test "serveStatic infers common content types" {
    try std.testing.expectEqualStrings("application/manifest+json; charset=utf-8", contentTypeForPath("site.webmanifest"));
    try std.testing.expectEqualStrings("application/xml; charset=utf-8", contentTypeForPath("feed.xml"));
    try std.testing.expectEqualStrings("image/webp", contentTypeForPath("image.webp"));
    try std.testing.expectEqualStrings("video/mp4", contentTypeForPath("clip.mp4"));
    try std.testing.expectEqualStrings("font/ttf", contentTypeForPath("font.ttf"));
    try std.testing.expectEqualStrings("application/gzip", contentTypeForPath("archive.gz"));
}

test "serveStatic serves index files and strips body for HEAD" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    var get_res = try app.request(std.testing.allocator, "/", .{ .method = .GET });
    defer get_res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, get_res.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", get_res.content_type);
    try std.testing.expect(std.mem.indexOf(u8, get_res.body, "zono static index") != null);

    var head_res = try app.request(std.testing.allocator, "/", .{ .method = .HEAD });
    defer head_res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, head_res.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", head_res.content_type);
    try std.testing.expectEqualStrings("", head_res.body);
}

test "serveStatic blocks path traversal attempts" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    var res = app.handle(@import("request.zig").Request.init(std.testing.allocator, .GET, "/../secret.txt"));
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.not_found, res.status);
}

test "serveStatic returns 304 when If-None-Match matches the etag" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    // First probe to learn the etag for hello.txt.
    var probe = try app.request(std.testing.allocator, "/hello.txt", .{ .method = .GET });
    defer probe.deinit();
    const etag = findHeader(&probe, "etag") orelse return error.TestUnexpectedResult;

    // Re-request with If-None-Match set to that etag.
    var res = try app.request(std.testing.allocator, "/hello.txt", .{
        .method = .GET,
        .headers = &.{.{ .name = "If-None-Match", .value = etag }},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.not_modified, res.status);
    try std.testing.expectEqualStrings("", res.body);
    try std.testing.expect(findHeader(&res, "etag") != null);
}

test "serveStatic returns 304 when If-Modified-Since is newer than mtime" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    // Use a far-future date so the comparison always succeeds.
    var res = try app.request(std.testing.allocator, "/hello.txt", .{
        .method = .GET,
        .headers = &.{.{ .name = "If-Modified-Since", .value = "Tue, 01 Jan 2999 00:00:00 GMT" }},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.not_modified, res.status);
    try std.testing.expectEqualStrings("", res.body);
}

test "serveStatic returns 206 Partial Content for valid byte ranges" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    // hello.txt is "hello\n" (6 bytes). Request bytes 1-3 → "ell".
    var res = try app.request(std.testing.allocator, "/hello.txt", .{
        .method = .GET,
        .headers = &.{.{ .name = "Range", .value = "bytes=1-3" }},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.partial_content, res.status);
    try std.testing.expectEqualStrings("ell", res.body);
    try std.testing.expectEqualStrings("bytes 1-3/6", findHeader(&res, "content-range").?);
    try std.testing.expectEqualStrings("bytes", findHeader(&res, "accept-ranges").?);
}

test "serveStatic returns 416 for unsatisfiable ranges" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    var res = try app.request(std.testing.allocator, "/hello.txt", .{
        .method = .GET,
        .headers = &.{.{ .name = "Range", .value = "bytes=100-200" }},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.range_not_satisfiable, res.status);
    try std.testing.expectEqualStrings("bytes */6", findHeader(&res, "content-range").?);
}

test "serveStatic honors suffix ranges" {
    var app = @import("app.zig").App.init(std.testing.allocator);
    defer app.deinit();

    try app.use(serveStatic(.{ .root = "testdata/static" }));

    // `bytes=-2` → last 2 bytes of "hello\n" → "o\n".
    var res = try app.request(std.testing.allocator, "/hello.txt", .{
        .method = .GET,
        .headers = &.{.{ .name = "Range", .value = "bytes=-2" }},
    });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.partial_content, res.status);
    try std.testing.expectEqualStrings("o\n", res.body);
    try std.testing.expectEqualStrings("bytes 4-5/6", findHeader(&res, "content-range").?);
}

fn findHeader(res: *const Response, name: []const u8) ?[]const u8 {
    for (res.extra_headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

test "parseRange handles common forms" {
    {
        const r = parseRange("bytes=0-99", 1000);
        try std.testing.expectEqual(@as(u64, 0), r.ok.start);
        try std.testing.expectEqual(@as(u64, 99), r.ok.end);
    }
    {
        const r = parseRange("bytes=500-", 1000);
        try std.testing.expectEqual(@as(u64, 500), r.ok.start);
        try std.testing.expectEqual(@as(u64, 999), r.ok.end);
    }
    {
        const r = parseRange("bytes=-100", 1000);
        try std.testing.expectEqual(@as(u64, 900), r.ok.start);
        try std.testing.expectEqual(@as(u64, 999), r.ok.end);
    }
    // end beyond file → clamped, not unsatisfiable
    {
        const r = parseRange("bytes=0-9999", 1000);
        try std.testing.expectEqual(@as(u64, 0), r.ok.start);
        try std.testing.expectEqual(@as(u64, 999), r.ok.end);
    }
    // start past EOF → unsatisfiable
    try std.testing.expect(parseRange("bytes=2000-", 1000) == .unsatisfiable);
    // multi-range → ignore
    try std.testing.expect(parseRange("bytes=0-10,20-30", 1000) == .ignore);
    // bogus syntax → ignore
    try std.testing.expect(parseRange("items=0-10", 1000) == .ignore);
    try std.testing.expect(parseRange("bytes=abc-def", 1000) == .ignore);
}

test "formatHttpDate and parseHttpDate roundtrip on a known epoch" {
    var buf: [40]u8 = undefined;
    // 784111777 = Sun, 06 Nov 1994 08:49:37 GMT (RFC 7231 example).
    const formatted = try formatHttpDate(&buf, 784111777);
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", formatted);

    const parsed = parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i128, 784111777), parsed);
}
