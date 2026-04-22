const std = @import("std");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");
pub const app = @import("app.zig");
pub const server = @import("server.zig");

pub const Request = request.Request;
pub const Param = request.Param;
pub const Response = response.Response;
pub const App = app.App;
pub const Router = router.Router;
pub const Route = router.Route;
pub const Server = server.Server;
pub const Options = server.Options;

pub const html = response.html;
pub const json = response.json;
pub const text = response.text;
pub const notFound = response.notFound;
pub const internalError = response.internalError;
pub const typedJson = response.typedJson;
pub const parseJson = response.parseJson;

test {
    _ = request;
    _ = response;
    _ = router;
    _ = app;
    _ = server;

    try std.testing.expect(!@hasDecl(@This(), "http"));
    try std.testing.expect(!@hasDecl(@This(), "extract"));
    try std.testing.expect(!@hasDecl(@This(), "static"));
    try std.testing.expect(!@hasDecl(@This(), "web"));
    try std.testing.expect(!@hasDecl(@This(), "http1"));
    try std.testing.expect(!@hasDecl(@This(), "thin"));

    try std.testing.expect(@hasDecl(@This(), "App"));
    try std.testing.expect(@hasDecl(@This(), "Request"));
    try std.testing.expect(@hasDecl(@This(), "Response"));
    try std.testing.expect(@hasDecl(@This(), "Router"));
    try std.testing.expect(@hasDecl(@This(), "Server"));
    try std.testing.expect(@hasDecl(@This(), "typedJson"));
}
