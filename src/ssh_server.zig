const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");

extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c.socklen_t) c_int;
extern "c" fn getpeername(fd: c_int, addr: *anyopaque, len: *c.socklen_t) c_int;

pub export fn get_ssh_conn_string(session_token: ?[*:0]const u8) ?[*:0]u8 {
    var port_arg: [16]u8 = std.mem.zeroes([16]u8);
    var ret: [*c]u8 = null;

    const ssh_port_advertized = if (c.tmate_settings.*.ssh_port_advertized == -1)
        c.tmate_settings.*.ssh_port
    else
        c.tmate_settings.*.ssh_port_advertized;

    if (ssh_port_advertized != 22) {
        _ = c.snprintf(&port_arg[0], port_arg.len, " -p%d", ssh_port_advertized);
    }
    _ = c.xasprintf(&ret, "ssh%s %s@%s", @as([*:0]const u8, @ptrCast(&port_arg[0])), session_token, c.tmate_settings.*.tmate_host);
    return @ptrCast(ret);
}

fn ptyRequest(
    _: c.ssh_session,
    _: c.ssh_channel,
    _: ?[*:0]const u8,
    width: c_int,
    height: c_int,
    _: c_int,
    _: c_int,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    client.winsize_pty.ws_col = @intCast(width);
    client.winsize_pty.ws_row = @intCast(height);
    return 0;
}

fn shellRequest(_: c.ssh_session, _: c.ssh_channel, userdata: ?*anyopaque) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    if (client.role != 0) return 1;
    client.role = c.TMATE_ROLE_PTY_CLIENT;
    return 0;
}

fn subsystemRequest(
    _: c.ssh_session,
    _: c.ssh_channel,
    subsystem: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    if (client.role != 0) return 1;
    if (subsystem) |sub| {
        const s = std.mem.span(sub);
        if (std.mem.eql(u8, s, "ztmate") or std.mem.eql(u8, s, "tmate")) {
            client.role = c.TMATE_ROLE_DAEMON;
        }
    }
    return 0;
}

fn execRequest(
    _: c.ssh_session,
    _: c.ssh_channel,
    command: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    if (client.role != 0) return 1;
    if (!c.tmate_has_websocket()) return 1;

    client.role = c.TMATE_ROLE_EXEC;
    client.exec_command = c.xstrdup(command);
    return 0;
}

fn channelOpenRequestCb(session: c.ssh_session, userdata: ?*anyopaque) callconv(.c) c.ssh_channel {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    if (client.username == null) return null;
    if (client.channel != null) return null;

    client.channel = c.ssh_channel_new(session);
    if (client.channel == null) {
        debug.fatal("Error getting channel", .{});
    }

    client.channel_cb = std.mem.zeroes(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.size = @sizeOf(c.struct_ssh_channel_callbacks_struct);
    client.channel_cb.userdata = client;
    client.channel_cb.channel_pty_request_function = ptyRequest;
    client.channel_cb.channel_shell_request_function = shellRequest;
    client.channel_cb.channel_subsystem_request_function = subsystemRequest;
    client.channel_cb.channel_exec_request_function = execRequest;
    _ = c.ssh_set_channel_callbacks(client.channel, &client.channel_cb);

    return client.channel;
}

fn authPubkeyCb(
    _: c.ssh_session,
    user: ?[*:0]const u8,
    pubkey: c.ssh_key,
    signature_state: u8,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));

    switch (signature_state) {
        c.SSH_PUBLICKEY_STATE_VALID => {
            client.username = c.xstrdup(user);
            const key_type = c.ssh_key_type_to_char(c.ssh_key_type(pubkey));

            var b64_key: [*c]u8 = null;
            if (c.ssh_pki_export_pubkey_base64(pubkey, &b64_key) != c.SSH_OK) {
                debug.fatal("error getting public key", .{});
            }

            var pubkey64: [*c]u8 = null;
            _ = c.xasprintf(&pubkey64, "%s %s", key_type, b64_key);
            c.free(b64_key);

            if (!c.would_tmate_session_allow_auth(user, pubkey64)) {
                c.free(pubkey64);
                return c.SSH_AUTH_DENIED;
            }

            client.pubkey = pubkey64;
            return c.SSH_AUTH_SUCCESS;
        },
        c.SSH_PUBLICKEY_STATE_NONE => return c.SSH_AUTH_SUCCESS,
        else => return c.SSH_AUTH_DENIED,
    }
}

