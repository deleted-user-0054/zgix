const std = @import("std");

pub fn cleanPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return "/";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '/');

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(allocator);

    const rooted = input[0] == '/';
    var index: usize = if (rooted) 1 else 0;
    const trailing = input.len > 1 and input[input.len - 1] == '/';

    while (index <= input.len) {
        const end = std.mem.indexOfScalarPos(u8, input, index, '/') orelse input.len;
        const segment = input[index..end];

        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            // Skip empty and current-dir segments.
        } else if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
        } else {
            try segments.append(allocator, segment);
        }

        if (end == input.len) break;
        index = end + 1;
    }

    for (segments.items, 0..) |segment, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }

    if (trailing and out.items.len > 1) try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

test "cleanPath normalizes slash, dot, and dot-dot segments" {
    const allocator = std.testing.allocator;

    const cleaned = try cleanPath(allocator, "/..//Users/./42/");
    defer allocator.free(cleaned);

    try std.testing.expectEqualStrings("/Users/42/", cleaned);
}
