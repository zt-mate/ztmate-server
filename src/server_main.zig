const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");
const rand = @import("rand.zig");

var cmdline: ?[*]u8 = null;
var cmdline_end: ?[*]u8 = null;

pub export var _tmate_settings: c.struct_tmate_settings = .{
    .keys_dir = c.TMATE_SSH_DEFAULT_KEYS_DIR,
    .authorized_keys_path = null,
    .authorized_keys_only = false,
    .ssh_port = c.TMATE_SSH_DEFAULT_PORT,
    .ssh_port_advertized = -1,
    .websocket_hostname = null,
    .websocket_port = c.TMATE_DEFAULT_WEBSOCKET_PORT,
    .tmate_host = null,
    .bind_addr = null,
    .log_level = c.LOG_INFO,
    .use_proxy_protocol = false,
};

pub export var tmate_settings: *c.struct_tmate_settings = &_tmate_settings;

extern var server_fd: c_int;

pub export fn request_server_termination() void {
    if (server_fd != 0) {
        c.server_send_exit();
    } else {
        c.exit(1);
    }
}

fn usage() void {
    _ = c.fprintf(
        c.stderr,
        "usage: ztmate-ssh-server [-A] [-b ip] [-h hostname] [-k keys_dir] [-p listen_port] [-q ssh_port_advertized] [-w websocket_hostname] [-z websocket_port] [-x] [-v]\n",
    );
}

fn getFullHostname() ?[*:0]u8 {
    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    var info: ?*c.struct_addrinfo = null;
    var hostname: [1024]u8 = undefined;

    if (c.gethostname(&hostname[0], hostname.len) < 0) {
        debug.fatal("cannot get hostname", .{});
    }
    hostname[1023] = 0;

    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;
    hints.ai_flags = c.AI_CANONNAME;

    const gai_result = c.getaddrinfo(&hostname[0], null, &hints, &info);
    if (gai_result != 0) {
        debug.info("cannot lookup hostname: %s", .{c.gai_strerror(gai_result)});
        return c.xstrdup(&hostname[0]);
    }

    const ret = c.xstrdup(info.?.*.ai_canonname);
    c.freeaddrinfo(info);
    return ret;
}

fn setupLocale() void {
    if (c.setlocale(c.LC_CTYPE, "en_US.UTF-8") == null) {
        if (c.setlocale(c.LC_CTYPE, "") == null) {
            debug.fatal("invalid LC_ALL, LC_CTYPE or LANG", .{});
        }
        const s = c.nl_langinfo(c.CODESET);
        if (c.strcasecmp(s, "UTF-8") != 0 and c.strcasecmp(s, "UTF8") != 0) {
            debug.fatal("need UTF-8 locale (LC_CTYPE) but have %s", .{s});
        }
    }

    _ = c.setlocale(c.LC_TIME, "");
    c.tzset();
}

fn checkOwnedDirectoryMode(path: [*:0]const u8, expected_mode: c.mode_t) c_int {
    var st: c.struct_stat = undefined;
    if (c.lstat(path, &st) != 0) return -1;
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return -1;
    if (st.st_uid != c.getuid()) return -1;
    if ((st.st_mode & 0o7777) != expected_mode) return -1;
    return 0;
}

pub fn serverMain(argc: c_int, argv: [*]?[*:0]u8, envp: [*]?[*:0]u8) c_int {
    while (true) {
        const opt = c.getopt(argc, @ptrCast(argv), "Ab:h:k:p:q:w:z:xv");
        if (opt == -1) break;
        switch (opt) {
            'A' => tmate_settings.authorized_keys_only = true,
            'b' => tmate_settings.bind_addr = c.xstrdup(c.optarg),
            'h' => tmate_settings.tmate_host = c.xstrdup(c.optarg),
            'k' => tmate_settings.keys_dir = c.xstrdup(c.optarg),
            'p' => tmate_settings.ssh_port = c.atoi(c.optarg),
            'q' => tmate_settings.ssh_port_advertized = c.atoi(c.optarg),
            'w' => tmate_settings.websocket_hostname = c.xstrdup(c.optarg),
            'z' => tmate_settings.websocket_port = c.atoi(c.optarg),
            'x' => tmate_settings.use_proxy_protocol = true,
            'v' => tmate_settings.log_level += 1,
            else => {
                usage();
                return 1;
            },
        }
    }

    c.init_logging(tmate_settings.log_level);
    setupLocale();

    if (tmate_settings.tmate_host == null) {
        tmate_settings.tmate_host = getFullHostname();
    }

    if (argv[0]) |a0| cmdline = @ptrCast(a0);
    if (envp[0]) |e0| cmdline_end = @ptrCast(e0);

    debug.tmate_preload_trace_lib();
    debug.tmate_catch_sigsegv();
    rand.tmate_init_rand();

    if ((c.mkdir(c.TMATE_WORKDIR, 0o700) < 0 and std.c._errno().* != c.EEXIST) or
        (c.mkdir(c.TMATE_WORKDIR ++ "/sessions", 0o700) < 0 and std.c._errno().* != c.EEXIST) or
        (c.mkdir(c.TMATE_WORKDIR ++ "/jail", 0o700) < 0 and std.c._errno().* != c.EEXIST))
    {
        debug.fatal("Cannot prepare session in " ++ c.TMATE_WORKDIR, .{});
    }

    if ((c.chmod(c.TMATE_WORKDIR, 0o700) < 0) or
        (c.chmod(c.TMATE_WORKDIR ++ "/sessions", 0o700) < 0) or
        (c.chmod(c.TMATE_WORKDIR ++ "/jail", 0o700) < 0))
    {
        debug.fatal("Cannot prepare session in " ++ c.TMATE_WORKDIR, .{});
    }

    if (checkOwnedDirectoryMode(c.TMATE_WORKDIR, 0o700) != 0 or
        checkOwnedDirectoryMode(c.TMATE_WORKDIR ++ "/sessions", 0o700) != 0 or
        checkOwnedDirectoryMode(c.TMATE_WORKDIR ++ "/jail", 0o700) != 0)
    {
        debug.fatal(
            c.TMATE_WORKDIR ++ " and subdirectories has incorrect ownership/mode. Try deleting " ++ c.TMATE_WORKDIR ++ " and try again",
            .{},
        );
    }

    c.tmate_ssh_server_main(
        c.tmate_session,
        tmate_settings.keys_dir,
        tmate_settings.bind_addr,
        tmate_settings.ssh_port,
    );
    return 0;
}

