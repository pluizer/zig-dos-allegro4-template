DOS-GAME
========

Zig 0.15 + Allegro 4 + DJGPP. Game code is written in Zig; Allegro and
djgpp libc are reached via @cImport. Builds a 32-bit protected-mode DOS
.exe with a CWSDPMI extender stub.


REQUIREMENTS
------------

Host:  make, curl, tar, dosbox

BUILD
-----

    make            # produces ./dos-game.exe
    make run        # launches dosbox dos-game.exe
    make clean      # removes build/ and dos-game.exe
    make distclean  # also removes vendor/ (Allegro, CWSDPMI, etc.)

First build also cross-compiles liballeg.a for djgpp (~minutes).


WRITING GAME CODE
-----------------

Game entry is `export fn main() c_int` in src/main.zig. Add modules under
src/*.zig; the Makefile compiles all of them as one Zig build-obj invocation
(any file in src/*.zig retriggers a rebuild).

Allegro is reached through src/allegro.zig:

    const al = @import("allegro.zig");

    al.c.<symbol>     - raw translate-c namespace (functions, types,
                        constants, KEY_* / GFX_* enums, SCREEN_W() / etc.)
    al.key            - keyboard array (translate-c miscompiles c.key)
    al.init()         - replaces the allegro_init() macro that translate-c
                        cannot parse
    al.message(slice) - allegro_message taking a Zig []const u8

Most code uses al.c.* directly. Add wrappers/fixes to allegro.zig only when
translate-c's output is broken or a macro doesn't translate.


ALLOCATORS
----------

    std.heap.c_allocator               djgpp malloc/free, DPMI heap
    std.heap.FixedBufferAllocator      stack/static buffer
    std.heap.ArenaAllocator            wraps another, free-all on deinit

Not available: page_allocator, DebugAllocator, smp_allocator (all OS-bound).


STD AVAILABILITY
----------------

Available:    std.ArrayList, AutoHashMap, StringHashMap, sort, mem, math,
              fmt, Random, hash, bit_set, BoundedArray, MultiArrayList,
              EnumMap, PriorityQueue, comptime, error unions, generics.

Unavailable:  std.fs, std.os, std.io.getStdOut, std.process, std.net,
              std.http, std.Thread, std.posix.

For file I/O, debug print, etc., @cImport djgpp libc (<stdio.h>, <fcntl.h>,
<dpmi.h>, <go32.h>) and call directly.


GOTCHAS
-------

1. f16 / SSE.

   The Makefile builds with -mno-sse. zig.h's _Float16 selection assumes
   SSE2 is available. src/zig_shim.h pre-includes <float.h> and #undefs
   FLT16_MANT_DIG so zig.h falls back to its software u16 path. Don't
   remove the shim unless SSE2 is enabled.

2. compiler_rt helpers.

   The Zig C backend references __multi3, __divti3, __udivti3, __modti3,
   __umodti3, etc., for 128-bit math. djgpp libgcc has 64-bit helpers
   (__muldi3, __divdi3) but no 128-bit ones. The provided helpers are
   in src/compiler_rt_shim.c. They can't be exported from Zig because the
   C backend's __asm() mangling skips the COFF leading-underscore
   convention; defining them in C makes djgpp-gcc handle mangling
   uniformly. On a link error for a missing __XXX symbol, copy the
   reference impl from /usr/lib/zig/compiler_rt/<name>.zig and translate
   to C operating on the zig_i128 / zig_u128 struct in this file.

3. translate-c miscompiles `extern volatile T arr[]`.

   Zig's type system can't express [N]volatile T (volatile attaches to
   pointers only). translate-c falls back to [*c]volatile T, and the C
   backend then emits `extern uint8_t arr;` (scalar, not array), breaking
   indexing. Workaround in src/allegro.zig: redeclare the symbol as
   `*volatile [N]T` via @extern. Apply the same pattern for any other
   volatile-array global needed.

4. allegro_init() macro.

   Macro body contains a function-pointer cast translate-c rejects. Use
   al.init() (calls install_allegro directly with null errno_ptr / null
   atexit_ptr).

5. -DALLEGRO_NO_ASM.

   Required when @cImport-ing <allegro.h>. Without it, translate-c parses
   al386gcc.h's GCC inline asm fixed-point ops and rejects %cc clobber
   syntax. The fallback C implementations of those ops are used instead.

6. Stack size.

   DJGPP defaults to ~256 KB. Deep recursion or large stack arrays will
   crash. Tune via _stklen if needed.


FLOATING POINT
--------------

x87 only (-mno-sse). f32 is not faster than f64 on x87; both go through
80-bit registers. For per-frame physics, prefer integer or fixed-point
(Allegro's fixed type, accessible via al.c.fixmul / al.c.fixsin / etc.).
For one-off math (sqrt, sin/cos at startup), f32/f64 are fine.
