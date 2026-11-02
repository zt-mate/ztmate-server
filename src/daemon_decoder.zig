const std = @import("std");
const c = @import("c.zig").c;
const protocol = @import("protocol.zig");
const msgpack = @import("msgpack.zig");
const debug = @import("debug.zig");

pub export var tmate_left_status: ?[*:0]u8 = null;
pub export var tmate_right_status: ?[*:0]u8 = null;

extern var next_window_pane_id: c_uint;

const AUTHORIZED_KEYS_ONLY_ERROR_MSG_1 = "Server requires authorized_keys but none are given.";
const AUTHORIZED_KEYS_ONLY_ERROR_MSG_2 = "Use '-a FILENAME' to specify an authorized_keys file.";
const AUTHORIZED_KEYS_ONLY_ERROR_MSG_3 = "Press <Ctrl-c><Ctrl-d> to exit.";

fn tmateReady(session: *c.struct_tmate_session, _: ?*c.struct_tmate_unpacker) void {
    if (session.authorized_keys != null) {
        const count = c.get_num_authorized_keys(session.authorized_keys);
        debug.info("Restricting ssh access, num_keys=%d", .{count});
    } else if (c.tmate_settings.*.authorized_keys_only) {
        c.tmate_notify("%s", AUTHORIZED_KEYS_ONLY_ERROR_MSG_1);
        c.tmate_notify("%s", AUTHORIZED_KEYS_ONLY_ERROR_MSG_2);
        c.tmate_notify("%s", AUTHORIZED_KEYS_ONLY_ERROR_MSG_3);
        c.tmate_notify("%s", "");
        c.server_send_exit();
    }
    c.server_add_accept(0);
}

fn tmateHeader(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    session.client_protocol_version = @intCast(msgpack.unpack_int(uk));

    if (session.client_protocol_version >= 3) {
        session.client_version = msgpack.unpack_string(uk);
    } else {
        session.client_version = c.xstrdup("1.8.5");
    }

    if (session.client_protocol_version < 6) {
        tmateReady(session, null);
    }

    if (session.client_protocol_version < 5) {
        session.daemon_encoder.mpac_version = 4;
    }

    debug.info("ztmate version=%s, protocol=%d", .{
        session.client_version,
        session.client_protocol_version,
    });

    if (c.tmate_has_websocket()) {
        c.tmate_send_websocket_header(session);
        return;
    }

    var ssh_conn_str = c.get_ssh_conn_string(session.session_token_ro);
    c.tmate_notify("Note: clear your terminal before sharing readonly access");
    c.tmate_notify("ssh session read only: %s", ssh_conn_str);
    c.tmate_set_env("ztmate_ssh_ro", ssh_conn_str);
    c.free(ssh_conn_str);

    ssh_conn_str = c.get_ssh_conn_string(session.session_token);
    c.tmate_notify("ssh session: %s", ssh_conn_str);
    c.tmate_set_env("ztmate_ssh", ssh_conn_str);
    c.free(ssh_conn_str);

    c.tmate_send_client_ready();
}

fn tmateUname(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const sysname = msgpack.unpack_string(uk);
    const nodename = msgpack.unpack_string(uk);
    const release = msgpack.unpack_string(uk);
    const version = msgpack.unpack_string(uk);
    const machine = msgpack.unpack_string(uk);
    debug.info("sysname=%s machine=%s release=%s version=%s nodename=%s", .{
        sysname,
        machine,
        release,
        version,
        nodename,
    });
    c.free(sysname);
    c.free(nodename);
    c.free(release);
    c.free(version);
    c.free(machine);
}

