const std = @import("std");
const c = @import("c.zig").c;
const debug = @import("debug.zig");

extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c.socklen_t) c_int;

fn resetAndEnableAuthorizedKeys() void {
    var keys = c.tmate_session.*.authorized_keys;
    if (keys != null) {
        var i: usize = 0;
        while (keys[i] != null) : (i += 1) {
            c.ssh_key_free(keys[i]);
        }
        c.free(@ptrCast(keys));
    }

    keys = @ptrCast(@alignCast(c.xreallocarray(null, @sizeOf(c.ssh_key), 1)));
    keys[0] = null;
    c.tmate_session.*.authorized_keys = keys;
}

fn importSshPubkey64(_keystr: [*:0]const u8) c.ssh_key {
    const keystr: [*:0]u8 = c.xstrdup(_keystr);
    defer c.free(keystr);

    const slice = std.mem.span(keystr);
    var it = std.mem.splitScalar(u8, slice, ' ');
    const key_type_slice = it.next() orelse return null;
    const key_content_slice = it.next() orelse return null;

    // Null-terminate in place since keystr is a mutable copy
    keystr[key_type_slice.len] = 0;
    const content_start = key_type_slice.len + 1;
    if (content_start + key_content_slice.len < slice.len) {
        keystr[content_start + key_content_slice.len] = 0;
    }

    const key_type_ptr: [*:0]const u8 = @ptrCast(keystr);
    const key_content_ptr: [*:0]const u8 = @ptrCast(keystr + content_start);

    const ktype = c.ssh_key_type_from_name(key_type_ptr);
    if (ktype == c.SSH_KEYTYPE_UNKNOWN) return null;

    var ret: c.ssh_key = null;
    if (c.ssh_pki_import_pubkey_base64(key_content_ptr, ktype, &ret) != c.SSH_OK) {
        return null;
    }
    return ret;
}

pub export fn get_num_authorized_keys(keys: ?[*]c.ssh_key) c_int {
    const k = keys orelse return 0;
    var count: c_int = 0;
    while (k[@intCast(count)] != null) {
        count += 1;
    }
    return count;
}

fn appendAuthorizedKey(keystr: [*:0]const u8) void {
    if (c.tmate_session.*.authorized_keys == null) {
        resetAndEnableAuthorizedKeys();
    }

    const pkey = importSshPubkey64(keystr);
    if (pkey == null) return;

    var keys = c.tmate_session.*.authorized_keys;
    const count: usize = @intCast(get_num_authorized_keys(keys));
    keys = @ptrCast(@alignCast(c.xreallocarray(@ptrCast(keys), @sizeOf(c.ssh_key), count + 2)));
    c.tmate_session.*.authorized_keys = keys;

    keys[count] = pkey;
    keys[count + 1] = null;
}

fn tmateSet(key: []const u8, value: [*:0]const u8) void {
    if (std.mem.eql(u8, key, "authorized_keys")) {
        appendAuthorizedKey(value);
    }
}

pub export fn tmate_hook_set_option_auth(name: ?[*:0]const u8, val: ?[*:0]const u8) void {
    const n = name orelse return;
    const name_slice = std.mem.span(n);
    if (std.mem.eql(u8, name_slice, "ztmate-authorized-keys") or std.mem.eql(u8, name_slice, "tmate-authorized-keys")) {
        resetAndEnableAuthorizedKeys();
    } else if (std.mem.eql(u8, name_slice, "ztmate-set") or std.mem.eql(u8, name_slice, "tmate-set")) {
        const v = val orelse return;
        const key_value: [*:0]u8 = c.xstrdup(v);
        defer c.free(key_value);

        const kv_slice = std.mem.span(key_value);
        if (std.mem.indexOfScalar(u8, kv_slice, '=')) |eq_idx| {
            key_value[eq_idx] = 0;
            const key_slice = kv_slice[0..eq_idx];
            const val_ptr: [*:0]const u8 = @ptrCast(key_value + eq_idx + 1);
            tmateSet(key_slice, val_ptr);
        }
    }
}

pub export fn tmate_allow_auth(pubkey: ?[*:0]const u8) bool {
    if (c.tmate_session.*.authorized_keys == null) return true;
    const pk = pubkey orelse return false;

    const client_pkey = importSshPubkey64(pk);
    if (client_pkey == null) return false;
    defer c.ssh_key_free(client_pkey);

    const keys = c.tmate_session.*.authorized_keys;
    var i: usize = 0;
    while (keys[i] != null) : (i += 1) {
        if (c.ssh_key_cmp(client_pkey, keys[i], c.SSH_KEY_CMP_PUBLIC) == 0) {
            return true;
        }
    }
    return false;
}

fn writeAll(fd: c_int, buf: [*]const u8, len: usize) c_int {
    var i: usize = 0;
    while (i < len) {
        const ret = c.write(fd, buf + i, len - i);
        if (ret <= 0) return -1;
        i += @intCast(ret);
    }
    return 0;
}

fn readAll(fd: c_int, buf: [*]u8, len: usize) c_int {
    var i: usize = 0;
    while (i < len) {
        const ret = c.read(fd, buf + i, len - i);
        if (ret <= 0) return -1;
        i += @intCast(ret);
    }
    return 0;
}

const RecvMsg = extern struct {
    hdr: c.struct_imsg_hdr align(1),
    allow: bool align(1),
};

pub export fn would_tmate_session_allow_auth(token: ?[*:0]const u8, pubkey: ?[*:0]const u8) bool {
    const tok = token orelse return true;
    if (c.tmate_validate_session_token(tok) < 0) return true;

    const sock_path = c.get_socket_path(tok);
    if (sock_path == null) return true;

    var sa: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    sa.sun_family = c.AF_UNIX;
    const size = c.strlcpy(&sa.sun_path[0], sock_path, @sizeOf(@TypeOf(sa.sun_path)));
    c.free(sock_path);
    if (size >= @sizeOf(@TypeOf(sa.sun_path))) return true;

    const sock_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (sock_fd < 0) return true;
    defer _ = c.close(sock_fd);

    if (connect(sock_fd, &sa, @sizeOf(c.struct_sockaddr_un)) == -1) {
        return true;
    }

    const pk_len: usize = if (pubkey) |pk| c.strlen(pk) + 1 else 0;
    var hdr = c.struct_imsg_hdr{
        .type = if (pubkey != null) c.MSG_IDENTIFY_TMATE_AUTH_PUBKEY else c.MSG_IDENTIFY_TMATE_AUTH_NONE,
        .len = @intCast(c.IMSG_HEADER_SIZE + pk_len),
        .flags = 0,
        .peerid = c.PROTOCOL_VERSION,
        .pid = @bitCast(@as(i32, -1)),
    };

    if (writeAll(sock_fd, @ptrCast(&hdr), @sizeOf(c.struct_imsg_hdr)) < 0) return true;
    if (pubkey) |pk| {
        if (writeAll(sock_fd, pk, pk_len) < 0) return true;
    }

    var recv_msg: RecvMsg = undefined;
    if (readAll(sock_fd, @ptrCast(&recv_msg), @sizeOf(RecvMsg)) < 0) return true;

    var ret = true;
    if (recv_msg.hdr.type == c.MSG_TMATE_AUTH_STATUS and recv_msg.hdr.len == @sizeOf(RecvMsg)) {
        ret = recv_msg.allow;
    }

    debug.debug("(preauth) allow=%d", .{@as(c_int, if (ret) 1 else 0)});
    return ret;
}
