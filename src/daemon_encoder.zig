const std = @import("std");
const c = @import("c.zig").c;
const protocol = @import("protocol.zig");
const msgpack = @import("msgpack.zig");
const debug = @import("debug.zig");

extern "c" fn vsnprintf(s: [*c]u8, n: usize, format: [*:0]const u8, arg: ?*anyopaque) c_int;

inline fn pk() *c.msgpack_packer {
    return &c.tmate_session.*.daemon_encoder.pk;
}

fn notifyRaw(msg: [*:0]const u8) void {
    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_NOTIFY));
    msgpack.msgpack_pack_string(pk(), msg);
}

pub fn notify(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt ++ "\x00", args) catch return;
    notifyRaw(@ptrCast(slice.ptr));
}

pub export fn tmate_notify(fmt: [*:0]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var msg: [1024]u8 = undefined;
    _ = vsnprintf(&msg[0], msg.len, fmt, @ptrCast(&ap));
    notifyRaw(@ptrCast(&msg[0]));
}

fn notifyLaterCb(_: c.evutil_socket_t, _: c_short, arg: ?*anyopaque) callconv(.c) void {
    const msg: [*:0]const u8 = @ptrCast(arg orelse return);
    notifyRaw(msg);
}

pub export fn tmate_notify_later(timeout: c_int, fmt: [*:0]const u8, ...) callconv(.c) void {
    var tv = c.struct_timeval{
        .tv_sec = timeout,
        .tv_usec = 0,
    };

    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    var msg: [*c]u8 = null;
    _ = c.xvasprintf(&msg, fmt, @ptrCast(&ap));

    c.event_set(&c.tmate_session.*.ev_notify_timer, -1, 0, notifyLaterCb, msg);
    _ = c.event_add(&c.tmate_session.*.ev_notify_timer, &tv);
}

pub export fn tmate_send_client_ready() void {
    if (c.tmate_session.*.client_protocol_version < 4) return;
    _ = c.msgpack_pack_array(pk(), 1);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_READY));
}

pub export fn tmate_set_env(name: ?[*:0]const u8, value: ?[*:0]const u8) void {
    if (c.tmate_session.*.client_protocol_version < 4) return;
    _ = c.msgpack_pack_array(pk(), 3);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_SET_ENV));
    msgpack.msgpack_pack_string(pk(), name);
    msgpack.msgpack_pack_string(pk(), value);
}

pub export fn tmate_client_resize(sx: c_uint, sy: c_uint) void {
    _ = c.msgpack_pack_array(pk(), 3);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_RESIZE));
    _ = c.msgpack_pack_int(pk(), @bitCast(sx));
    _ = c.msgpack_pack_int(pk(), @bitCast(sy));
}

pub export fn tmate_client_legacy_pane_key(_: c_int, key: c_int) void {
    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_LEGACY_PANE_KEY));
    _ = c.msgpack_pack_int(pk(), key);
}

pub export fn tmate_client_pane_key(pane_id: c_int, key_in: c.key_code) void {
    var key = key_in;
    if (key == c.KEYC_NONE or key == c.KEYC_UNKNOWN) return;
    if (c.KEYC_IS_MOUSE(key)) return;

    if (c.tmate_session.*.client_protocol_version < 5) {
        c.tmate_translate_legacy_key(pane_id, key);
        return;
    }

    if (c.tmate_session.*.client_protocol_version == 5 and (key & c.KEYC_BASE) != 0) {
        if ((key & c.KEYC_MASK_KEY) >= (c.KEYC_BSPACE & c.KEYC_MASK_KEY)) {
            key -= 9;
        }
    }

    _ = c.msgpack_pack_array(pk(), 3);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_PANE_KEY));
    _ = c.msgpack_pack_int(pk(), pane_id);
    _ = c.msgpack_pack_uint64(pk(), key);
}

extern const cmd_bind_key_entry: c.struct_cmd_entry;
extern const cmd_unbind_key_entry: c.struct_cmd_entry;
extern const cmd_set_option_entry: c.struct_cmd_entry;
extern const cmd_set_window_option_entry: c.struct_cmd_entry;
extern const cmd_detach_client_entry: c.struct_cmd_entry;
extern const cmd_attach_session_entry: c.struct_cmd_entry;

pub export fn tmate_should_exec_cmd_locally(cmd: ?*const c.struct_cmd_entry) c_int {
    const target = cmd orelse return 0;
    const local_cmds = [_]*const c.struct_cmd_entry{
        &cmd_bind_key_entry,
        &cmd_unbind_key_entry,
        &cmd_set_option_entry,
        &cmd_set_window_option_entry,
        &cmd_detach_client_entry,
        &cmd_attach_session_entry,
    };
    for (local_cmds) |entry| {
        if (entry == target) return 1;
    }
    return 0;
}

