const std = @import("std");
const c = @import("c.zig").c;
const protocol = @import("protocol.zig");
const msgpack = @import("msgpack.zig");
const debug = @import("debug.zig");

extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c.socklen_t) c_int;

const CONTROL_PROTOCOL_VERSION = 2;

inline fn pk() *c.msgpack_packer {
    return &c.tmate_session.*.websocket_encoder.pk;
}

fn packStringOrNil(str: ?[*:0]const u8) void {
    if (str) |s| {
        msgpack.msgpack_pack_string(pk(), s);
    } else {
        _ = c.msgpack_pack_nil(pk());
    }
}

fn ctlDaemonFwdMsg(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    if (uk.argc != 1) {
        msgpack.tmate_decoder_error();
    }
    c.tmate_send_mc_obj(&uk.argv[0]);
}

fn doSnapshot(_: *c.struct_tmate_unpacker, max_history_lines: c_uint, pane: *c.struct_window_pane) void {
    var gc: c.struct_grid_cell = undefined;
    const screen = &pane.base;
    const grid = screen.grid;

    _ = c.msgpack_pack_array(pk(), 4);
    _ = c.msgpack_pack_int(pk(), @bitCast(pane.id));

    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @bitCast(screen.cx));
    _ = c.msgpack_pack_int(pk(), @bitCast(screen.cy));

    _ = c.msgpack_pack_unsigned_int(pk(), @bitCast(screen.mode));

    const max_lines = max_history_lines + grid.*.sy;
    const total_lines = grid.*.hsize + grid.*.sy;
    var line_i: c_uint = if (total_lines > max_lines) total_lines - max_lines else 0;

    _ = c.msgpack_pack_array(pk(), total_lines - line_i);
    while (line_i < total_lines) : (line_i += 1) {
        const line = &grid.*.linedata[line_i];

        _ = c.msgpack_pack_array(pk(), 2);
        var str_len: usize = 0;
        var i: c_uint = 0;
        while (i < line.cellsize) : (i += 1) {
            c.grid_get_cell(grid, i, line_i, &gc);
            str_len += gc.data.size;
        }

        _ = c.msgpack_pack_str(pk(), str_len);
        i = 0;
        while (i < line.cellsize) : (i += 1) {
            c.grid_get_cell(grid, i, line_i, &gc);
            _ = c.msgpack_pack_str_body(pk(), &gc.data.data[0], gc.data.size);
        }

        _ = c.msgpack_pack_array(pk(), line.cellsize);
        i = 0;
        while (i < line.cellsize) : (i += 1) {
            c.grid_get_cell(grid, i, line_i, &gc);
            const packed_val: c_uint = (@as(c_uint, gc.flags) << 24) |
                (@as(c_uint, gc.attr) << 16) |
                (@as(c_uint, gc.unnamed_1.bg) << 8) |
                @as(c_uint, gc.unnamed_0.fg);
            _ = c.msgpack_pack_unsigned_int(pk(), packed_val);
        }
    }
}

fn ctlDaemonRequestSnapshot(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const max_history_lines: c_uint = @intCast(msgpack.unpack_int(uk));

    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_SNAPSHOT));

    const s = c.sessions_RB_MINMAX(&c.sessions, -1);
    if (s == null) {
        debug.fatal("no session?", .{});
    }

    var num_panes: usize = 0;
    var wl = c.winlinks_RB_MINMAX(&s.*.windows, -1);
    while (wl != null) : (wl = c.winlinks_RB_NEXT(wl)) {
        const w = wl.*.window orelse continue;
        var pane = w.*.panes.tqh_first;
        while (pane != null) : (pane = pane.*.entry.tqe_next) {
            num_panes += 1;
        }
    }

    _ = c.msgpack_pack_array(pk(), num_panes);
    wl = c.winlinks_RB_MINMAX(&s.*.windows, -1);
    while (wl != null) : (wl = c.winlinks_RB_NEXT(wl)) {
        const w = wl.*.window orelse continue;
        var pane = w.*.panes.tqh_first;
        while (pane != null) : (pane = pane.*.entry.tqe_next) {
            doSnapshot(uk, max_history_lines, pane);
        }
    }
}

fn ctlPaneKeys(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const pane_id: c_int = @intCast(msgpack.unpack_int(uk));
    const str = msgpack.unpack_string(uk);
    defer c.free(str);

    if (str) |s| {
        var i: usize = 0;
        while (s[i] != 0) : (i += 1) {
            c.tmate_client_pane_key(pane_id, s[i]);
        }
    }
}

fn ctlResize(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    session.websocket_sx = @intCast(msgpack.unpack_int(uk));
    session.websocket_sy = @intCast(msgpack.unpack_int(uk));
    c.recalculate_sizes();
}

fn ctlSshExecResponse(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const exit_code: c_int = @intCast(msgpack.unpack_int(uk));
    const message = msgpack.unpack_string(uk);
    defer c.free(message);

    c.tmate_dump_exec_response(session, exit_code, message);
}

