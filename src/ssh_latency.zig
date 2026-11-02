const c = @import("c.zig").c;

pub export fn start_keepalive_timer(client: ?*c.struct_tmate_ssh_client, timeout_ms: c_int) void {
    const cl = client orelse return;
    var tv = c.struct_timeval{
        .tv_sec = @divTrunc(timeout_ms, 1000),
        .tv_usec = @rem(timeout_ms, 1000) * 1000,
    };

    cl.keepalive_interval_ms = timeout_ms;
    c.event_set(&cl.ev_keepalive_timer, -1, 0, onKeepaliveTimer, cl);
    _ = c.event_add(&cl.ev_keepalive_timer, &tv);
}

fn onKeepaliveTimer(_: c.evutil_socket_t, _: c_short, arg: ?*anyopaque) callconv(.c) void {
    const client: *c.struct_tmate_ssh_client = @ptrCast(@alignCast(arg.?));

    const v084 = (0 << 16) | (8 << 8) | 4;
    const v087 = (0 << 16) | (8 << 8) | 7;
    if (c.ssh_version(v084) != null and c.ssh_version(v087) == null) {
        return;
    }

    if (c.ssh_send_keepalive(client.session) == c.SSH_ERROR) {
        return;
    }

    start_keepalive_timer(client, client.keepalive_interval_ms);
}