pub export fn tmate_client_cmd_str(client_id: c_int, cmd: ?[*:0]const u8) void {
    const cmd_s = cmd orelse return;
    debug.debug("Remote cmd (cid=%d): %s", .{ client_id, cmd_s });

    _ = c.msgpack_pack_array(pk(), 3);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_EXEC_CMD_STR));
    _ = c.msgpack_pack_int(pk(), client_id);
    msgpack.msgpack_pack_string(pk(), cmd_s);
}

const ArgsEntry = extern struct {
    flag: u8,
    value: ?[*:0]u8,
    entry: extern struct {
        rbe_left: ?*ArgsEntry,
        rbe_right: ?*ArgsEntry,
        rbe_parent: ?*ArgsEntry,
        rbe_color: c_int,
    },
};

fn extractCmd(cmd: *c.struct_cmd, _argc: *c_int, _argv: *?[*]?[*:0]u8) void {
    const args = cmd.args;
    var argc: c_int = 1; // cmd name

    var raw_entry = c.args_tree_RB_MINMAX(&args.*.tree, -1);
    while (raw_entry != null) : (raw_entry = c.args_tree_RB_NEXT(raw_entry)) {
        const entry: *ArgsEntry = @ptrCast(@alignCast(raw_entry));
        argc += 1;
        if (entry.value != null) {
            argc += 1;
        }
    }
    argc += args.*.argc;

    const argv: [*]?[*:0]u8 = @ptrCast(@alignCast(c.xmalloc(@sizeOf(?[*:0]u8) * @as(usize, @intCast(argc)))));
    var next: usize = 0;

    argv[next] = c.xstrdup(cmd.entry.*.name);
    next += 1;

    raw_entry = c.args_tree_RB_MINMAX(&args.*.tree, -1);
    while (raw_entry != null) : (raw_entry = c.args_tree_RB_NEXT(raw_entry)) {
        const entry: *ArgsEntry = @ptrCast(@alignCast(raw_entry));
        var flag_str: [*c]u8 = null;
        _ = c.xasprintf(&flag_str, "-%c", @as(c_int, entry.flag));
        argv[next] = @ptrCast(flag_str);
        next += 1;
        if (entry.value) |val| {
            argv[next] = c.xstrdup(val);
            next += 1;
        }
    }

    var i: usize = 0;
    const args_argc: usize = @intCast(args.*.argc);
    while (i < args_argc) : (i += 1) {
        argv[next] = c.xstrdup(args.*.argv[i]);
        next += 1;
    }

    _argc.* = argc;
    _argv.* = argv;
}

pub export fn tmate_client_cmd_args(client_id: c_int, argc: c_int, argv: ?[*]const ?[*:0]const u8) void {
    const av = argv orelse return;
    _ = c.msgpack_pack_array(pk(), @intCast(argc + 2));
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateDaemonInMsgTypes.TMATE_IN_EXEC_CMD));
    _ = c.msgpack_pack_int(pk(), client_id);

    var i: usize = 0;
    const count: usize = @intCast(argc);
    while (i < count) : (i += 1) {
        msgpack.msgpack_pack_string(pk(), av[i]);
    }
}

pub export fn tmate_client_cmd(client_id: c_int, cmd: ?*c.struct_cmd) void {
    const cm = cmd orelse return;
    const cmd_str = c.cmd_print(cm);
    if (c.tmate_session.*.client_protocol_version < 6) {
        tmate_client_cmd_str(client_id, cmd_str);
        c.free(cmd_str);
        return;
    }
    debug.debug("Remote cmd (cid=%d): %s", .{ client_id, cmd_str });
    c.free(cmd_str);

    var argc: c_int = 0;
    var argv: ?[*]?[*:0]u8 = null;
    extractCmd(cm, &argc, &argv);
    tmate_client_cmd_args(client_id, argc, @ptrCast(argv));
    c.cmd_free_argv(argc, @ptrCast(argv));
}

pub export fn tmate_client_set_active_pane(client_id: c_int, win_idx: c_int, pane_id: c_int) void {
    var target: [64]u8 = undefined;
    _ = c.snprintf(&target[0], target.len, "%d.%d", win_idx, pane_id);
    const argv = [_]?[*:0]const u8{ "select-pane", "-t", @ptrCast(&target[0]) };
    tmate_client_cmd_args(client_id, 3, &argv);
}

pub export fn tmate_send_mc_obj(obj: ?*c.msgpack_object) void {
    const o = obj orelse return;
    _ = msgpack._msgpack_pack_object(pk(), o.*);
}
