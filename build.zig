const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_flags = &[_][]const u8{
        "-std=gnu99",
        "-D_GNU_SOURCE",
        "-D_DEFAULT_SOURCE",
        "-DIS_LINUX",
        "-DPACKAGE_STRING=\"ztmate-ssh-server 2.3.0\"",
        "-DPACKAGE_VERSION=\"2.3.0\"",
        "-DBUILD=\"2.3.0\"",
        "-DETC_TMUX_CONF=\"/etc/tmux.conf\"",
        "-DHAVE_CURSES_H=1",
        "-DHAVE_DIRENT_H=1",
        "-DHAVE_FCNTL_H=1",
        "-DHAVE_INTTYPES_H=1",
        "-DHAVE_NCURSES_H=1",
        "-DHAVE_EXECINFO_H=1",
        "-DHAVE_PATHS_H=1",
        "-DHAVE_PTY_H=1",
        "-DHAVE_STDINT_H=1",
        "-DHAVE_SYS_DIR_H=1",
        "-DHAVE_TERM_H=1",
        "-DHAVE_DIRFD=1",
        "-DHAVE_FLOCK=1",
        "-DHAVE_BACKTRACE=1",
        "-DHAVE_SYSCONF=1",
        "-DHAVE_CFMAKERAW=1",
        "-DHAVE_SETRESUID=1",
        "-DHAVE_SETRESGID=1",
        "-DHAVE_SETREUID=1",
        "-DHAVE_SETREGID=1",
        "-DHAVE_FORKPTY=1",
        "-DHAVE_DAEMON=1",
        "-DHAVE_SETENV=1",
        "-DHAVE_ASPRINTF=1",
        "-DHAVE_STRCASESTR=1",
        "-DHAVE_STRSEP=1",
        "-DHAVE_OPENAT=1",
        "-DHAVE_BSD_TYPES=1",
        "-DHAVE___PROGNAME=1",
        "-DHAVE_PROC_PID=1",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-missing-field-initializers",
        "-Wno-deprecated-declarations",
    };

    const tmux_c_sources = &[_][]const u8{
        "alerts.c",
        "arguments.c",
        "attributes.c",
        "cfg.c",
        "client.c",
        "cmd-attach-session.c",
        "cmd-bind-key.c",
        "cmd-break-pane.c",
        "cmd-capture-pane.c",
        "cmd-choose-buffer.c",
        "cmd-choose-client.c",
        "cmd-choose-tree.c",
        "cmd-clear-history.c",
        "cmd-command-prompt.c",
        "cmd-confirm-before.c",
        "cmd-copy-mode.c",
        "cmd-detach-client.c",
        "cmd-display-message.c",
        "cmd-display-panes.c",
        "cmd-find.c",
        "cmd-find-window.c",
        "cmd-if-shell.c",
        "cmd-join-pane.c",
        "cmd-kill-pane.c",
        "cmd-kill-server.c",
        "cmd-kill-session.c",
        "cmd-kill-window.c",
        "cmd-list-buffers.c",
        "cmd-list-clients.c",
        "cmd-list-keys.c",
        "cmd-list-panes.c",
        "cmd-list-sessions.c",
        "cmd-list-windows.c",
        "cmd-list.c",
        "cmd-load-buffer.c",
        "cmd-lock-server.c",
        "cmd-move-window.c",
        "cmd-new-session.c",
        "cmd-new-window.c",
        "cmd-paste-buffer.c",
        "cmd-pipe-pane.c",
        "cmd-queue.c",
        "cmd-refresh-client.c",
        "cmd-rename-session.c",
        "cmd-rename-window.c",
        "cmd-resize-pane.c",
        "cmd-respawn-pane.c",
        "cmd-respawn-window.c",
        "cmd-rotate-window.c",
        "cmd-run-shell.c",
        "cmd-save-buffer.c",
        "cmd-select-layout.c",
        "cmd-select-pane.c",
        "cmd-select-window.c",
        "cmd-send-keys.c",
        "cmd-set-buffer.c",
        "cmd-set-environment.c",
        "cmd-set-hook.c",
        "cmd-set-option.c",
        "cmd-show-environment.c",
        "cmd-show-messages.c",
        "cmd-show-options.c",
        "cmd-source-file.c",
        "cmd-split-window.c",
        "cmd-string.c",
        "cmd-swap-pane.c",
        "cmd-swap-window.c",
        "cmd-switch-client.c",
        "cmd-unbind-key.c",
        "cmd-wait-for.c",
        "cmd.c",
        "colour.c",
        "control.c",
        "control-notify.c",
        "environ.c",
        "format.c",
        "grid-view.c",
        "grid.c",
        "hooks.c",
        "input-keys.c",
        "input.c",
        "job.c",
        "key-bindings.c",
        "key-string.c",
        "layout-custom.c",
        "layout-set.c",
        "layout.c",
        "log.c",
        "mode-key.c",
        "names.c",
        "notify.c",
        "options-table.c",
        "options.c",
        "paste.c",
        "proc.c",
        "resize.c",
        "screen-redraw.c",
        "screen-write.c",
        "screen.c",
        "server-client.c",
        "server-fn.c",
        "server.c",
        "session.c",
        "signal.c",
        "status.c",
        "style.c",
        "tmux.c",
        "tty-acs.c",
        "tty-keys.c",
        "tty-term.c",
        "tty.c",
        "utf8.c",
        "window-choose.c",
        "window-clock.c",
        "window-copy.c",
        "window.c",
        "xmalloc.c",
        "xterm-keys.c",
        "osdep-linux.c",
        "compat/imsg.c",
        "compat/imsg-buffer.c",
        "compat/closefrom.c",
        "compat/strlcpy.c",
        "compat/strlcat.c",
        "compat/fgetln.c",
        "compat/fparseln.c",
        "compat/strtonum.c",
        "compat/vis.c",
        "compat/unvis.c",
        "compat/reallocarray.c",
        "compat/getopt.c",
        "compat/b64_ntop.c",
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_mod.addIncludePath(b.path("."));
    root_mod.addIncludePath(b.path("include"));
    root_mod.addLibraryPath(b.path("lib"));

    root_mod.addCSourceFiles(.{
        .files = tmux_c_sources,
        .flags = c_flags,
    });

    root_mod.linkSystemLibrary("event", .{});
    root_mod.linkSystemLibrary("ncurses", .{});
    root_mod.linkSystemLibrary("tinfo", .{});
    root_mod.linkSystemLibrary("ssh", .{});
    root_mod.linkSystemLibrary("util", .{});

    const exe = b.addExecutable(.{
        .name = "ztmate-ssh-server",
        .root_module = root_mod,
    });
    exe.rdynamic = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ztmate-ssh-server");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(b.path("."));
    test_mod.addIncludePath(b.path("include"));
    test_mod.addLibraryPath(b.path("lib"));
    test_mod.addCSourceFiles(.{
        .files = tmux_c_sources,
        .flags = c_flags,
    });
    test_mod.linkSystemLibrary("event", .{});
    test_mod.linkSystemLibrary("ncurses", .{});
    test_mod.linkSystemLibrary("tinfo", .{});
    test_mod.linkSystemLibrary("ssh", .{});
    test_mod.linkSystemLibrary("util", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
