const std = @import("std");

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Header = std.http.Header;
const HeaderLookupFn = *const fn (ctx: *const anyopaque, name: []const u8) ?[]const u8;
const HeadersCollectFn = *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const Header;
pub const FormError = std.mem.Allocator.Error || error{
    InvalidPercentEncoding,
};
pub const ParseBodyError = FormError || error{
    UnsupportedContentType,
    MissingMultipartBoundary,
    InvalidMultipartBody,
    UnsupportedMultipartFile,
};

pub const ParseBodyOptions = struct {
    all: bool = false,
};

pub const ParsedBodyEntry = struct {
    key: []const u8,
    values: [][]const u8,
    array_like: bool = false,
};

pub const ParsedBodyField = struct {
    values: []const []const u8,
    array_like: bool = false,

    pub fn value(self: ParsedBodyField) ?[]const u8 {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn all(self: ParsedBodyField) []const []const u8 {
        return self.values;
    }

    pub fn isArray(self: ParsedBodyField) bool {
        return self.array_like or self.values.len > 1;
    }
};

pub const ParsedBody = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedBodyEntry = &.{},

    pub fn get(self: ParsedBody, name: []const u8) ?ParsedBodyField {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, name)) {
                return .{
                    .values = entry.values,
                    .array_like = entry.array_like,
                };
            }
        }
        return null;
    }

    pub fn value(self: ParsedBody, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn values(self: ParsedBody, name: []const u8) ?[]const []const u8 {
        return if (self.get(name)) |field| field.values else null;
    }

    pub fn entriesSlice(self: ParsedBody) []const ParsedBodyEntry {
        return self.entries;
    }

    pub fn deinit(self: *ParsedBody) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            for (entry.values) |entry_value| {
                self.allocator.free(entry_value);
            }
            self.allocator.free(entry.values);
        }
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const ParsedHeaderEntry = struct {
    name: []const u8,
    values: [][]const u8,
};

pub const ParsedHeaderField = struct {
    values: []const []const u8,

    pub fn value(self: ParsedHeaderField) ?[]const u8 {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn all(self: ParsedHeaderField) []const []const u8 {
        return self.values;
    }

    pub fn isArray(self: ParsedHeaderField) bool {
        return self.values.len > 1;
    }
};

pub const ParsedHeaders = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedHeaderEntry = &.{},

    pub fn get(self: ParsedHeaders, name: []const u8) ?ParsedHeaderField {
        for (self.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                return .{
                    .values = entry.values,
                };
            }
        }
        return null;
    }

    pub fn value(self: ParsedHeaders, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn values(self: ParsedHeaders, name: []const u8) ?[]const []const u8 {
        return if (self.get(name)) |field| field.values else null;
    }

    pub fn entriesSlice(self: ParsedHeaders) []const ParsedHeaderEntry {
        return self.entries;
    }

    pub fn deinit(self: *ParsedHeaders) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            for (entry.values) |entry_value| {
                self.allocator.free(entry_value);
            }
            self.allocator.free(entry.values);
        }
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const ParsedMultipartFile = struct {
    filename: []const u8,
    content_type: ?[]const u8 = null,
    content: []const u8,
};

pub const ParsedMultipartFileEntry = struct {
    key: []const u8,
    files: []ParsedMultipartFile,
    array_like: bool = false,
};

pub const ParsedMultipartFileField = struct {
    files: []const ParsedMultipartFile,
    array_like: bool = false,

    pub fn value(self: ParsedMultipartFileField) ?ParsedMultipartFile {
        if (self.files.len == 0) return null;
        return self.files[self.files.len - 1];
    }

    pub fn all(self: ParsedMultipartFileField) []const ParsedMultipartFile {
        return self.files;
    }

    pub fn isArray(self: ParsedMultipartFileField) bool {
        return self.array_like or self.files.len > 1;
    }
};

