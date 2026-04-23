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
/// Fallthrough semantics: when the requested file is missing we call
/// `next.run()` and return whatever the downstream handler produced. This
/// requires a pre-flight existence check; we do that via `Dir.access` on the
/// live server `Io` (`Context.io`). In test paths that call `App.handle`
/// without a live server, we fall back to a short-lived `Io.Threaded` just
/// for the access check so behavior matches production.
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

            // Pre-flight existence check: preserves "fall through when
            // missing" semantics. Uses the live server Io when available;
            // otherwise (unit tests) a short-lived Threaded Io. This Io is
            // only used for the access syscall and does not outlive it.
            const exists = if (c.io()) |io|
                fileExists(io, full_path)
            else blk: {
                var io_impl = std.Io.Threaded.init_single_threaded;
                break :blk fileExists(io_impl.io(), full_path);
            };

            if (!exists) {
                c.req.allocator.free(full_path);
                next.run();
                return c.takeResponse();
            }

            // Path+content_type must outlive the handler return since the
            // server reads them when driving `.file` body delivery. Use the
            // response's own owned allocator via `ensureOwned` after clone.
            const owned_path = c.req.allocator.dupe(u8, full_path) catch {
                c.req.allocator.free(full_path);
                return response_mod.internalError("static path dupe failed");
            };
            c.req.allocator.free(full_path);

            const content_type = static_options.content_type orelse contentTypeForPath(relative_path);

            var built: Response = .{
                .status = .ok,
                .content_type = content_type,
                .body = "",
                .body_kind = .{ .file = .{
                    .path = owned_path,
                    .max_bytes = static_options.max_bytes,
                    .head_only = c.req.method == .HEAD,
                    .path_owner = c.req.allocator,
                } },
            };
            if (static_options.cache_control) |cache_control| {
                _ = built.header("cache-control", cache_control);
            }
            return built;
        }
    }.run;
}

fn fileExists(io: std.Io, full_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    // Also reject directories so the "index" path gets a shot at serving
    // `root/index.html`. `access` returns success for directories on most
    // platforms.
    var f = std.Io.Dir.cwd().openFile(io, full_path, .{ .allow_directory = false }) catch return false;
    f.close(io);
    return true;
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

    // Use `app.request` (not `handle`) because `.file` bodies are only
    // materialized into `res.body` by the `renderStreamingToBuffered`
    // path, which `request` invokes and `handle` does not.
    var res = try app.request(std.testing.allocator, "/hello.txt", .{ .method = .GET });
    defer res.deinit();

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type);
    try std.testing.expectEqualStrings("hello\n", res.body);
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
