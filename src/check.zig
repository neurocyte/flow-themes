const std = @import("std");

test {
    std.testing.refAllDecls(@import("theme"));
    std.testing.refAllDecls(@import("themes"));
}

pub fn main() void {
    std.testing.refAllDecls(@This());
}
