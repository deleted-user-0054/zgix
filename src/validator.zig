const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const ValidationTarget = request_mod.ValidationTarget;
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const Response = @import("response.zig").Response;

fn ValidatorMarker(comptime target: ValidationTarget, comptime parser: anytype) type {
    return struct {
        pub const is_validator = true;
        pub const validator_target = target;
        pub const validator_parser = parser;
    };
}

pub fn validator(comptime target: ValidationTarget, comptime parser: anytype) ValidatorMarker(target, parser) {
    return .{};
}

pub fn form(comptime parser: anytype) ValidatorMarker(.form, parser) {
    return validator(.form, parser);
}

pub fn json(comptime parser: anytype) ValidatorMarker(.json, parser) {
    return validator(.json, parser);
}

pub fn query(comptime parser: anytype) ValidatorMarker(.query, parser) {
    return validator(.query, parser);
}

pub fn header(comptime parser: anytype) ValidatorMarker(.header, parser) {
    return validator(.header, parser);
}

pub fn cookie(comptime parser: anytype) ValidatorMarker(.cookie, parser) {
    return validator(.cookie, parser);
}

pub fn param(comptime parser: anytype) ValidatorMarker(.param, parser) {
    return validator(.param, parser);
}

pub fn wrapValidator(comptime target: ValidationTarget, comptime parser: anytype) *const fn (*Context, Context.Next) anyerror!Response {
    const ParserResult = parserResultType(parser);

    return struct {
        fn run(c: *Context, next: Context.Next) !Response {
            const parsed: ParserResult = try invokeParser(parser, c);
            try c.setValid(target, parsed);
            next.run();
            return c.takeResponse();
        }
    }.run;
}

fn parserResultType(comptime parser: anytype) type {
    const info = parserInfo(parser);
    if (info.return_type == null) {
        @compileError("zono.validator parsers must return a value or !value.");
    }

    const ReturnType = info.return_type.?;
    return switch (@typeInfo(ReturnType)) {
        .error_union => |error_union| error_union.payload,
        else => ReturnType,
    };
}

fn invokeParser(comptime parser: anytype, c: *Context) anyerror!parserResultType(parser) {
    const info = parserInfo(parser);
    const ReturnType = info.return_type.?;

    const result = switch (info.params.len) {
        1 => blk: {
            const ParamType = info.params[0].type orelse @compileError("zono.validator parsers must use concrete parameter types.");
            if (ParamType == Request) break :blk parser(c.req);
            if (ParamType == *Context) break :blk parser(c);
            @compileError("zono.validator parsers must accept zono.Request or *zono.Context.");
        },
        else => @compileError("zono.validator parsers must accept exactly one parameter."),
    };

    return switch (@typeInfo(ReturnType)) {
        .error_union => try result,
        else => result,
    };
}

fn parserInfo(comptime parser: anytype) std.builtin.Type.Fn {
    const ParserType = @TypeOf(parser);
    return switch (@typeInfo(ParserType)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("zono.validator requires a function or function pointer parser."),
        },
        else => @compileError("zono.validator requires a function or function pointer parser."),
    };
}

test "validator target sugar helpers preserve the correct target" {
    const QueryValidator = @TypeOf(query(struct {
        fn run(_: Request) struct { page: u32 } {
            return .{ .page = 1 };
        }
    }.run));
    const JsonValidator = @TypeOf(json(struct {
        fn run(_: Request) struct { ok: bool } {
            return .{ .ok = true };
        }
    }.run));

    try std.testing.expectEqual(ValidationTarget.query, QueryValidator.validator_target);
    try std.testing.expectEqual(ValidationTarget.json, JsonValidator.validator_target);
}
