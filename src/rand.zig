const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");

var dev_urandom_fd: c_int = -1;

pub export fn tmate_init_rand() void {
    dev_urandom_fd = c.open("/dev/urandom", c.O_RDONLY);
    if (dev_urandom_fd < 0) {
        debug.fatal("Cannot open /dev/urandom", .{});
    }
}

pub export fn tmate_get_random_bytes(buffer: ?*anyopaque, len: isize) void {
    if (len <= 0) return;
    const buf = buffer orelse return;
    if (c.read(dev_urandom_fd, buf, @intCast(len)) != len) {
        debug.fatal("Cannot read from /dev/urandom", .{});
    }
}

pub export fn tmate_get_random_long() c_long {
    var val: c_long = 0;
    tmate_get_random_bytes(&val, @sizeOf(c_long));
    return val;
}

pub export fn random_stream_init(rs: ?*c.struct_random_stream) void {
    const r = rs orelse return;
    r.pos = c.RS_BUF_SIZE;
}

pub export fn random_stream_get(rs: ?*c.struct_random_stream, count: usize) ?[*]u8 {
    const r = rs orelse return null;
    if (count > c.RS_BUF_SIZE) {
        debug.fatal("buffer too small", .{});
    }
    if (@as(usize, @intCast(r.pos)) + count > c.RS_BUF_SIZE) {
        tmate_get_random_bytes(&r.bytes[0], c.RS_BUF_SIZE);
        r.pos = 0;
    }
    const ret: [*]u8 = @ptrCast(&r.bytes[@intCast(r.pos)]);
    r.pos += @intCast(count);
    return ret;
}
