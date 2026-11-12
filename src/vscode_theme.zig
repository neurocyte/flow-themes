const std = @import("std");
const cbor = @import("cbor");
const theme = @import("theme");
const eql = std.mem.eql;

const Color = theme.Color;
const Style = theme.Style;
const Token = theme.Token;
const TokenMap = std.StringHashMap(Rule);

const Rule = struct {
    style: Style,
    selector: enum { plain, descendant },
};

pub const Error = error{ OutOfMemory, InvalidTheme, IncludeNotFound };

pub const Options = struct {
    /// fail on unknown token settings and invalid colors instead of skipping them
    strict: bool = false,
    /// receives the error message instead of std.log
    diagnostic: ?*Diagnostic = null,
};

pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn fail(diagnostic: ?*Diagnostic, file_name: []const u8, comptime format: []const u8, args: anytype) error{InvalidTheme} {
        if (diagnostic) |self| {
            const written = std.fmt.bufPrint(&self.buf, "{s}: " ++ format, .{file_name} ++ args) catch self.buf[0..];
            self.len = written.len;
        } else std.log.err("{s}: " ++ format, .{file_name} ++ args);
        return error.InvalidTheme;
    }
};

pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// cbor of the theme file named by an "include" field; must stay valid until load returns
        include: *const fn (ptr: *anyopaque, file_name: []const u8) Error![]const u8,
        scope_id: *const fn (ptr: *anyopaque, scope: []const u8) error{OutOfMemory}!usize,
    };
};

const max_include_depth = 8;

const Source = struct {
    allocator: std.mem.Allocator,
    options: Options,
    file_name: []const u8,
    cb: []const u8,
    include: ?*const Source = null,

    fn invalid(self: Source, comptime format: []const u8, args: anytype) error{InvalidTheme} {
        return Diagnostic.fail(self.options.diagnostic, self.file_name, format, args);
    }
};

/// Convert JSONC theme text to cbor. The caller owns the returned slice.
pub fn to_cbor(allocator: std.mem.Allocator, file_name: []const u8, jsonc: []const u8, diagnostic: ?*Diagnostic) error{ OutOfMemory, InvalidTheme }![]const u8 {
    const json = strip_jsonc(allocator, jsonc) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedComment => return Diagnostic.fail(diagnostic, file_name, "unterminated comment", .{}),
    };
    defer allocator.free(json);
    return cbor.fromJsonAlloc(allocator, json) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Diagnostic.fail(diagnostic, file_name, "invalid JSON: {t}", .{e}),
    };
}

/// Remove comments and trailing commas. The caller owns the returned slice.
pub fn strip_jsonc(allocator: std.mem.Allocator, input: []const u8) error{ OutOfMemory, UnterminatedComment }![]u8 {
    const out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);

    var len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '"') {
            const end = string_end(input, i);
            @memcpy(out[len..][0 .. end - i], input[i..end]);
            len += end - i;
            i = end;
        } else if (std.mem.startsWith(u8, input[i..], "//")) {
            i = std.mem.findScalarPos(u8, input, i, '\n') orelse input.len;
        } else if (std.mem.startsWith(u8, input[i..], "/*")) {
            const end = std.mem.findPos(u8, input, i + 2, "*/") orelse return error.UnterminatedComment;
            out[len] = ' ';
            len += 1;
            i = end + 2;
        } else {
            out[len] = input[i];
            len += 1;
            i += 1;
        }
    }

    var result: usize = 0;
    i = 0;
    while (i < len) {
        if (out[i] == '"') {
            const end = string_end(out[0..len], i);
            std.mem.copyForwards(u8, out[result..], out[i..end]);
            result += end - i;
            i = end;
            continue;
        }
        if (out[i] == ',') {
            const next = std.mem.findNonePos(u8, out[0..len], i + 1, " \t\r\n") orelse len;
            if (next < len and (out[next] == '}' or out[next] == ']')) {
                i += 1;
                continue;
            }
        }
        out[result] = out[i];
        result += 1;
        i += 1;
    }
    return allocator.realloc(out, result);
}

fn string_end(input: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < input.len) : (i += 1) switch (input[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        else => {},
    };
    return input.len;
}