fn ctlRenameSession(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const stoken = msgpack.unpack_string(uk);
    const stoken_ro = msgpack.unpack_string(uk);
    defer c.free(stoken);
    defer c.free(stoken_ro);

    c.set_session_token(session, stoken);
}

fn tmateDispatchWebsocketMessage(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const cmd: c_int = @intCast(msgpack.unpack_int(uk));
    const msg_type = std.enums.fromInt(protocol.TmateControlInMsgTypes, cmd) orelse {
        debug.info("Bad websocket server message type: %d", .{cmd});
        return;
    };

    switch (msg_type) {
        .TMATE_CTL_DEAMON_FWD_MSG => ctlDaemonFwdMsg(session, uk),
        .TMATE_CTL_REQUEST_SNAPSHOT => ctlDaemonRequestSnapshot(session, uk),
        .TMATE_CTL_PANE_KEYS => ctlPaneKeys(session, uk),
        .TMATE_CTL_RESIZE => ctlResize(session, uk),
        .TMATE_CTL_EXEC_RESPONSE => ctlSshExecResponse(session, uk),
        .TMATE_CTL_RENAME_SESSION => ctlRenameSession(session, uk),
    }
}

pub export fn tmate_websocket_exec(session: ?*c.struct_tmate_session, command: ?[*:0]const u8) void {
    const sess = session orelse return;
    if (!c.tmate_has_websocket()) return;

    const client = &sess.ssh_client;
    _ = c.msgpack_pack_array(pk(), 5);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_EXEC));
    msgpack.msgpack_pack_string(pk(), client.username);
    msgpack.msgpack_pack_string(pk(), @ptrCast(&client.ip_address[0]));
    packStringOrNil(client.pubkey);
    msgpack.msgpack_pack_string(pk(), command);
}

pub export fn tmate_notify_client_join(_: ?*c.struct_tmate_session, cl: ?*c.struct_client) void {
    const client = cl orelse return;
    debug.info("Client joined (cid=%d)", .{client.id});

    if (!c.tmate_has_websocket()) return;

    client.flags |= c.CLIENT_TMATE_NOTIFIED_JOIN;

    _ = c.msgpack_pack_array(pk(), 5);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_CLIENT_JOIN));
    _ = c.msgpack_pack_int(pk(), client.id);
    msgpack.msgpack_pack_string(pk(), client.ip_address);
    packStringOrNil(client.pubkey);
    msgpack.msgpack_pack_boolean(pk(), client.readonly != 0);
}

pub export fn tmate_notify_client_left(_: ?*c.struct_tmate_session, cl: ?*c.struct_client) void {
    const client = cl orelse return;
    if ((client.flags & c.CLIENT_IDENTIFIED) == 0) return;

    debug.info("Client left (cid=%d)", .{client.id});

    if (!c.tmate_has_websocket()) return;
    if ((client.flags & c.CLIENT_TMATE_NOTIFIED_JOIN) == 0) return;

    client.flags &= ~@as(c_int, c.CLIENT_TMATE_NOTIFIED_JOIN);

    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_CLIENT_LEFT));
    _ = c.msgpack_pack_int(pk(), client.id);
}

pub export fn tmate_send_websocket_daemon_msg(_: ?*c.struct_tmate_session, uk: ?*c.struct_tmate_unpacker) void {
    const u = uk orelse return;
    if (!c.tmate_has_websocket()) return;

    _ = c.msgpack_pack_array(pk(), 2);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_DEAMON_OUT_MSG));

    _ = c.msgpack_pack_array(pk(), @intCast(u.argc));
    var i: usize = 0;
    while (i < @as(usize, @intCast(u.argc))) : (i += 1) {
        _ = msgpack._msgpack_pack_object(pk(), u.argv[i]);
    }
}

pub export fn tmate_send_websocket_header(session: ?*c.struct_tmate_session) void {
    const sess = session orelse return;
    if (!c.tmate_has_websocket()) return;

    _ = c.msgpack_pack_array(pk(), 9);
    _ = c.msgpack_pack_int(pk(), @intFromEnum(protocol.TmateControlOutMsgTypes.TMATE_CTL_HEADER));
    _ = c.msgpack_pack_int(pk(), CONTROL_PROTOCOL_VERSION);
    msgpack.msgpack_pack_string(pk(), @ptrCast(&sess.ssh_client.ip_address[0]));
    packStringOrNil(sess.ssh_client.pubkey);
    msgpack.msgpack_pack_string(pk(), sess.session_token);
    msgpack.msgpack_pack_string(pk(), sess.session_token_ro);

    const ssh_cmd_fmt = c.get_ssh_conn_string("%s");
    msgpack.msgpack_pack_string(pk(), ssh_cmd_fmt);
    c.free(ssh_cmd_fmt);

    msgpack.msgpack_pack_string(pk(), sess.client_version);
    _ = c.msgpack_pack_int(pk(), sess.client_protocol_version);
}

fn onWebsocketDecoderRead(userdata: ?*anyopaque, uk: ?*c.struct_tmate_unpacker) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    if (uk) |u| {
        tmateDispatchWebsocketMessage(session, u);
    }
}

