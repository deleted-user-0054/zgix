const root = @import("src/zono.zig");
const std = @import("std");

pub const request = root.request;
pub const response = root.response;
pub const router = root.router;
pub const app = root.app;
pub const context = root.context;
pub const server = root.server;
pub const path = root.path;
pub const serve_static = root.serve_static;
pub const websocket = root.websocket;

pub const Request = root.Request;
pub const Param = root.Param;
pub const Header = root.Header;
pub const ParseBodyError = root.ParseBodyError;
pub const ParseBodyOptions = root.ParseBodyOptions;
pub const ParsedBody = root.ParsedBody;
pub const ParsedBodyEntry = root.ParsedBodyEntry;
pub const ParsedBodyField = root.ParsedBodyField;
pub const ParsedHeaders = root.ParsedHeaders;
pub const ParsedHeaderEntry = root.ParsedHeaderEntry;
pub const ParsedHeaderField = root.ParsedHeaderField;
pub const ParsedFormData = root.ParsedFormData;
pub const ParsedFormFile = root.ParsedFormFile;
pub const ParsedFormFiles = root.ParsedFormFiles;
pub const ParsedFormFileEntry = root.ParsedFormFileEntry;
pub const ParsedFormFileField = root.ParsedFormFileField;

pub const Response = root.Response;
pub const App = root.App;
pub const Context = root.Context;
pub const Router = root.Router;
pub const Route = root.Route;
pub const Server = root.Server;
pub const Options = root.Options;
pub const AppOptions = root.AppOptions;
pub const AppRequestOptions = root.AppRequestOptions;
pub const ServeStaticOptions = root.ServeStaticOptions;
pub const WebSocketConnection = root.WebSocketConnection;
pub const WebSocketUpgradeOptions = root.WebSocketUpgradeOptions;

pub const CookieOptions = root.CookieOptions;
pub const DeleteCookieOptions = root.DeleteCookieOptions;
pub const CookieError = root.CookieError;
pub const SameSite = root.SameSite;
pub const CookiePriority = root.CookiePriority;
pub const CookiePrefix = root.CookiePrefix;

pub const html = root.html;
pub const body = root.body;
pub const json = root.json;
pub const text = root.text;
pub const notFound = root.notFound;
pub const redirect = root.redirect;
pub const options = root.options;
pub const methodNotAllowed = root.methodNotAllowed;
pub const internalError = root.internalError;
pub const typedJson = root.typedJson;
pub const parseJson = root.parseJson;
pub const generateCookie = root.generateCookie;
pub const generateDeleteCookie = root.generateDeleteCookie;
pub const cleanPath = root.cleanPath;
pub const serveStatic = root.serveStatic;
pub const upgradeWebSocket = root.upgradeWebSocket;
pub const isWebSocketUpgrade = root.isWebSocketUpgrade;

test {
    _ = root;

    try std.testing.expect(!@hasDecl(root, "validator"));
    try std.testing.expect(!@hasDecl(root, "cors"));
    try std.testing.expect(!@hasDecl(root, "stream"));
    try std.testing.expect(!@hasDecl(root, "toRawResponse"));
    try std.testing.expect(!@hasDecl(root, "routeOnError"));
    try std.testing.expect(!@hasDecl(root, "HTTPException"));

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
    try std.testing.expect(@hasDecl(root, "serveStatic"));
    try std.testing.expect(@hasDecl(root, "upgradeWebSocket"));
}