pub const ParsedMultipartFiles = struct {
    allocator: std.mem.Allocator,
    entries: []const ParsedMultipartFileEntry = &.{},

    pub fn get(self: ParsedMultipartFiles, name: []const u8) ?ParsedMultipartFileField {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, name)) {
                return .{
                    .files = entry.files,
                    .array_like = entry.array_like,
                };
            }
        }
        return null;
    }

    pub fn file(self: ParsedMultipartFiles, name: []const u8) ?ParsedMultipartFile {
        return if (self.get(name)) |field| field.value() else null;
    }

    pub fn files(self: ParsedMultipartFiles, name: []const u8) ?[]const ParsedMultipartFile {
        return if (self.get(name)) |field| field.files else null;
    }

    pub fn entriesSlice(self: ParsedMultipartFiles) []const ParsedMultipartFileEntry {
        return self.entries;
    }

    pub fn deinit(self: *ParsedMultipartFiles) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            for (entry.files) |multipart_file| {
                self.allocator.free(multipart_file.filename);
                if (multipart_file.content_type) |content_type| self.allocator.free(content_type);
                self.allocator.free(multipart_file.content);
            }
            self.allocator.free(entry.files);
        }
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const ParsedMultipart = struct {
    fields: ParsedBody,
    files: ParsedMultipartFiles,

    pub fn init(allocator: std.mem.Allocator) ParsedMultipart {
        return .{
            .fields = .{ .allocator = allocator },
            .files = .{ .allocator = allocator },
        };
    }

    pub fn get(self: ParsedMultipart, name: []const u8) ?ParsedBodyField {
        return self.fields.get(name);
    }

    pub fn value(self: ParsedMultipart, name: []const u8) ?[]const u8 {
        return self.fields.value(name);
    }

    pub fn values(self: ParsedMultipart, name: []const u8) ?[]const []const u8 {
        return self.fields.values(name);
    }

    pub fn getFile(self: ParsedMultipart, name: []const u8) ?ParsedMultipartFileField {
        return self.files.get(name);
    }

    pub fn file(self: ParsedMultipart, name: []const u8) ?ParsedMultipartFile {
        return self.files.file(name);
    }

    pub fn fileValues(self: ParsedMultipart, name: []const u8) ?[]const ParsedMultipartFile {
        return self.files.files(name);
    }

    pub fn deinit(self: *ParsedMultipart) void {
        self.fields.deinit();
        self.files.deinit();
    }
};

