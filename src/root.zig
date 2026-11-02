const std = @import("std");

pub const c = @import("c.zig");
pub const protocol = @import("protocol.zig");
pub const debug = @import("debug.zig");
pub const rand = @import("rand.zig");
pub const msgpack = @import("msgpack.zig");
pub const auth_keys = @import("auth_keys.zig");
pub const daemon_encoder = @import("daemon_encoder.zig");
pub const daemon_legacy = @import("daemon_legacy.zig");
pub const daemon_decoder = @import("daemon_decoder.zig");
pub const ssh_daemon = @import("ssh_daemon.zig");
pub const ssh_exec = @import("ssh_exec.zig");
pub const ssh_client_pty = @import("ssh_client_pty.zig");
pub const ssh_latency = @import("ssh_latency.zig");
pub const ssh_server = @import("ssh_server.zig");
pub const websocket = @import("websocket.zig");
pub const server_main = @import("server_main.zig");

comptime {
    _ = debug;
    _ = rand;
    _ = msgpack;
    _ = auth_keys;
    _ = daemon_encoder;
    _ = daemon_legacy;
    _ = daemon_decoder;
    _ = ssh_daemon;
    _ = ssh_exec;
    _ = ssh_client_pty;
    _ = ssh_latency;
    _ = ssh_server;
    _ = websocket;
    _ = server_main;
}

test "protocol enum values match tmate-protocol.h" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_HEADER));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_EXEC));
    try std.testing.expectEqual(@as(c_int, 5), @intFromEnum(protocol.TmateControlInMsgTypes.TMATE_CTL_RENAME_SESSION));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(protocol.TmateDaemonOutMsgTypes.TMATE_OUT_HEADER));
    try std.testing.expectEqual(@as(c_int, 13), @intFromEnum(protocol.TmateDaemonOutMsgTypes.TMATE_OUT_UNAME));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_NOTIFY));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_SET_ENV));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_EXEC_CMD));
}

test "session token validation and socket path" {
    try std.testing.expectEqual(@as(c_int, 0), ssh_client_pty.tmate_validate_session_token("abcdefgh1234567890"));
    try std.testing.expectEqual(@as(c_int, 0), ssh_client_pty.tmate_validate_session_token("ro-abcdefgh1234567890"));
    try std.testing.expectEqual(@as(c_int, -1), ssh_client_pty.tmate_validate_session_token("ab"));
    try std.testing.expectEqual(@as(c_int, -1), ssh_client_pty.tmate_validate_session_token("bad..token"));

    const path = server_main.get_socket_path("foo/bar.baz");
    try std.testing.expect(path != null);
    defer c.c.free(path);
    try std.testing.expectEqualStrings("/tmp/ztmate/sessions/foo=bar=baz", std.mem.span(path.?));
}

test "msgpack v4 and v5 pack and streaming unpack roundtrip" {
    const BufferCtx = struct {
        data: [512]u8 = undefined,
        len: usize = 0,

        fn writeCallback(userdata: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const src = buf[0..len];
            @memcpy(self.data[self.len .. self.len + len], src);
            self.len += len;
            return 0;
        }
    };

    var ctx = BufferCtx{};
    var enc: c.c.struct_tmate_encoder = std.mem.zeroes(c.c.struct_tmate_encoder);
    enc.mpac_version = 5;
    msgpack.msgpack_packer_init(&enc.pk, &ctx, BufferCtx.writeCallback);

    _ = msgpack.msgpack_pack_array(&enc.pk, 4);
    _ = msgpack.msgpack_pack_int(&enc.pk, 6);
    msgpack.msgpack_pack_string(&enc.pk, "ztmate-ssh-server");
    _ = msgpack.msgpack_pack_int(&enc.pk, -19);
    msgpack.msgpack_pack_boolean(&enc.pk, true);

    var unpacker: c.c.msgpack_unpacker = undefined;
    try std.testing.expect(msgpack.msgpack_unpacker_init(&unpacker, 64));
    defer msgpack.msgpack_unpacker_destroy(&unpacker);

    var result: c.c.msgpack_unpacked = undefined;
    msgpack.msgpack_unpacked_init(&result);
    defer msgpack.msgpack_unpacked_destroy(&result);

    try std.testing.expect(msgpack.msgpack_unpacker_reserve_buffer(&unpacker, ctx.len));
    @memcpy(msgpack.msgpack_unpacker_buffer(&unpacker)[0..ctx.len], ctx.data[0..ctx.len]);
    msgpack.msgpack_unpacker_buffer_consumed(&unpacker, ctx.len);
    try std.testing.expect(msgpack.msgpack_unpacker_next(&unpacker, &result));

    var uk: c.c.struct_tmate_unpacker = undefined;
    msgpack.init_unpacker(&uk, result.data);
    try std.testing.expectEqual(@as(i64, 6), msgpack.unpack_int(&uk));

    const s = msgpack.unpack_string(&uk);
    try std.testing.expect(s != null);
    defer c.c.free(s);
    try std.testing.expectEqualStrings("ztmate-ssh-server", std.mem.span(s.?));
    try std.testing.expectEqual(@as(i64, -19), msgpack.unpack_int(&uk));
    try std.testing.expectEqual(true, msgpack.unpack_bool(&uk));
}
