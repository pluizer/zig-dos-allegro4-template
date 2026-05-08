const std = @import("std");
const al = @import("allegro.zig");

extern "c" fn exit(code: c_int) noreturn;

fn handlePanic(msg: []const u8, _: ?usize) noreturn {
    _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
    al.message(msg);
    exit(1);
}

pub const panic = std.debug.FullPanic(handlePanic);

const State = struct {
    x: c_int,
    y: c_int,
};

const heap = std.heap.c_allocator;

var fba_buf: [4096]u8 = undefined;

fn smokeTest() !void {
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const a = fba.allocator();
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(a);
    try list.appendSlice(a, "abcdefghij");
    if (list.items.len != 10) return error.SmokeTestFailed;
}

// Stresses ArrayList(struct), AutoHashMap, std.sort.pdq, std.Random, and
// std.fmt.bufPrint together. Generates 100 deterministic pseudo-random u32
// values, sorts them, builds a value->index map, computes a XOR checksum,
// and writes the result into `out` as a null-terminated string.
// Returns the slice (excluding the terminator) on success.
fn runStdSelfTest(out: []u8) ![:0]u8 {
    const Item = struct { value: u32, original_index: u32 };

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();

    var items: std.ArrayList(Item) = .{};
    defer items.deinit(heap);
    try items.ensureTotalCapacity(heap, 100);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try items.append(heap, .{ .value = rng.int(u32), .original_index = i });
    }

    const lessThan = struct {
        fn f(_: void, a: Item, b: Item) bool {
            return a.value < b.value;
        }
    }.f;
    std.sort.pdq(Item, items.items, {}, lessThan);

    // Verify sorted order.
    for (items.items[1..], 0..) |it, k| {
        if (it.value < items.items[k].value) return error.NotSorted;
    }

    var by_value: std.AutoHashMap(u32, u32) = .init(heap);
    defer by_value.deinit();
    for (items.items, 0..) |it, idx| {
        try by_value.put(it.value, @intCast(idx));
    }
    if (by_value.count() != 100) return error.WrongMapSize;

    // Spot-check: median value's map entry must point to index 50.
    const median = items.items[50].value;
    const idx_of_median = by_value.get(median) orelse return error.MissingMapKey;
    if (idx_of_median != 50) return error.WrongMapValue;

    var checksum: u32 = 0;
    for (items.items) |it| checksum ^= it.value;

    return std.fmt.bufPrintZ(out,
        "std ok n={d} min={x} med={x} max={x} sum={x}",
        .{
            items.items.len,
            items.items[0].value,
            median,
            items.items[items.items.len - 1].value,
            checksum,
        });
}

export fn main() c_int {
    if (al.init() != 0) return 1;
    _ = al.c.install_keyboard();
    _ = al.c.install_timer();

    if (al.c.set_gfx_mode(al.c.GFX_AUTODETECT, 640, 480, 0, 0) != 0) {
        _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
        al.message("set_gfx_mode failed");
        return 1;
    }
    al.c.set_palette(&al.c.desktop_palette);

    const back = al.c.create_bitmap(al.c.SCREEN_W(), al.c.SCREEN_H()) orelse {
        _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
        al.message("create_bitmap failed");
        return 1;
    };
    defer al.c.destroy_bitmap(back);

    smokeTest() catch {
        _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
        al.message("FBA smoke test failed");
        return 1;
    };

    var status_buf: [128]u8 = undefined;
    const status = runStdSelfTest(&status_buf) catch |err| {
        _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
        var ebuf: [128]u8 = undefined;
        const emsg = std.fmt.bufPrint(&ebuf, "std self-test failed: {s}", .{@errorName(err)}) catch "std self-test failed";
        al.message(emsg);
        return 1;
    };

    const s = heap.create(State) catch {
        _ = al.c.set_gfx_mode(al.c.GFX_TEXT, 0, 0, 0, 0);
        al.message("heap allocation failed");
        return 1;
    };
    defer heap.destroy(s);
    s.* = .{ .x = @divTrunc(al.c.SCREEN_W(), 2), .y = @divTrunc(al.c.SCREEN_H(), 2) };

    const black = al.c.makecol(0, 0, 0);
    const white = al.c.makecol(255, 255, 255);
    const red = al.c.makecol(255, 64, 64);

    while (al.key[al.c.KEY_ESC] == 0) {
        if (al.key[al.c.KEY_LEFT] != 0) s.x -= 1;
        if (al.key[al.c.KEY_RIGHT] != 0) s.x += 1;
        if (al.key[al.c.KEY_UP] != 0) s.y -= 1;
        if (al.key[al.c.KEY_DOWN] != 0) s.y += 1;

        al.c.clear_to_color(back, black);
        al.c.textout_centre_ex(back, al.c.font, "dos-game",
            @divTrunc(al.c.SCREEN_W(), 2), 8, white, -1);
        al.c.textout_ex(back, al.c.font, status.ptr,
            4, al.c.SCREEN_H() - 12, white, -1);
        al.c.circlefill(back, s.x, s.y, 8, red);

        al.c.vsync();
        al.c.blit(back, al.c.screen, 0, 0, 0, 0, al.c.SCREEN_W(), al.c.SCREEN_H());
    }
    return 0;
}
