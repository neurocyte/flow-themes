const std = @import("std");
const cbor = @import("cbor");
const theme = @import("theme");
const eql = std.mem.eql;

const Color = theme.Color;
const Style = theme.Style;
const Token = theme.Token;
const TokenMap = std.StringHashMap(Style);

pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// cbor of the theme file named by an "include" field
        include: *const fn (ptr: *anyopaque, file_name: []const u8) ?[]const u8,
        scope_id: *const fn (ptr: *anyopaque, scope: []const u8) usize,
    };

    fn include(self: Context, file_name: []const u8) []const u8 {
        return self.vtable.include(self.ptr, file_name) orelse {
            std.log.err("failed to find include file: {s}", .{std.fs.path.basename(file_name)});
            unreachable;
        };
    }

    fn scope_id(self: Context, scope: []const u8) usize {
        return self.vtable.scope_id(self.ptr, scope);
    }
};

const Source = struct {
    allocator: std.mem.Allocator,
    context: Context,
    cb: []const u8,

    fn included(self: Source, cb: []const u8) Source {
        return .{ .allocator = self.allocator, .context = self.context, .cb = cb };
    }
};

/// The returned theme references file_name and cb. The caller owns theme.tokens.
pub fn load(allocator: std.mem.Allocator, context: Context, file_name: []const u8, cb: []const u8) theme {
    const src: Source = .{ .allocator = allocator, .context = context, .cb = cb };

    const basename = std.fs.path.basename(file_name);
    const suffix = std.mem.lastIndexOf(u8, basename, "-color-theme");
    const ext = std.mem.lastIndexOf(u8, basename, ".json");
    const name: []const u8 = if (suffix) |pos| basename[0..pos] else if (ext) |pos| basename[0..pos] else basename;
    var description: ?[]const u8 = null;
    var theme_type: ?[]const u8 = null;
    var iter = cb;
    var len = cbor.decodeMapHeader(&iter) catch unreachable;

    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch unreachable)) unreachable;
        if (eql(u8, "name", field_name)) {
            var description_: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &description_) catch unreachable)) unreachable;
            description = description_;
        } else if (eql(u8, "type", field_name)) {
            var theme_type_: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &theme_type_) catch unreachable)) unreachable;
            theme_type = theme_type_;
        } else {
            cbor.skipValue(&iter) catch unreachable;
        }
    }
    const declared = parse_type_string(theme_type);
    const computed = compute_theme_type(src);
    const final_type: theme.Type = computed orelse declared orelse .dark;

    if (computed) |c| {
        if (declared) |d| {
            if (d != c) std.log.warn(
                "warning: theme '{s}' declares type '{t}' but editor luma indicates '{t}'; using '{t}'",
                .{ name, d, c, c },
            );
        } else if (theme_type) |raw| {
            std.log.warn(
                "warning: theme '{s}' has unrecognized type '{s}'; using computed '{t}'",
                .{ name, raw, c },
            );
        } else {
            std.log.warn(
                "warning: theme '{s}' missing type field; using computed '{t}'",
                .{ name, c },
            );
        }
    } else if (declared == null and theme_type != null) {
        std.log.warn(
            "warning: theme '{s}' has unrecognized type '{s}' and no explicit editor colors to derive from; defaulting to 'dark'",
            .{ name, theme_type.? },
        );
    }

    const type_idx: usize = if (final_type == .light) @as(usize, 1) else 0;
    var result: theme = undefined;
    result.name = name;
    result.description = description orelse name;
    result.type = final_type;
    result.tokens = load_tokens(src, basename);
    result.scope_type = .text_mate;
    inline for (@typeInfo(theme).@"struct".field_names) |field_name| {
        if (comptime @hasDecl(derive_style, field_name))
            @field(result, field_name) = @field(derive_style, field_name)(type_idx, src)
        else if (comptime !is_one_of(field_name, &.{ "name", "description", "type", "tokens", "scope_type" }))
            @compileError("no derive_style for theme field " ++ field_name);
    }
    return result;
}

fn is_one_of(comptime name: []const u8, comptime names: []const []const u8) bool {
    for (names) |n| if (eql(u8, n, name)) return true;
    return false;
}

fn load_tokens(src: Source, file_name: []const u8) []Token {
    var tokens = load_token_colors(file_name, src);
    defer tokens.deinit();

    const Entry = struct { scope: []const u8, token: Token };
    const entries = src.allocator.alloc(Entry, tokens.count()) catch unreachable;
    defer src.allocator.free(entries);
    var iter = tokens.iterator();
    var i: usize = 0;
    while (iter.next()) |token| : (i += 1) entries[i] = .{
        .scope = token.key_ptr.*,
        .token = .{ .id = src.context.scope_id(token.key_ptr.*), .style = token.value_ptr.* },
    };
    std.sort.pdq(Entry, entries, {}, struct {
        fn less_than(_: void, lhs: Entry, rhs: Entry) bool {
            return std.mem.lessThan(u8, lhs.scope, rhs.scope);
        }
    }.less_than);

    const result = src.allocator.alloc(Token, entries.len) catch unreachable;
    for (entries, result) |entry, *token| token.* = entry.token;
    return result;
}

fn load_token_colors(file_name: []const u8, src: Source) TokenMap {
    var iter = src.cb;
    var len = cbor.decodeMapHeader(&iter) catch unreachable;
    var tokens_cb: ?[]const u8 = null;
    var include: ?[]const u8 = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch unreachable)) unreachable;
        if (eql(u8, "tokenColors", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch unreachable)) unreachable;
            tokens_cb = value;
        } else if (eql(u8, "include", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            include = value;
        } else {
            cbor.skipValue(&iter) catch unreachable;
        }
    }
    var tokens = if (include) |inc|
        load_token_colors(file_name, src.included(src.context.include(inc)))
    else
        TokenMap.init(src.allocator);
    if (tokens_cb) |cb_| load_token_colors_array(file_name, &tokens, cb_);
    return tokens;
}

fn load_token_colors_array(file_name: []const u8, tokens: *TokenMap, cb: []const u8) void {
    var iter = cb;
    var len = cbor.decodeArrayHeader(&iter) catch unreachable;
    while (len > 0) : (len -= 1) {
        var value: []const u8 = undefined;
        if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch unreachable)) unreachable;
        load_token_object(file_name, tokens, value);
    }
}

fn load_token_object(file_name: []const u8, tokens: *TokenMap, cb: []const u8) void {
    var iter = cb;
    var len = cbor.decodeMapHeader(&iter) catch {
        iter = cb;
        const t = cbor.decodeType(&iter) catch unreachable;
        std.debug.panic("unexpected type for token object: {any}", .{t});
    };
    var scopes_cb: ?[]const u8 = null;
    var scopes_name: ?[]const u8 = null;
    var style: ?Style = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch unreachable)) unreachable;
        if (eql(u8, "scope", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch unreachable)) unreachable;
            scopes_cb = value;
        } else if (eql(u8, "settings", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch unreachable)) unreachable;
            style = load_token_settings_object(file_name, scopes_name, value);
        } else if (eql(u8, "name", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            scopes_name = value;
        } else {
            cbor.skipValue(&iter) catch unreachable;
        }
    }
    if (style) |sty| if (scopes_cb) |cb_| load_scopes(tokens, sty, cb_);
}

