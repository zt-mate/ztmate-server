const root = @import("root.zig");

pub export fn main(argc: c_int, argv: [*]?[*:0]u8, envp: [*]?[*:0]u8) callconv(.c) c_int {
    return root.server_main.serverMain(argc, argv, envp);
}

comptime {
    _ = root;
}
