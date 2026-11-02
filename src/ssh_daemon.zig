const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");
const rand = @import("rand.zig");
const msgpack = @import("msgpack.zig");

pub export var _tmate_session: c.struct_tmate_session = std.mem.zeroes(c.struct_tmate_session);
pub export var tmate_session: *c.struct_tmate_session = &_tmate_session;

fn onDaemonDecoderRead(userdata: ?*anyopaque, uk: ?*c.struct_tmate_unpacker) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    c.tmate_dispatch_daemon_message(session, uk);
    c.tmate_send_websocket_daemon_msg(session, uk);
}

fn onSshChannelRead(
    _: c.ssh_session,
    _: c.ssh_channel,
    _data: ?*anyopaque,
    total_len_in: u32,
    _: c_int,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    var data: [*]const u8 = @ptrCast(_data orelse return 0);
    var total_len: usize = total_len_in;
    var written: usize = 0;
    var buf: ?[*]u8 = null;
    var len: usize = 0;

    while (total_len > 0) {
        msgpack.tmate_decoder_get_buffer(&session.daemon_decoder, &buf, &len);
        if (len == 0) {
            debug.fatal("No more room in client decoder. Message too big?", .{});
        }
        if (len > total_len) {
            len = total_len;
        }
        @memcpy(buf.?[0..len], data[0..len]);
        msgpack.tmate_decoder_commit(&session.daemon_decoder, len);

        total_len -= len;
        written += len;
        data += len;
    }

    return @intCast(written);
}

fn onDaemonEncoderWrite(userdata: ?*anyopaque, buffer: ?*c.struct_evbuffer) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    const buf_ev = buffer orelse return;

    while (true) {
        const len = c.evbuffer_get_length(buf_ev);
        if (len == 0) break;

        const buf = c.evbuffer_pullup(buf_ev, -1);
        const written = c.ssh_channel_write(session.ssh_client.channel, buf, @intCast(len));
        if (written < 0) {
            debug.info("Error writing to channel: %s", .{c.ssh_get_error(session.ssh_client.session)});
            c.request_server_termination();
            break;
        }

        _ = c.evbuffer_drain(buf_ev, @intCast(written));
    }
}

fn tmateDaemonInit(session: *c.struct_tmate_session) void {
    const client = &session.ssh_client;

    client.channel_cb = std.mem.zeroes(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.size = @sizeOf(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.userdata = session;
    client.channel_cb.channel_data_function = onSshChannelRead;
    _ = c.ssh_set_channel_callbacks(client.channel, &client.channel_cb);

    msgpack.tmate_encoder_init(&session.daemon_encoder, onDaemonEncoderWrite, session);
    msgpack.tmate_decoder_init(&session.daemon_decoder, onDaemonDecoderRead, session);

    c.tmate_init_websocket(session, null);
}

fn handleSigterm(_: c_int) callconv(.c) void {
    c.request_server_termination();
}

const rand_tmate_token_digits = "abcdefghjkmnpqrstuvwxyz" ++
    "ABCDEFGHJKLMNPQRSTUVWXYZ" ++
    "23456789";
const NUM_DIGITS = rand_tmate_token_digits.len;

fn getRandomToken() [*:0]u8 {
    var rs: c.struct_random_stream = undefined;
    const token: [*]u8 = @ptrCast(c.xmalloc(c.TMATE_TOKEN_LEN + 1));

    rand.random_stream_init(&rs);

    var i: usize = 0;
    while (i < c.TMATE_TOKEN_LEN) : (i += 1) {
        var ch: u8 = undefined;
        while (true) {
            ch = rand.random_stream_get(&rs, 1).?[0];
            if (ch < NUM_DIGITS) break;
        }
        token[i] = rand_tmate_token_digits[ch];
    }
    token[c.TMATE_TOKEN_LEN] = 0;
    return @ptrCast(token);
}

fn createSessionRoSymlink(session: *c.struct_tmate_session) void {
    const tmp = getRandomToken();
    var token: [*c]u8 = null;
    _ = c.xasprintf(&token, "ro-%s", tmp);
    c.free(tmp);

    session.session_token_ro = token;

    var session_ro_path: [*c]u8 = null;
    _ = c.xasprintf(&session_ro_path, c.TMATE_WORKDIR ++ "/sessions/%s", session.session_token_ro);

    _ = c.unlink(session_ro_path);
    if (c.symlink(session.session_token, session_ro_path) < 0) {
        debug.fatal("Cannot create read-only symlink", .{});
    }
    c.free(session_ro_path);
}

pub export fn tmate_spawn_daemon(session: ?*c.struct_tmate_session) void {
    const sess = session orelse return;
    const client = &sess.ssh_client;

    const token = getRandomToken();
    c.set_session_token(sess, token);
    c.free(token);

    debug.info("Spawning daemon ip=%s", .{@as([*:0]const u8, @ptrCast(&client.ip_address[0]))});

    sess.tmux_socket_fd = c.server_create_socket();
    if (sess.tmux_socket_fd < 0) {
        debug.fatal("Cannot create to the tmux socket", .{});
    }

    createSessionRoSymlink(sess);

    c.setup_ncurse(c.STDOUT_FILENO, "screen-256color");

    tmateDaemonInit(sess);

    const log_fd: c_int = if (c.log_file != null) c.fileno(c.log_file) else -1;
    var fds = [_]c_int{
        sess.tmux_socket_fd,
        c.ssh_get_fd(sess.ssh_client.session),
        log_fd,
        sess.websocket_fd,
    };
    c.close_fds_except(&fds[0], 4);

    c.get_in_jail();
    _ = c.event_reinit(sess.ev_base);

    c.tmux_server_init();
    _ = c.signal(c.SIGTERM, handleSigterm);
    _ = c.server_start(sess.ev_base, -1, null);
}

var warned_named_session: bool = false;

fn handleSessionNameOptions(name: [*:0]const u8, _: ?[*:0]const u8) void {
    if (c.tmate_has_websocket()) return;

    const s = std.mem.span(name);
    if (std.mem.eql(u8, s, "ztmate-api-key") or
        std.mem.eql(u8, s, "ztmate-session-name") or
        std.mem.eql(u8, s, "ztmate-session-name-ro") or
        std.mem.eql(u8, s, "tmate-api-key") or
        std.mem.eql(u8, s, "tmate-session-name") or
        std.mem.eql(u8, s, "tmate-session-name-ro"))
    {
        if (!warned_named_session) {
            debug.info("Named sessions are not supported (no websocket server)", .{});
            c.tmate_notify("Named sessions are not supported (no websocket server)");
        }
        warned_named_session = true;
    }
}

pub export fn tmate_hook_set_option(name: ?[*:0]const u8, val: ?[*:0]const u8) void {
    const n = name orelse return;
    c.tmate_hook_set_option_auth(n, val);
    handleSessionNameOptions(n, val);
}