pub export fn get_socket_path(_token: ?[*:0]const u8) ?[*:0]u8 {
    const tok_in = _token orelse return null;
    const token: [*:0]u8 = c.xstrdup(tok_in);
    defer c.free(token);

    var i: usize = 0;
    while (token[i] != 0) : (i += 1) {
        if (token[i] == '/' or token[i] == '.') {
            token[i] = '=';
        }
    }

    var path: [*c]u8 = null;
    _ = c.xasprintf(&path, c.TMATE_WORKDIR ++ "/sessions/%s", token);
    return @ptrCast(path);
}

pub export fn set_session_token(session: ?*c.struct_tmate_session, token: ?[*:0]const u8) void {
    const sess = session orelse return;
    const tok = token orelse return;

    sess.session_token = c.xstrdup(tok);
    c.socket_path = get_socket_path(tok);

    var obf: [*c]u8 = null;
    _ = c.xasprintf(&obf, "%.4s...", sess.session_token);
    sess.obfuscated_session_token = obf;

    if (cmdline != null and cmdline_end != null) {
        const start_addr = @intFromPtr(cmdline.?);
        const end_addr = @intFromPtr(cmdline_end.?);
        if (end_addr > start_addr) {
            const size = end_addr - start_addr;
            @memset(cmdline.?[0..size], 0);
            const role_str: [*:0]const u8 = if (sess.ssh_client.role == c.TMATE_ROLE_DAEMON) "(daemon)" else "(pty client)";
            _ = c.snprintf(
                cmdline.?,
                size - 1,
                "ztmate-ssh-server [%s] %s %s",
                c.tmate_session.*.obfuscated_session_token,
                role_str,
                @as([*:0]const u8, @ptrCast(&sess.ssh_client.ip_address[0])),
            );
        }
    }

    var log_prefix: [*c]u8 = null;
    _ = c.xasprintf(&log_prefix, "[%s] ", sess.obfuscated_session_token);
    c.set_log_prefix(log_prefix);
    c.free(log_prefix);
}

pub export fn close_fds_except(fd_to_preserve: ?[*]c_int, num_fds: c_int) void {
    const fds = fd_to_preserve;
    const count: usize = if (num_fds > 0) @intCast(num_fds) else 0;

    var fd: c_int = 0;
    while (fd < 1024) : (fd += 1) {
        var preserve = false;
        if (fds) |arr| {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (arr[i] == fd) {
                    preserve = true;
                    break;
                }
            }
        }
        if (!preserve) {
            _ = c.close(fd);
        }
    }
}

pub export fn get_in_jail() void {
    const pw = c.getpwnam(c.TMATE_JAIL_USER);
    if (pw == null) {
        debug.fatal("Cannot get the /etc/passwd entry for %s", .{c.TMATE_JAIL_USER});
    }
    const uid = pw.*.pw_uid;
    const gid = pw.*.pw_gid;

    if (c.getuid() != 0) {
        debug.fatal("Need root privileges to create the jail", .{});
    }

    if (c.chroot(c.TMATE_WORKDIR ++ "/jail") < 0) {
        debug.fatal("Cannot chroot()", .{});
    }

    if (c.chdir("/") < 0) {
        debug.fatal("Cannot chdir()", .{});
    }

    if (c.unshare(c.CLONE_NEWPID | c.CLONE_NEWIPC | c.CLONE_NEWNS | c.CLONE_NEWNET) < 0) {
        debug.fatal("Cannot create new namespace", .{});
    }

    var gids = [_]c.gid_t{gid};
    if (c.setgroups(1, &gids[0]) < 0) {
        debug.fatal("Cannot setgroups()", .{});
    }

    if (c.setresgid(gid, gid, gid) < 0) {
        debug.fatal("Cannot setresgid() %d", .{gid});
    }

    if (c.setresuid(uid, uid, uid) < 0) {
        debug.fatal("Cannot setresuid()", .{});
    }

    _ = c.nice(1);

    debug.debug(
        "Dropped priviledges to %s (%d,%d), jailed in %s",
        .{ c.TMATE_JAIL_USER, uid, gid, c.TMATE_WORKDIR ++ "/jail" },
    );
}

pub export fn setup_ncurse(fd: c_int, name: ?[*:0]const u8) void {
    var err: c_int = 0;
    if (c.setupterm(@constCast(name), fd, &err) != c.OK) {
        debug.fatal("Cannot setup terminal", .{});
    }
}