fn tmateSyncWindowPanes(w: *c.struct_window, w_uk: *c.struct_tmate_unpacker, num_panes: *c_int) void {
    var uk: c.struct_tmate_unpacker = undefined;
    var tmp_uk: c.struct_tmate_unpacker = undefined;

    var wp = w.panes.tqh_first;
    while (wp != null) : (wp = wp.*.entry.tqe_next) {
        wp.*.flags |= c.PANE_KILL;
    }

    msgpack.unpack_array(w_uk, &tmp_uk);
    while (tmp_uk.argc > 0) {
        msgpack.unpack_array(&tmp_uk, &uk);
        num_panes.* += 1;
        if (num_panes.* > c.TMATE_MAX_PANES) {
            debug.fatal("Too many opened panes (max=%d)", .{@as(c_int, c.TMATE_MAX_PANES)});
        }

        const id: c_uint = @intCast(msgpack.unpack_int(&uk));
        const sx: c_uint = @intCast(msgpack.unpack_int(&uk));
        const sy: c_uint = @intCast(msgpack.unpack_int(&uk));
        const xoff: c_uint = @intCast(msgpack.unpack_int(&uk));
        const yoff: c_uint = @intCast(msgpack.unpack_int(&uk));

        var pane = c.window_pane_find_by_id(id);
        if (pane != null and pane.*.window != w) {
            debug.fatal("Pane id=%u in the wrong window", .{id});
        }

        if (pane == null) {
            next_window_pane_id = id;
            pane = c.window_add_pane(w, c.TMATE_HLIMIT);
            _ = c.window_set_active_pane(w, pane);
        }
        pane.*.flags &= ~@as(c_int, c.PANE_KILL);

        if (pane.*.xoff != xoff or pane.*.yoff != yoff or
            pane.*.sx != sx or pane.*.sx != sy)
        {
            pane.*.xoff = xoff;
            pane.*.yoff = yoff;
            c.window_pane_resize(pane, sx, sy);
            pane.*.flags |= c.PANE_REDRAW;
        }
    }

    wp = w.panes.tqh_first;
    while (wp != null) {
        const wp_tmp = wp.*.entry.tqe_next;
        if ((wp.*.flags & c.PANE_KILL) != 0) {
            c.window_remove_pane(w, wp);
        }
        wp = wp_tmp;
    }

    const active_pane_id: c_uint = @intCast(msgpack.unpack_int(w_uk));
    const active_wp = c.window_pane_find_by_id(active_pane_id);
    if (active_wp == null or active_wp.*.window != w) {
        debug.fatal("Invalid active_pane_id recevied", .{});
    }
    _ = c.window_set_active_pane(w, active_wp);
}

fn tmateSyncWindows(s: *c.struct_session, s_uk: *c.struct_tmate_unpacker) void {
    var uk: c.struct_tmate_unpacker = undefined;
    var tmp_uk: c.struct_tmate_unpacker = undefined;
    var num_panes: c_int = 0;
    var cause: [*c]u8 = null;

    var wl = c.winlinks_RB_MINMAX(&s.windows, -1);
    while (wl != null) : (wl = c.winlinks_RB_NEXT(wl)) {
        wl.*.flags |= c.WINLINK_KILL;
    }

    msgpack.unpack_array(s_uk, &tmp_uk);
    while (tmp_uk.argc > 0) {
        msgpack.unpack_array(&tmp_uk, &uk);
        const idx: c_int = @intCast(msgpack.unpack_int(&uk));
        const name = msgpack.unpack_string(&uk);

        var winlink = c.winlink_find_by_index(&s.windows, idx);
        if (winlink == null) {
            winlink = c.session_new(s, name, 0, null, null, null, idx, &cause);
            if (winlink == null) {
                debug.fatal("can't create window idx=%d", .{idx});
            }
        }

        winlink.*.flags &= ~@as(c_int, c.WINLINK_KILL);
        const w = winlink.*.window;

        c.free(w.*.name);
        w.*.name = name;
        w.*.sx = s.sx;
        w.*.sy = s.sy;

        tmateSyncWindowPanes(w, &uk, &num_panes);
    }

    wl = c.winlinks_RB_MINMAX(&s.windows, -1);
    while (wl != null) {
        const wl_tmp = c.winlinks_RB_NEXT(wl);
        if ((wl.*.flags & c.WINLINK_KILL) != 0) {
            _ = c.session_detach(s, wl);
        }
        wl = wl_tmp;
    }

    const active_window_idx: c_int = @intCast(msgpack.unpack_int(s_uk));
    const active_wl = c.winlink_find_by_index(&s.windows, active_window_idx);
    if (active_wl == null) {
        debug.fatal("no valid active window", .{});
    }

    _ = c.session_set_current(s, active_wl);
    c.server_redraw_window(active_wl.*.window);
}

fn tmateSyncLayout(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var cause: [*c]u8 = null;
    const sx: c_uint = @intCast(msgpack.unpack_int(uk));
    const sy: c_uint = @intCast(msgpack.unpack_int(uk));

    var s = c.sessions_RB_MINMAX(&c.sessions, -1);
    if (s == null) {
        s = c.session_create("default", -1, null, "/", "/", null, null, 0, sx, sy, &cause);
        if (s == null) {
            debug.fatal("can't create main session", .{});
        }
    }

    s.*.sx = sx;
    s.*.sy = sy;

    tmateSyncWindows(s, uk);
}

