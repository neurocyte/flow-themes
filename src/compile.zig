const std = @import("std");
const eql = std.mem.eql;

const theme = @import("theme");
const vscode_theme = @import("vscode_theme");
const theme_file = @import("theme_files.zig").theme_file;
var theme_files = @import("theme_files.zig").theme_files;

const Color = theme.Color;
const Style = theme.Style;
const ScopeType = theme.ScopeType;
const Tokens = theme.Tokens;

const context: vscode_theme.Context = .{
    .ptr = &theme_files,
    .vtable = &.{ .include = include, .scope_id = scope_id },
};

fn include(ptr: *anyopaque, file_name: []const u8) vscode_theme.Error![]const u8 {
    const files: *@TypeOf(theme_files) = @ptrCast(@alignCast(ptr));
    for (files) |*tf| {
        if (eql(u8, std.fs.path.basename(file_name), std.fs.path.basename(tf.file_name)))
            return load_cbor(tf);
    }
    return error.IncludeNotFound;
}

fn scope_id(_: *anyopaque, scope: []const u8) error{OutOfMemory}!usize {
    if (scopes.get(scope)) |id| return id;
    try scopes_vec.append(allocator, scope);
    const id = scopes_vec.items.len - 1;
    try scopes.put(scope, id);
    return id;
}

fn load_cbor(theme_: *theme_file) error{ OutOfMemory, InvalidTheme }![]const u8 {
    if (theme_.cbor) |cb| return cb;
    const cb = try vscode_theme.to_cbor(allocator, theme_.file_name, theme_.json, null);
    theme_.cbor = cb;
    return cb;
}

const Writer = std.Io.File.Writer;

fn write_field_string(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    _ = try writer.print("        .@\"{s}\" = \"{s}\",\n", .{ name, value });
}

fn write_Style(writer: *std.Io.Writer, value: Style) !void {
    _ = try writer.print(".{{ ", .{});
    if (value.fg) |fg| _ = try writer.print(".fg = .{{ .color = 0x{x}, .alpha = 0x{x} }},", .{ fg.color, fg.alpha });
    if (value.bg) |bg| _ = try writer.print(".bg = .{{ .color = 0x{x}, .alpha = 0x{x} }},", .{ bg.color, bg.alpha });
    if (value.fs) |fs| _ = try writer.print(".fs = .{s},", .{switch (fs) {
        .normal => "normal",
        .bold => "bold",
        .italic => "italic",
        .underline => "underline",
        .undercurl => "undercurl",
        .strikethrough => "strikethrough",
    }});
    _ = try writer.print("}}", .{});
}

fn write_field_Style(writer: *std.Io.Writer, name: []const u8, value: Style) !void {
    _ = try writer.print("        .@\"{s}\" = ", .{name});
    try write_Style(writer, value);
    _ = try writer.print(",\n", .{});
}

fn write_field_Color(writer: *std.Io.Writer, name: []const u8, value: Color) !void {
    try writer.print("        .@\"{s}\" = .{{ .color = 0x{x}, .alpha = 0x{x} }},\n", .{
        name,
        value.color,
        value.alpha,
    });
}

fn write_field_ansi_palette(writer: *std.Io.Writer, name: []const u8, value: [16][3]u8) !void {
    try writer.print("        .@\"{s}\" = .{{\n", .{name});
    for (value) |rgb|
        try writer.print("            .{{ 0x{x:0>2}, 0x{x:0>2}, 0x{x:0>2} }},\n", .{ rgb[0], rgb[1], rgb[2] });
    try writer.print("        }},\n", .{});
}

fn write_field_ScopeType(writer: *std.Io.Writer, name: []const u8, value: ScopeType) !void {
    _ = try writer.print("        .@\"{s}\" = .{t},\n", .{ name, value });
}

fn write_field_token_array(writer: *std.Io.Writer, name: []const u8, values: Tokens) !void {
    _ = try writer.print("        .@\"{s}\" = &[_]theme.Token{{ \n", .{name});
    for (values) |value| {
        _ = try writer.print("            .{{ .id = {d}, .style = ", .{value.id});
        try write_Style(writer, value.style);
        _ = try writer.print("}},\n", .{});
    }
    _ = try writer.print("        }},\n", .{});
}

fn write_field_Type(writer: *std.Io.Writer, name: []const u8, value: theme.Type) !void {
    _ = try writer.print("        .@\"{s}\" = .{t},\n", .{ name, value });
}

fn write_field(writer: *std.Io.Writer, name: []const u8, value: anytype) !void {
    return if (@TypeOf(value) == Style)
        write_field_Style(writer, name, value)
    else if (@TypeOf(value) == Color)
        write_field_Color(writer, name, value)
    else if (@TypeOf(value) == [16][3]u8)
        write_field_ansi_palette(writer, name, value)
    else if (@TypeOf(value) == ScopeType)
        write_field_ScopeType(writer, name, value)
    else if (@TypeOf(value) == Tokens)
        write_field_token_array(writer, name, value)
    else if (@TypeOf(value) == theme.Type)
        write_field_Type(writer, name, value)
    else
        write_field_string(writer, name, value);
}

fn write_theme(writer: *std.Io.Writer, item: theme) !void {
    _ = try writer.write("    .{\n");

    inline for (@typeInfo(theme).@"struct".field_names) |field_name|
        try write_field(writer, field_name, @field(item, field_name));

    _ = try writer.write("    },\n");
}

fn write_all_themes(io: std.Io, writer: *std.Io.Writer) !void {
    _ = try writer.write("const theme = @import(\"theme\");\n");
    _ = try writer.write("pub const themes = [_]theme{\n");
    for (&theme_files) |*file| {
        try write_file(io, "themes", std.fs.path.basename(file.file_name), file.json);
        std.log.info("theme: {s}", .{std.fs.path.basename(file.file_name)});
        const theme_ = vscode_theme.load(allocator, context, file.file_name, try load_cbor(file), .{ .strict = true }) catch |e|
            fatal("failed to load theme {s}: {t}", .{ file.file_name, e });
        try write_theme(writer, theme_);
    }
    _ = try writer.write("};\n\n");
    _ = try writer.write("pub const scopes = [_][]const u8{\n");
    for (scopes_vec.items, 0..) |value, i|
        _ = try writer.print("    \"{s}\", // {d}\n", .{ value, i });
    _ = try writer.write("};\n");
}

var allocator: std.mem.Allocator = undefined;
const ScopeMap = std.StringHashMap(usize);
var scopes: ScopeMap = undefined;
var scopes_vec: std.ArrayList([]const u8) = undefined;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    allocator = arena;
    scopes = ScopeMap.init(allocator);
    scopes_vec = .empty;

    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) fatal("wrong number of arguments", .{});

    const output_file_path = args[1];

    var output_file = std.Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.writer(output_file, io, &buf);
    defer writer.flush() catch @panic("flush failed");
    try write_all_themes(io, &writer.interface);
    return std.process.cleanExit(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

fn write_file(io: std.Io, dir: []const u8, file_name: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(io, dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var sub_dir = try cwd.openDir(io, dir, .{});
    defer sub_dir.close(io);
    try sub_dir.writeFile(io, .{ .sub_path = file_name, .data = data });
}
