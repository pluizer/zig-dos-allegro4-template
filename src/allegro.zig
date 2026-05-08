// Curated Zig wrapper around Allegro 4. Use `al.c.*` for the raw translate-c
// namespace; use the symbols defined here for cases where translate-c gets it
// wrong or where a macro doesn't translate. Add new wrappers here as needed —
// don't sprinkle workarounds into game code.

pub const c = @cImport({
    @cInclude("allegro.h");
});

// ---- translate-c bugs ----

// `extern volatile char key[KEY_MAX]`. translate-c can't express `[N]volatile
// T` (Zig only allows volatile on pointers), so it falls back to
// `[*c]volatile u8`. The Zig C backend then emits `extern uint8_t key;` —
// scalar, breaks indexing. Redeclare as pointer-to-volatile-array so the C
// backend emits a real array extern. Same workaround applies to any other
// `extern volatile T arr[]` global Allegro exposes (key_shifts is a scalar,
// joy[] is a struct array, neither of those is currently used).
pub const key: *volatile [c.KEY_MAX]u8 = @extern(*volatile [c.KEY_MAX]u8, .{ .name = "key" });

// ---- macros translate-c rejects ----

// allegro_init() is a macro whose body contains a function-pointer cast
// translate-c can't parse (`(int (*)(void (*)(void)))atexit`). The same macro
// expansion calls _install_allegro_version_check; the public inline
// `install_allegro` does the same with explicit parameters and translates
// fine. errno_ptr and atexit_ptr are optional — Allegro tolerates null.
pub fn init() c_int {
    return c.install_allegro(c.SYSTEM_AUTODETECT, null, null);
}

// ---- ergonomics ----

// allegro_message is a printf-style variadic. For Zig slice -> C string with
// no formatting, copy into a stack buffer and pass as the format itself
// (works as long as msg has no '%'). Truncates messages over 511 chars.
pub fn message(msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    c.allegro_message(&buf);
}