pub const ParsedFormData = ParsedMultipart;
pub const ParsedFormFile = ParsedMultipartFile;
pub const ParsedFormFiles = ParsedMultipartFiles;
pub const ParsedFormFileEntry = ParsedMultipartFileEntry;
pub const ParsedFormFileField = ParsedMultipartFileField;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    query_string: []const u8 = "",
    body: []const u8 = "",
    cookies_raw: []const u8 = "",
    header_list: []const Header = &.{},
    header_lookup_ctx: ?*const anyopaque = null,
    header_lookup_fn: ?HeaderLookupFn = null,
    headers_collect_fn: ?HeadersCollectFn = null,
    params: []const Param = &.{},

    pub fn init(allocator: std.mem.Allocator, method: std.http.Method, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .path = path,
        };
    }

    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        for (self.params) |entry| {
            if (std.mem.eql(u8, entry.key, name)) return entry.value;
        }
        return null;
    }

    pub fn paramsSlice(self: Request) []const Param {
        return self.params;
    }

    pub fn parseParams(self: Request, param_options: ParseBodyOptions) std.mem.Allocator.Error!ParsedBody {
        if (self.params.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
        errdefer {
            deinitParsedBodyEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }

        for (self.params) |param_entry| {
            const key = try self.allocator.dupe(u8, param_entry.key);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, param_entry.value);
            errdefer self.allocator.free(value);

            try appendParsedBodyEntry(self.allocator, &entries, key, value, param_options);
        }

        return .{
            .allocator = self.allocator,
            .entries = try entries.toOwnedSlice(self.allocator),
        };
    }

    pub fn queryParam(self: Request, name: []const u8) ?[]const u8 {
        var rest = self.query_string;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const kv = rest[0..amp];
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
            } else if (std.mem.eql(u8, kv, name)) {
                return "";
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }
        return null;
    }

    pub fn query(self: Request, name: []const u8) ?[]const u8 {
        return self.queryParam(name);
    }

    pub fn parseQuery(self: Request, query_options: ParseBodyOptions) FormError!ParsedBody {
        if (self.query_string.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        return try parseUrlEncodedPairs(self.allocator, self.query_string, query_options);
    }

    pub fn queries(self: Request, name: []const u8) ![]const []const u8 {
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        var rest = self.query_string;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const kv = rest[0..amp];
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                if (std.mem.eql(u8, kv[0..eq], name)) {
                    try values.append(self.allocator, kv[eq + 1 ..]);
                }
            } else if (std.mem.eql(u8, kv, name)) {
                try values.append(self.allocator, "");
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.header_list) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        if (self.header_lookup_fn) |lookup| {
            return lookup(self.header_lookup_ctx.?, name);
        }
        return null;
    }

    pub fn headersSlice(self: Request) []const Header {
        if (self.header_list.len > 0) return self.header_list;
        if (self.headers_collect_fn) |collect| {
            return collect(self.header_lookup_ctx.?, self.allocator) catch &.{};
        }
        return self.header_list;
    }

    pub fn headers(self: Request) std.mem.Allocator.Error!ParsedHeaders {
        return self.parseHeaders();
    }

    pub fn headerValues(self: Request, name: []const u8) std.mem.Allocator.Error![]const []const u8 {
        const collected = try self.collectAllHeaders();
        defer if (collected.owns_slice) self.allocator.free(collected.headers);

        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        for (collected.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                try values.append(self.allocator, entry.value);
            }
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    pub fn parseHeaders(self: Request) std.mem.Allocator.Error!ParsedHeaders {
        const collected = try self.collectAllHeaders();
        defer if (collected.owns_slice) self.allocator.free(collected.headers);

        if (collected.headers.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        var entries: std.ArrayListUnmanaged(ParsedHeaderEntry) = .empty;
        errdefer {
            deinitParsedHeaderEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }

        for (collected.headers) |header_entry| {
            const normalized_name = try normalizeHeaderName(self.allocator, header_entry.name);
            errdefer self.allocator.free(normalized_name);
            const value = try self.allocator.dupe(u8, header_entry.value);
            errdefer self.allocator.free(value);

            try appendParsedHeaderEntry(self.allocator, &entries, normalized_name, value);
        }

        return .{
            .allocator = self.allocator,
            .entries = try entries.toOwnedSlice(self.allocator),
        };
    }

    pub fn contentType(self: Request) ?[]const u8 {
        const raw = self.header("content-type") orelse return null;
        const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
        return std.mem.trim(u8, raw[0..semi], " \t");
    }

    pub fn hasContentType(self: Request, value: []const u8) bool {
        const content_type = self.contentType() orelse return false;
        return std.ascii.eqlIgnoreCase(content_type, value);
    }

    pub fn cookie(self: Request, name: []const u8) ?[]const u8 {
        var rest = if (self.cookies_raw.len > 0)
            self.cookies_raw
        else
            self.header("cookie") orelse "";
        while (rest.len > 0) {
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            const pair = rest[0..semi];
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
            rest = if (semi < rest.len) rest[semi + 1 ..] else "";
        }
        return null;
    }

    pub fn cookies(self: Request) std.mem.Allocator.Error!ParsedBody {
        const raw_cookies = if (self.cookies_raw.len > 0)
            self.cookies_raw
        else
            self.header("cookie") orelse "";

        if (raw_cookies.len == 0) {
            return .{
                .allocator = self.allocator,
            };
        }

        return try parseCookiePairs(self.allocator, raw_cookies);
    }

    pub fn text(self: Request) []const u8 {
        return self.body;
    }

    pub fn json(self: Request, comptime T: type) !?std.json.Parsed(T) {
        if (self.body.len == 0) return null;
        return try std.json.parseFromSlice(T, self.allocator, self.body, .{
            .ignore_unknown_fields = true,
        });
    }

    pub fn parseBody(self: Request, body_options: ParseBodyOptions) ParseBodyError!ParsedFormData {
        if (self.body.len == 0) {
            return ParsedFormData.init(self.allocator);
        }
        if (self.hasContentType("application/x-www-form-urlencoded")) {
            return try parseUrlEncodedFormData(self.allocator, self.body, body_options);
        }
        if (self.hasContentType("multipart/form-data")) {
            const raw_content_type = self.header("content-type") orelse return error.MissingMultipartBoundary;
            return try parseMultipartForm(self.allocator, raw_content_type, self.body, body_options);
        } else {
            return error.UnsupportedContentType;
        }
    }

    pub fn parseMultipart(self: Request, body_options: ParseBodyOptions) ParseBodyError!ParsedFormData {
        if (self.body.len == 0) {
            return ParsedFormData.init(self.allocator);
        }
        if (!self.hasContentType("multipart/form-data")) {
            return error.UnsupportedContentType;
        }

        const raw_content_type = self.header("content-type") orelse return error.MissingMultipartBoundary;
        return try parseMultipartForm(self.allocator, raw_content_type, self.body, body_options);
    }

    pub fn formValue(self: Request, name: []const u8) FormError!?[]const u8 {
        if (!self.hasContentType("application/x-www-form-urlencoded") or self.body.len == 0) return null;

        var rest = self.body;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const pair = rest[0..amp];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key_raw = pair[0..eq];
            const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            const decoded_key = try decodeFormComponent(self.allocator, key_raw);
            if (std.mem.eql(u8, decoded_key, name)) {
                return try decodeFormComponent(self.allocator, value_raw);
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        return null;
    }

    pub fn formValues(self: Request, name: []const u8) FormError![]const []const u8 {
        if (!self.hasContentType("application/x-www-form-urlencoded") or self.body.len == 0) return &.{};

        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        var rest = self.body;
        while (rest.len > 0) {
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const pair = rest[0..amp];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key_raw = pair[0..eq];
            const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            const decoded_key = try decodeFormComponent(self.allocator, key_raw);
            if (std.mem.eql(u8, decoded_key, name)) {
                try values.append(self.allocator, try decodeFormComponent(self.allocator, value_raw));
            }
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
        }

        if (values.items.len == 0) return &.{};
        return try values.toOwnedSlice(self.allocator);
    }

    const CollectedHeaders = struct {
        headers: []const Header = &.{},
        owns_slice: bool = false,
    };

    fn collectAllHeaders(self: Request) std.mem.Allocator.Error!CollectedHeaders {
        if (self.header_list.len > 0) {
            return .{
                .headers = self.header_list,
            };
        }
        if (self.headers_collect_fn) |collect| {
            const collected = try collect(self.header_lookup_ctx.?, self.allocator);
            return .{
                .headers = collected,
                .owns_slice = collected.len > 0,
            };
        }
        return .{};
    }
};

fn decodeFormComponent(allocator: std.mem.Allocator, input: []const u8) FormError![]const u8 {
    if (input.len == 0) return try allocator.alloc(u8, 0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const c = input[index];
        switch (c) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (index + 2 >= input.len) return error.InvalidPercentEncoding;
                const hi = std.fmt.charToDigit(input[index + 1], 16) catch return error.InvalidPercentEncoding;
                const lo = std.fmt.charToDigit(input[index + 2], 16) catch return error.InvalidPercentEncoding;
                try out.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
                index += 2;
            },
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn appendParsedBodyEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedBodyEntry),
    key: []const u8,
    value: []const u8,
    body_options: ParseBodyOptions,
) std.mem.Allocator.Error!void {
    const collect_all_values = body_options.all or std.mem.endsWith(u8, key, "[]");

    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;

        allocator.free(key);

        if (collect_all_values) {
            const new_values = try allocator.alloc([]const u8, entry.values.len + 1);
            @memcpy(new_values[0..entry.values.len], entry.values);
            new_values[entry.values.len] = value;
            allocator.free(entry.values);
            entry.values = new_values;
            entry.array_like = true;
            return;
        }

        allocator.free(entry.values[entry.values.len - 1]);
        entry.values[entry.values.len - 1] = value;
        return;
    }

    const values = try allocator.alloc([]const u8, 1);
    values[0] = value;
    try entries.append(allocator, .{
        .key = key,
        .values = values,
        .array_like = std.mem.endsWith(u8, key, "[]"),
    });
}

