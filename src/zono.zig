const std = @import("std");

pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");
pub const app = @import("app.zig");
pub const context = @import("context.zig");
pub const server = @import("server.zig");
pub const path = @import("path.zig");
pub const serve_static = @import("serve_static.zig");
pub const websocket = @import("websocket.zig");

pub const Request = request.Request;
pub const Param = request.Param;
pub const Header = request.Header;
pub const ParseBodyError = request.ParseBodyError;
pub const ParseBodyOptions = request.ParseBodyOptions;
pub const ParsedBody = request.ParsedBody;
pub const ParsedBodyEntry = request.ParsedBodyEntry;
pub const ParsedBodyField = request.ParsedBodyField;
pub const ParsedHeaders = request.ParsedHeaders;
pub const ParsedHeaderEntry = request.ParsedHeaderEntry;
pub const ParsedHeaderField = request.ParsedHeaderField;
pub const ParsedFormData = request.ParsedFormData;
pub const ParsedFormFile = request.ParsedFormFile;
pub const ParsedFormFiles = request.ParsedFormFiles;
pub const ParsedFormFileEntry = request.ParsedFormFileEntry;
pub const ParsedFormFileField = request.ParsedFormFileField;

pub const Response = response.Response;
pub const App = app.App;
pub const Context = context.Context;
pub const Router = router.Router;
pub const Route = router.Route;
pub const Server = server.Server;
pub const Options = server.Options;
pub const AppOptions = app.App.Options;
pub const AppRequestOptions = app.App.RequestOptions;
pub const ServeStaticOptions = serve_static.ServeStaticOptions;
pub const WebSocketConnection = response.WebSocketConnection;
pub const WebSocketUpgradeOptions = websocket.WebSocketUpgradeOptions;

pub const CookieOptions = response.CookieOptions;
pub const DeleteCookieOptions = response.DeleteCookieOptions;
pub const CookieError = response.CookieError;
pub const SameSite = response.SameSite;
pub const CookiePriority = response.CookiePriority;
pub const CookiePrefix = response.CookiePrefix;

pub const html = response.html;
pub const body = response.body;
pub const json = response.json;
pub const text = response.text;
pub const notFound = response.notFound;
pub const redirect = response.redirect;
pub const options = response.options;
pub const methodNotAllowed = response.methodNotAllowed;
pub const internalError = response.internalError;
pub const typedJson = response.typedJson;
pub const parseJson = response.parseJson;
pub const generateCookie = response.generateCookie;
pub const generateDeleteCookie = response.generateDeleteCookie;
pub const cleanPath = path.cleanPath;
pub const serveStatic = serve_static.serveStatic;
pub const upgradeWebSocket = websocket.upgradeWebSocket;
pub const isWebSocketUpgrade = websocket.isWebSocketUpgrade;

test {
    _ = request;
    _ = response;
    _ = router;
    _ = app;
    _ = context;
    _ = server;
    _ = path;
    _ = serve_static;
    _ = websocket;

    try std.testing.expect(!@hasDecl(@This(), "validator"));
    try std.testing.expect(!@hasDecl(@This(), "cors"));
    try std.testing.expect(!@hasDecl(@This(), "stream"));
    try std.testing.expect(!@hasDecl(@This(), "toRawResponse"));
    try std.testing.expect(!@hasDecl(@This(), "routeOnError"));
    try std.testing.expect(!@hasDecl(@This(), "HTTPException"));

    try std.testing.expect(!@hasDecl(@This(), "http"));
    try std.testing.expect(!@hasDecl(@This(), "extract"));
    try std.testing.expect(!@hasDecl(@This(), "static"));
    try std.testing.expect(!@hasDecl(@This(), "web"));
    try std.testing.expect(!@hasDecl(@This(), "http1"));
    try std.testing.expect(!@hasDecl(@This(), "thin"));

    try std.testing.expect(@hasDecl(@This(), "App"));
    try std.testing.expect(@hasDecl(@This(), "Context"));
    try std.testing.expect(@hasDecl(@This(), "Request"));
    try std.testing.expect(@hasDecl(@This(), "Response"));
    try std.testing.expect(@hasDecl(@This(), "Router"));
    try std.testing.expect(@hasDecl(@This(), "Server"));
    try std.testing.expect(@hasDecl(@This(), "serveStatic"));
    try std.testing.expect(@hasDecl(@This(), "upgradeWebSocket"));
    try std.testing.expect(@hasDecl(@This(), "typedJson"));
    try std.testing.expect(@hasDecl(@This(), "cleanPath"));
}
