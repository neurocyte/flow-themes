const cbor = @import("cbor");
const std = @import("std");
const eql = std.mem.eql;

const theme = @import("theme");
const theme_file = @import("theme_files.zig").theme_file;
var theme_files = @import("theme_files.zig").theme_files;

const Color = theme.Color;
const Style = theme.Style;
const Token = theme.Token;
const Tokens = theme.Tokens;
const TokenMap = std.StringHashMap(Style);

fn get_include_json(file_name: []const u8) []const u8 {
    for (&theme_files) |*tf| {
        if (eql(u8, std.fs.path.basename(file_name), std.fs.path.basename(tf.file_name)))
            return load_cbor(tf);
    }
    std.debug.print("failed to find include file: {s}\n", .{std.fs.path.basename(file_name)});
    unreachable;
}

fn load_json(theme_: *theme_file) theme {
    const file_name = theme_.file_name;
    const cb = load_cbor(theme_);

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
    const type_idx: usize = if (theme_type) |t| if (eql(u8, t, "light")) 1 else 0 else 0;
    return .{
        .name = name,
        .description = description orelse name,
        .type = theme_type orelse "dark",
        .tokens = to_token_array(load_token_colors(file_name, cb)),
        .editor = derive_style.editor(type_idx, cb),
        .editor_cursor = derive_style.editor_cursor(type_idx, cb),
        .editor_line_highlight = derive_style.editor_line_highlight(type_idx, cb),
        .editor_error = derive_style.editor_error(type_idx, cb),
        .editor_warning = derive_style.editor_warning(type_idx, cb),
        .editor_information = derive_style.editor_information(type_idx, cb),
        .editor_hint = derive_style.editor_hint(type_idx, cb),
        .editor_match = derive_style.editor_match(type_idx, cb),
        .editor_selection = derive_style.editor_selection(type_idx, cb),
        .editor_whitespace = derive_style.editor_whitespace(type_idx, cb),
        .editor_gutter = derive_style.editor_gutter(type_idx, cb),
        .editor_gutter_active = derive_style.editor_gutter_active(type_idx, cb),
        .editor_gutter_modified = derive_style.editor_gutter_modified(type_idx, cb),
        .editor_gutter_added = derive_style.editor_gutter_added(type_idx, cb),
        .editor_gutter_deleted = derive_style.editor_gutter_deleted(type_idx, cb),
        .editor_widget = derive_style.editor_widget(type_idx, cb),
        .editor_widget_border = derive_style.editor_widget_border(type_idx, cb),
        .statusbar = derive_style.statusbar(type_idx, cb),
        .statusbar_hover = derive_style.statusbar_hover(type_idx, cb),
        .scrollbar = derive_style.scrollbar(type_idx, cb),
        .scrollbar_hover = derive_style.scrollbar_hover(type_idx, cb),
        .scrollbar_active = derive_style.scrollbar_active(type_idx, cb),
        .sidebar = derive_style.sidebar(type_idx, cb),
        .panel = derive_style.panel(type_idx, cb),
        .input = derive_style.input(type_idx, cb),
        .input_border = derive_style.input_border(type_idx, cb),
        .input_placeholder = derive_style.input_placeholder(type_idx, cb),
        .input_option_active = derive_style.input_option_active(type_idx, cb),
        .input_option_hover = derive_style.input_option_hover(type_idx, cb),
    };
}

fn load_cbor(theme_: *theme_file) []const u8 {
    if (theme_.cbor) |cb| return cb;
    const buf = allocator.alloc(u8, theme_.json.len) catch unreachable;
    const cb = cbor.fromJson(theme_.json, buf) catch unreachable;
    theme_.cbor = cb;
    return cb;
}

fn load_token_colors(file_name: []const u8, cb: []const u8) TokenMap {
    var iter = cb;
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
    var tokens = if (include) |inc| load_token_colors(file_name, get_include_json(inc)) else TokenMap.init(allocator);
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
    var it = std.mem.splitScalar(u8, scopes_, ' ');
    while (it.next()) |scope_| {
        var it2 = std.mem.splitScalar(u8, scope_, ',');
        while (it2.next()) |scope|
            tokens.put(scope, style) catch unreachable;
    }
}