/// The returned theme references file_name and cb. The caller owns theme.tokens.
pub fn load(allocator: std.mem.Allocator, context: Context, file_name: []const u8, cb: []const u8, options: Options) Error!theme {
    var chain: [max_include_depth]Source = undefined;
    chain[0] = .{ .allocator = allocator, .options = options, .file_name = std.fs.path.basename(file_name), .cb = cb };
    const meta = try load_meta(chain[0]);
    var include = meta.include;
    var depth: usize = 1;
    while (include) |include_name| : (depth += 1) {
        if (depth == max_include_depth) return chain[0].invalid("too many nested includes", .{});
        chain[depth] = .{
            .allocator = allocator,
            .options = options,
            .file_name = std.fs.path.basename(include_name),
            .cb = context.vtable.include(context.ptr, include_name) catch |e| switch (e) {
                error.IncludeNotFound => return chain[depth - 1].invalid("include '{s}' not found", .{include_name}),
                else => return e,
            },
        };
        chain[depth - 1].include = &chain[depth];
        include = (try load_meta(chain[depth])).include;
    }
    const src = chain[0];
    for (chain[0..depth]) |s| try check_colors(s);

    const basename = src.file_name;
    const suffix = std.mem.findLast(u8, basename, "-color-theme");
    const ext = std.mem.findLast(u8, basename, ".json");
    const name: []const u8 = if (suffix) |pos| basename[0..pos] else if (ext) |pos| basename[0..pos] else basename;

    const declared = parse_type_string(meta.type);
    const computed = compute_theme_type(src);
    const final_type: theme.Type = computed orelse declared orelse .dark;

    if (computed) |c| {
        if (declared) |d| {
            if (d != c) std.log.warn(
                "warning: theme '{s}' declares type '{t}' but editor luma indicates '{t}'; using '{t}'",
                .{ name, d, c, c },
            );
        } else if (meta.type) |raw| {
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
    } else if (declared == null and meta.type != null) {
        std.log.warn(
            "warning: theme '{s}' has unrecognized type '{s}' and no explicit editor colors to derive from; defaulting to 'dark'",
            .{ name, meta.type.? },
        );
    }

    const type_idx: usize = if (final_type == .light) @as(usize, 1) else 0;
    var result: theme = undefined;
    result.name = name;
    result.description = meta.name orelse name;
    result.type = final_type;
    result.tokens = try load_tokens(src, context);
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

const Meta = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    include: ?[]const u8 = null,
};

fn load_meta(src: Source) error{InvalidTheme}!Meta {
    var meta: Meta = .{};
    var iter = src.cb;
    var len = cbor.decodeMapHeader(&iter) catch return src.invalid("theme is not a JSON object", .{});
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return src.invalid("invalid field name", .{});
        const field: *?[]const u8 = if (eql(u8, "name", field_name))
            &meta.name
        else if (eql(u8, "type", field_name))
            &meta.type
        else if (eql(u8, "include", field_name))
            &meta.include
        else {
            cbor.skipValue(&iter) catch return src.invalid("invalid value for '{s}'", .{field_name});
            continue;
        };
        var value: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &value) catch false)) return src.invalid("'{s}' is not a string", .{field_name});
        field.* = value;
    }
    return meta;
}

fn check_colors(src: Source) error{InvalidTheme}!void {
    var iter = colors_map(src) orelse return;
    var len = cbor.decodeMapHeader(&iter) catch return src.invalid("'colors' is not an object", .{});
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return src.invalid("invalid 'colors' entry", .{});
        var value: []const u8 = undefined;
        if (cbor.matchString(&iter, &value) catch false) {
            if (value.len == 0 or parse_color(value) != null) continue;
            if (src.options.strict) return src.invalid("invalid color '{s}' for 'colors.{s}'", .{ value, field_name });
            std.log.warn("{s}: ignoring invalid color '{s}' for 'colors.{s}'", .{ src.file_name, value, field_name });
        } else {
            if (src.options.strict) return src.invalid("'colors.{s}' is not a string", .{field_name});
            std.log.warn("{s}: ignoring non-string 'colors.{s}'", .{ src.file_name, field_name });
            cbor.skipValue(&iter) catch return src.invalid("invalid value for 'colors.{s}'", .{field_name});
        }
    }
}

fn colors_map(src: Source) ?[]const u8 {
    var iter = src.cb;
    var len = cbor.decodeMapHeader(&iter) catch return null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch return null)) return null;
        if (eql(u8, "colors", field_name)) return iter;
        cbor.skipValue(&iter) catch return null;
    }
    return null;
}

