const std = @import("std");

pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("IS_LINUX", "1");
    @cDefine("HAVE_CURSES_H", "1");
    @cDefine("HAVE_FORKPTY", "1");
    @cDefine("HAVE_PTY_H", "1");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/ioctl.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("fcntl.h");
    @cInclude("ctype.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("pty.h");
    @cInclude("termios.h");
    @cInclude("sched.h");
    @cInclude("langinfo.h");
    @cInclude("locale.h");
    @cInclude("curses.h");
    @cInclude("term.h");
    @cInclude("execinfo.h");
    @cInclude("event2/util.h");
    @cInclude("event2/event.h");
    @cInclude("libssh/libssh.h");
    @cInclude("libssh/server.h");
    @cInclude("libssh/callbacks.h");
    @cInclude("tmate.h");
    @cInclude("tmate-protocol.h");
    @cInclude("window-copy.h");
});

/// Internal args_entry structure from arguments.c
pub const ArgsEntry = extern struct {
    flag: u8,
    value: [*c]u8,
    entry: extern struct {
        rbe_left: ?*ArgsEntry,
        rbe_right: ?*ArgsEntry,
        rbe_parent: ?*ArgsEntry,
        rbe_color: c_int,
    },
};

pub extern fn args_tree_RB_MINMAX(head: *c.struct_args_tree, val: c_int) ?*ArgsEntry;
pub extern fn args_tree_RB_NEXT(elm: *ArgsEntry) ?*ArgsEntry;
pub extern var next_window_pane_id: c.u_int;
pub extern var server_fd: c_int;
pub extern fn server_send_exit() void;

pub const RB_NEGINF: c_int = -1;

pub fn logDebug(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.log_emit(c.LOG_DEBUG, "%s", slice.ptr);
}

pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.log_emit(c.LOG_INFO, "%s", slice.ptr);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrintZ(&buf, fmt, args) catch "fatal error";
    c.fatalx("%s", slice.ptr);
}

pub fn fatalQuiet(comptime fmt: []const u8, args: anytype) noreturn {
    logDebug(fmt, args);
    c.exit(1);
}

pub fn fatalErrno(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrintZ(&buf, fmt, args) catch "fatal error";
    c.fatal("%s", slice.ptr);
}
