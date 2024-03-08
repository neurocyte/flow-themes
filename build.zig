const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const cbor_mod = b.createModule(.{ .root_source_file = .{ .path = "src/cbor.zig" } });
    const theme_mod = b.createModule(.{ .root_source_file = .{ .path = "src/theme.zig" } });
    const themes_compile = b.addExecutable(.{
        .name = "themes_compile",
        .target = target,
        .root_source_file = .{ .path = "src/compile.zig" },
    });
    add_themes(b, themes_compile);
    themes_compile.root_module.addImport("cbor", cbor_mod);
    themes_compile.root_module.addImport("theme", theme_mod);
    // b.installArtifact(themes_compile);
    const themes_compile_step = b.addRunArtifact(themes_compile);
    const themes_compile_output = themes_compile_step.addOutputFileArg("themes.zig");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(themes_compile_output, .{ .custom = "src" }, "themes.zig").step);
    b.installFile("src/theme.zig", "src/theme.zig");
    b.installFile("src/build-dest.zig", "./build.zig");
}

fn theme_file(b: *std.Build, exe: anytype, comptime dep_name: []const u8, comptime sub_path: []const u8) void {
    const dep = b.dependency("theme_" ++ dep_name, .{});
    exe.root_module.addImport(sub_path, b.createModule(.{ .root_source_file = dep.path(sub_path) }));
}

fn add_themes(b: *std.Build, exe: anytype) void {
    theme_file(b, exe, "1984", "themes/1984-color-theme.json");
    theme_file(b, exe, "1984", "themes/1984-cyberpunk-color-theme.json");
    theme_file(b, exe, "1984", "themes/1984-orwell-color-theme.json");
    theme_file(b, exe, "1984", "themes/1984-light-color-theme.json");
    theme_file(b, exe, "cobalt2", "theme/cobalt2.json");
    theme_file(b, exe, "oldschool", "themes/oldschool-gray-color-theme.json");
    theme_file(b, exe, "oldschool", "themes/oldschool-terminal-green.json");
    theme_file(b, exe, "turbo_colors", "themes/Turbo Colors-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-tomorrow-night-blue/themes/tomorrow-night-blue-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-monokai/themes/monokai-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-solarized-dark/themes/solarized-dark-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-solarized-light/themes/solarized-light-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-kimbie-dark/themes/kimbie-dark-color-theme.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/dark_modern.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/dark_plus.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/dark_vs.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/light_modern.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/light_plus.json");
    theme_file(b, exe, "vscode", "extensions/theme-defaults/themes/light_vs.json");
    theme_file(b, exe, "CRT", "themes/CRT-64-color-theme.json");
    theme_file(b, exe, "CRT", "themes/CRT-Amber-color-theme.json");
    theme_file(b, exe, "CRT", "themes/CRT-Gray-color-theme.json");
    theme_file(b, exe, "CRT", "themes/CRT-Green-color-theme.json");
    theme_file(b, exe, "CRT", "themes/CRT-Paper-color-theme.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-dark-hard.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-dark-medium.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-dark-soft.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-light-hard.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-light-medium.json");
    theme_file(b, exe, "gruvbox", "themes/gruvbox-light-soft.json");
    theme_file(b, exe, "tokyo_night", "themes/tokyo-night-storm-color-theme.json");
    theme_file(b, exe, "tokyo_night", "themes/tokyo-night-color-theme.json");
    theme_file(b, exe, "tokyo_night", "themes/tokyo-night-light-color-theme.json");
    theme_file(b, exe, "ayu", "ayu-dark.json");
    theme_file(b, exe, "ayu", "ayu-dark-bordered.json");
    theme_file(b, exe, "ayu", "ayu-mirage.json");
    theme_file(b, exe, "ayu", "ayu-mirage-bordered.json");
    theme_file(b, exe, "ayu", "ayu-light.json");
    theme_file(b, exe, "ayu", "ayu-light-bordered.json");
    theme_file(b, exe, "onedark_pro", "themes/OneDark-Pro.json");
    theme_file(b, exe, "rose_pine", "themes/rose-pine-color-theme.json");
    theme_file(b, exe, "rose_pine", "themes/rose-pine-no-italics-color-theme.json");
    theme_file(b, exe, "rose_pine", "themes/rose-pine-moon-color-theme.json");
    theme_file(b, exe, "rose_pine", "themes/rose-pine-moon-no-italics-color-theme.json");
    theme_file(b, exe, "rose_pine", "themes/rose-pine-dawn-color-theme.json");
}