fn tmatePtyData(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var buf: ?[*]const u8 = null;
    var len: usize = 0;

    const id: c_uint = @intCast(msgpack.unpack_int(uk));
    msgpack.unpack_buffer(uk, &buf, &len);

    const wp = c.window_pane_find_by_id(id);
    if (wp == null) {
        debug.fatal("can't find pane id=%d (pty_data)", .{id});
    }

    _ = c.evbuffer_add(wp.*.event_input, buf, len);
    c.input_parse(wp);

    wp.*.window.*.flags |= c.WINDOW_SILENCE;
}

fn tmateExecCmdStr(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var cmdlist: [*c]c.struct_cmd_list = null;
    var cause: [*c]u8 = null;

    const cmd_str = msgpack.unpack_string(uk);
    defer c.free(cmd_str);

    debug.debug("Local cmd: %s", .{cmd_str});

    if (c.cmd_string_parse(cmd_str, &cmdlist, null, 0, &cause) != 0) {
        debug.debug("parse error: %s", .{cause});
        c.free(cause);
        return;
    }

    const cmd_q = c.cmdq_new(null);
    c.cmdq_run(cmd_q, cmdlist, null);
    c.cmd_list_free(cmdlist);
    _ = c.cmdq_free(cmd_q);
}

fn tmateExecCmd(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var cause: [*c]u8 = null;
    const argc: c_int = @intCast(uk.argc);
    const argv: [*]?[*:0]u8 = @ptrCast(@alignCast(c.xmalloc(@sizeOf(?[*:0]u8) * @as(usize, @intCast(argc)))));
    defer c.cmd_free_argv(argc, @ptrCast(argv));

    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        argv[i] = msgpack.unpack_string(uk);
    }

    const cmd = c.cmd_parse(argc, @ptrCast(argv), null, 0, &cause);
    if (cmd == null) {
        debug.debug("parse error: %s", .{cause});
        c.free(cause);
        return;
    }

    const cmd_str = c.cmd_print(cmd);
    debug.debug("Local cmd: %s", .{cmd_str});
    c.free(cmd_str);

    const cmdlist: *c.struct_cmd_list = @ptrCast(@alignCast(c.xcalloc(1, @sizeOf(c.struct_cmd_list))));
    cmdlist.references = 1;
    cmdlist.list.tqh_first = null;
    cmdlist.list.tqh_last = &cmdlist.list.tqh_first;

    cmd.*.qentry.tqe_next = null;
    cmd.*.qentry.tqe_prev = cmdlist.list.tqh_last;
    cmdlist.list.tqh_last.* = cmd;
    cmdlist.list.tqh_last = &cmd.*.qentry.tqe_next;

    const cmd_q = c.cmdq_new(null);
    c.cmdq_run(cmd_q, cmdlist, null);
    c.cmd_list_free(cmdlist);
    _ = c.cmdq_free(cmd_q);
}

fn tmateFailedCmd(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const client_id: c_int = @intCast(msgpack.unpack_int(uk));
    const cause = msgpack.unpack_string(uk);
    defer c.free(cause);

    var cl = c.clients.tqh_first;
    while (cl != null) : (cl = cl.*.entry.tqe_next) {
        if (cl.*.id == client_id) {
            if (cause) |cs| {
                cs[0] = std.ascii.toUpper(cs[0]);
                c.status_message_set(cl, "%s", cs);
            }
            break;
        }
    }
}

fn tmateStatus(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    c.free(tmate_left_status);
    c.free(tmate_right_status);
    tmate_left_status = msgpack.unpack_string(uk);
    tmate_right_status = msgpack.unpack_string(uk);

    var cl = c.clients.tqh_first;
    while (cl != null) : (cl = cl.*.entry.tqe_next) {
        cl.*.flags |= c.CLIENT_STATUS;
    }
}