fn authNoneCb(_: c.ssh_session, user: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) c_int {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(userdata.?));
    if (!c.would_tmate_session_allow_auth(user, null)) {
        return c.SSH_AUTH_DENIED;
    }

    client.username = c.xstrdup(user);
    client.pubkey = null;
    return c.SSH_AUTH_SUCCESS;
}

var ssh_server_cb: c.struct_ssh_server_callbacks_struct = blk: {
    var cb = std.mem.zeroes(c.struct_ssh_server_callbacks_struct);
    cb.auth_pubkey_function = authPubkeyCb;
    cb.auth_none_function = authNoneCb;
    cb.channel_open_request_session_function = channelOpenRequestCb;
    break :blk cb;
};

fn onSshRead(_: c.evutil_socket_t, _: c_short, arg: ?*anyopaque) callconv(.c) void {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(arg.?));
    _ = c.ssh_execute_message_callbacks(client.session);

    if (c.ssh_is_connected(client.session) == 0) {
        debug.debug("ssh disconnected", .{});
        _ = c.event_del(&client.ev_ssh);
        c.request_server_termination();
    }
}

fn registerOnSshRead(client: *c.struct_tmate_ssh_client) void {
    c.event_set(&client.ev_ssh, c.ssh_get_fd(client.session), c.EV_READ | c.EV_PERSIST, onSshRead, client);
    _ = c.event_add(&client.ev_ssh, null);
}

fn handleSigalrm(_: c_int) callconv(.c) void {
    debug.fatalQuiet("Connection grace period (%ds) passed", .{@as(c_int, c.TMATE_SSH_GRACE_PERIOD)});
}

fn clientBootstrap(_session: *c.struct_tmate_session) void {
    const client = &_session.ssh_client;
    var grace_period: c_long = c.TMATE_SSH_GRACE_PERIOD;
    const session = client.session;

    debug.debug("Bootstrapping ssh client ip=%s", .{@as([*:0]const u8, @ptrCast(&client.ip_address[0]))});

    _session.ev_base = c.osdep_event_init();

    _ = c.setpgid(0, 0);

    {
        var flag: c_int = 1;
        const fd = c.ssh_get_fd(session);
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &flag, @sizeOf(c_int));
        flag = 0x10;
        _ = c.setsockopt(fd, c.IPPROTO_IP, c.IP_TOS, &flag, @sizeOf(c_int));
    }

    _session.websocket_fd = -1;
    if (c.tmate_has_websocket()) {
        _session.websocket_fd = c.tmate_connect_to_websocket();
    }

    ssh_server_cb.userdata = client;
    ssh_server_cb.size = @sizeOf(c.struct_ssh_server_callbacks_struct);
    _ = c.ssh_set_server_callbacks(client.session, &ssh_server_cb);

    _ = c.ssh_options_set(session, c.SSH_OPTIONS_TIMEOUT, &grace_period);
    _ = c.ssh_options_set(session, c.SSH_OPTIONS_COMPRESSION, "yes");

    c.ssh_set_auth_methods(client.session, c.SSH_AUTH_METHOD_NONE | c.SSH_AUTH_METHOD_PUBLICKEY);

    debug.debug("Exchanging DH keys", .{});
    if (c.ssh_handle_key_exchange(session) < 0) {
        debug.fatalQuiet("Error doing the key exchange: %s", .{c.ssh_get_error(session)});
    }

    const mainloop = c.ssh_event_new();
    _ = c.ssh_event_add_session(mainloop, session);

    while (client.role == 0) {
        if (c.ssh_event_dopoll(mainloop, -1) == c.SSH_ERROR) {
            debug.fatalQuiet("Error polling ssh socket: %s", .{c.ssh_get_error(session)});
        }
    }

    _ = c.alarm(0);

    c.start_keepalive_timer(client, c.TMATE_SSH_KEEPALIVE_SEC * 1000);
    registerOnSshRead(client);

    switch (client.role) {
        c.TMATE_ROLE_DAEMON => c.tmate_spawn_daemon(_session),
        c.TMATE_ROLE_PTY_CLIENT => c.tmate_spawn_pty_client(_session),
        c.TMATE_ROLE_EXEC => c.tmate_spawn_exec(_session),
        else => {},
    }
}