fn deinitParsedBodyEntries(allocator: std.mem.Allocator, entries: []const ParsedBodyEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        for (entry.values) |entry_value| {
            allocator.free(entry_value);
        }
        allocator.free(entry.values);
    }
}

fn deinitParsedHeaderEntries(allocator: std.mem.Allocator, entries: []const ParsedHeaderEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        for (entry.values) |entry_value| {
            allocator.free(entry_value);
        }
        allocator.free(entry.values);
    }
}

fn deinitParsedMultipartFileEntries(allocator: std.mem.Allocator, entries: []const ParsedMultipartFileEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        for (entry.files) |multipart_file| {
            allocator.free(multipart_file.filename);
            if (multipart_file.content_type) |content_type| allocator.free(content_type);
            allocator.free(multipart_file.content);
        }
        allocator.free(entry.files);
    }
}

fn normalizeHeaderName(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try allocator.dupe(u8, name);
    for (out) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
    return out;
}

fn appendParsedHeaderEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedHeaderEntry),
    name: []const u8,
    value: []const u8,
) std.mem.Allocator.Error!void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;

        allocator.free(name);

        const new_values = try allocator.alloc([]const u8, entry.values.len + 1);
        @memcpy(new_values[0..entry.values.len], entry.values);
        new_values[entry.values.len] = value;
        allocator.free(entry.values);
        entry.values = new_values;
        return;
    }

    const values = try allocator.alloc([]const u8, 1);
    values[0] = value;
    try entries.append(allocator, .{
        .name = name,
        .values = values,
    });
}