fn tmateSyncCopyMode(session: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var cm_uk: c.struct_tmate_unpacker = undefined;
    var sel_uk: c.struct_tmate_unpacker = undefined;
    var input_uk: c.struct_tmate_unpacker = undefined;
    var base_backing: c_int = 1;

    const pane_id: c_uint = @intCast(msgpack.unpack_int(uk));
    const wp = c.window_pane_find_by_id(pane_id);
    if (wp == null) {
        debug.fatal("can't find window pane=%d", .{pane_id});
    }

    msgpack.unpack_array(uk, &cm_uk);

    if (cm_uk.argc == 0) {
        if (wp.*.mode != null) {
            const data: *c.struct_window_copy_mode_data = @ptrCast(@alignCast(wp.*.modedata));
            c.free(@constCast(data.inputprompt));
            c.window_pane_reset_mode(wp);
        }
        return;
    }

    if (session.client_protocol_version >= 2) {
        base_backing = @intCast(msgpack.unpack_int(&cm_uk));
    }

    if (c.window_pane_set_mode(wp, &c.window_copy_mode) == 0) {
        if (base_backing != 0) {
            c.window_copy_init_from_pane(wp, 0);
        } else {
            c.window_copy_init_for_output(wp);
        }
    }
    const data: *c.struct_window_copy_mode_data = @ptrCast(@alignCast(wp.*.modedata));

    data.oy = @intCast(msgpack.unpack_int(&cm_uk));
    data.cx = @intCast(msgpack.unpack_int(&cm_uk));
    data.cy = @intCast(msgpack.unpack_int(&cm_uk));

    msgpack.unpack_array(&cm_uk, &sel_uk);

    if (sel_uk.argc != 0) {
        data.screen.sel.flag = 1;
        data.selx = @intCast(msgpack.unpack_int(&sel_uk));
        if (session.client_protocol_version >= 2) {
            const raw_sely: c_int = @intCast(msgpack.unpack_int(&sel_uk));
            const hsize: c_int = @intCast(data.backing.*.grid.*.hsize);
            const sy: c_int = @intCast(data.backing.*.grid.*.sy);
            data.sely = @intCast(-raw_sely + hsize + sy - 1);
        } else {
            data.sely = @intCast(msgpack.unpack_int(&sel_uk));
        }
        data.rectflag = @intCast(msgpack.unpack_int(&sel_uk));
    } else {
        data.screen.sel.flag = 0;
    }

    msgpack.unpack_array(&cm_uk, &input_uk);

    if (input_uk.argc != 0) {
        data.inputtype = @intCast(msgpack.unpack_int(&input_uk));

        c.free(@constCast(data.inputprompt));
        data.inputprompt = msgpack.unpack_string(&input_uk);

        c.free(data.inputstr);
        data.inputstr = msgpack.unpack_string(&input_uk);
    } else {
        data.inputtype = c.WINDOW_COPY_OFF;
        c.free(@constCast(data.inputprompt));
        data.inputprompt = null;
    }

    _ = c.window_copy_update_selection(wp, 1);
    c.window_copy_redraw_screen(wp);
}

fn tmateWriteCopyMode(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    const id: c_uint = @intCast(msgpack.unpack_int(uk));
    const wp = c.window_pane_find_by_id(id);
    if (wp == null) {
        debug.fatal("can't find pane id=%d (copy_mode)", .{id});
    }

    const str = msgpack.unpack_string(uk);
    defer c.free(str);

    if (c.window_pane_set_mode(wp, &c.window_copy_mode) == 0) {
        c.window_copy_init_for_output(wp);
    }

    c.window_copy_add(wp, "%s", str);
}

fn tmateFin(session: *c.struct_tmate_session, _: *c.struct_tmate_unpacker) void {
    session.fin_received = true;
    c.request_server_termination();
}

fn tmateReconnect(_: *c.struct_tmate_session, _: *c.struct_tmate_unpacker) void {
    if (!c.tmate_has_websocket()) {
        debug.fatal("Cannot do reconnections without the websocket server", .{});
    }
}

fn restoreSnapshotGrid(grid: *c.struct_grid, uk: *c.struct_tmate_unpacker) void {
    var gc: c.struct_grid_cell = undefined;
    var lines_uk: c.struct_tmate_unpacker = undefined;
    var line_uk: c.struct_tmate_unpacker = undefined;
    var line_flags_uk: c.struct_tmate_unpacker = undefined;

    msgpack.unpack_array(uk, &lines_uk);
    var line_i: c_uint = 0;
    while (lines_uk.argc > 0) : (line_i += 1) {
        while (line_i >= grid.hsize + grid.sy) {
            c.grid_scroll_history(grid);
        }

        msgpack.unpack_array(&lines_uk, &line_uk);
        const line_str = msgpack.unpack_string(&line_uk);
        const utf8_data = c.utf8_fromcstr(line_str);
        c.free(line_str);

        msgpack.unpack_array(&line_uk, &line_flags_uk);
        var i: c_uint = 0;
        while (line_flags_uk.argc > 0) : (i += 1) {
            c.utf8_copy(&gc.data, &utf8_data[i]);
            const packed_flags: u32 = @intCast(msgpack.unpack_int(&line_flags_uk));
            gc.flags = @intCast((packed_flags >> 24) & 0xFF);
            gc.attr = @intCast((packed_flags >> 16) & 0xFF);
            gc.unnamed_1.bg = @intCast((packed_flags >> 8) & 0xFF);
            gc.unnamed_0.fg = @intCast(packed_flags & 0xFF);
            c.grid_set_cell(grid, i, line_i, &gc);
        }
        c.free(utf8_data);
    }
}

