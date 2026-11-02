const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");
const rand = @import("rand.zig");

const BAD_TOKEN_ERROR_STR = "Invalid session token\r\n";
const EXPIRED_TOKEN_ERROR_STR = "Invalid or expired session token\r\n";

fn onSshChannelRead(
    _: c.ssh_session,
    _: c.ssh_channel,
    _data: ?*anyopaque,
    total_len_in: u32,
    _: c_int,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    if (session.readonly) {
        return @intCast(total_len_in);
    }

    var data: [*]const u8 = @ptrCast(_data orelse return 0);
    var total_len: usize = total_len_in;
    var written: usize = 0;

    c.setblocking(session.pty, 1);
    while (total_len > 0) {
        const len = c.write(session.pty, data, total_len);
        if (len < 0) {
            debug.fatal("Error writing to pty", .{});
        }
        const ulen: usize = @intCast(len);
        total_len -= ulen;
        written += ulen;
        data += ulen;
    }
    c.setblocking(session.pty, 0);

    return @intCast(written);
}

fn onSshMessageCallback(_: c.ssh_session, msg: c.ssh_message, arg: ?*anyopaque) callconv(.c) c_int {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(arg.?));
    if (c.ssh_message_type(msg) == c.SSH_REQUEST_CHANNEL and
        c.ssh_message_subtype(msg) == c.SSH_CHANNEL_REQUEST_WINDOW_CHANGE)
    {
        var ws: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
        ws.ws_col = @intCast(c.ssh_message_channel_request_pty_width(msg));
        ws.ws_row = @intCast(c.ssh_message_channel_request_pty_height(msg));

        _ = c.ioctl(session.pty, c.TIOCSWINSZ, &ws);
        c.client_signal(c.SIGWINCH);
        return 1;
    }
    return 0;
}

fn onPtyEvent(session: *c.struct_tmate_session) void {
    var buf: [4096]u8 = undefined;

    while (true) {
        const len = c.read(session.pty, &buf[0], buf.len);
        if (len < 0) {
            if (std.c._errno().* == c.EAGAIN) return;
            debug.fatal("pty read error", .{});
        }
        if (len == 0) {
            debug.fatal("pty reached EOF", .{});
        }

        const written = c.ssh_channel_write(session.ssh_client.channel, &buf[0], @intCast(len));
        if (written < 0) {
            debug.fatal("Error writing to channel: %s", .{c.ssh_get_error(session.ssh_client.session)});
        }
        if (len != written) {
            debug.fatal("Cannot write %d bytes, wrote %d", .{ @as(c_int, @intCast(len)), @as(c_int, @intCast(written)) });
        }
    }
}

fn onPtyEventCb(_: c.evutil_socket_t, _: c_short, arg: ?*anyopaque) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(arg.?));
    onPtyEvent(session);
}

fn tmateFlushPty(session: *c.struct_tmate_session) void {
    onPtyEvent(session);
    _ = c.close(session.pty);
}