fn parseUrlEncodedBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedBody {
    return try parseUrlEncodedPairs(allocator, body, body_options);
}

fn parseUrlEncodedFormData(
    allocator: std.mem.Allocator,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedFormData {
    return .{
        .fields = try parseUrlEncodedPairs(allocator, body, body_options),
        .files = .{ .allocator = allocator },
    };
}

fn parseUrlEncodedPairs(
    allocator: std.mem.Allocator,
    input: []const u8,
    body_options: ParseBodyOptions,
) FormError!ParsedBody {
    var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, entries.items);
        entries.deinit(allocator);
    }

    var rest = input;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const pair = rest[0..amp];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key_raw = pair[0..eq];
        const value_raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try decodeFormComponent(allocator, key_raw);
        errdefer allocator.free(key);
        const value = try decodeFormComponent(allocator, value_raw);
        errdefer allocator.free(value);

        try appendParsedBodyEntry(allocator, &entries, key, value, body_options);
        rest = if (amp < rest.len) rest[amp + 1 ..] else "";
    }

    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseCookiePairs(
    allocator: std.mem.Allocator,
    input: []const u8,
) std.mem.Allocator.Error!ParsedBody {
    var entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, entries.items);
        entries.deinit(allocator);
    }

    var rest = input;
    while (rest.len > 0) {
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const pair = rest[0..semi];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try allocator.dupe(u8, pair[0..eq]);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, if (eq < pair.len) pair[eq + 1 ..] else "");
        errdefer allocator.free(value);

        try appendParsedBodyEntry(allocator, &entries, key, value, .{});
        rest = if (semi < rest.len) rest[semi + 1 ..] else "";
    }

    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseMultipartForm(
    allocator: std.mem.Allocator,
    raw_content_type: []const u8,
    body: []const u8,
    body_options: ParseBodyOptions,
) ParseBodyError!ParsedFormData {
    const boundary = extractMultipartBoundary(raw_content_type) orelse return error.MissingMultipartBoundary;
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);
    const separator = try std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary});
    defer allocator.free(separator);

    var field_entries: std.ArrayListUnmanaged(ParsedBodyEntry) = .empty;
    var file_entries: std.ArrayListUnmanaged(ParsedMultipartFileEntry) = .empty;
    errdefer {
        deinitParsedBodyEntries(allocator, field_entries.items);
        field_entries.deinit(allocator);
        deinitParsedMultipartFileEntries(allocator, file_entries.items);
        file_entries.deinit(allocator);
    }

    var rest = body;
    if (!std.mem.startsWith(u8, rest, delimiter)) return error.InvalidMultipartBody;
    rest = rest[delimiter.len..];

    while (true) {
        if (std.mem.startsWith(u8, rest, "--")) {
            const tail = rest[2..];
            if (tail.len == 0 or std.mem.eql(u8, tail, "\r\n")) {
                break;
            }
            return error.InvalidMultipartBody;
        }
        if (!std.mem.startsWith(u8, rest, "\r\n")) return error.InvalidMultipartBody;
        rest = rest[2..];

        const separator_index = std.mem.indexOf(u8, rest, separator) orelse return error.InvalidMultipartBody;
        const part = rest[0..separator_index];
        rest = rest[separator_index + separator.len ..];

        const parsed_part = try parseMultipartPart(part);

        if (parsed_part.filename) |filename| {
            const key = try allocator.dupe(u8, parsed_part.name);
            errdefer allocator.free(key);
            const owned_filename = try allocator.dupe(u8, filename);
            errdefer allocator.free(owned_filename);
            const owned_content = try allocator.dupe(u8, parsed_part.value);
            errdefer allocator.free(owned_content);
            const owned_content_type = if (parsed_part.content_type) |content_type|
                try allocator.dupe(u8, content_type)
            else
                null;
            errdefer if (owned_content_type) |content_type| allocator.free(content_type);

            try appendParsedMultipartFileEntry(allocator, &file_entries, key, .{
                .filename = owned_filename,
                .content_type = owned_content_type,
                .content = owned_content,
            });
        } else {
            const key = try allocator.dupe(u8, parsed_part.name);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, parsed_part.value);
            errdefer allocator.free(value);
            try appendParsedBodyEntry(allocator, &field_entries, key, value, body_options);
        }
    }

    return .{
        .fields = .{
            .allocator = allocator,
            .entries = try field_entries.toOwnedSlice(allocator),
        },
        .files = .{
            .allocator = allocator,
            .entries = try file_entries.toOwnedSlice(allocator),
        },
    };
}

