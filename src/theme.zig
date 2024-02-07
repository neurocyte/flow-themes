name: []const u8,
description: []const u8,
type: []const u8,
tokens: Tokens,

editor: Style,
editor_cursor: Style,
editor_line_highlight: Style,
editor_error: Style,
editor_match: Style,
editor_selection: Style,
editor_whitespace: Style,
editor_gutter: Style,
editor_gutter_active: Style,
editor_gutter_modified: Style,
editor_gutter_added: Style,
editor_gutter_deleted: Style,
statusbar: Style,
statusbar_hover: Style,
scrollbar: Style,
scrollbar_hover: Style,
scrollbar_active: Style,
sidebar: Style,
panel: Style,

pub const FontStyle = enum { normal, bold, italic, underline, strikethrough };
pub const Style = struct { fg: ?Color = null, bg: ?Color = null, fs: ?FontStyle = null };
pub const Color = u24;
pub const Token = struct { id: usize, style: Style };
pub const Tokens = []const Token;
