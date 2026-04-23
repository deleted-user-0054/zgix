const std = @import("std");
const zono = @import("zono");

pub fn main(init: std.process.Init) !void {
    var io_impl = std.Io.Threaded.init(init.gpa, .{});
    defer io_impl.deinit();
    var app = zono.App.init(init.gpa);
    defer app.deinit();
    try app.get("/api/json", contextJson);
    var server = zono.Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3003"),
    });
    try server.serve(io_impl.io(), &app);
}

fn contextJson(c: *zono.Context) zono.Response {
    return c.json(.{
        .ok = true,
        .framework = "zono",
    });
}