const ParsedMultipartPart = struct {
    name: []const u8,
    value: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

fn parseMultipartPart(part: []const u8) ParseBodyError!ParsedMultipartPart {
    const separator_index = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return error.InvalidMultipartBody;
    const headers_block = part[0..separator_index];
    const value = part[separator_index + 4 ..];

    var disposition_value: ?[]const u8 = null;
    var content_type_value: ?[]const u8 = null;
    var rest = headers_block;
    while (rest.len > 0) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidMultipartBody;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
            disposition_value = header_value;
        } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
            content_type_value = header_value;
        }
        rest = if (line_end < rest.len) rest[line_end + 2 ..] else "";
    }

    const disposition = disposition_value orelse return error.InvalidMultipartBody;
    if (!std.ascii.startsWithIgnoreCase(disposition, "form-data")) return error.InvalidMultipartBody;

    return .{
        .name = extractDispositionParameter(disposition, "name") orelse return error.InvalidMultipartBody,
        .value = value,
        .filename = extractDispositionParameter(disposition, "filename"),
        .content_type = content_type_value,
    };
}

fn appendParsedMultipartFileEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(ParsedMultipartFileEntry),
    key: []const u8,
    file: ParsedMultipartFile,
) std.mem.Allocator.Error!void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;

        allocator.free(key);

        const new_files = try allocator.alloc(ParsedMultipartFile, entry.files.len + 1);
        @memcpy(new_files[0..entry.files.len], entry.files);
        new_files[entry.files.len] = file;
        allocator.free(entry.files);
        entry.files = new_files;
        entry.array_like = true;
        return;
    }

    const files = try allocator.alloc(ParsedMultipartFile, 1);
    files[0] = file;
    try entries.append(allocator, .{
        .key = key,
        .files = files,
        .array_like = std.mem.endsWith(u8, key, "[]"),
    });
}

fn extractMultipartBoundary(raw_content_type: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, raw_content_type, ';');
    _ = parts.next();

    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (!std.ascii.startsWithIgnoreCase(part, "boundary=")) continue;

        const value = part["boundary=".len..];
        if (value.len == 0) return null;
        if (value[0] == '"' and value.len >= 2 and value[value.len - 1] == '"') {
            return value[1 .. value.len - 1];
        }
        return value;
    }

    return null;
}

fn extractDispositionParameter(disposition: []const u8, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, disposition, ';');
    _ = parts.next();

    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const param_name = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(param_name, name)) continue;

        const raw_value = std.mem.trim(u8, part[eq + 1 ..], " \t");
        if (raw_value.len == 0) return "";
        if (raw_value[0] == '"' and raw_value.len >= 2 and raw_value[raw_value.len - 1] == '"') {
            return raw_value[1 .. raw_value.len - 1];
        }
        return raw_value;
    }

    return null;
}

test "request queryParam returns first matching value" {
    var req = Request.init(std.testing.allocator, .GET, "/search");
    req.query_string = "q=zig&page=2&q=ignored";

    try std.testing.expectEqualStrings("zig", req.queryParam("q").?);
    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
    try std.testing.expect(req.queryParam("missing") == null);
}

test "request parseParams returns an aggregated params view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/users/42");
    req.params = &.{
        .{ .key = "id", .value = "41" },
        .{ .key = "id", .value = "42" },
        .{ .key = "tag[]", .value = "zig" },
        .{ .key = "tag[]", .value = "router" },
        .{ .key = "slug", .value = "readme" },
    };

    var parsed = try req.parseParams(.{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("42", parsed.value("id").?);
    try std.testing.expect(!parsed.get("id").?.isArray());
    try std.testing.expectEqualStrings("readme", parsed.value("slug").?);

    const tags = parsed.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
    try std.testing.expect(parsed.get("tag[]").?.isArray());
}

test "request parseParams all collects repeated keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.params = &.{
        .{ .key = "tag", .value = "zig" },
        .{ .key = "tag", .value = "web" },
        .{ .key = "tag", .value = "router" },
    };

    var parsed = try req.parseParams(.{
        .all = true,
    });
    defer parsed.deinit();

    const tags = parsed.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web", tags[1]);
    try std.testing.expectEqualStrings("router", tags[2]);
    try std.testing.expect(parsed.get("tag").?.isArray());
    try std.testing.expectEqualStrings("router", parsed.value("tag").?);
}

test "request cookie parses raw cookie header" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.cookies_raw = "session=abc; theme=dark";

    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}

test "request header lookup is case-insensitive" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-request-id", .value = "req-123" },
    };

    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("req-123", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("missing") == null);
}