fn tmateClientPtyInit(session: *c.struct_tmate_session) void {
    const client = &session.ssh_client;

    _ = c.ioctl(session.pty, c.TIOCSWINSZ, &session.ssh_client.winsize_pty);

    client.channel_cb = std.mem.zeroes(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.size = @sizeOf(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.userdata = session;
    client.channel_cb.channel_data_function = onSshChannelRead;
    _ = c.ssh_set_channel_callbacks(client.channel, &client.channel_cb);

    c.ssh_set_message_callback(session.ssh_client.session, onSshMessageCallback, session);

    c.setblocking(session.pty, 0);
    c.event_set(&session.ev_pty, session.pty, c.EV_READ | c.EV_PERSIST, onPtyEventCb, session);
    _ = c.event_add(&session.ev_pty, null);
}

fn randomSleep() void {
    var ts: c.struct_timespec = undefined;
    ts.tv_sec = 0;
    const r = @rem(@abs(rand.tmate_get_random_long()), 150000000);
    ts.tv_nsec = @intCast(50000000 + r);
    _ = c.nanosleep(&ts, null);
}

fn sshEcho(ssh_client: *c.struct_tmate_ssh_client, str: [*:0]const u8) void {
    _ = c.ssh_channel_write(ssh_client.channel, str, @intCast(c.strlen(str)));
}

const valid_digits = "abcdefghijklmnopqrstuvwxyz" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "0123456789-_/";

pub export fn tmate_validate_session_token(token: ?[*:0]const u8) c_int {
    const tok = token orelse return -1;
    const slice = std.mem.span(tok);
    if (slice.len <= 2) return -1;

    for (slice) |ch| {
        if (std.mem.indexOfScalar(u8, valid_digits, ch) == null) {
            return -1;
        }
    }
    return 0;
}

pub export fn tmate_spawn_pty_client(session: ?*c.struct_tmate_session) void {
    const sess = session orelse return;
    const client = &sess.ssh_client;

    var attach_str = "attach".*;
    var r_str = "-r".*;
    var argv_rw = [_]?[*:0]u8{ @ptrCast(&attach_str), null };
    var argv_ro = [_]?[*:0]u8{ @ptrCast(&attach_str), @ptrCast(&r_str), null };
    var argv: [*]?[*:0]u8 = &argv_rw;
    var argc: c_int = 1;

    const token = client.username;
    if (tmate_validate_session_token(token) < 0) {
        sshEcho(client, BAD_TOKEN_ERROR_STR);
        debug.fatal("Invalid token", .{});
    }

    c.set_session_token(sess, token);

    debug.info("Spawning pty client ip=%s", .{@as([*:0]const u8, @ptrCast(&client.ip_address[0]))});

    sess.tmux_socket_fd = c.client_connect(sess.ev_base, c.socket_path, 0);
    if (sess.tmux_socket_fd < 0) {
        if (c.tmate_has_websocket()) {
            client.exec_command = c.xstrdup("explain-session-not-found");
            c.tmate_spawn_exec(sess);
        }

        randomSleep();
        sshEcho(client, EXPIRED_TOKEN_ERROR_STR);
        debug.fatal("Expired token", .{});
    }

    sess.readonly = false;
    var fstat: c.struct_stat = undefined;
    if (c.lstat(c.socket_path, &fstat) < 0) {
        debug.fatal("Cannot fstat()", .{});
    }
    if ((fstat.st_mode & c.S_IFMT) == c.S_IFLNK) {
        sess.readonly = true;
        argv = &argv_ro;
        argc = 2;
    }

    var slave_pty: c_int = -1;
    if (c.openpty(&sess.pty, &slave_pty, null, null, null) < 0) {
        debug.fatal("Cannot allocate pty", .{});
    }

    _ = c.dup2(slave_pty, c.STDIN_FILENO);
    _ = c.dup2(slave_pty, c.STDOUT_FILENO);
    _ = c.dup2(slave_pty, c.STDERR_FILENO);

    c.setup_ncurse(slave_pty, "screen-256color");

    tmateClientPtyInit(sess);

    const log_fd: c_int = if (c.log_file != null) c.fileno(c.log_file) else -1;
    var fds = [_]c_int{
        c.STDIN_FILENO,
        c.STDOUT_FILENO,
        c.STDERR_FILENO,
        sess.tmux_socket_fd,
        c.ssh_get_fd(sess.ssh_client.session),
        sess.pty,
        log_fd,
    };
    c.close_fds_except(&fds[0], 7);
    c.get_in_jail();
    _ = c.event_reinit(sess.ev_base);

    const ret = c.client_main(sess.ev_base, argc, @ptrCast(argv), c.CLIENT_UTF8 | c.CLIENT_256COLOURS, null);
    tmateFlushPty(sess);
    c.exit(ret);
}
