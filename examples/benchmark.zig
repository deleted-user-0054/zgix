const std = @import("std");
const zgix = @import("zgix");

pub fn main(init: std.process.Init) !void {
    var io_impl = std.Io.Threaded.init(init.gpa, .{});
    defer io_impl.deinit();
    var app = zgix.App.init(init.gpa);
    defer app.deinit();
    try app.get("/api/json", json);
    var server = zgix.Server.init(.{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3003"),
    });
    try server.serve(io_impl.io(), &app);
}

fn json(req: zgix.Request) zgix.Response {
    _ = req;
    return zgix.json("{\"ok\":true,\"framework\":\"zgix\"}");
}