fn find_color(name: []const u8, src: Source) ?Color {
    if (colors_map(src)) |colors| if (find_in_colors(name, colors)) |color| return color;
    return if (src.include) |include| find_color(name, include.*) else null;
}

/// the last valid entry wins, as in JavaScript
fn find_in_colors(name: []const u8, colors: []const u8) ?Color {
    var iter = colors;
    var len = cbor.decodeMapHeader(&iter) catch return null;
    var match: ?Color = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch return match)) return match;
        var value: []const u8 = undefined;
        if (cbor.matchString(&iter, &value) catch return match) {
            if (eql(u8, field_name, name)) match = parse_color(value) orelse match;
        } else cbor.skipValue(&iter) catch return match;
    }
    return match;
}

fn load_tokens(src: Source, context: Context) Error![]Token {
    var tokens: TokenMap = .init(src.allocator);
    defer tokens.deinit();
    try load_token_colors(src, &tokens);

    const Entry = struct { scope: []const u8, token: Token };
    const entries = try src.allocator.alloc(Entry, tokens.count());
    defer src.allocator.free(entries);
    var iter = tokens.iterator();
    var i: usize = 0;
    while (iter.next()) |token| : (i += 1) entries[i] = .{
        .scope = token.key_ptr.*,
        .token = .{ .id = try context.vtable.scope_id(context.ptr, token.key_ptr.*), .style = token.value_ptr.style },
    };
    std.sort.pdq(Entry, entries, {}, struct {
        fn less_than(_: void, lhs: Entry, rhs: Entry) bool {
            return std.mem.lessThan(u8, lhs.scope, rhs.scope);
        }
    }.less_than);

    const result = try src.allocator.alloc(Token, entries.len);
    for (entries, result) |entry, *token| token.* = entry.token;
    return result;
}

/// included token colors come first, so the including theme overrides them
fn load_token_colors(src: Source, tokens: *TokenMap) Error!void {
    if (src.include) |include| try load_token_colors(include.*, tokens);
    var iter = src.cb;
    var len = cbor.decodeMapHeader(&iter) catch return src.invalid("theme is not a JSON object", .{});
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return src.invalid("invalid field name", .{});
        if (!eql(u8, "tokenColors", field_name)) {
            cbor.skipValue(&iter) catch return src.invalid("invalid value for '{s}'", .{field_name});
            continue;
        }
        var count = cbor.decodeArrayHeader(&iter) catch
            return src.invalid("'tokenColors' is not an array (tokenColors files are not supported)", .{});
        while (count > 0) : (count -= 1) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch false)) return src.invalid("invalid 'tokenColors' entry", .{});
            try load_token_object(src, tokens, value);
        }
    }
}

fn load_token_object(src: Source, tokens: *TokenMap, cb: []const u8) Error!void {
    var iter = cb;
    var len = cbor.decodeMapHeader(&iter) catch return src.invalid("'tokenColors' entry is not an object", .{});
    var scopes_cb: ?[]const u8 = null;
    var scopes_name: ?[]const u8 = null;
    var settings_cb: ?[]const u8 = null;
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return src.invalid("invalid 'tokenColors' field name", .{});
        if (eql(u8, "scope", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch false)) return src.invalid("invalid 'scope'", .{});
            scopes_cb = value;
        } else if (eql(u8, "settings", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchValue(&iter, cbor.extract_cbor(&value)) catch false)) return src.invalid("invalid 'settings'", .{});
            settings_cb = value;
        } else if (eql(u8, "name", field_name)) {
            var value: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &value) catch false)) return src.invalid("token 'name' is not a string", .{});
            scopes_name = value;
        } else {
            cbor.skipValue(&iter) catch return src.invalid("invalid value for token field '{s}'", .{field_name});
        }
    }
    const style = try load_token_settings_object(src, scopes_name, settings_cb orelse return);
    if (scopes_cb) |cb_| try load_scopes(src, tokens, style, cb_);
}

