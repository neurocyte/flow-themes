const std = @import("std");
pub const theme_file = struct { file_name: []const u8, json: []const u8, cbor: ?[]const u8 = null };

pub const theme_files = [_]theme_file{

    // dark themes

    THEME("default.json"),
    THEME("themes/1984-color-theme.json"),
    THEME("themes/1984-cyberpunk-color-theme.json"),
    THEME("themes/1984-orwell-color-theme.json"),
    THEME("theme/cobalt2.json"),
    THEME("themes/oldschool-gray-color-theme.json"),
    THEME("themes/oldschool-terminal-green.json"),
    THEME("themes/Turbo Colors-color-theme.json"),
    THEME("extensions/theme-tomorrow-night-blue/themes/tomorrow-night-blue-color-theme.json"),
    THEME("extensions/theme-monokai/themes/monokai-color-theme.json"),
    THEME("extensions/theme-solarized-dark/themes/solarized-dark-color-theme.json"),
    THEME("extensions/theme-kimbie-dark/themes/kimbie-dark-color-theme.json"),
    THEME("themes/CRT-64-color-theme.json"),
    THEME("themes/CRT-Amber-color-theme.json"),
    THEME("themes/CRT-Gray-color-theme.json"),
    THEME("themes/CRT-Green-color-theme.json"),
    THEME("themes/gruvbox-dark-hard.json"),
    THEME("themes/gruvbox-dark-medium.json"),
    THEME("themes/gruvbox-dark-soft.json"),
    THEME("themes/tokyo-night-storm-color-theme.json"),
    THEME("themes/tokyo-night-color-theme.json"),
    THEME("ayu-dark.json"),
    THEME("ayu-dark-bordered.json"),
    THEME("ayu-mirage.json"),
    THEME("ayu-mirage-bordered.json"),
    THEME("extensions/theme-defaults/themes/dark_vs.json"),
    THEME("extensions/theme-defaults/themes/dark_plus.json"),
    THEME("extensions/theme-defaults/themes/dark_modern.json"),
    THEME("themes/OneDark-Pro.json"),

    // light themes

    THEME("themes/1984-light-color-theme.json"),
    THEME("extensions/theme-solarized-light/themes/solarized-light-color-theme.json"),
    THEME("themes/CRT-Paper-color-theme.json"),
    THEME("themes/gruvbox-light-hard.json"),
    THEME("themes/gruvbox-light-medium.json"),
    THEME("themes/gruvbox-light-soft.json"),
    THEME("extensions/theme-defaults/themes/light_vs.json"),
    THEME("extensions/theme-defaults/themes/light_plus.json"),
    THEME("extensions/theme-defaults/themes/light_modern.json"),
    THEME("themes/tokyo-night-light-color-theme.json"),
    THEME("ayu-light.json"),
    THEME("ayu-light-bordered.json"),
};

fn THEME(comptime file_path: []const u8) theme_file {
    @setEvalBranchQuota(2000);
    return .{ .file_name = std.fs.path.basename(file_path), .json = @embedFile(file_path) };
}