fn load_token_settings_object(file_name: []const u8, scopes_name: ?[]const u8, cb: []const u8) Style {
    var iter = cb;
    var len = cbor.decodeMapHeader(&iter) catch unreachable;
    var style: Style = .{};
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch unreachable)) unreachable;
        if (eql(u8, "foreground", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            style.fg = parse_color_value(value);
        } else if (eql(u8, "background", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            style.bg = parse_color_value(value);
        } else if (eql(u8, "fontStyle", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            if (eql(u8, "italic", value)) {
                style.fs = .italic;
            } else if (eql(u8, "bold", value)) {
                style.fs = .bold;
            } else if (eql(u8, "underline", value)) {
                style.fs = .underline;
            } else if (eql(u8, "italic underline", value)) {
                style.fs = .italic;
                style.fs = .underline;
            } else if (eql(u8, "bold italic", value)) {
                style.fs = .bold;
                style.fs = .italic;
            } else if (eql(u8, "italic bold", value)) {
                style.fs = .bold;
                style.fs = .italic;
            } else if (eql(u8, "strikethrough", value)) {
                style.fs = .strikethrough;
            } else if (eql(u8, "normal", value)) {
                style.fs = .normal;
            } else if (eql(u8, "regular", value)) {
                style.fs = .normal;
            } else if (eql(u8, "", value)) {
                style.fs = .normal;
            } else {
                std.debug.panic("unhandled fontStyle \"{s}\" in {s} -> {s}", .{ value, file_name, scopes_name orelse "unknown" });
            }
        } else if (eql(u8, "caret", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "invisibles", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "lineHighlight", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "selection", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "findHighlight", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "findHighlightForeground", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "selectionBorder", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "activeGuide", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "bracketsForeground", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "bracketsOptions", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "bracketContentsForeground", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "bracketContentsOptions", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else if (eql(u8, "tagsOptions", field_name)) {
            cbor.skipValue(&iter) catch unreachable;
        } else {
            std.debug.panic("unhandled style case \"{s}\" in {s} -> {s}", .{ field_name, file_name, scopes_name orelse "unknown" });
        }
    }
    return style;
}

fn load_scopes(tokens: *TokenMap, style: Style, cb: []const u8) void {
    var iter = cb;
    var len = cbor.decodeArrayHeader(&iter) catch {
        iter = cb;
        var value: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
        load_scopes_string(tokens, style, value);
        return;
    };
    while (len > 0) : (len -= 1) {
        var value: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
        load_scopes_string(tokens, style, value);
    }
}

fn load_scopes_string(tokens: *TokenMap, style: Style, scopes_: []const u8) void {
    var it = std.mem.splitScalar(u8, scopes_, ',');
    while (it.next()) |raw| {
        const selector = std.mem.trim(u8, raw, " ");
        if (selector.len == 0) continue;
        const target = if (std.mem.lastIndexOfScalar(u8, selector, ' ')) |i| selector[i + 1 ..] else selector;
        if (target.len > 0) tokens.put(target, style) catch unreachable;
    }
}

fn find_color(name: []const u8, src: Source) ?Color {
    var iter = src.cb;
    var len = cbor.decodeMapHeader(&iter) catch unreachable;
    var include: ?[]const u8 = null;
    var match: ?Color = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch unreachable)) unreachable;
        if (eql(u8, "colors", field_name)) {
            match = find_in_colors(name, &iter);
        } else if (eql(u8, "include", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch unreachable)) unreachable;
            include = value;
        } else {
            cbor.skipValue(&iter) catch unreachable;
        }
    }
    return if (match) |v| v else if (include) |inc| find_color(name, src.included(src.context.include(inc))) else null;
}

fn find_in_colors(name: []const u8, iter: *[]const u8) ?Color {
    var len = cbor.decodeMapHeader(iter) catch return null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        var value: []const u8 = undefined;
        if (!(cbor.matchString(iter, &field_name) catch unreachable)) unreachable;
        if (!(cbor.matchString(iter, &value) catch unreachable)) unreachable;
        if (eql(u8, field_name, name))
            return parse_color_value(value);
    }
    return null;
}

fn luma_of(c: Color) u32 {
    const r: u32 = (c.color >> 16) & 0xFF;
    const g: u32 = (c.color >> 8) & 0xFF;
    const b: u32 = c.color & 0xFF;
    return (r * 299 + g * 587 + b * 114) / 1000;
}

fn parse_type_string(s: ?[]const u8) ?theme.Type {
    const t = s orelse return null;
    if (eql(u8, t, "dark")) return .dark;
    if (eql(u8, t, "light")) return .light;
    return null;
}

fn compute_theme_type(src: Source) ?theme.Type {
    const bg = find_color("editor.background", src) orelse return null;
    const fg_luma: u32 = if (find_color("editor.foreground", src)) |fg| luma_of(fg) else 128;
    return if (luma_of(bg) < fg_luma) .dark else .light;
}

fn parse_color_value_checked(s: []const u8) !Color {
    const parseInt = @import("std").fmt.parseInt;
    if (s[0] != '#' or s.len < 7 or s.len > 9) return error.Failed;
    const r = try parseInt(u32, s[1..3], 16);
    const b = try parseInt(u32, s[3..5], 16);
    const g = try parseInt(u32, s[5..7], 16);
    var color: Color = .{ .color = @truncate((r << 16) + (b << 8) + g) };
    if (s.len > 7)
        color.alpha = try parseInt(u8, s[7..], 16);
    return color;
}

fn parse_color_value(s: []const u8) Color {
    if (4 <= s.len and s.len <= 5) return parse_color_value_4bit(s);
    return parse_color_value_checked(s) catch {
        std.log.err("failed to parse color value: {s}", .{s});
        unreachable;
    };
}

fn parse_color_value_4bit(s: []const u8) Color {
    const color = "#" ++ s[1..2] ++ s[1..2] ++ s[2..3] ++ s[2..3] ++ s[3..4] ++ s[3..4];
    const expanded = if (s.len > 4) color ++ s[4..5] ++ s[4..5] else color;
    return parse_color_value_checked(expanded) catch {
        std.log.err("failed to parse expanded color value: {s} {s}", .{ s, expanded });
        unreachable;
    };
}

