const c = @import("c.zig").c;

const LEGACY_KEYC_NONE = 0xfff;
const LEGACY_KEYC_BASE = 0x1000;
const LEGACY_KEYC_ESCAPE = 0x2000;
const LEGACY_KEYC_CTRL = 0x4000;
const LEGACY_KEYC_SHIFT = 0x8000;
const LEGACY_KEYC_PREFIX = 0x10000;

const LegacyKeyCode = enum(c_int) {
    MOUSE = LEGACY_KEYC_BASE,
    BSPACE,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
    IC,
    DC,
    HOME,
    END,
    NPAGE,
    PPAGE,
    BTAB,
    UP,
    DOWN,
    LEFT,
    RIGHT,
    KP_SLASH,
    KP_STAR,
    KP_MINUS,
    KP_SEVEN,
    KP_EIGHT,
    KP_NINE,
    KP_PLUS,
    KP_FOUR,
    KP_FIVE,
    KP_SIX,
    KP_ONE,
    KP_TWO,
    KP_THREE,
    KP_ENTER,
    KP_ZERO,
    KP_PERIOD,
    FOCUS_IN,
    FOCUS_OUT,
};

pub export fn tmate_translate_legacy_key(pane_id: c_int, key: c.key_code) void {
    const justkey: c.key_code = key & c.KEYC_MASK_KEY;
    var lflags: c_int = 0;

    if ((key & c.KEYC_ESCAPE) != 0) lflags |= LEGACY_KEYC_ESCAPE;
    if ((key & c.KEYC_CTRL) != 0) lflags |= LEGACY_KEYC_CTRL;
    if ((key & c.KEYC_SHIFT) != 0) lflags |= LEGACY_KEYC_SHIFT;

    const lkey: c_int = switch (justkey) {
        c.KEYC_BSPACE => @intFromEnum(LegacyKeyCode.BSPACE),
        c.KEYC_F1 => @intFromEnum(LegacyKeyCode.F1),
        c.KEYC_F2 => @intFromEnum(LegacyKeyCode.F2),
        c.KEYC_F3 => @intFromEnum(LegacyKeyCode.F3),
        c.KEYC_F4 => @intFromEnum(LegacyKeyCode.F4),
        c.KEYC_F5 => @intFromEnum(LegacyKeyCode.F5),
        c.KEYC_F6 => @intFromEnum(LegacyKeyCode.F6),
        c.KEYC_F7 => @intFromEnum(LegacyKeyCode.F7),
        c.KEYC_F8 => @intFromEnum(LegacyKeyCode.F8),
        c.KEYC_F9 => @intFromEnum(LegacyKeyCode.F9),
        c.KEYC_F10 => @intFromEnum(LegacyKeyCode.F10),
        c.KEYC_F11 => @intFromEnum(LegacyKeyCode.F11),
        c.KEYC_F12 => @intFromEnum(LegacyKeyCode.F12),
        c.KEYC_IC => @intFromEnum(LegacyKeyCode.IC),
        c.KEYC_DC => @intFromEnum(LegacyKeyCode.DC),
        c.KEYC_HOME => @intFromEnum(LegacyKeyCode.HOME),
        c.KEYC_END => @intFromEnum(LegacyKeyCode.END),
        c.KEYC_NPAGE => @intFromEnum(LegacyKeyCode.NPAGE),
        c.KEYC_PPAGE => @intFromEnum(LegacyKeyCode.PPAGE),
        c.KEYC_BTAB => @intFromEnum(LegacyKeyCode.BTAB),
        c.KEYC_UP => @intFromEnum(LegacyKeyCode.UP),
        c.KEYC_DOWN => @intFromEnum(LegacyKeyCode.DOWN),
        c.KEYC_LEFT => @intFromEnum(LegacyKeyCode.LEFT),
        c.KEYC_RIGHT => @intFromEnum(LegacyKeyCode.RIGHT),
        c.KEYC_KP_SLASH => @intFromEnum(LegacyKeyCode.KP_SLASH),
        c.KEYC_KP_STAR => @intFromEnum(LegacyKeyCode.KP_STAR),
        c.KEYC_KP_MINUS => @intFromEnum(LegacyKeyCode.KP_MINUS),
        c.KEYC_KP_SEVEN => @intFromEnum(LegacyKeyCode.KP_SEVEN),
        c.KEYC_KP_EIGHT => @intFromEnum(LegacyKeyCode.KP_EIGHT),
        c.KEYC_KP_NINE => @intFromEnum(LegacyKeyCode.KP_NINE),
        c.KEYC_KP_PLUS => @intFromEnum(LegacyKeyCode.KP_PLUS),
        c.KEYC_KP_FOUR => @intFromEnum(LegacyKeyCode.KP_FOUR),
        c.KEYC_KP_FIVE => @intFromEnum(LegacyKeyCode.KP_FIVE),
        c.KEYC_KP_SIX => @intFromEnum(LegacyKeyCode.KP_SIX),
        c.KEYC_KP_ONE => @intFromEnum(LegacyKeyCode.KP_ONE),
        c.KEYC_KP_TWO => @intFromEnum(LegacyKeyCode.KP_TWO),
        c.KEYC_KP_THREE => @intFromEnum(LegacyKeyCode.KP_THREE),
        c.KEYC_KP_ENTER => @intFromEnum(LegacyKeyCode.KP_ENTER),
        c.KEYC_KP_ZERO => @intFromEnum(LegacyKeyCode.KP_ZERO),
        c.KEYC_KP_PERIOD => @intFromEnum(LegacyKeyCode.KP_PERIOD),
        c.KEYC_FOCUS_IN => @intFromEnum(LegacyKeyCode.FOCUS_IN),
        c.KEYC_FOCUS_OUT => @intFromEnum(LegacyKeyCode.FOCUS_OUT),
        else => blk: {
            if (justkey >= c.KEYC_BASE) return;
            if (justkey > 0x7f) {
                var ud: c.struct_utf8_data = undefined;
                if (c.utf8_split(@intCast(justkey), &ud) != c.UTF8_DONE) return;
                var i: usize = 0;
                while (i < ud.size) : (i += 1) {
                    c.tmate_client_legacy_pane_key(pane_id, lflags | @as(c_int, ud.data[i]));
                    lflags = 0;
                }
                return;
            }
            break :blk @intCast(justkey);
        },
    };

    c.tmate_client_legacy_pane_key(pane_id, lflags | lkey);
}