fn to_token_array(tokens: TokenMap) []Token {
    var iter = tokens.iterator();
    var arr = std.ArrayList(Token).init(allocator);
    while (iter.next()) |token|
        (arr.addOne() catch unreachable).* = Token{ .id = to_scope_id(token.key_ptr.*), .style = token.value_ptr.* };
    const result = arr.toOwnedSlice() catch unreachable;
    std.sort.pdq(Token, result, {}, compare_tokens);
    return result;
}

fn to_scope_id(scope: []const u8) usize {
    if (scopes.get(scope)) |id| return id;
    (scopes_vec.addOne() catch unreachable).* = scope;
    const id = scopes_vec.items.len - 1;
    scopes.put(scope, id) catch unreachable;
    return id;
}

fn compare_tokens(_: void, lhs: Token, rhs: Token) bool {
    return std.mem.lessThan(u8, scopes_vec.items[lhs.id], scopes_vec.items[rhs.id]);
}

fn find_color(name: []const u8, cb: []const u8) ?Color {
    var iter = cb;
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
    return if (match) |v| v else if (include) |inc| find_color(name, get_include_json(inc)) else null;
}

fn find_in_colors(name: []const u8, iter: *[]const u8) ?Color {
    var len = cbor.decodeMapHeader(iter) catch unreachable;
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
        std.debug.print("failed to parse color value: {s}\n", .{s});
        unreachable;
    };
}

fn parse_color_value_4bit(s: []const u8) Color {
    const color = "#" ++ s[1..2] ++ s[1..2] ++ s[2..3] ++ s[2..3] ++ s[3..4] ++ s[3..4];
    const expanded = if (s.len > 4) color ++ s[4..5] ++ s[4..5] else color;
    return parse_color_value_checked(expanded) catch {
        std.debug.print("failed to parse expanded color value: {s} {s}\n", .{ s, expanded });
        unreachable;
    };
}