fn getClientIpSocket(fd: c_int, dst: [*]u8, len: usize) c_int {
    var sa: c.struct_sockaddr = undefined;
    var sa_len: c.socklen_t = @sizeOf(c.struct_sockaddr);

    if (getpeername(fd, &sa, &sa_len) < 0) return -1;

    switch (sa.sa_family) {
        c.AF_INET => {
            const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(&sa));
            if (c.inet_ntop(c.AF_INET, &sin.sin_addr, dst, @intCast(len)) == null) return -1;
        },
        c.AF_INET6 => {
            const sin6: *const c.struct_sockaddr_in6 = @ptrCast(@alignCast(&sa));
            if (c.inet_ntop(c.AF_INET6, &sin6.sin6_addr, dst, @intCast(len)) == null) return -1;
        },
        else => return -1,
    }
    return 0;
}

fn readSingleLine(fd: c_int, dst: [*]u8, len: usize) c_int {
    var i: usize = 0;
    while (i < len) {
        if (c.read(fd, dst + i, 1) <= 0) break;
        if (dst[i] == '\r') continue;
        if (dst[i] == '\n') {
            dst[i] = 0;
            return @intCast(i);
        }
        i += 1;
    }
    return -1;
}

fn getClientIpProxyProtocol(fd: c_int, dst: [*]u8, len: usize) c_int {
    var header: [110]u8 = undefined;
    const signature = "PROXY ";

    const ret = c.read(fd, &header[0], signature.len);
    if (ret <= 0) {
        debug.fatalQuiet("Disconnected, health checker?", .{});
    }
    if (ret != signature.len) return -1;
    if (!std.mem.eql(u8, header[0..signature.len], signature)) return -1;

    if (readSingleLine(fd, @ptrCast(&header[0]), header.len) < 0) return -1;

    debug.debug("proxy header: %s", .{@as([*:0]const u8, @ptrCast(&header[0]))});

    var tok_num: usize = 0;
    var tok = c.strtok(&header[0], " ");
    while (tok != null) : ({
        tok = c.strtok(null, " ");
        tok_num += 1;
    }) {
        if (tok_num == 1) {
            _ = c.strlcpy(dst, tok, len);
        }
    }

    if (tok_num != 5) return -1;
    return 0;
}

fn getClientIp(fd: c_int, dst: [*]u8, len: usize) c_int {
    if (c.tmate_settings.*.use_proxy_protocol) {
        return getClientIpProxyProtocol(fd, dst, len);
    } else {
        return getClientIpSocket(fd, dst, len);
    }
}

fn sshLogFunction(_: c_int, function: ?[*:0]const u8, buffer: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    c.log_emit(c.LOG_DEBUG, "[%s] %s", function, buffer);
}

fn sshImportKey(bind: c.ssh_bind, keys_dir: [*:0]const u8, name: [*:0]const u8) void {
    var path: [c.PATH_MAX]u8 = undefined;
    var key: c.ssh_key = null;

    _ = c.snprintf(&path[0], path.len, "%s/%s", keys_dir, name);
    if (c.access(&path[0], c.F_OK) < 0) return;

    debug.info("Loading key %s", .{@as([*:0]const u8, @ptrCast(&path[0]))});

    _ = c.ssh_pki_import_privkey_file(&path[0], null, null, null, &key);
    _ = c.ssh_bind_options_set(bind, c.SSH_BIND_OPTIONS_IMPORT_KEY, key);
}