fn load_token_settings_object(src: Source, scopes_name: ?[]const u8, cb: []const u8) Error!Style {
    const token_name = scopes_name orelse "unknown";
    var iter = cb;
    var len = cbor.decodeMapHeader(&iter) catch return src.invalid("settings of '{s}' is not an object", .{token_name});
    var style: Style = .{};
    while (len > 0) : (len -= 1) {
        var field_name: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &field_name) catch false)) return src.invalid("invalid settings field name in '{s}'", .{token_name});
        const field = std.meta.stringToEnum(SettingsField, field_name) orelse {
            if (src.options.strict) return src.invalid("unhandled style case \"{s}\" in '{s}'", .{ field_name, token_name });
            cbor.skipValue(&iter) catch return src.invalid("invalid value for '{s}' in '{s}'", .{ field_name, token_name });
            continue;
        };
        switch (field) {
            .foreground, .background => {
                var value: []const u8 = undefined;
                if (!(cbor.matchString(&iter, &value) catch false))
                    return src.invalid("'{s}' in '{s}' is not a string", .{ field_name, token_name });
                const color = parse_color(value) orelse
                    return src.invalid("invalid color '{s}' for '{s}' in '{s}'", .{ value, field_name, token_name });
                if (field == .foreground) style.fg = color else style.bg = color;
            },
            .fontStyle => {
                var value: []const u8 = undefined;
                if (!(cbor.matchString(&iter, &value) catch false))
                    return src.invalid("'fontStyle' in '{s}' is not a string", .{token_name});
                if (parse_font_style(value)) |fs| {
                    style.fs = fs;
                } else {
                    if (src.options.strict) return src.invalid("unhandled fontStyle \"{s}\" in '{s}'", .{ value, token_name });
                    std.log.warn("{s}: ignoring unknown fontStyle \"{s}\" in '{s}'", .{ src.file_name, value, token_name });
                }
            },
            else => cbor.skipValue(&iter) catch return src.invalid("invalid value for '{s}' in '{s}'", .{ field_name, token_name }),
        }
    }
    return style;
}

const SettingsField = enum {
    foreground,
    background,
    fontStyle,
    caret,
    invisibles,
    lineHighlight,
    selection,
    findHighlight,
    findHighlightForeground,
    selectionBorder,
    activeGuide,
    bracketsForeground,
    bracketsOptions,
    bracketContentsForeground,
    bracketContentsOptions,
    tagsOptions,
};

/// a space separated list of styles, in any order
fn parse_font_style(value: []const u8) ?theme.FontStyle {
    var bold = false;
    var italic = false;
    var underline = false;
    var strikethrough = false;
    var words = std.mem.tokenizeScalar(u8, value, ' ');
    while (words.next()) |word| {
        if (eql(u8, word, "bold")) {
            bold = true;
        } else if (eql(u8, word, "italic")) {
            italic = true;
        } else if (eql(u8, word, "underline")) {
            underline = true;
        } else if (eql(u8, word, "strikethrough")) {
            strikethrough = true;
        } else if (!eql(u8, word, "normal") and !eql(u8, word, "regular")) return null;
    }
    const count = @as(u8, @intFromBool(bold)) + @intFromBool(italic) + @intFromBool(underline) + @intFromBool(strikethrough);
    return switch (count) {
        0 => .normal,
        1 => if (bold) .bold else if (italic) .italic else if (underline) .underline else .strikethrough,
        2 => if (bold and italic) .bold_italic else if (italic and underline) .italic_underline else if (bold and underline) .bold_underline else null,
        3 => if (bold and italic and underline) .bold_italic_underline else null,
        else => null,
    };
}

fn load_scopes(src: Source, tokens: *TokenMap, style: Style, cb: []const u8) Error!void {
    var iter = cb;
    var value: []const u8 = undefined;
    if (cbor.matchString(&iter, &value) catch false)
        return load_scopes_string(tokens, style, value);
    iter = cb;
    var len = cbor.decodeArrayHeader(&iter) catch return src.invalid("'scope' is not a string or an array", .{});
    while (len > 0) : (len -= 1) {
        if (!(cbor.matchString(&iter, &value) catch false)) return src.invalid("'scope' entry is not a string", .{});
        try load_scopes_string(tokens, style, value);
    }
}