test "request headerValues collects repeated case-insensitive matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.header_list = &.{
        .{ .name = "x-tag", .value = "zig" },
        .{ .name = "X-Tag", .value = "router" },
        .{ .name = "x-request-id", .value = "req-123" },
    };

    const values = try req.headerValues("x-tag");
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("router", values[1]);
}

test "request headers returns a case-insensitive aggregated header view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.header_list = &.{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Set-Cookie", .value = "a=1" },
        .{ .name = "set-cookie", .value = "b=2" },
        .{ .name = "X-Mode", .value = "test" },
    };

    var parsed = try req.headers();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("application/json; charset=utf-8", parsed.value("content-type").?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", parsed.value("Content-Type").?);
    try std.testing.expectEqualStrings("test", parsed.value("x-mode").?);

    const cookies = parsed.values("set-cookie").?;
    try std.testing.expectEqual(@as(usize, 2), cookies.len);
    try std.testing.expectEqualStrings("a=1", cookies[0]);
    try std.testing.expectEqualStrings("b=2", cookies[1]);
    try std.testing.expect(parsed.get("set-cookie").?.isArray());

    try std.testing.expectEqualStrings("content-type", parsed.entriesSlice()[0].name);
}

test "request cookie falls back to cookie header" {
    var req = Request.init(std.testing.allocator, .GET, "/");
    req.header_list = &.{
        .{ .name = "cookie", .value = "session=abc; theme=dark" },
    };

    try std.testing.expectEqualStrings("abc", req.cookie("session").?);
    try std.testing.expectEqualStrings("dark", req.cookie("theme").?);
}

test "request cookies returns an aggregated cookie view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/");
    req.cookies_raw = "session=abc; theme=dark; empty=; session=override";

    var parsed = try req.cookies();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("override", parsed.value("session").?);
    try std.testing.expectEqualStrings("dark", parsed.value("theme").?);
    try std.testing.expectEqualStrings("", parsed.value("empty").?);
}

test "request queries returns all matching values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "tag=zig&tag=web&tag&tag=router";

    const values = try req.queries("tag");
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web", values[1]);
    try std.testing.expectEqualStrings("", values[2]);
    try std.testing.expectEqualStrings("router", values[3]);
}

test "request parseQuery returns an aggregated query view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "q=hello+world&tag=zig&tag=router&list%5B%5D=a&list%5B%5D=b&flag";

    var parsed = try req.parseQuery(.{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello world", parsed.value("q").?);
    try std.testing.expectEqualStrings("router", parsed.value("tag").?);
    try std.testing.expectEqualStrings("", parsed.value("flag").?);
    try std.testing.expect(!parsed.get("tag").?.isArray());

    const list_values = parsed.values("list[]").?;
    try std.testing.expectEqual(@as(usize, 2), list_values.len);
    try std.testing.expectEqualStrings("a", list_values[0]);
    try std.testing.expectEqualStrings("b", list_values[1]);
    try std.testing.expect(parsed.get("list[]").?.isArray());
}

test "request parseQuery all collects repeated keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .GET, "/search");
    req.query_string = "tag=zig&tag=web&tag=router";

    var parsed = try req.parseQuery(.{
        .all = true,
    });
    defer parsed.deinit();

    const values = parsed.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web", values[1]);
    try std.testing.expectEqualStrings("router", values[2]);
    try std.testing.expect(parsed.get("tag").?.isArray());
}

test "request json parses typed payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/posts");
    req.body = "{\"title\":\"hello\"}";

    const parsed = (try req.json(struct { title: []const u8 })).?;
    try std.testing.expectEqualStrings("hello", parsed.value.title);
}

test "request contentType ignores parameters" {
    var req = Request.init(std.testing.allocator, .POST, "/submit");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };

    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", req.contentType().?);
    try std.testing.expect(req.hasContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(!req.hasContentType("application/json"));
}

test "request formValue decodes urlencoded bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/submit");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    req.body = "title=hello+world&note=zig%2Bweb&empty";

    try std.testing.expectEqualStrings("hello world", (try req.formValue("title")).?);
    try std.testing.expectEqualStrings("zig+web", (try req.formValue("note")).?);
    try std.testing.expectEqualStrings("", (try req.formValue("empty")).?);
    try std.testing.expect((try req.formValue("missing")) == null);
}