fn restoreSnapshotPane(uk: *c.struct_tmate_unpacker) void {
    var grid_uk: c.struct_tmate_unpacker = undefined;

    const id: c_uint = @intCast(msgpack.unpack_int(uk));
    const wp = c.window_pane_find_by_id(id);
    if (wp == null) {
        debug.fatal("can't find pane id=%d (snapshot restore)", .{id});
    }
    const screen = &wp.*.base;
    c.screen_reinit(screen);
    wp.*.flags |= c.PANE_REDRAW;

    screen.*.mode = @intCast(msgpack.unpack_int(uk));

    msgpack.unpack_array(uk, &grid_uk);
    screen.*.cx = @intCast(msgpack.unpack_int(&grid_uk));
    screen.*.cy = @intCast(msgpack.unpack_int(&grid_uk));
    c.grid_clear_history(screen.*.grid);
    restoreSnapshotGrid(screen.*.grid, &grid_uk);

    if (wp.*.saved_grid != null) {
        c.grid_destroy(wp.*.saved_grid);
        wp.*.saved_grid = null;
    }

    if (msgpack.unpack_peek_type(uk) == c.MSGPACK_OBJECT_NIL) {
        return;
    }

    msgpack.unpack_array(uk, &grid_uk);
    wp.*.saved_cx = @intCast(msgpack.unpack_int(&grid_uk));
    wp.*.saved_cy = @intCast(msgpack.unpack_int(&grid_uk));
    wp.*.saved_grid = c.grid_create(screen.*.grid.*.sx, screen.*.grid.*.sy, 0);
    restoreSnapshotGrid(wp.*.saved_grid, &grid_uk);
}

fn tmateSnapshot(_: *c.struct_tmate_session, uk: *c.struct_tmate_unpacker) void {
    var panes_uk: c.struct_tmate_unpacker = undefined;
    var pane_uk: c.struct_tmate_unpacker = undefined;

    msgpack.unpack_array(uk, &panes_uk);
    while (panes_uk.argc > 0) {
        msgpack.unpack_array(&panes_uk, &pane_uk);
        restoreSnapshotPane(&pane_uk);
    }
}

pub export fn tmate_dispatch_daemon_message(
    session: ?*c.struct_tmate_session,
    uk_in: ?*c.struct_tmate_unpacker,
) void {
    const sess = session orelse return;
    const u_in = uk_in orelse return;
    var uk_copy = u_in.*;
    const uk = &uk_copy;

    const cmd: c_int = @intCast(msgpack.unpack_int(uk));
    const msg_type = std.enums.fromInt(protocol.TmateDaemonOutMsgTypes, cmd) orelse {
        debug.fatal("Bad message type: %d", .{cmd});
    };

    switch (msg_type) {
        .TMATE_OUT_HEADER => tmateHeader(sess, uk),
        .TMATE_OUT_SYNC_LAYOUT => tmateSyncLayout(sess, uk),
        .TMATE_OUT_PTY_DATA => tmatePtyData(sess, uk),
        .TMATE_OUT_EXEC_CMD_STR => tmateExecCmdStr(sess, uk),
        .TMATE_OUT_FAILED_CMD => tmateFailedCmd(sess, uk),
        .TMATE_OUT_STATUS => tmateStatus(sess, uk),
        .TMATE_OUT_SYNC_COPY_MODE => tmateSyncCopyMode(sess, uk),
        .TMATE_OUT_WRITE_COPY_MODE => tmateWriteCopyMode(sess, uk),
        .TMATE_OUT_FIN => tmateFin(sess, uk),
        .TMATE_OUT_READY => tmateReady(sess, uk),
        .TMATE_OUT_RECONNECT => tmateReconnect(sess, uk),
        .TMATE_OUT_SNAPSHOT => tmateSnapshot(sess, uk),
        .TMATE_OUT_EXEC_CMD => tmateExecCmd(sess, uk),
        .TMATE_OUT_UNAME => tmateUname(sess, uk),
    }
}