fn load_scopes_string(tokens: *TokenMap, style: Style, scopes_: []const u8) error{OutOfMemory}!void {
    var it = std.mem.splitScalar(u8, scopes_, ',');
    while (it.next()) |raw| {
        const selector = std.mem.trim(u8, raw, " ");
        if (selector.len == 0) continue;
        const target = if (std.mem.findScalarLast(u8, selector, ' ')) |i| selector[i + 1 ..] else selector;
        if (target.len == 0) continue;
        const rule: Rule = .{ .style = style, .selector = if (target.len < selector.len) .descendant else .plain };
        const entry = try tokens.getOrPut(target);
        if (entry.found_existing and entry.value_ptr.selector == .plain and rule.selector == .descendant) continue;
        entry.value_ptr.* = rule;
    }
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

/// #rgb, #rgba, #rrggbb or #rrggbbaa
fn parse_color(s: []const u8) ?Color {
    if (s.len == 0 or s[0] != '#') return null;
    const hex = s[1..];
    for (hex) |c| if (!std.ascii.isHex(c)) return null;
    var buf: [8]u8 = undefined;
    const digits: []const u8 = switch (hex.len) {
        3, 4 => blk: {
            for (hex, 0..) |c, i| {
                buf[i * 2] = c;
                buf[i * 2 + 1] = c;
            }
            break :blk buf[0 .. hex.len * 2];
        },
        6, 8 => hex,
        else => return null,
    };
    return .{
        .color = std.fmt.parseInt(u24, digits[0..6], 16) catch unreachable,
        .alpha = if (digits.len == 8) std.fmt.parseInt(u8, digits[6..8], 16) catch unreachable else 0xFF,
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

const testing = std.testing;

fn expect_stripped(expected: []const u8, input: []const u8) !void {
    const result = try strip_jsonc(testing.allocator, input);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "strip_jsonc" {
    try expect_stripped("{\"a\": 1}", "{\"a\": 1}");
    try expect_stripped("{ \n  \"a\": 1 \n}", "{ // comment\n  \"a\": 1 // more\n}");
    try expect_stripped("{   \"a\":   1}", "{ /* x */ \"a\": /* y\n z */ 1}");
    try expect_stripped("{\"a\": [1, 2]\n}", "{\"a\": [1, 2,],\n}");
    try expect_stripped("{\"a\": 1 \n}", "{\"a\": 1, // last\n}");
    try expect_stripped("{\"a\": \"http://x/*y*/\"}", "{\"a\": \"http://x/*y*/\"}");
    try expect_stripped("{\"a\": \"q\\\",}\"}", "{\"a\": \"q\\\",}\"}");
    try expect_stripped("[\"a,]\"]", "[\"a,]\",]");
    try testing.expectError(error.UnterminatedComment, strip_jsonc(testing.allocator, "{} /* open"));
}

test "parse_font_style" {
    try testing.expectEqual(.normal, parse_font_style(""));
    try testing.expectEqual(.normal, parse_font_style("regular"));
    try testing.expectEqual(.bold, parse_font_style("bold"));
    try testing.expectEqual(.strikethrough, parse_font_style(" strikethrough "));
    try testing.expectEqual(.bold_italic, parse_font_style("bold italic"));
    try testing.expectEqual(.bold_italic, parse_font_style("italic bold"));
    try testing.expectEqual(.italic_underline, parse_font_style("underline italic"));
    try testing.expectEqual(.bold_underline, parse_font_style("underline bold"));
    try testing.expectEqual(.bold_italic_underline, parse_font_style("bold italic underline"));
    try testing.expectEqual(null, parse_font_style("bold strikethrough"));
    try testing.expectEqual(null, parse_font_style("oblique"));
}

test "parse_color" {
    try testing.expectEqual(Color{ .color = 0x112233 }, parse_color("#123").?);
    try testing.expectEqual(Color{ .color = 0x112233, .alpha = 0x44 }, parse_color("#1234").?);
    try testing.expectEqual(Color{ .color = 0xa0b0c0 }, parse_color("#A0b0C0").?);
    try testing.expectEqual(Color{ .color = 0xa0b0c0, .alpha = 0x80 }, parse_color("#a0b0c080").?);
    try testing.expectEqual(null, parse_color(""));
    try testing.expectEqual(null, parse_color("#12345"));
    try testing.expectEqual(null, parse_color("#12345g"));
    try testing.expectEqual(null, parse_color("123456"));
}

const TestContext = struct {
    base: []const u8,
    scopes: std.ArrayList([]const u8) = .empty,

    fn context(self: *TestContext) Context {
        return .{ .ptr = self, .vtable = &.{ .include = include, .scope_id = scope_id } };
    }

    fn include(ptr: *anyopaque, file_name: []const u8) Error![]const u8 {
        const self: *TestContext = @ptrCast(@alignCast(ptr));
        if (!eql(u8, file_name, "./base.json")) return error.IncludeNotFound;
        return self.base;
    }

    fn scope_id(ptr: *anyopaque, scope: []const u8) error{OutOfMemory}!usize {
        const self: *TestContext = @ptrCast(@alignCast(ptr));
        for (self.scopes.items, 0..) |s, i| if (eql(u8, s, scope)) return i;
        try self.scopes.append(testing.allocator, scope);
        return self.scopes.items.len - 1;
    }
};

test "load with include" {
    const a = testing.allocator;
    const base = try to_cbor(a, "base.json",
        \\{
        \\  "colors": { "editor.background": "#000000", "statusBar.background": "#010203" },
        \\  "tokenColors": [
        \\    { "scope": "comment", "settings": { "foreground": "#111111" } },
        \\    { "scope": ["string", "keyword"], "settings": { "foreground": "#222222" } },
        \\  ],
        \\}
    , null);
    defer a.free(base);
    const top = try to_cbor(a, "top-color-theme.json",
        \\{
        \\  // the name is the description
        \\  "name": "Top Theme",
        \\  "include": "./base.json",
        \\  "colors": {
        \\    "editor.foreground": "#ffffff",
        \\    "editor.background": "#202020",
        \\    "editor.background": "#101010",
        \\    "editor.selectionBackground": "",
        \\  },
        \\  "tokenColors": [
        \\    { "scope": ["source string", "source number"], "settings": { "foreground": "#333333", "fontStyle": "bold italic", "unknownKey": 1 } },
        \\    { "settings": { "foreground": "#444444" } },
        \\  ],
        \\}
    , null);
    defer a.free(top);

    var ctx: TestContext = .{ .base = base };
    defer ctx.scopes.deinit(a);
    const t = try load(a, ctx.context(), "/x/top-color-theme.json", top, .{});
    defer a.free(t.tokens);

    try testing.expectEqualStrings("top", t.name);
    try testing.expectEqualStrings("Top Theme", t.description);
    try testing.expectEqual(theme.Type.dark, t.type);
    try testing.expectEqual(Color{ .color = 0x101010 }, t.editor.bg.?);
    try testing.expectEqual(Color{ .color = 0x010203 }, t.statusbar.bg.?);
    try testing.expectEqual(Color{ .color = 0x264F78 }, t.editor_selection.bg.?);

    // "source string" does not replace the plain "string" of base.json
    try testing.expectEqual(4, t.tokens.len);
    const expected = [_]struct { []const u8, u24, ?theme.FontStyle }{
        .{ "comment", 0x111111, null },
        .{ "keyword", 0x222222, null },
        .{ "number", 0x333333, .bold_italic },
        .{ "string", 0x222222, null },
    };
    for (expected, t.tokens) |e, token| {
        try testing.expectEqualStrings(e[0], ctx.scopes.items[token.id]);
        try testing.expectEqual(e[1], token.style.fg.?.color);
        try testing.expectEqual(e[2], token.style.fs);
    }

    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.InvalidTheme, load(a, ctx.context(), "top.json", top, .{ .strict = true, .diagnostic = &diagnostic }));
    try testing.expectEqualStrings("top.json: unhandled style case \"unknownKey\" in 'unknown'", diagnostic.message());
}

test "load errors" {
    const a = testing.allocator;
    var ctx: TestContext = .{ .base = &.{} };
    defer ctx.scopes.deinit(a);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "[]", "case.json: theme is not a JSON object" },
        .{ "{\"include\": \"./missing.json\"}", "case.json: include './missing.json' not found" },
        .{ "{\"tokenColors\": \"./file.tmTheme\"}", "case.json: 'tokenColors' is not an array (tokenColors files are not supported)" },
        .{ "{\"tokenColors\": [{\"scope\": 1, \"settings\": {}}]}", "case.json: 'scope' is not a string or an array" },
        .{ "{\"tokenColors\": [{\"scope\": \"a\", \"settings\": {\"foreground\": \"red\"}}]}", "case.json: invalid color 'red' for 'foreground' in 'unknown'" },
    };
    for (cases) |case| {
        const cb = try to_cbor(a, "case.json", case[0], null);
        defer a.free(cb);
        var diagnostic: Diagnostic = .{};
        try testing.expectError(error.InvalidTheme, load(a, ctx.context(), "case.json", cb, .{ .diagnostic = &diagnostic }));
        try testing.expectEqualStrings(case[1], diagnostic.message());
    }
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.InvalidTheme, to_cbor(a, "bad.json", "{\"a\": }", &diagnostic));
    try testing.expectEqualStrings("bad.json: invalid JSON: SyntaxError", diagnostic.message());
}