const derive_style = struct {
    pub fn editor(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editor.foreground", src)) |col| col else defaults.@"editor.foreground"(type_idx, src),
            .bg = if (find_color("editor.background", src)) |col| col else defaults.@"editor.background"(type_idx, src),
        };
    }

    pub fn editor_cursor(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorCursor.background", src)) |col|
                col
            else if (find_color("terminalCursor.background", src)) |col|
                col
            else
                defaults.@"editorCursor.background"(type_idx, src),
            .bg = if (find_color("editorCursor.foreground", src)) |col|
                col
            else if (find_color("terminalCursor.foreground", src)) |col|
                col
            else
                defaults.@"editorCursor.foreground"(type_idx, src),
        };
    }

    pub fn editor_cursor_primary(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorMultiCursor.primary.background", src)) |col|
                col
            else if (find_color("terminalCursor.background", src)) |col|
                col
            else
                defaults.@"editorMultiCursor.primary.background"(type_idx, src),
            .bg = if (find_color("editorMultiCursor.primary.foreground", src)) |col|
                col
            else if (find_color("terminalCursor.foreground", src)) |col|
                col
            else
                defaults.@"editorMultiCursor.primary.foreground"(type_idx, src),
        };
    }

    pub fn editor_cursor_secondary(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorMultiCursor.secondary.background", src)) |col|
                col
            else if (find_color("terminalCursor.background", src)) |col|
                col
            else
                defaults.@"editorMultiCursor.secondary.background"(type_idx, src),
            .bg = if (find_color("editorMultiCursor.secondary.foreground", src)) |col|
                col
            else if (find_color("terminalCursor.foreground", src)) |col|
                col
            else
                defaults.@"editorMultiCursor.secondary.foreground"(type_idx, src),
        };
    }

    pub fn editor_line_highlight(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editor.foreground", src)) |col| col else defaults.@"editor.foreground"(type_idx, src),
            .bg = if (find_color("editor.lineHighlightBackground", src)) |col| col else defaults.@"editor.lineHighlightBackground"(type_idx, src),
        };
    }

    pub fn editor_error(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorError.foreground", src)) |col| col else defaults.@"editorError.foreground"(type_idx, src),
            .bg = if (find_color("editorError.background", src)) |col| col else defaults.@"editorError.background"(type_idx, src),
        };
    }

    pub fn editor_warning(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorWarning.foreground", src)) |col| col else defaults.@"editorWarning.foreground"(type_idx, src),
            .bg = if (find_color("editorWarning.background", src)) |col| col else defaults.@"editorWarning.background"(type_idx, src),
        };
    }

    pub fn editor_information(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorInfo.foreground", src)) |col| col else defaults.@"editorInfo.foreground"(type_idx, src),
            .bg = if (find_color("editorInfo.background", src)) |col| col else defaults.@"editorInfo.background"(type_idx, src),
        };
    }

    pub fn editor_hint(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorHint.foreground", src)) |col| col else defaults.@"editorHint.foreground"(type_idx, src),
            .bg = if (find_color("editorHint.background", src)) |col| col else defaults.@"editorHint.background"(type_idx, src),
        };
    }

    pub fn editor_match(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editor.foreground", src)) |col| col else defaults.@"editor.foreground"(type_idx, src),
            .bg = if (find_color("editor.findMatchBackground", src)) |col| col else defaults.@"editor.findMatchBackground"(type_idx, src),
        };
    }

    pub fn editor_selection(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editor.selectionForeground", src)) |col| col else defaults.@"editor.selectionForeground"(type_idx, src),
            .bg = if (find_color("editor.selectionBackground", src)) |col| col else defaults.@"editor.selectionBackground"(type_idx, src),
        };
    }

    pub fn terminal_selection(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("terminal.selectionForeground", src)) |col| col else defaults.@"terminal.selectionForeground"(type_idx, src),
            .bg = if (find_color("terminal.selectionBackground", src)) |col| col else defaults.@"terminal.selectionBackground"(type_idx, src),
        };
    }

    pub fn editor_whitespace(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorWhitespace.foreground", src)) |col| col else defaults.@"editorWhitespace.foreground"(type_idx, src),
            .bg = if (find_color("editor.background", src)) |col| col else defaults.@"editor.background"(type_idx, src),
        };
    }

    pub fn editor_gutter(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorLineNumber.foreground", src)) |col| col else defaults.@"editorLineNumber.foreground"(type_idx, src),
            .bg = if (find_color("editorGutter.background", src)) |col| col else defaults.@"editorGutter.background"(type_idx, src),
        };
    }

    pub fn editor_gutter_active(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorLineNumber.activeForeground", src)) |col| col else defaults.@"editorLineNumber.activeForeground"(type_idx, src),
            .bg = if (find_color("editorGutter.background", src)) |col| col else defaults.@"editorGutter.background"(type_idx, src),
        };
    }

    pub fn editor_gutter_modified(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorGutter.modifiedBackground", src)) |col| col else defaults.@"editorGutter.modifiedBackground"(type_idx, src),
            .bg = if (find_color("editorGutter.background", src)) |col| col else defaults.@"editorGutter.background"(type_idx, src),
        };
    }

    pub fn editor_gutter_added(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorGutter.addedBackground", src)) |col| col else defaults.@"editorGutter.addedBackground"(type_idx, src),
            .bg = if (find_color("editorGutter.background", src)) |col| col else defaults.@"editorGutter.background"(type_idx, src),
        };
    }

    pub fn editor_gutter_deleted(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorGutter.deletedBackground", src)) |col| col else defaults.@"editorGutter.deletedBackground"(type_idx, src),
            .bg = if (find_color("editorGutter.background", src)) |col| col else defaults.@"editorGutter.background"(type_idx, src),
        };
    }

    pub fn diff_editor_inserted_line(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditor.insertedLineBackground", src)) |col| col else defaults.@"diffEditor.insertedLineBackground"(type_idx, src),
        };
    }

    pub fn diff_editor_removed_line(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditor.removedLineBackground", src)) |col| col else defaults.@"diffEditor.removedLineBackground"(type_idx, src),
        };
    }

    pub fn diff_editor_inserted_text(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditor.insertedTextBackground", src)) |col| col else defaults.@"diffEditor.insertedTextBackground"(type_idx, src),
        };
    }

    pub fn diff_editor_removed_text(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditor.removedTextBackground", src)) |col| col else defaults.@"diffEditor.removedTextBackground"(type_idx, src),
        };
    }

    pub fn diff_editor_gutter_inserted_line(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditorGutter.insertedLineBackground", src)) |col| col else defaults.@"diffEditorGutter.insertedLineBackground"(type_idx, src),
        };
    }

    pub fn diff_editor_gutter_removed_line(type_idx: usize, src: Source) Style {
        return .{
            .bg = if (find_color("diffEditorGutter.removedLineBackground", src)) |col| col else defaults.@"diffEditorGutter.removedLineBackground"(type_idx, src),
        };
    }

    pub fn editor_widget(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorWidget.foreground", src)) |col| col else defaults.@"editorWidget.foreground"(type_idx, src),
            .bg = if (find_color("editorWidget.background", src)) |col| col else defaults.@"editorWidget.background"(type_idx, src),
        };
    }

    pub fn editor_widget_border(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("editorWidget.foreground", src)) |col| col else defaults.@"editorWidget.foreground"(type_idx, src),
            .bg = if (find_color("editorWidget.border", src)) |col| col else defaults.@"editorWidget.border"(type_idx, src),
        };
    }

    pub fn statusbar(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("statusBar.foreground", src)) |col| col else defaults.@"statusBar.foreground"(type_idx, src),
            .bg = if (find_color("statusBar.background", src)) |col| col else defaults.@"statusBar.background"(type_idx, src),
        };
    }

    pub fn statusbar_hover(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("statusBarItem.hoverForeground", src)) |col| col else defaults.@"statusBarItem.hoverForeground"(type_idx, src),
            .bg = if (find_color("statusBarItem.hoverBackground", src)) |col| col else defaults.@"statusBarItem.hoverBackground"(type_idx, src),
        };
    }

    pub fn scrollbar(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.background", src)) |col| col else defaults.@"scrollbarSlider.background"(type_idx, src),
            .bg = editor(type_idx, src).bg,
        };
    }

    pub fn scrollbar_hover(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.hoverBackground", src)) |col| col else defaults.@"scrollbarSlider.hoverBackground"(type_idx, src),
            .bg = editor(type_idx, src).bg,
        };
    }

    pub fn scrollbar_active(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.activeBackground", src)) |col| col else defaults.@"scrollbarSlider.activeBackground"(type_idx, src),
            .bg = editor(type_idx, src).bg,
        };
    }

    pub fn sidebar(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("sideBar.foreground", src)) |col| col else defaults.@"sideBar.foreground"(type_idx, src),
            .bg = if (find_color("sideBar.background", src)) |col| col else defaults.@"sideBar.background"(type_idx, src),
        };
    }

    pub fn panel(type_idx: usize, src: Source) Style {
        const editor_style = editor(type_idx, src);
        return .{
            .fg = editor_style.fg,
            .bg = if (find_color("panel.background", src)) |col| col else editor_style.bg,
        };
    }

    pub fn input(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("input.foreground", src)) |col| col else defaults.@"input.foreground"(type_idx, src),
            .bg = if (find_color("input.background", src)) |col| col else defaults.@"input.background"(type_idx, src),
        };
    }

    pub fn input_border(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("input.border", src)) |col| col else defaults.@"input.border"(type_idx, src),
            .bg = if (find_color("input.background", src)) |col| col else defaults.@"input.background"(type_idx, src),
        };
    }

    pub fn input_placeholder(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("input.placeholderForeground", src)) |col| col else defaults.@"input.placeholderForeground"(type_idx, src),
            .bg = if (find_color("input.background", src)) |col| col else defaults.@"input.background"(type_idx, src),
        };
    }

    pub fn input_option(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("input.foreground", src)) |col| col else defaults.@"input.foreground"(type_idx, src),
            .bg = if (find_color("input.background", src)) |col| col else defaults.@"input.background"(type_idx, src),
        };
    }

    pub fn input_option_active(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("inputOption.activeForeground", src)) |col| col else defaults.@"inputOption.activeForeground"(type_idx, src),
            .bg = if (find_color("inputOption.activeBackground", src)) |col| col else defaults.@"inputOption.activeBackground"(type_idx, src),
        };
    }

    pub fn input_option_hover(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("input.foreground", src)) |col| col else defaults.@"input.foreground"(type_idx, src),
            .bg = if (find_color("inputOption.hoverBackground", src)) |col| col else defaults.@"inputOption.hoverBackground"(type_idx, src),
        };
    }

    pub fn tab_active(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("tab.activeForeground", src)) |col| col else defaults.@"tab.activeForeground"(type_idx, src),
            .bg = if (find_color("tab.activeBackground", src)) |col| col else defaults.@"tab.activeBackground"(type_idx, src),
        };
    }

    pub fn tab_inactive(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("tab.inactiveForeground", src)) |col| col else defaults.@"tab.inactiveForeground"(type_idx, src),
            .bg = if (find_color("tab.inactiveBackground", src)) |col| col else defaults.@"tab.inactiveBackground"(type_idx, src),
        };
    }

    pub fn tab_selected(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("tab.selectedForeground", src)) |col| col else defaults.@"tab.selectedForeground"(type_idx, src),
            .bg = if (find_color("tab.selectedBackground", src)) |col| col else defaults.@"tab.selectedBackground"(type_idx, src),
        };
    }

    pub fn tab_unfocused_active(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("tab.unfocusedActiveForeground", src)) |col| col else defaults.@"tab.unfocusedActiveForeground"(type_idx, src),
            .bg = if (find_color("tab.unfocusedActiveBackground", src)) |col| col else defaults.@"tab.unfocusedActiveBackground"(type_idx, src),
        };
    }

    pub fn tab_unfocused_inactive(type_idx: usize, src: Source) Style {
        return .{
            .fg = if (find_color("tab.unfocusedInactiveForeground", src)) |col| col else defaults.@"tab.unfocusedInactiveForeground"(type_idx, src),
            .bg = if (find_color("tab.unfocusedInactiveBackground", src)) |col| col else defaults.@"tab.unfocusedInactiveBackground"(type_idx, src),
        };
    }

    pub fn tab_bar(type_idx: usize, src: Source) Style {
        return .{
            .fg = derive_style.tab_inactive(type_idx, src).fg,
            .bg = if (find_color("editorGroupHeader.tabsBackground", src)) |col| col else defaults.@"editorGroupHeader.tabsBackground"(type_idx, src),
        };
    }

    pub fn ansi_black(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBlack", src)) |col| col else defaults.@"terminal.ansiBlack"(type_idx, src).?;
    }

    pub fn ansi_red(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiRed", src)) |col| col else defaults.@"terminal.ansiRed"(type_idx, src).?;
    }

    pub fn ansi_green(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiGreen", src)) |col| col else defaults.@"terminal.ansiGreen"(type_idx, src).?;
    }

    pub fn ansi_yellow(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiYellow", src)) |col| col else defaults.@"terminal.ansiYellow"(type_idx, src).?;
    }

    pub fn ansi_blue(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBlue", src)) |col| col else defaults.@"terminal.ansiBlue"(type_idx, src).?;
    }

    pub fn ansi_magenta(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiMagenta", src)) |col| col else defaults.@"terminal.ansiMagenta"(type_idx, src).?;
    }

    pub fn ansi_cyan(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiCyan", src)) |col| col else defaults.@"terminal.ansiCyan"(type_idx, src).?;
    }

    pub fn ansi_white(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiWhite", src)) |col| col else defaults.@"terminal.ansiWhite"(type_idx, src).?;
    }

    pub fn ansi_bright_black(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightBlack", src)) |col| col else defaults.@"terminal.ansiBrightBlack"(type_idx, src).?;
    }

    pub fn ansi_bright_red(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightRed", src)) |col| col else defaults.@"terminal.ansiBrightRed"(type_idx, src).?;
    }

    pub fn ansi_bright_green(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightGreen", src)) |col| col else defaults.@"terminal.ansiBrightGreen"(type_idx, src).?;
    }

    pub fn ansi_bright_yellow(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightYellow", src)) |col| col else defaults.@"terminal.ansiBrightYellow"(type_idx, src).?;
    }

    pub fn ansi_bright_blue(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightBlue", src)) |col| col else defaults.@"terminal.ansiBrightBlue"(type_idx, src).?;
    }

    pub fn ansi_bright_magenta(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightMagenta", src)) |col| col else defaults.@"terminal.ansiBrightMagenta"(type_idx, src).?;
    }

    pub fn ansi_bright_cyan(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightCyan", src)) |col| col else defaults.@"terminal.ansiBrightCyan"(type_idx, src).?;
    }

    pub fn ansi_bright_white(type_idx: usize, src: Source) Color {
        return if (find_color("terminal.ansiBrightWhite", src)) |col| col else defaults.@"terminal.ansiBrightWhite"(type_idx, src).?;
    }

    pub fn ansi_palette(type_idx: usize, src: Source) [16][3]u8 {
        const c = struct {
            fn f(v: u24) [3]u8 {
                return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
            }
        }.f;
        return .{
            c(ansi_black(type_idx, src).color),
            c(ansi_red(type_idx, src).color),
            c(ansi_green(type_idx, src).color),
            c(ansi_yellow(type_idx, src).color),
            c(ansi_blue(type_idx, src).color),
            c(ansi_magenta(type_idx, src).color),
            c(ansi_cyan(type_idx, src).color),
            c(ansi_white(type_idx, src).color),
            c(ansi_bright_black(type_idx, src).color),
            c(ansi_bright_red(type_idx, src).color),
            c(ansi_bright_green(type_idx, src).color),
            c(ansi_bright_yellow(type_idx, src).color),
            c(ansi_bright_blue(type_idx, src).color),
            c(ansi_bright_magenta(type_idx, src).color),
            c(ansi_bright_cyan(type_idx, src).color),
            c(ansi_bright_white(type_idx, src).color),
        };
    }
};

