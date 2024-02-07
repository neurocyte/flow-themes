const std = @import("std");

pub fn build(b: *std.Build) void {
    const theme_mod = b.addModule("theme", .{
        .root_source_file = .{ .path = "src/theme.zig" },
    });

    _ = b.addModule("themes", .{
        .root_source_file = .{ .path = "src/themes.zig" },
        .imports = &.{
            .{ .name = "theme", .module = theme_mod },
        },
    });
}