const derive_style = struct {
    fn editor(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editor.foreground", cb)) |col| col else defaults.@"editor.foreground"(type_idx, cb),
            .bg = if (find_color("editor.background", cb)) |col| col else defaults.@"editor.background"(type_idx, cb),
        };
    }

    fn editor_cursor(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorCursor.background", cb)) |col|
                col
            else if (find_color("terminalCursor.background", cb)) |col|
                col
            else
                defaults.@"editorCursor.background"(type_idx, cb),
            .bg = if (find_color("editorCursor.foreground", cb)) |col|
                col
            else if (find_color("terminalCursor.foreground", cb)) |col|
                col
            else
                defaults.@"editorCursor.foreground"(type_idx, cb),
        };
    }

    fn editor_line_highlight(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editor.foreground", cb)) |col| col else defaults.@"editor.foreground"(type_idx, cb),
            .bg = if (find_color("editor.lineHighlightBackground", cb)) |col| col else defaults.@"editor.lineHighlightBackground"(type_idx, cb),
        };
    }

    fn editor_error(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorError.foreground", cb)) |col| col else defaults.@"editorError.foreground"(type_idx, cb),
            .bg = if (find_color("editorError.background", cb)) |col| col else defaults.@"editorError.background"(type_idx, cb),
        };
    }

    fn editor_warning(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorWarning.foreground", cb)) |col| col else defaults.@"editorWarning.foreground"(type_idx, cb),
            .bg = if (find_color("editorWarning.background", cb)) |col| col else defaults.@"editorWarning.background"(type_idx, cb),
        };
    }

    fn editor_information(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorInfo.foreground", cb)) |col| col else defaults.@"editorInfo.foreground"(type_idx, cb),
            .bg = if (find_color("editorInfo.background", cb)) |col| col else defaults.@"editorInfo.background"(type_idx, cb),
        };
    }

    fn editor_hint(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorHint.foreground", cb)) |col| col else defaults.@"editorHint.foreground"(type_idx, cb),
            .bg = if (find_color("editorHint.background", cb)) |col| col else defaults.@"editorHint.background"(type_idx, cb),
        };
    }

    fn editor_match(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editor.foreground", cb)) |col| col else defaults.@"editor.foreground"(type_idx, cb),
            .bg = if (find_color("editor.findMatchBackground", cb)) |col| col else defaults.@"editor.findMatchBackground"(type_idx, cb),
        };
    }

    fn editor_selection(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editor.selectionForeground", cb)) |col| col else defaults.@"editor.selectionForeground"(type_idx, cb),
            .bg = if (find_color("editor.selectionBackground", cb)) |col| col else defaults.@"editor.selectionBackground"(type_idx, cb),
        };
    }

    fn editor_whitespace(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorWhitespace.foreground", cb)) |col| col else defaults.@"editorWhitespace.foreground"(type_idx, cb),
            .bg = if (find_color("editor.background", cb)) |col| col else defaults.@"editor.background"(type_idx, cb),
        };
    }

    fn editor_gutter(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorLineNumber.foreground", cb)) |col| col else defaults.@"editorLineNumber.foreground"(type_idx, cb),
            .bg = if (find_color("editorGutter.background", cb)) |col| col else defaults.@"editorGutter.background"(type_idx, cb),
        };
    }

    fn editor_gutter_active(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorLineNumber.activeForeground", cb)) |col| col else defaults.@"editorLineNumber.activeForeground"(type_idx, cb),
            .bg = if (find_color("editorGutter.background", cb)) |col| col else defaults.@"editorGutter.background"(type_idx, cb),
        };
    }

    fn editor_gutter_modified(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorGutter.modifiedBackground", cb)) |col| col else defaults.@"editorGutter.modifiedBackground"(type_idx, cb),
            .bg = if (find_color("editorGutter.background", cb)) |col| col else defaults.@"editorGutter.background"(type_idx, cb),
        };
    }

    fn editor_gutter_added(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorGutter.addedBackground", cb)) |col| col else defaults.@"editorGutter.addedBackground"(type_idx, cb),
            .bg = if (find_color("editorGutter.background", cb)) |col| col else defaults.@"editorGutter.background"(type_idx, cb),
        };
    }

    fn editor_gutter_deleted(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorGutter.deletedBackground", cb)) |col| col else defaults.@"editorGutter.deletedBackground"(type_idx, cb),
            .bg = if (find_color("editorGutter.background", cb)) |col| col else defaults.@"editorGutter.background"(type_idx, cb),
        };
    }

    fn editor_widget(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorWidget.foreground", cb)) |col| col else defaults.@"editorWidget.foreground"(type_idx, cb),
            .bg = if (find_color("editorWidget.background", cb)) |col| col else defaults.@"editorWidget.background"(type_idx, cb),
        };
    }

    fn editor_widget_border(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("editorWidget.foreground", cb)) |col| col else defaults.@"editorWidget.foreground"(type_idx, cb),
            .bg = if (find_color("editorWidget.border", cb)) |col| col else defaults.@"editorWidget.border"(type_idx, cb),
        };
    }

    fn statusbar(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("statusBar.foreground", cb)) |col| col else defaults.@"statusBar.foreground"(type_idx, cb),
            .bg = if (find_color("statusBar.background", cb)) |col| col else defaults.@"statusBar.background"(type_idx, cb),
        };
    }

    fn statusbar_hover(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("statusBarItem.hoverForeground", cb)) |col| col else defaults.@"statusBarItem.hoverForeground"(type_idx, cb),
            .bg = if (find_color("statusBarItem.hoverBackground", cb)) |col| col else defaults.@"statusBarItem.hoverBackground"(type_idx, cb),
        };
    }

    fn scrollbar(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.background", cb)) |col| col else defaults.@"scrollbarSlider.background"(type_idx, cb),
            .bg = editor(type_idx, cb).bg,
        };
    }

    fn scrollbar_hover(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.hoverBackground", cb)) |col| col else defaults.@"scrollbarSlider.hoverBackground"(type_idx, cb),
            .bg = editor(type_idx, cb).bg,
        };
    }

    fn scrollbar_active(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("scrollbarSlider.activeBackground", cb)) |col| col else defaults.@"scrollbarSlider.activeBackground"(type_idx, cb),
            .bg = editor(type_idx, cb).bg,
        };
    }

    fn sidebar(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("sideBar.foreground", cb)) |col| col else defaults.@"sideBar.foreground"(type_idx, cb),
            .bg = if (find_color("sideBar.background", cb)) |col| col else defaults.@"sideBar.background"(type_idx, cb),
        };
    }

    fn panel(type_idx: usize, cb: []const u8) Style {
        const editor_style = editor(type_idx, cb);
        return .{
            .fg = editor_style.fg,
            .bg = if (find_color("panel.background", cb)) |col| col else editor_style.bg,
        };
    }

    fn input(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("input.foreground", cb)) |col| col else defaults.@"input.foreground"(type_idx, cb),
            .bg = if (find_color("input.background", cb)) |col| col else defaults.@"input.background"(type_idx, cb),
        };
    }

    fn input_border(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("input.border", cb)) |col| col else defaults.@"input.border"(type_idx, cb),
            .bg = if (find_color("input.background", cb)) |col| col else defaults.@"input.background"(type_idx, cb),
        };
    }

    fn input_placeholder(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("input.placeholderForeground", cb)) |col| col else defaults.@"input.placeholderForeground"(type_idx, cb),
            .bg = if (find_color("input.background", cb)) |col| col else defaults.@"input.background"(type_idx, cb),
        };
    }

    fn input_option(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("input.foreground", cb)) |col| col else defaults.@"input.foreground"(type_idx, cb),
            .bg = if (find_color("input.background", cb)) |col| col else defaults.@"input.background"(type_idx, cb),
        };
    }

    fn input_option_active(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("inputOption.activeForeground", cb)) |col| col else defaults.@"inputOption.activeForeground"(type_idx, cb),
            .bg = if (find_color("inputOption.activeBackground", cb)) |col| col else defaults.@"inputOption.activeBackground"(type_idx, cb),
        };
    }

    fn input_option_hover(type_idx: usize, cb: []const u8) Style {
        return .{
            .fg = if (find_color("input.foreground", cb)) |col| col else defaults.@"input.foreground"(type_idx, cb),
            .bg = if (find_color("inputOption.hoverBackground", cb)) |col| col else defaults.@"inputOption.hoverBackground"(type_idx, cb),
        };
    }
};

