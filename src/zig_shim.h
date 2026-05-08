/* Pre-include float.h with the IEC 60559 macro that zig.h sets, then strip
   FLT16_MANT_DIG. zig.h uses that macro to pick _Float16 as zig_f16, but on
   i386 -mno-sse djgpp gcc rejects _Float16 codegen even though it advertises
   the macro. Removing it forces zig.h's software-fallback uint16_t branch. */
#define __STDC_WANT_IEC_60559_TYPES_EXT__
#include <float.h>
#undef FLT16_MANT_DIG
