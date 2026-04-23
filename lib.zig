const root = @import("src/zono.zig");
const std = @import("std");

pub const request = root.request;
pub const response = root.response;
pub const router = root.router;
pub const app = root.app;
pub const context = root.context;
pub const server = root.server;
pub const path = root.path;

pub const Request = root.Request;
pub const Param = root.Param;
pub const Header = root.Header;
pub const ValidationTarget = root.ValidationTarget;
pub const RequestBlob = root.RequestBlob;
pub const ParseBodyError = root.ParseBodyError;
pub const ParseBodyOptions = root.ParseBodyOptions;
pub const ParsedBody = root.ParsedBody;
pub const ParsedBodyEntry = root.ParsedBodyEntry;
pub const ParsedBodyField = root.ParsedBodyField;
pub const ParsedHeaders = root.ParsedHeaders;
pub const ParsedHeaderEntry = root.ParsedHeaderEntry;
pub const ParsedHeaderField = root.ParsedHeaderField;
pub const ParsedMultipart = root.ParsedMultipart;
pub const ParsedMultipartFile = root.ParsedMultipartFile;
pub const ParsedMultipartFiles = root.ParsedMultipartFiles;
pub const ParsedMultipartFileEntry = root.ParsedMultipartFileEntry;
pub const ParsedMultipartFileField = root.ParsedMultipartFileField;
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
pub const routeOnError = root.routeOnError;

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