fn prepareSsh(keys_dir: [*:0]const u8, bind_addr: ?[*:0]const u8, port_in: c_int) c.ssh_bind {
    var port = port_in;
    const diff = c.log_get_level() - c.LOG_INFO;
    var ssh_log_level: c_int = c.SSH_LOG_WARNING + (if (diff > 0) diff else 0);

    _ = c.ssh_set_log_callback(sshLogFunction);

    const bind = c.ssh_bind_new();
    if (bind == null) {
        debug.fatal("Cannot initialize ssh", .{});
    }

    _ = c.ssh_bind_options_parse_config(bind, null);

    if (bind_addr) |ba| {
        _ = c.ssh_bind_options_set(bind, c.SSH_BIND_OPTIONS_BINDADDR, ba);
    }
    _ = c.ssh_bind_options_set(bind, c.SSH_BIND_OPTIONS_BINDPORT, &port);
    _ = c.ssh_bind_options_set(bind, c.SSH_BIND_OPTIONS_BANNER, c.TMATE_SSH_BANNER);
    _ = c.ssh_bind_options_set(bind, c.SSH_BIND_OPTIONS_LOG_VERBOSITY, &ssh_log_level);

    sshImportKey(bind, keys_dir, "ssh_host_rsa_key");
    sshImportKey(bind, keys_dir, "ssh_host_ed25519_key");

    if (c.ssh_bind_listen(bind) < 0) {
        debug.fatal("Error listening to socket: %s", .{c.ssh_get_error(bind)});
    }

    debug.info("Accepting connections on %s:%d", .{ bind_addr orelse "", port });
    return bind;
}

fn handleSigchld(_: c_int) callconv(.c) void {
    var status: c_int = 0;
    while (c.waitpid(c.WAIT_ANY, &status, c.WNOHANG) > 0) {}
}

pub export fn tmate_ssh_server_main(
    session: ?*c.struct_tmate_session,
    keys_dir: ?[*:0]const u8,
    bind_addr: ?[*:0]const u8,
    port: c_int,
) void {
    const sess = session orelse return;
    const kd = keys_dir orelse return;
    const client = &sess.ssh_client;

    debug.tmate_catch_sigsegv();
    _ = c.signal(c.SIGCHLD, handleSigchld);

    const bind = prepareSsh(kd, bind_addr, port);

    client.session = c.ssh_new();
    client.channel = null;
    client.winsize_pty.ws_col = 80;
    client.winsize_pty.ws_row = 24;
    sess.session_token = @constCast("init");

    if (client.session == null) {
        debug.fatal("Cannot initialize session", .{});
    }

    while (true) {
        const fd = accept(c.ssh_bind_get_fd(bind), null, null);
        if (fd < 0) {
            debug.fatal("Error accepting connection", .{});
        }

        const pid = c.fork();
        if (pid < 0) {
            debug.fatal("Can't fork", .{});
        }

        if (pid != 0) {
            _ = c.close(fd);
            continue;
        }

        _ = c.signal(c.SIGALRM, handleSigalrm);
        _ = c.alarm(c.TMATE_SSH_GRACE_PERIOD);

        if (getClientIp(fd, @ptrCast(&client.ip_address[0]), client.ip_address.len) < 0) {
            if (c.tmate_settings.*.use_proxy_protocol) {
                debug.fatal("Proxy header invalid. Load balancer may be misconfigured", .{});
            } else {
                debug.fatal("Error getting client IP from connection", .{});
            }
        }

        debug.debug("Connection accepted ip=%s", .{@as([*:0]const u8, @ptrCast(&client.ip_address[0]))});

        if (c.ssh_bind_accept_fd(bind, client.session, fd) < 0) {
            debug.fatal("Error accepting connection: %s", .{c.ssh_get_error(bind)});
        }

        c.ssh_bind_free(bind);

        clientBootstrap(sess);
    }
}
