/* compiler_rt helpers Zig's C backend references but doesn't emit, and which
   djgpp's libgcc (32-bit i386) doesn't provide.

   These can't be exported from Zig directly: the Zig C backend emits @export'd
   names via __asm() through zig.h's zig_mangle_c, which on i386 COFF skips
   the leading-underscore convention — leaving `__multi3` as the literal COFF
   symbol while the GCC-generated call sites reference `___multi3`. Defining
   them in C lets djgpp-gcc apply the COFF convention uniformly on both ends.

   On targets where __SIZEOF_INT128__ is undefined (32-bit i386), zig.h
   represents zig_i128/zig_u128 as a struct with explicit lo/hi halves and
   16-byte alignment. The signatures below must match that struct layout.

   Add more on link errors. */

#include <stdint.h>

typedef struct { uint64_t lo;  int64_t hi; } __attribute__((aligned(16))) zig_i128;
typedef struct { uint64_t lo; uint64_t hi; } __attribute__((aligned(16))) zig_u128;

/* Unsigned 64x64 -> 128 multiply, schoolbook via 32x32 partials. */
static zig_u128 mul_u64_u128(uint64_t a, uint64_t b)
{
    uint32_t al = (uint32_t)a, ah = (uint32_t)(a >> 32);
    uint32_t bl = (uint32_t)b, bh = (uint32_t)(b >> 32);

    uint64_t p00 = (uint64_t)al * bl;
    uint64_t p01 = (uint64_t)al * bh;
    uint64_t p10 = (uint64_t)ah * bl;
    uint64_t p11 = (uint64_t)ah * bh;

    uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;

    zig_u128 r;
    r.lo = (uint32_t)p00 | (mid << 32);
    r.hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    return r;
}

zig_i128 __multi3(zig_i128 a, zig_i128 b)
{
    zig_u128 prod = mul_u64_u128(a.lo, b.lo);
    int64_t hi = (int64_t)prod.hi;
    hi += (int64_t)a.lo * b.hi;
    hi += a.hi * (int64_t)b.lo;

    zig_i128 r;
    r.lo = prod.lo;
    r.hi = hi;
    return r;
}

/* ---- 128-bit division ---- */

/* Bit-by-bit restoring binary long division. 128 iterations per call. Slow
   but small and obviously correct; acceptable for the rare paths that need
   i128/u128 div in game code. Replace with a faster algorithm if profiling
   shows it matters. */
static zig_u128 udivmod128(zig_u128 a, zig_u128 b, zig_u128 *rem_out)
{
    zig_u128 q = { 0, 0 };
    zig_u128 r = { 0, 0 };

    for (int i = 127; i >= 0; i--) {
        /* r <<= 1, shift in bit i of a */
        r.hi = (r.hi << 1) | (r.lo >> 63);
        r.lo <<= 1;
        uint64_t bit = (i >= 64) ? ((a.hi >> (i - 64)) & 1u)
                                 : ((a.lo >> i)        & 1u);
        r.lo |= bit;

        /* if r >= b: r -= b, set bit i of q */
        int ge = (r.hi > b.hi) || (r.hi == b.hi && r.lo >= b.lo);
        if (ge) {
            uint64_t borrow = (r.lo < b.lo) ? 1u : 0u;
            r.lo -= b.lo;
            r.hi  = r.hi - b.hi - borrow;
            if (i >= 64) q.hi |= (uint64_t)1u << (i - 64);
            else         q.lo |= (uint64_t)1u <<  i;
        }
    }

    if (rem_out) *rem_out = r;
    return q;
}

static zig_u128 negate_u128(zig_u128 x)
{
    zig_u128 r;
    r.lo = (~x.lo) + 1u;
    r.hi = (~x.hi) + (x.lo == 0 ? 1u : 0u);
    return r;
}

static zig_u128 abs_i128(zig_i128 x, int *neg)
{
    zig_u128 u;
    u.lo = x.lo;
    u.hi = (uint64_t)x.hi;
    if (x.hi < 0) { u = negate_u128(u); *neg = 1; }
    else          { *neg = 0; }
    return u;
}

static zig_i128 to_i128(zig_u128 u, int neg)
{
    if (neg) u = negate_u128(u);
    zig_i128 r;
    r.lo = u.lo;
    r.hi = (int64_t)u.hi;
    return r;
}

zig_u128 __udivti3(zig_u128 a, zig_u128 b)
{
    return udivmod128(a, b, 0);
}

zig_u128 __umodti3(zig_u128 a, zig_u128 b)
{
    zig_u128 r;
    udivmod128(a, b, &r);
    return r;
}

zig_i128 __divti3(zig_i128 a, zig_i128 b)
{
    int na, nb;
    zig_u128 ua = abs_i128(a, &na);
    zig_u128 ub = abs_i128(b, &nb);
    zig_u128 q  = udivmod128(ua, ub, 0);
    return to_i128(q, na ^ nb);
}

zig_i128 __modti3(zig_i128 a, zig_i128 b)
{
    int na, nb;
    zig_u128 ua = abs_i128(a, &na);
    zig_u128 ub = abs_i128(b, &nb);
    zig_u128 r;
    udivmod128(ua, ub, &r);
    return to_i128(r, na);
}