test "request formValues collects repeated fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = Request.init(arena.allocator(), .POST, "/submit");
    req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };
    req.body = "tag=zig&tag=web+toolkit&tag=router";

    const values = try req.formValues("tag");
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("zig", values[0]);
    try std.testing.expectEqualStrings("web toolkit", values[1]);
    try std.testing.expectEqualStrings("router", values[2]);
}

test "request parseBody keeps the last scalar value and preserves array-like keys" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
    };
    parsed_req.body = "title=hello&title=updated&tag%5B%5D=zig&tag%5B%5D=router&empty";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("updated", body.value("title").?);
    try std.testing.expect(body.get("title").?.isArray() == false);

    const tags = body.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
    try std.testing.expect(body.get("tag[]").?.isArray());

    try std.testing.expectEqualStrings("", body.value("empty").?);
}

test "request parseBody all collects repeated scalar fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    parsed_req.body = "tag=zig&tag=web+toolkit&tag=router";

    var body = try parsed_req.parseBody(.{
        .all = true,
    });
    defer body.deinit();

    const tags = body.values("tag").?;
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web toolkit", tags[1]);
    try std.testing.expectEqualStrings("router", tags[2]);
    try std.testing.expect(body.get("tag").?.isArray());
    try std.testing.expectEqualStrings("router", body.value("tag").?);
}

test "request parseBody rejects unsupported content types" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "application/json" },
    };
    parsed_req.body = "{\"title\":\"hello\"}";

    try std.testing.expectError(error.UnsupportedContentType, parsed_req.parseBody(.{}));
}

test "request parseBody parses multipart text fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zgix-boundary" },
    };
    parsed_req.body =
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag[]\"\r\n\r\n" ++
        "zig\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag[]\"\r\n\r\n" ++
        "router\r\n" ++
        "--zgix-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello world", body.value("title").?);
    const tags = body.values("tag[]").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("router", tags[1]);
}

test "request parseBody multipart all collects repeated fields" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=\"zgix-boundary\"" },
    };
    parsed_req.body =
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" ++
        "zig\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" ++
        "web toolkit\r\n" ++
        "--zgix-boundary--\r\n";

    var body = try parsed_req.parseBody(.{
        .all = true,
    });
    defer body.deinit();

    const tags = body.values("tag").?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("web toolkit", tags[1]);
}

test "request parseMultipart returns text fields and files" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zgix-boundary" },
    };
    parsed_req.body =
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--zgix-boundary--\r\n";

    var multipart = try parsed_req.parseMultipart(.{});
    defer multipart.deinit();

    try std.testing.expectEqualStrings("hello world", multipart.value("title").?);

    const avatar = multipart.file("avatar").?;
    try std.testing.expectEqualStrings("a.txt", avatar.filename);
    try std.testing.expectEqualStrings("text/plain", avatar.content_type.?);
    try std.testing.expectEqualStrings("hello", avatar.content);
}

test "request parseMultipart collects repeated files" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zgix-boundary" },
    };
    parsed_req.body =
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"photos[]\"; filename=\"a.txt\"\r\n\r\n" ++
        "A\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"photos[]\"; filename=\"b.txt\"\r\n\r\n" ++
        "B\r\n" ++
        "--zgix-boundary--\r\n";

    var multipart = try parsed_req.parseMultipart(.{});
    defer multipart.deinit();

    const photos = multipart.fileValues("photos[]").?;
    try std.testing.expectEqual(@as(usize, 2), photos.len);
    try std.testing.expectEqualStrings("a.txt", photos[0].filename);
    try std.testing.expectEqualStrings("A", photos[0].content);
    try std.testing.expectEqualStrings("b.txt", photos[1].filename);
    try std.testing.expectEqualStrings("B", photos[1].content);
    try std.testing.expect(multipart.getFile("photos[]").?.isArray());
}

test "request parseBody multipart returns files directly" {
    var parsed_req = Request.init(std.testing.allocator, .POST, "/submit");
    parsed_req.header_list = &.{
        .{ .name = "content-type", .value = "multipart/form-data; boundary=zgix-boundary" },
    };
    parsed_req.body =
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n\r\n" ++
        "hello world\r\n" ++
        "--zgix-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello\r\n" ++
        "--zgix-boundary--\r\n";

    var body = try parsed_req.parseBody(.{});
    defer body.deinit();

    try std.testing.expectEqualStrings("hello world", body.value("title").?);

    const avatar = body.file("avatar").?;
    try std.testing.expectEqualStrings("a.txt", avatar.filename);
    try std.testing.expectEqualStrings("text/plain", avatar.content_type.?);
    try std.testing.expectEqualStrings("hello", avatar.content);
}
