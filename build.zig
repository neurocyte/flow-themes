const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const cbor_mod = b.createModule(.{ .root_source_file = b.path("src/cbor.zig") });
    const theme_mod = b.createModule(.{ .root_source_file = b.path("src/theme.zig") });
    const themes_compile = b.addExecutable(.{
        .name = "themes_compile",
        .target = target,
        .root_source_file = b.path("src/compile.zig"),
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
    theme_file(b, exe, "gruvbox_material", "themes/gruvbox-material-dark.json");
    theme_file(b, exe, "gruvbox_material", "themes/gruvbox-material-light.json");
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
    theme_file(b, exe, "adwaita", "themes/adwaita-dark.json");
    theme_file(b, exe, "adwaita", "themes/adwaita-light.json");
    theme_file(b, exe, "everforest", "themes/everforest-dark.json");
    theme_file(b, exe, "everforest", "themes/everforest-light.json");
    theme_file(b, exe, "nord", "themes/nord-color-theme.json");
    theme_file(b, exe, "catppuccin", "themes/frappe.json");
    theme_file(b, exe, "catppuccin", "themes/latte.json");
    theme_file(b, exe, "catppuccin", "themes/macchiato.json");
    theme_file(b, exe, "catppuccin", "themes/mocha.json");
    theme_file(b, exe, "mellow", "themes/mellow.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/duckbones_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/duckbones_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/duckbones_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/forestbones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/kanagawabones_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/kanagawabones_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/kanagawabones_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/neobones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/nordbones_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/nordbones_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/nordbones_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/rosebones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/seoulbones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/tokyobones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/vimbones_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/vimbones_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/vimbones_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenbones_light_dim.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenburned_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenburned_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenburned_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_dark_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_dark_stark.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_dark_warm.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_light_bright.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_light_default.json");
    theme_file(b, exe, "zenbones", "extras/vscode/themes/zenwritten_light_dim.json");
    theme_file(b, exe, "hypersubatomic", "themes/Hypersubatomic-color-theme.json");
}
