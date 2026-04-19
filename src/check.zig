const std = @import("std");

test {
    std.testing.refAllDecls(@import("theme"));
    std.testing.refAllDecls(@import("themes"));
}
