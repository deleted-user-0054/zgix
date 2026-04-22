const root = @import("src/zgix.zig");
const std = @import("std");

pub const request = root.request;
pub const response = root.response;
pub const router = root.router;
pub const app = root.app;
pub const server = root.server;

pub const Request = root.Request;
pub const Param = root.Param;
pub const Response = root.Response;
pub const App = root.App;
pub const Router = root.Router;
pub const Route = root.Route;
pub const Server = root.Server;
pub const Options = root.Options;

pub const html = root.html;
pub const json = root.json;
pub const text = root.text;
pub const notFound = root.notFound;
pub const internalError = root.internalError;
pub const typedJson = root.typedJson;
pub const parseJson = root.parseJson;

test {
    _ = root;

    try std.testing.expect(!@hasDecl(root, "http"));
    try std.testing.expect(!@hasDecl(root, "extract"));
    try std.testing.expect(!@hasDecl(root, "static"));
    try std.testing.expect(!@hasDecl(root, "web"));
    try std.testing.expect(!@hasDecl(root, "http1"));
    try std.testing.expect(!@hasDecl(root, "thin"));

    try std.testing.expect(@hasDecl(root, "App"));
    try std.testing.expect(@hasDecl(root, "Request"));
    try std.testing.expect(@hasDecl(root, "Response"));
    try std.testing.expect(@hasDecl(root, "Server"));
}
