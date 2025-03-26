name: []const u8,
description: []const u8,
type: []const u8,

editor: Style,
editor_cursor: Style,
editor_cursor_primary: Style,
editor_cursor_secondary: Style,
editor_line_highlight: Style,
editor_error: Style,
editor_warning: Style,
editor_information: Style,
editor_hint: Style,
editor_match: Style,
editor_selection: Style,
editor_whitespace: Style,
editor_gutter: Style,
editor_gutter_active: Style,
editor_gutter_modified: Style,
editor_gutter_added: Style,
editor_gutter_deleted: Style,
editor_widget: Style,
editor_widget_border: Style,
statusbar: Style,
statusbar_hover: Style,
scrollbar: Style,
scrollbar_hover: Style,
scrollbar_active: Style,
sidebar: Style,
panel: Style,
input: Style,
input_border: Style,
input_placeholder: Style,
input_option_active: Style,
input_option_hover: Style,
tab_active: Style,
tab_inactive: Style,
tab_selected: Style,

tokens: Tokens,

pub const FontStyle = enum { normal, bold, italic, underline, undercurl, strikethrough };
pub const Style = struct { fg: ?Color = null, bg: ?Color = null, fs: ?FontStyle = null };
pub const Color = struct {
    color: u24,
    alpha: u8 = 0xFF,

    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("color");
        try writer.print("\"#{X:0>6}\"", .{self.color});
        try writer.objectField("alpha");
        try writer.print("{d}", .{self.alpha});
        try writer.endObject();
    }

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
        var color: Color = .{ .color = 0 };
        if (try source.next() != .object_begin) return error.UnexpectedToken;
        var key = try source.next();
        while (key != .object_end) : (key = try source.next()) {
            if (key != .string) return error.UnexpectedToken;
            if (std.mem.eql(u8, key.string, "color")) {
                const value = try source.next();
                if (value != .string) return error.UnexpectedToken;
                if (value.string.len != 7 or value.string[0] != '#') return error.InvalidNumber;
                color.color = try std.fmt.parseInt(u24, value.string[1..], 16);
            } else if (std.mem.eql(u8, key.string, "alpha")) {
                const value = try source.next();
                if (value != .number) return error.UnexpectedToken;
                color.alpha = try std.fmt.parseInt(u8, value.number, 10);
            }
        }
        return color;
    }
};
pub const Token = struct { id: usize, style: Style };
pub const Tokens = []const Token;

const std = @import("std");