fn onWebsocketRead(_: ?*c.struct_bufferevent, _session: ?*anyopaque) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(_session.?));
    var buf: ?[*]u8 = null;
    var len: usize = 0;

    const websocket_in = c.bufferevent_get_input(session.bev_websocket);

    while (c.evbuffer_get_length(websocket_in) != 0) {
        msgpack.tmate_decoder_get_buffer(&session.websocket_decoder, &buf, &len);
        if (len == 0) {
            debug.fatal("No more room in client decoder. Message too big?", .{});
        }

        const written = c.evbuffer_remove(websocket_in, buf, len);
        if (written < 0) {
            debug.fatal("Cannot read websocket buffer", .{});
        }

        msgpack.tmate_decoder_commit(&session.websocket_decoder, @intCast(written));
    }
}

fn onWebsocketEncoderWrite(userdata: ?*anyopaque, buffer: ?*c.struct_evbuffer) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(userdata.?));
    const websocket_out = c.bufferevent_get_output(session.bev_websocket);

    if (c.evbuffer_add_buffer(websocket_out, buffer) < 0) {
        debug.fatal("Cannot write to websocket server buffer", .{});
    }
}

fn onWebsocketEventDefault(session: ?*c.struct_tmate_session, events: c_short) callconv(.c) void {
    const sess = session orelse return;
    if ((events & c.BEV_EVENT_EOF) != 0) {
        if (sess.fin_received) {
            c.exit(0);
        }
        debug.fatal("Connection to websocket server closed", .{});
    }

    if ((events & c.BEV_EVENT_ERROR) != 0) {
        const err = std.c._errno().*;
        debug.fatal("Connection to websocket server error: %s", .{c.strerror(err)});
    }
}

fn onWebsocketEvent(_: ?*c.struct_bufferevent, events: c_short, _session: ?*anyopaque) callconv(.c) void {
    const session: *c.struct_tmate_session = @ptrCast(@alignCast(_session.?));
    if (session.on_websocket_error) |cb| {
        cb(session, events);
    }
}

pub export fn tmate_init_websocket(
    session: ?*c.struct_tmate_session,
    on_websocket_error: ?*const c.on_websocket_error_cb,
) void {
    const sess = session orelse return;
    if (!c.tmate_has_websocket()) return;

    sess.websocket_sx = @bitCast(@as(c_int, -1));
    sess.websocket_sy = @bitCast(@as(c_int, -1));

    sess.bev_websocket = c.bufferevent_socket_new(sess.ev_base, sess.websocket_fd, c.BEV_OPT_CLOSE_ON_FREE);
    if (sess.bev_websocket == null) {
        debug.fatal("Cannot setup socket bufferevent", .{});
    }

    sess.on_websocket_error = on_websocket_error orelse onWebsocketEventDefault;

    c.bufferevent_setcb(sess.bev_websocket, onWebsocketRead, null, onWebsocketEvent, sess);
    _ = c.bufferevent_enable(sess.bev_websocket, c.EV_READ | c.EV_WRITE);

    msgpack.tmate_encoder_init(&sess.websocket_encoder, onWebsocketEncoderWrite, sess);
    msgpack.tmate_decoder_init(&sess.websocket_decoder, onWebsocketDecoderRead, sess);
}

fn connectToWebsocket(hostname: [*:0]const u8, port: c_int) c_int {
    const sockfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sockfd < 0) {
        debug.fatal("Cannot create socket", .{});
    }

    const host = c.gethostbyname(hostname);
    if (host == null) {
        debug.fatal("Cannot resolve %s", .{hostname});
    }

    var servaddr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    servaddr.sin_family = @intCast(host.*.h_addrtype);
    const addr_len: usize = @intCast(host.*.h_length);
    const dst_bytes: [*]u8 = @ptrCast(&servaddr.sin_addr);
    const src_bytes: [*]const u8 = @ptrCast(host.*.h_addr_list[0]);
    @memcpy(dst_bytes[0..addr_len], src_bytes[0..addr_len]);
    servaddr.sin_port = std.mem.nativeToBig(u16, @intCast(port));

    if (connect(sockfd, &servaddr, @sizeOf(c.struct_sockaddr_in)) < 0) {
        debug.fatal("Cannot connect to websocket server at %s:%d", .{ hostname, port });
    }

    var flag: c_int = 1;
    if (c.setsockopt(sockfd, c.IPPROTO_TCP, c.TCP_NODELAY, &flag, @sizeOf(c_int)) < 0) {
        debug.fatal("Can't set websocket server socket to TCP_NODELAY", .{});
    }

    if (c.fcntl(sockfd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) {
        debug.fatal("Can't set websocket server socket to non-blocking", .{});
    }

    debug.debug("Connected to websocket server at %s:%d", .{ hostname, port });
    return sockfd;
}

pub export fn tmate_connect_to_websocket() c_int {
    return connectToWebsocket(c.tmate_settings.*.websocket_hostname, c.tmate_settings.*.websocket_port);
}
