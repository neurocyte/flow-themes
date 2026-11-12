const std = @import("std");

pub fn build(b: *std.Build) void {
    const theme_mod = b.addModule("theme", .{
        .root_source_file = b.path("src/theme.zig"),
    });

    _ = b.addModule("themes", .{
        .root_source_file = b.path("src/themes.zig"),
        .imports = &.{
            .{ .name = "theme", .module = theme_mod },
        },
    });

    // importers replace the "cbor" placeholder with addImport
    _ = b.addModule("vscode_theme", .{
        .root_source_file = b.path("src/vscode_theme.zig"),
        .imports = &.{
            .{ .name = "theme", .module = theme_mod },
            .{ .name = "cbor", .module = b.createModule(.{ .root_source_file = b.path("src/cbor_missing.zig") }) },
        },
    });
}