const defaults = struct {
    cb: []const u8,

    // registerColor('foreground', { dark: '#CCCCCC', light: '#616161', hcDark: '#FFFFFF', hcLight: '#292929' }, nls.localize('foreground', "Overall foreground color. This color is only used if not overridden by a component."));
    fn foreground(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xCCCCCC }, .{ .color = 0x616161 } })[type_idx];
    }

    // registerColor('editor.foreground', { light: '#333333', dark: '#BBBBBB', hcDark: Color.white, hcLight: foreground }, nls.localize('editorForeground', "Editor default foreground color."));
    fn @"editor.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xBBBBBB }, .{ .color = 0x333333 } })[type_idx];
    }

    // registerColor('editor.background', { light: '#ffffff', dark: '#1E1E1E', hcDark: Color.black, hcLight: Color.white }, nls.localize('editorBackground', "Editor background color."));
    fn @"editor.background"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x1E1E1E }, .{ .color = 0xffffff } })[type_idx];
    }

    // registerColor('editorCursor.foreground', { dark: '#AEAFAD', light: Color.black, hcDark: Color.white, hcLight: '#0F4A85' }, nls.localize('caret', 'Color of the editor cursor.'));
    fn @"editorCursor.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xAEAFAD }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('editorCursor.background', null, nls.localize('editorCursorBackground', 'The background color of the editor cursor. Allows customizing the color of a character overlapped by a block cursor.'));
    fn @"editorCursor.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editor.lineHighlightBackground', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('lineHighlight', 'Background color for the highlight of line at the cursor position.'));
    fn @"editor.lineHighlightBackground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editorError.foreground', { dark: '#F14C4C', light: '#E51400', hcDark: '#F48771', hcLight: '#B5200D' }, nls.localize('editorError.foreground', 'Foreground color of error squigglies in the editor.'));
    fn @"editorError.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xF14C4C }, .{ .color = 0xE51400 } })[type_idx];
    }

    // registerColor('editorError.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorError.background', 'Background color of error text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorError.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editorWarning.foreground', { dark: '#CCA700', light: '#BF8803', hcDark: '#FFD370', hcLight: '#895503' }, nls.localize('editorWarning.foreground', 'Foreground color of warning squigglies in the editor.'));
    fn @"editorWarning.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xCCA700 }, .{ .color = 0xBF8803 } })[type_idx];
    }

    // registerColor('editorWarning.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorWarning.background', 'Background color of warning text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorWarning.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editorInfo.foreground', { dark: '#3794FF', light: '#1a85ff', hcDark: '#3794FF', hcLight: '#1a85ff' }, nls.localize('editorInfo.foreground', 'Foreground color of info squigglies in the editor.'));
    fn @"editorInfo.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x3794FF }, .{ .color = 0x1a85ff } })[type_idx];
    }

    // registerColor('editorInfo.background', { dark: null, light: null, hcDark: null, hcLight: null }, nls.localize('editorInfo.background', 'Background color of info text in the editor. The color must not be opaque so as not to hide underlying decorations.'), true);
    fn @"editorInfo.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editorHint.foreground', { dark: Color.fromHex('#eeeeee').transparent(0.7), light: '#6c6c6c', hcDark: null, hcLight: null }, nls.localize('editorHint.foreground', 'Foreground color of hint squigglies in the editor.'));
    fn @"editorHint.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xeeeeee, .alpha = 0xb3 }, .{ .color = 0x6c6c6c } })[type_idx];
    }

    // none
    fn @"editorHint.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editor.findMatchBackground', { light: '#A8AC94', dark: '#515C6A', hcDark: null, hcLight: null }, nls.localize('editorFindMatch', "Color of the current search match."));
    fn @"editor.findMatchBackground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x515C6A }, .{ .color = 0xA8AC94 } })[type_idx];
    }

    // registerColor('editor.findMatchHighlightBackground', { light: '#EA5C0055', dark: '#EA5C0055', hcDark: null, hcLight: null }, nls.localize('findMatchHighlight', "Color of the other search matches. The color must not be opaque so as not to hide underlying decorations."), true);
    fn @"editor.findMatchHighlightBackground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xEA5C00 }, .{ .color = 0xEA5C00 } })[type_idx];
    }

    // registerColor('editor.selectionForeground', { light: null, dark: null, hcDark: '#000000', hcLight: Color.white }, nls.localize('editorSelectionForeground', "Color of the selected text for high contrast."));
    fn @"editor.selectionForeground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).fg;
    }

    // registerColor('editor.selectionBackground', { light: '#ADD6FF', dark: '#264F78', hcDark: '#f3f518', hcLight: '#0F4A85' }, nls.localize('editorSelectionBackground', "Color of the editor selection."));
    fn @"editor.selectionBackground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x264F78 }, .{ .color = 0xADD6FF } })[type_idx];
    }

    // registerColor('sideBar.foreground', { dark: null, light: null, hcDark: null, hcLight: null }, localize('sideBarForeground', "Side bar foreground color. The side bar is the container for views like explorer and search."));
    fn @"sideBar.foreground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).fg;
    }

    // registerColor('sideBar.background', { dark: '#252526', light: '#F3F3F3', hcDark: '#000000', hcLight: '#FFFFFF' }, localize('sideBarBackground', "Side bar background color. The side bar is the container for views like explorer and search."));
    fn @"sideBar.background"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x252526 }, .{ .color = 0xF3F3F3 } })[type_idx];
    }

    // registerColor('scrollbar.shadow', { dark: '#000000', light: '#DDDDDD', hcDark: null, hcLight: null }, nls.localize('scrollbarShadow', "Scrollbar shadow to indicate that the view is scrolled."));
    fn @"scrollbar.shadow"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x000000 }, .{ .color = 0xDDDDDD } })[type_idx];
    }

    // registerColor('scrollbarSlider.background', { dark: Color.fromHex('#797979').transparent(0.4), light: Color.fromHex('#646464').transparent(0.4), hcDark: transparent(contrastBorder, 0.6), hcLight: transparent(contrastBorder, 0.4) }, nls.localize('scrollbarSliderBackground', "Scrollbar slider background color."));
    fn @"scrollbarSlider.background"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x797979 }, .{ .color = 0x646464 } })[type_idx];
    }

    // registerColor('scrollbarSlider.hoverBackground', { dark: Color.fromHex('#646464').transparent(0.7), light: Color.fromHex('#646464').transparent(0.7), hcDark: transparent(contrastBorder, 0.8), hcLight: transparent(contrastBorder, 0.8) }, nls.localize('scrollbarSliderHoverBackground', "Scrollbar slider background color when hovering."));
    fn @"scrollbarSlider.hoverBackground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x646464 }, .{ .color = 0x646464 } })[type_idx];
    }

    // registerColor('scrollbarSlider.activeBackground', { dark: Color.fromHex('#BFBFBF').transparent(0.4), light: Color.fromHex('#000000').transparent(0.6), hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('scrollbarSliderActiveBackground', "Scrollbar slider background color when clicked on."));
    fn @"scrollbarSlider.activeBackground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xBFBFBF }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('statusBar.foreground', { dark: '#FFFFFF', light: '#FFFFFF', hcDark: '#FFFFFF', hcLight: editorForeground }, localize('statusBarForeground', "Status bar foreground color when a workspace or folder is opened. The status bar is shown in the bottom of the window."));
    fn @"statusBar.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xFFFFFF }, .{ .color = 0xFFFFFF } })[type_idx];
    }

    // registerColor('statusBar.background', { dark: '#007ACC', light: '#007ACC', hcDark: null, hcLight: null, }, localize('statusBarBackground', "Status bar background color when a workspace or folder is opened. The status bar is shown in the bottom of the window."));
    fn @"statusBar.background"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x007ACC }, .{ .color = 0x007ACC } })[type_idx];
    }

    // registerColor('statusBarItem.hoverForeground', { dark: STATUS_BAR_FOREGROUND, light: STATUS_BAR_FOREGROUND, hcDark: STATUS_BAR_FOREGROUND, hcLight: STATUS_BAR_FOREGROUND }, localize('statusBarItemHoverForeground', "Status bar item foreground color when hovering. The status bar is shown in the bottom of the window."));
    fn @"statusBarItem.hoverForeground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.statusbar(type_idx, cb).fg;
    }

    // registerColor('statusBarItem.hoverBackground', { dark: Color.white.transparent(0.12), light: Color.white.transparent(0.12), hcDark: Color.white.transparent(0.12), hcLight: Color.black.transparent(0.12) }, localize('statusBarItemHoverBackground', "Status bar item background color when hovering. The status bar is shown in the bottom of the window."));
    fn @"statusBarItem.hoverBackground"(type_idx: usize, cb: []const u8) ?Color {
        return .{ .color = derive_style.statusbar(type_idx, cb).bg.?.color, .alpha = 256 * 12 / 100 };
    }

    // registerColor('editorWhitespace.foreground', { dark: '#e3e4e229', light: '#33333333', hcDark: '#e3e4e229', hcLight: '#CCCCCC' }, nls.localize('editorWhitespaces', 'Color of whitespace characters in the editor.'));
    fn @"editorWhitespace.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xe3e4e2, .alpha = 0x29 }, .{ .color = 0x333333, .alpha = 0x33 } })[type_idx];
    }

    // registerColor('editorLineNumber.foreground', { dark: '#858585', light: '#237893', hcDark: Color.white, hcLight: '#292929' }, nls.localize('editorLineNumbers', 'Color of editor line numbers.'));
    fn @"editorLineNumber.foreground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0x858585 }, .{ .color = 0x237893 } })[type_idx];
    }

    // registerColor('editorLineNumber.activeForeground', { dark: deprecatedEditorActiveLineNumber, light: deprecatedEditorActiveLineNumber, hcDark: deprecatedEditorActiveLineNumber, hcLight: deprecatedEditorActiveLineNumber }, nls.localize('editorActiveLineNumber', 'Color of editor active line number'));
    // registerColor('editorActiveLineNumber.foreground', { dark: '#c6c6c6', light: '#0B216F', hcDark: activeContrastBorder, hcLight: activeContrastBorder }, nls.localize('editorActiveLineNumber', 'Color of editor active line number'), false, nls.localize('deprecatedEditorActiveLineNumber', 'Id is deprecated. Use \'editorLineNumber.activeForeground\' instead.'));
    fn @"editorLineNumber.activeForeground"(type_idx: usize, _: []const u8) Color {
        return ([2]Color{ .{ .color = 0xc6c6c6 }, .{ .color = 0x0B216F } })[type_idx];
    }

    // registerColor('editorGutter.background', { dark: editorBackground, light: editorBackground, hcDark: editorBackground, hcLight: editorBackground }, nls.localize('editorGutter', 'Background color of the editor gutter. The gutter contains the glyph margins and the line numbers.'));
    fn @"editorGutter.background"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).bg;
    }

    // registerColor('editorGutter.modifiedBackground', { dark: '#1B81A8', light: '#2090D3', hcDark: '#1B81A8',	hcLight: '#2090D3'}, nls.localize('editorGutterModifiedBackground', "Editor gutter background color for lines that are modified."));
    fn @"editorGutter.modifiedBackground"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x1B81A8 }, .{ .color = 0x2090D3 } })[type_idx];
    }

    // registerColor('editorGutter.addedBackground', { dark: '#487E02', light: '#48985D', hcDark: '#487E02', hcLight: '#48985D' }, nls.localize('editorGutterAddedBackground', "Editor gutter background color for lines that are added."));
    fn @"editorGutter.addedBackground"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x487E02 }, .{ .color = 0x48985D } })[type_idx];
    }

    // registerColor('editorGutter.deletedBackground', { dark: editorErrorForeground, light: editorErrorForeground, hcDark: editorErrorForeground, hcLight: editorErrorForeground }, nls.localize('editorGutterDeletedBackground', "Editor gutter background color for lines that are deleted."));
    fn @"editorGutter.deletedBackground"(type_idx: usize, cb: []const u8) ?Color {
        return @"editorError.foreground"(type_idx, cb);
    }

    // registerColor('editorWidget.foreground', { dark: foreground, light: foreground, hcDark: foreground, hcLight: foreground }, nls.localize('editorWidgetForeground', 'Foreground color of editor widgets, such as find/replace.'));
    fn @"editorWidget.foreground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).fg;
    }

    // registerColor('editorWidget.background', { dark: '#252526', light: '#F3F3F3', hcDark: '#0C141F', hcLight: Color.white }, nls.localize('editorWidgetBackground', 'Background color of editor widgets, such as find/replace.'));
    fn @"editorWidget.background"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x252526 }, .{ .color = 0xF3F3F3 } })[type_idx];
    }

    // registerColor('editorWidget.border', { dark: '#454545', light: '#C8C8C8', hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('editorWidgetBorder', 'Border color of editor widgets. The color is only used if the widget chooses to have a border and if the color is not overridden by a widget.'));
    fn @"editorWidget.border"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x454545 }, .{ .color = 0xC8C8C8 } })[type_idx];
    }

    // registerColor('input.foreground', { dark: foreground, light: foreground, hcDark: foreground, hcLight: foreground }, nls.localize('inputBoxForeground', "Input box foreground."));
    fn @"input.foreground"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).fg;
    }

    // registerColor('input.background', { dark: '#3C3C3C', light: Color.white, hcDark: Color.black, hcLight: Color.white }, nls.localize('inputBoxBackground', "Input box background."));
    fn @"input.background"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x3C3C3C }, .{ .color = 0xFFFFFF } })[type_idx];
    }

    // registerColor('input.border', { dark: null, light: null, hcDark: contrastBorder, hcLight: contrastBorder }, nls.localize('inputBoxBorder', "Input box border."));
    fn @"input.border"(type_idx: usize, cb: []const u8) ?Color {
        return derive_style.editor(type_idx, cb).fg;
    }

    // registerColor('input.placeholderForeground', { light: transparent(foreground, 0.5), dark: transparent(foreground, 0.5), hcDark: transparent(foreground, 0.7), hcLight: transparent(foreground, 0.7) }, nls.localize('inputPlaceholderForeground', "Input box foreground color for placeholder text."));
    fn @"input.placeholderForeground"(type_idx: usize, cb: []const u8) ?Color {
        return .{ .color = derive_style.editor(type_idx, cb).fg.?.color, .alpha = 256 / 2 };
    }

    // registerColor('inputOption.activeForeground', { dark: Color.white, light: Color.black, hcDark: foreground, hcLight: foreground }, nls.localize('inputOption.activeForeground', "Foreground color of activated options in input fields."));
    fn @"inputOption.activeForeground"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0xFFFFFF }, .{ .color = 0x000000 } })[type_idx];
    }

    // registerColor('focusBorder', { dark: '#007FD4', light: '#0090F1', hcDark: '#F38518', hcLight: '#006BBD' }, nls.localize('focusBorder', "Overall border color for focused elements. This color is only used if not overridden by a component."));
    fn focusBorder(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x007FD4 }, .{ .color = 0x0090F1 } })[type_idx];
    }

    // registerColor('inputOption.activeBackground', { dark: transparent(focusBorder, 0.4), light: transparent(focusBorder, 0.2), hcDark: Color.transparent, hcLight: Color.transparent }, nls.localize('inputOption.activeBackground', "Background hover color of options in input fields."));
    fn @"inputOption.activeBackground"(type_idx: usize, cb: []const u8) ?Color {
        return ([2]Color{ .{ .color = focusBorder(0, cb).?.color, .alpha = 256 * 40 / 100 }, .{ .color = focusBorder(1, cb).?.color, .alpha = 256 * 20 / 100 } })[type_idx];
    }

    // registerColor('inputOption.hoverBackground', { dark: '#5a5d5e80', light: '#b8b8b850', hcDark: null, hcLight: null }, nls.localize('inputOption.hoverBackground', "Background color of activated options in input fields."));
    fn @"inputOption.hoverBackground"(type_idx: usize, _: []const u8) ?Color {
        return ([2]Color{ .{ .color = 0x5a5d5e, .alpha = 0x80 }, .{ .color = 0xb8b8b8, .alpha = 0x50 } })[type_idx];
    }
};