const defaults = struct {
    // registerColor('foreground', { dark: '#CCCCCC', light: '#616161', hcDark: '#FFFFFF', hcLight: '#292929' }, nls.localize('foreground', "Overall foreground color. This color is only used if not overridden by a component."));
    fn foreground(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xCCCCCC }, .{ .color = 0x616161 } })[type_idx];
    }

    // registerColor('editor.foreground', { light: '#333333', dark: '#BBBBBB', hcDark: Color.white, hcLight: foreground }, nls.localize('editorForeground', "Editor default foreground color."));
    fn @"editor.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xBBBBBB }, .{ .color = 0x333333 } })[type_idx];
    }

    // registerColor('editor.background', { light: '#ffffff', dark: '#1E1E1E', hcDark: Color.black, hcLight: Color.white }, nls.localize('editorBackground', "Editor background color."));
    fn @"editor.background"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x1E1E1E }, .{ .color = 0xffffff } })[type_idx];
    }

    // registerColor('editorCursor.foreground', { dark: '#AEAFAD', light: Color.black, hcDark: Color.white, hcLight: '#0F4A85' }, nls.localize('caret', 'Color of the editor cursor.'));
    fn @"editorCursor.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xAEAFAD }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('editorCursor.background', null, nls.localize('editorCursorBackground', 'The background color of the editor cursor. Allows customizing the color of a character overlapped by a block cursor.'));
    fn @"editorCursor.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorMultiCursor.primary.foreground', editorCursorForeground, nls.localize('editorMultiCursorPrimaryForeground', 'Color of the primary editor cursor when multiple cursors are present.'));
    fn @"editorMultiCursor.primary.foreground"(type_idx: usize, src: Source) ?Color {
        return @"editorCursor.foreground"(type_idx, src);
    }

    // registerColor('editorMultiCursor.primary.background', editorCursorBackground, nls.localize('editorMultiCursorPrimaryBackground', 'The background color of the primary editor cursor when multiple cursors are present. Allows customizing the color of a character overlapped by a block cursor.'));
    fn @"editorMultiCursor.primary.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorMultiCursor.secondary.foreground', editorCursorForeground, nls.localize('editorMultiCursorSecondaryForeground', 'Color of secondary editor cursors when multiple cursors are present.'));
    fn @"editorMultiCursor.secondary.foreground"(type_idx: usize, src: Source) ?Color {
        return @"editorCursor.foreground"(type_idx, src);
    }

    // registerColor('editorMultiCursor.secondary.background', editorCursorBackground, nls.localize('editorMultiCursorSecondaryBackground', 'The background color of secondary editor cursors when multiple cursors are present. Allows customizing the color of a character overlapped by a block cursor.'));
    fn @"editorMultiCursor.secondary.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editor.lineHighlightBackground', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('lineHighlight', 'Background color for the highlight of line at the cursor position.'));
    fn @"editor.lineHighlightBackground"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorError.foreground', { dark: '#F14C4C', light: '#E51400', hcDark: '#F48771', hcLight: '#B5200D' }, nls.localize('editorError.foreground', 'Foreground color of error squigglies in the editor.'));
    fn @"editorError.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xF14C4C }, .{ .color = 0xE51400 } })[type_idx];
    }

    // registerColor('editorError.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorError.background', 'Background color of error text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorError.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorWarning.foreground', { dark: '#CCA700', light: '#BF8803', hcDark: '#FFD370', hcLight: '#895503' }, nls.localize('editorWarning.foreground', 'Foreground color of warning squigglies in the editor.'));
    fn @"editorWarning.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xCCA700 }, .{ .color = 0xBF8803 } })[type_idx];
    }

    // registerColor('editorWarning.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorWarning.background', 'Background color of warning text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorWarning.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorInfo.foreground', { dark: '#3794FF', light: '#1a85ff', hcDark: '#3794FF', hcLight: '#1a85ff' }, nls.localize('editorInfo.foreground', 'Foreground color of info squigglies in the editor.'));
    fn @"editorInfo.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x3794FF }, .{ .color = 0x1a85ff } })[type_idx];
    }

    // registerColor('editorInfo.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorInfo.background', 'Background color of info text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorInfo.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorHint.foreground', { dark: Color.fromHex('#eeeeee').transparent(0.7), light: '#6c6c6c', hcDark: null, hcLight: null }, nls.localize('editorHint.foreground', 'Foreground color of hint squigglies in the editor.'));
    fn @"editorHint.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xeeeeee, .alpha = 0xb3 }, .{ .color = 0x6c6c6c } })[type_idx];
    }

    // none
    fn @"editorHint.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editor.findMatchBackground', { light: '#A8AC94', dark: '#515C6A', hcDark: null, hcLight: null }, nls.localize('editorFindMatch', "Color of the current search match."));
    fn @"editor.findMatchBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x515C6A }, .{ .color = 0xA8AC94 } })[type_idx];
    }

    // registerColor('editor.findMatchHighlightBackground', { light: '#EA5C0055', dark: '#EA5C0055', hcDark: null, hcLight: null }, nls.localize('findMatchHighlight', "Color of the other search matches. The color must not be opaque so as not to hide underlying decorations."), true);
    fn @"editor.findMatchHighlightBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xEA5C00 }, .{ .color = 0xEA5C00 } })[type_idx];
    }

    // registerColor('editor.selectionForeground', { light: null, dark: null, hcDark: '#000000', hcLight: Color.white }, nls.localize('editorSelectionForeground', "Color of the selected text for high contrast."));
    fn @"editor.selectionForeground"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).fg;
    }

    // registerColor('editor.selectionBackground', { light: '#ADD6FF', dark: '#264F78', hcDark: '#f3f518', hcLight: '#0F4A85' }, nls.localize('editorSelectionBackground', "Color of the editor selection."));
    fn @"editor.selectionBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x264F78 }, .{ .color = 0xADD6FF } })[type_idx];
    }

    // registerColor('terminal.selectionBackground', editorSelectionBackground, nls.localize('terminal.selectionBackground', 'The selection background color of the terminal.'));
    fn @"terminal.selectionBackground"(type_idx: usize, src: Source) Color {
        return @"editor.selectionBackground"(type_idx, src);
    }

    // registerColor('terminal.selectionForeground', { light: null, dark: null, hcDark: '#000000', hcLight: '#ffffff' }, nls.localize('terminal.selectionForeground', 'The selection foreground color of the terminal. When this is null the selection foreground will be retained and have the minimum contrast ratio feature applied.'));
    fn @"terminal.selectionForeground"(_: usize, _: Source) ?Color {
        return null;
    }

    // registerColor('sideBar.foreground', { dark: null, light: null, hcDark: null, hcLight: null }, localize('sideBarForeground', "Side bar foreground color. The side bar is the container for views like explorer and search."));
    fn @"sideBar.foreground"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).fg;
    }

    // registerColor('sideBar.background', { dark: '#252526', light: '#F3F3F3', hcDark: '#000000', hcLight: '#FFFFFF' }, localize('sideBarBackground', "Side bar background color. The side bar is the container for views like explorer and search."));
    fn @"sideBar.background"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x252526 }, .{ .color = 0xF3F3F3 } })[type_idx];
    }

    // registerColor('scrollbar.shadow', { dark: '#000000', light: '#DDDDDD', hcDark: null, hcLight: null }, nls.localize('scrollbarShadow', "Scrollbar shadow to indicate that the view is scrolled."));
    fn @"scrollbar.shadow"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x000000 }, .{ .color = 0xDDDDDD } })[type_idx];
    }

    // registerColor('scrollbarSlider.background', { dark: Color.fromHex('#797979').transparent(0.4), light: Color.fromHex('#646464').transparent(0.4), hcDark: transparent(contrastBorder, 0.6), hcLight: transparent(contrastBorder, 0.4) }, nls.localize('scrollbarSliderBackground', "Scrollbar slider background color."));
    fn @"scrollbarSlider.background"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x797979 }, .{ .color = 0x646464 } })[type_idx];
    }

    // registerColor('scrollbarSlider.hoverBackground', { dark: Color.fromHex('#646464').transparent(0.7), light: Color.fromHex('#646464').transparent(0.7), hcDark: transparent(contrastBorder, 0.8), hcLight: transparent(contrastBorder, 0.8) }, nls.localize('scrollbarSliderHoverBackground', "Scrollbar slider background color when hovering."));
    fn @"scrollbarSlider.hoverBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x646464 }, .{ .color = 0x646464 } })[type_idx];
    }

    // registerColor('scrollbarSlider.activeBackground', { dark: Color.fromHex('#BFBFBF').transparent(0.4), light: Color.fromHex('#000000').transparent(0.6), hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('scrollbarSliderActiveBackground', "Scrollbar slider background color when clicked on."));
    fn @"scrollbarSlider.activeBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xBFBFBF }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('statusBar.foreground', { dark: '#FFFFFF', light: '#FFFFFF', hcDark: '#FFFFFF', hcLight: editorForeground }, localize('statusBarForeground', "Status bar foreground color when a workspace or folder is opened. The status bar is shown in the bottom of the window."));
    fn @"statusBar.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xFFFFFF }, .{ .color = 0xFFFFFF } })[type_idx];
    }

    // registerColor('statusBar.background', { dark: '#007ACC', light: '#007ACC', hcDark: null, hcLight: null, }, localize('statusBarBackground', "Status bar background color when a workspace or folder is opened. The status bar is shown in the bottom of the window."));
    fn @"statusBar.background"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x007ACC }, .{ .color = 0x007ACC } })[type_idx];
    }

    // registerColor('statusBarItem.hoverForeground', { dark: STATUS_BAR_FOREGROUND, light: STATUS_BAR_FOREGROUND, hcDark: STATUS_BAR_FOREGROUND, hcLight: STATUS_BAR_FOREGROUND }, localize('statusBarItemHoverForeground', "Status bar item foreground color when hovering. The status bar is shown in the bottom of the window."));
    fn @"statusBarItem.hoverForeground"(type_idx: usize, src: Source) ?Color {
        return derive_style.statusbar(type_idx, src).fg;
    }

    // registerColor('statusBarItem.hoverBackground', { dark: Color.white.transparent(0.12), light: Color.white.transparent(0.12), hcDark: Color.white.transparent(0.12), hcLight: Color.black.transparent(0.12) }, localize('statusBarItemHoverBackground', "Status bar item background color when hovering. The status bar is shown in the bottom of the window."));
    fn @"statusBarItem.hoverBackground"(type_idx: usize, src: Source) ?Color {
        return .{ .color = derive_style.statusbar(type_idx, src).bg.?.color, .alpha = 256 * 12 / 100 };
    }

    // registerColor('editorWhitespace.foreground', { dark: '#e3e4e229', light: '#33333333', hcDark: '#e3e4e229', hcLight: '#CCCCCC' }, nls.localize('editorWhitespaces', 'Color of whitespace characters in the editor.'));
    fn @"editorWhitespace.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xe3e4e2, .alpha = 0x29 }, .{ .color = 0x333333, .alpha = 0x33 } })[type_idx];
    }

    // registerColor('editorLineNumber.foreground', { dark: '#858585', light: '#237893', hcDark: Color.white, hcLight: '#292929' }, nls.localize('editorLineNumbers', 'Color of editor line numbers.'));
    fn @"editorLineNumber.foreground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x858585 }, .{ .color = 0x237893 } })[type_idx];
    }

    // registerColor('editorLineNumber.activeForeground', { dark: deprecatedEditorActiveLineNumber, light: deprecatedEditorActiveLineNumber, hcDark: deprecatedEditorActiveLineNumber, hcLight: deprecatedEditorActiveLineNumber }, nls.localize('editorActiveLineNumber', 'Color of editor active line number'));
    // registerColor('editorActiveLineNumber.foreground', { dark: '#c6c6c6', light: '#0B216F', hcDark: activeContrastBorder, hcLight: activeContrastBorder }, nls.localize('editorActiveLineNumber', 'Color of editor active line number'), false, nls.localize('deprecatedEditorActiveLineNumber', 'Id is deprecated. Use \'editorLineNumber.activeForeground\' instead.'));
    fn @"editorLineNumber.activeForeground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0xc6c6c6 }, .{ .color = 0x0B216F } })[type_idx];
    }

    // registerColor('editorGutter.background', { dark: editorBackground, light: editorBackground, hcDark: editorBackground, hcLight: editorBackground }, nls.localize('editorGutter', 'Background color of the editor gutter. The gutter contains the glyph margins and the line numbers.'));
    fn @"editorGutter.background"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).bg;
    }

    // registerColor('editorGutter.modifiedBackground', { dark: '#1B81A8', light: '#2090D3', hcDark: '#1B81A8', hcLight: '#2090D3'}, nls.localize('editorGutterModifiedBackground', "Editor gutter background color for lines that are modified."));
    fn @"editorGutter.modifiedBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x1B81A8 }, .{ .color = 0x2090D3 } })[type_idx];
    }

    // registerColor('editorGutter.addedBackground', { dark: '#487E02', light: '#48985D', hcDark: '#487E02', hcLight: '#48985D' }, nls.localize('editorGutterAddedBackground', "Editor gutter background color for lines that are added."));
    fn @"editorGutter.addedBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x487E02 }, .{ .color = 0x48985D } })[type_idx];
    }

    // registerColor('editorGutter.deletedBackground', { dark: editorErrorForeground, light: editorErrorForeground, hcDark: editorErrorForeground, hcLight: editorErrorForeground }, nls.localize('editorGutterDeletedBackground', "Editor gutter background color for lines that are deleted."));
    fn @"editorGutter.deletedBackground"(type_idx: usize, src: Source) ?Color {
        return @"editorError.foreground"(type_idx, src);
    }

    // export const defaultInsertColor = new Color(new RGBA(155, 185, 85, .2));
    // registerColor('diffEditor.insertedLineBackground', { dark: defaultInsertColor, light: defaultInsertColor, hcDark: null, hcLight: null }, nls.localize('diffEditorInsertedLines', 'Background color for lines that got inserted. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"diffEditor.insertedLineBackground"(_: usize, _: Source) Color {
        return .{ .color = 0x9bb955, .alpha = 0x33 };
    }

    // export const defaultRemoveColor = new Color(new RGBA(255, 0, 0, .2));
    // registerColor('diffEditor.removedLineBackground', { dark: defaultRemoveColor, light: defaultRemoveColor, hcDark: null, hcLight: null }, nls.localize('diffEditorRemovedLines', 'Background color for lines that got removed. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"diffEditor.removedLineBackground"(_: usize, _: Source) Color {
        return .{ .color = 0xff0000, .alpha = 0x33 };
    }

    // registerColor('diffEditor.insertedTextBackground', { dark: '#9ccc2c33', light: '#9ccc2c40', hcDark: null, hcLight: null }, nls.localize('diffEditorInserted', 'Background color for text that got inserted. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"diffEditor.insertedTextBackground"(type_idx: usize, _: Source) Color {
        return ([2]Color{ .{ .color = 0x9ccc2c, .alpha = 0x33 }, .{ .color = 0x9ccc2c, .alpha = 0x40 } })[type_idx];
    }

    // registerColor('diffEditor.removedTextBackground', { dark: '#ff000033', light: '#ff000033', hcDark: null, hcLight: null }, nls.localize('diffEditorRemoved', 'Background color for text that got removed. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"diffEditor.removedTextBackground"(_: usize, _: Source) Color {
        return .{ .color = 0xff0000, .alpha = 0x33 };
    }

    // registerColor('diffEditorGutter.insertedLineBackground', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('diffEditorInsertedLineGutter', 'Background color for the margin where lines got inserted.'));
    fn @"diffEditorGutter.insertedLineBackground"(_: usize, _: Source) ?Color {
        return null;
    }

    // registerColor('diffEditorGutter.removedLineBackground', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('diffEditorRemovedLineGutter', 'Background color for the margin where lines got removed.'));
    fn @"diffEditorGutter.removedLineBackground"(_: usize, _: Source) ?Color {
        return null;
    }

    // registerColor('editorWidget.foreground', { dark: foreground, light: foreground, hcDark: foreground, hcLight: foreground }, nls.localize('editorWidgetForeground', 'Foreground color of editor widgets, such as find/replace.'));
    fn @"editorWidget.foreground"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).fg;
    }

    // registerColor('editorWidget.background', { dark: '#252526', light: '#F3F3F3', hcDark: '#0C141F', hcLight: Color.white }, nls.localize('editorWidgetBackground', 'Background color of editor widgets, such as find/replace.'));
    fn @"editorWidget.background"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x252526 }, .{ .color = 0xF3F3F3 } })[type_idx];
    }

    // registerColor('editorWidget.border', { dark: '#454545', light: '#C8C8C8', hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('editorWidgetBorder', 'Border color of editor widgets. The color is only used if the widget chooses to have a border and if the color is not overridden by a widget.'));
    fn @"editorWidget.border"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x454545 }, .{ .color = 0xC8C8C8 } })[type_idx];
    }

    // registerColor('input.foreground', { dark: foreground, light: foreground, hcDark: foreground, hcLight: foreground }, nls.localize('inputBoxForeground', "Input box foreground."));
    fn @"input.foreground"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).fg;
    }

    // registerColor('input.background', { dark: '#3C3C3C', light: Color.white, hcDark: Color.black, hcLight: Color.white }, nls.localize('inputBoxBackground', "Input box background."));
    fn @"input.background"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x3C3C3C }, .{ .color = 0xFFFFFF } })[type_idx];
    }

    // registerColor('input.border', { dark: null, light: null, hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('inputBoxBorder', "Input box border."));
    fn @"input.border"(type_idx: usize, src: Source) ?Color {
        return derive_style.editor(type_idx, src).fg;
    }

    // registerColor('input.placeholderForeground', { light: transparent(foreground, 0.5), dark: transparent(foreground, 0.5), hcDark: transparent(foreground, 0.7), hcLight: transparent(foreground, 0.7) }, nls.localize('inputPlaceholderForeground', "Input box foreground color for placeholder text."));
    fn @"input.placeholderForeground"(type_idx: usize, src: Source) ?Color {
        return .{ .color = derive_style.editor(type_idx, src).fg.?.color, .alpha = 256 / 2 };
    }

    // registerColor('inputOption.activeForeground', { dark: Color.white, light: Color.black, hcDark: foreground, hcLight: foreground }, nls.localize('inputOption.activeForeground', "Foreground color of activated options in input fields."));
    fn @"inputOption.activeForeground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xFFFFFF }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('focusBorder', { dark: '#007FD4', light: '#0090F1', hcDark: '#F38518', hcLight: '#006BBD' }, nls.localize('focusBorder', "Overall border color for focused elements. This color is only used if not overridden by a component."));
    fn focusBorder(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x007FD4 }, .{ .color = 0x0090F1 } })[type_idx];
    }

    // registerColor('inputOption.activeBackground', { dark: transparent(focusBorder, 0.4), light: transparent(focusBorder, 0.2), hcDark: Color.transparent, hcLight: Color.transparent }, nls.localize('inputOption.activeBackground', "Background hover color of options in input fields."));
    fn @"inputOption.activeBackground"(type_idx: usize, src: Source) ?Color {
        return ([2]Color{ .{ .color = focusBorder(0, src).?.color, .alpha = 256 * 40 / 100 }, .{ .color = focusBorder(1, src).?.color, .alpha = 256 * 20 / 100 } })[type_idx];
    }

    // registerColor('inputOption.hoverBackground', { dark: '#5a5d5e80', light: '#b8b8b850', hcDark: null, hcLight: null }, nls.localize('inputOption.hoverBackground', "Background color of activated options in input fields."));
    fn @"inputOption.hoverBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x5a5d5e, .alpha = 0x80 }, .{ .color = 0xb8b8b8, .alpha = 0x50 } })[type_idx];
    }

    // export const COLOR_THEME_DARK_INITIAL_COLORS = {
    //     'tab.activeBackground': '#1f1f1f',
    //     'tab.activeForeground': '#ffffff',
    // };
    // export const COLOR_THEME_LIGHT_INITIAL_COLORS = {
    //     'tab.activeBackground': '#ffffff',
    //     'tab.activeForeground': '#3b3b3b',
    // };
    fn @"tab.activeBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x1f1f1f }, .{ .color = 0xffffff } })[type_idx];
    }

    fn @"tab.activeForeground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xffffff }, .{ .color = 0x3b3b3b } })[type_idx];
    }

    // dark: transparent(TAB_ACTIVE_FOREGROUND, 0.5),
    // light: transparent(TAB_ACTIVE_FOREGROUND, 0.7),
    fn @"tab.inactiveForeground"(type_idx: usize, src: Source) ?Color {
        return ([2]Color{ .{ .color = derive_style.tab_active(type_idx, src).fg.?.color, .alpha = 256 / 2 }, .{ .color = derive_style.tab_active(type_idx, src).fg.?.color, .alpha = 256 * 7 / 10 } })[type_idx];
    }

    // registerColor('tab.inactiveBackground', { dark: '#2D2D2D', light: '#ECECEC', },
    fn @"tab.inactiveBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x2D2D2D }, .{ .color = 0xECECEC } })[type_idx];
    }

    // registerColor('tab.selectedBackground', TAB_ACTIVE_BACKGROUND
    fn @"tab.selectedBackground"(type_idx: usize, src: Source) ?Color {
        return .{ .color = derive_style.tab_active(type_idx, src).bg.?.color };
    }

    // registerColor('tab.selectedForeground', TAB_ACTIVE_FOREGROUND
    fn @"tab.selectedForeground"(type_idx: usize, src: Source) ?Color {
        return .{ .color = derive_style.tab_active(type_idx, src).fg.?.color };
    }

    fn @"tab.unfocusedActiveBackground"(type_idx: usize, src: Source) ?Color {
        return derive_style.tab_active(type_idx, src).bg;
    }

    fn @"tab.unfocusedActiveForeground"(type_idx: usize, src: Source) ?Color {
        return ([2]Color{
            .{ .color = derive_style.tab_active(type_idx, src).fg.?.color, .alpha = 256 / 2 },
            .{ .color = derive_style.tab_active(type_idx, src).fg.?.color, .alpha = 256 * 7 / 10 },
        })[type_idx];
    }

    fn @"tab.unfocusedInactiveBackground"(type_idx: usize, src: Source) ?Color {
        return derive_style.tab_inactive(type_idx, src).bg;
    }

    fn @"tab.unfocusedInactiveForeground"(type_idx: usize, src: Source) ?Color {
        return ([2]Color{
            .{ .color = derive_style.tab_inactive(type_idx, src).fg.?.color, .alpha = 256 / 2 },
            .{ .color = derive_style.tab_inactive(type_idx, src).fg.?.color, .alpha = 256 / 2 },
        })[type_idx];
    }

    // registerColor('editorGroupHeader.tabsBackground', { dark: '#252526', light: '#F3F3F3', },
    fn @"editorGroupHeader.tabsBackground"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x252526 }, .{ .color = 0xF3F3F3 } })[type_idx];
    }

    // 'terminal.ansiBlack': index: 0, dark: '#000000', light: '#000000',
    fn @"terminal.ansiBlack"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x000000 }, .{ .color = 0x000000 } })[type_idx];
    }

    // 'terminal.ansiRed': index: 1, dark: '#cd3131', light: '#cd3131',
    fn @"terminal.ansiRed"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xcd3131 }, .{ .color = 0xcd3131 } })[type_idx];
    }

    // 'terminal.ansiGreen': index: 2, dark: '#0DBC79', light: '#107C10',
    fn @"terminal.ansiGreen"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x0DBC79 }, .{ .color = 0x107C10 } })[type_idx];
    }

    // 'terminal.ansiYellow': index: 3, dark: '#e5e510', light: '#949800',
    fn @"terminal.ansiYellow"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xe5e510 }, .{ .color = 0x949800 } })[type_idx];
    }

    // 'terminal.ansiBlue': index: 4, dark: '#2472c8', light: '#0451a5',
    fn @"terminal.ansiBlue"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x2472c8 }, .{ .color = 0x0451a5 } })[type_idx];
    }

    // 'terminal.ansiMagenta': index: 5, dark: '#bc3fbc', light: '#bc05bc',
    fn @"terminal.ansiMagenta"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xbc3fbc }, .{ .color = 0xbc05bc } })[type_idx];
    }

    // 'terminal.ansiCyan': index: 6, dark: '#11a8cd', light: '#0598bc',
    fn @"terminal.ansiCyan"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x11a8cd }, .{ .color = 0x0598bc } })[type_idx];
    }

    // 'terminal.ansiWhite': index: 7, dark: '#e5e5e5', light: '#555555',
    fn @"terminal.ansiWhite"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xe5e5e5 }, .{ .color = 0x555555 } })[type_idx];
    }

    // 'terminal.ansiBrightBlack': index: 8, dark: '#666666', light: '#666666',
    fn @"terminal.ansiBrightBlack"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x666666 }, .{ .color = 0x666666 } })[type_idx];
    }

    // 'terminal.ansiBrightRed': index: 9, dark: '#f14c4c', light: '#cd3131',
    fn @"terminal.ansiBrightRed"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xf14c4c }, .{ .color = 0xcd3131 } })[type_idx];
    }

    // 'terminal.ansiBrightGreen': index: 10, dark: '#23d18b', light: '#14CE14',
    fn @"terminal.ansiBrightGreen"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x23d18b }, .{ .color = 0x14CE14 } })[type_idx];
    }

    // 'terminal.ansiBrightYellow': index: 11, dark: '#f5f543', light: '#b5ba00',
    fn @"terminal.ansiBrightYellow"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xf5f543 }, .{ .color = 0xb5ba00 } })[type_idx];
    }

    // 'terminal.ansiBrightBlue': index: 12, dark: '#3b8eea', light: '#0451a5',
    fn @"terminal.ansiBrightBlue"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x3b8eea }, .{ .color = 0x0451a5 } })[type_idx];
    }

    // 'terminal.ansiBrightMagenta': index: 13, dark: '#d670d6', light: '#bc05bc',
    fn @"terminal.ansiBrightMagenta"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xd670d6 }, .{ .color = 0xbc05bc } })[type_idx];
    }

    // 'terminal.ansiBrightCyan': index: 14, dark: '#29b8db', light: '#0598bc',
    fn @"terminal.ansiBrightCyan"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0x29b8db }, .{ .color = 0x0598bc } })[type_idx];
    }

    // 'terminal.ansiBrightWhite': index: 15, dark: '#e5e5e5', light: '#a5a5a5',
    fn @"terminal.ansiBrightWhite"(type_idx: usize, _: Source) ?Color {
        return ([2]Color{ .{ .color = 0xe5e5e5 }, .{ .color = 0xa5a5a5 } })[type_idx];
    }
};
