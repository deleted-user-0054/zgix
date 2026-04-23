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
    max_bytes: usize = 16 * 1024 * 1024,
};

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
            defer c.req.allocator.free(full_path);

            var io_impl = std.Io.Threaded.init_single_threaded;
            const io = io_impl.io();
            const file = std.Io.Dir.cwd().readFileAlloc(io, full_path, c.req.allocator, .limited(static_options.max_bytes)) catch |err| switch (err) {
                error.FileNotFound, error.IsDir, error.NotDir => {
                    next.run();
                    return c.takeResponse();
                },
                else => return response_mod.internalError("static file read failed"),
            };
            defer c.req.allocator.free(file);

            const body_content = if (c.req.method == .HEAD) "" else file;
            var res = response_mod.body(.ok, static_options.content_type orelse contentTypeForPath(relative_path), body_content).clone(c.req.allocator) catch {
                return response_mod.internalError("static response alloc failed");
            };
            if (static_options.cache_control) |cache_control| {
                _ = res.header("cache-control", cache_control);
            }
            return res;
        }
    }.run;
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

    var res = app.handle(@import("request.zig").Request.init(std.testing.allocator, .GET, "/hello.txt"));
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

    var get_res = app.handle(@import("request.zig").Request.init(std.testing.allocator, .GET, "/"));
    defer get_res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, get_res.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", get_res.content_type);
    try std.testing.expect(std.mem.indexOf(u8, get_res.body, "zono static index") != null);

    var head_res = app.handle(@import("request.zig").Request.init(std.testing.allocator, .HEAD, "/"));
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