const Writer = std.fs.File.Writer;

fn write_field_string(writer: Writer, name: []const u8, value: []const u8) !void {
    _ = try writer.print("        .@\"{s}\" = \"{s}\",\n", .{ name, value });
}

fn write_Style(writer: Writer, value: Style) !void {
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

fn write_field_Style(writer: Writer, name: []const u8, value: Style) !void {
    _ = try writer.print("        .@\"{s}\" = ", .{name});
    try write_Style(writer, value);
    _ = try writer.print(",\n", .{});
}

fn write_field_token_array(writer: Writer, name: []const u8, values: Tokens) !void {
    _ = try writer.print("        .@\"{s}\" = &[_]theme.Token{{ \n", .{name});
    for (values) |value| {
        _ = try writer.print("            .{{ .id = {d}, .style = ", .{value.id});
        try write_Style(writer, value.style);
        _ = try writer.print("}},\n", .{});
    }
    _ = try writer.print("        }},\n", .{});
}

fn write_field(writer: Writer, name: []const u8, value: anytype) !void {
    return if (@TypeOf(value) == Style)
        write_field_Style(writer, name, value)
    else if (@TypeOf(value) == Tokens)
        write_field_token_array(writer, name, value)
    else
        write_field_string(writer, name, value);
}

fn write_theme(writer: Writer, item: theme) !void {
    _ = try writer.write("    .{\n");

    inline for (@typeInfo(theme).Struct.fields) |field_info|
        try write_field(writer, field_info.name, @field(item, field_info.name));

    _ = try writer.write("    },\n");
}

fn write_all_themes(writer: Writer) !void {
    _ = try writer.write("const theme = @import(\"theme\");\n");
    _ = try writer.write("pub const themes = [_]theme{\n");
    for (&theme_files) |*file| {
        try write_file("themes", std.fs.path.basename(file.file_name), file.json);
        std.debug.print("theme: {s}\n", .{std.fs.path.basename(file.file_name)});
        file.json = try hjson(file.json);
        // try write_file("cleaned", std.fs.path.basename(file.file_name), file.json);
        const theme_ = load_json(file);
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    allocator = arena;
    scopes = ScopeMap.init(allocator);
    scopes_vec = std.ArrayList([]const u8).init(allocator);

    const args = try std.process.argsAlloc(arena);

    if (args.len != 2) fatal("wrong number of arguments", .{});

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();
    try write_all_themes(output_file.writer());
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn hjson(data: []const u8) ![]const u8 {
    const cmd = [_][]const u8{ "hjson", "-j" }; // Replace with your shell command
    var child = std.process.Child.init(&cmd, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    try child.stdin.?.writeAll(data);
    child.stdin.?.close();
    child.stdin = null;
    var out = std.ArrayList(u8).init(allocator);
    var writer = out.writer();
    var buffer: [256]u8 = undefined;
    while (true) {
        const bytesRead = try child.stdout.?.read(&buffer);
        if (bytesRead == 0) break;
        try writer.writeAll(buffer[0..bytesRead]);
    }
    const term = child.wait() catch |e| std.debug.panic("error running hjson: {any}", .{e});
    switch (term) {
        std.process.Child.Term.Exited => |code| if (code == 0) return out.toOwnedSlice(),
        else => {},
    }
    std.debug.panic("Exited with code {any}", .{term});
}

fn write_file(dir: []const u8, file_name: []const u8, data: []const u8) !void {
    const cwd = std.fs.cwd();
    cwd.makeDir(dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var file = try (try cwd.openDir(dir, .{})).createFile(file_name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}
