const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");

pub export fn tmate_dump_exec_response(
    session: ?*c.struct_tmate_session,
    exit_code: c_int,
    message: ?[*:0]const u8,
) void {
    const sess = session orelse return;
    const msg = message orelse return;
    const client = &sess.ssh_client;

    _ = c.ssh_channel_write(client.channel, msg, @intCast(c.strlen(msg)));
    _ = c.ssh_channel_request_send_exit_status(client.channel, exit_code);

    _ = c.ssh_channel_send_eof(client.channel);
    _ = c.ssh_channel_close(client.channel);

    if (c.event_base_loopexit(sess.ev_base, null) < 0) {
        debug.fatal("Cannot stop event loop", .{});
    }
}

fn onWebsocketError(session: ?*c.struct_tmate_session, _: c_short) callconv(.c) void {
    debug.info("Lost websocket server connection", .{});
    tmate_dump_exec_response(session, 1, "Internal Error\r\n");
}

fn tmateClientExecInit(session: *c.struct_tmate_session) void {
    const client = &session.ssh_client;

    client.channel_cb = std.mem.zeroes(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.size = @sizeOf(c.struct_ssh_channel_callbacks_struct);
    _ = c.ssh_set_channel_callbacks(client.channel, &client.channel_cb);

    c.tmate_init_websocket(session, onWebsocketError);
    c.tmate_websocket_exec(session, client.exec_command);
}

pub export fn tmate_spawn_exec(session: ?*c.struct_tmate_session) void {
    const sess = session orelse return;
    const client = &sess.ssh_client;

    debug.info("Spawning exec client ip=%s", .{@as([*:0]const u8, @ptrCast(&client.ip_address[0]))});

    const log_fd: c_int = if (c.log_file != null) c.fileno(c.log_file) else -1;
    var fds = [_]c_int{
        c.ssh_get_fd(sess.ssh_client.session),
        log_fd,
        sess.websocket_fd,
    };
    c.close_fds_except(&fds[0], 3);
    c.get_in_jail();
    _ = c.event_reinit(sess.ev_base);

    tmateClientExecInit(sess);

    if (c.event_base_dispatch(sess.ev_base) < 0) {
        debug.fatal("Cannot run event loop", .{});
    }
    c.exit(0);
}
