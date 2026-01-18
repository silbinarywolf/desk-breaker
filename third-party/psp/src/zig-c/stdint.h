// Monkey-patch-ish. Include ahead of the PSP SDK headers so that
// the types are 32-bit and correct.

#ifndef ZIG_PSP_STDINT_H
#define ZIG_PSP_STDINT_H

// NOTE(jae): 2026-01-15
// Copy-paste from zig.h with Zig 0.15.2 build

#if SCHAR_MIN == ~0x7F && SCHAR_MAX == 0x7F && UCHAR_MAX == 0xFF
typedef unsigned      char uint8_t;
typedef   signed      char  int8_t;
#define  INT8_C(c) c
#define UINT8_C(c) c##U
#elif SHRT_MIN == ~0x7F && SHRT_MAX == 0x7F && USHRT_MAX == 0xFF
typedef unsigned     short uint8_t;
typedef   signed     short  int8_t;
#define  INT8_C(c) c
#define UINT8_C(c) c##U
#elif INT_MIN == ~0x7F && INT_MAX == 0x7F && UINT_MAX == 0xFF
typedef unsigned       int uint8_t;
typedef   signed       int  int8_t;
#define  INT8_C(c) c
#define UINT8_C(c) c##U
#elif LONG_MIN == ~0x7F && LONG_MAX == 0x7F && ULONG_MAX == 0xFF
typedef unsigned      long uint8_t;
typedef   signed      long  int8_t;
#define  INT8_C(c) c##L
#define UINT8_C(c) c##LU
#elif LLONG_MIN == ~0x7F && LLONG_MAX == 0x7F && ULLONG_MAX == 0xFF
typedef unsigned long long uint8_t;
typedef   signed long long  int8_t;
#define  INT8_C(c) c##LL
#define UINT8_C(c) c##LLU
#endif
#define  INT8_MIN (~INT8_C(0x7F))
#define  INT8_MAX ( INT8_C(0x7F))
#define UINT8_MAX ( INT8_C(0xFF))

#if SCHAR_MIN == ~0x7FFF && SCHAR_MAX == 0x7FFF && UCHAR_MAX == 0xFFFF
typedef unsigned      char uint16_t;
typedef   signed      char  int16_t;
#define  INT16_C(c) c
#define UINT16_C(c) c##U
#elif SHRT_MIN == ~0x7FFF && SHRT_MAX == 0x7FFF && USHRT_MAX == 0xFFFF
typedef unsigned     short uint16_t;
typedef   signed     short  int16_t;
#define  INT16_C(c) c
#define UINT16_C(c) c##U
#elif INT_MIN == ~0x7FFF && INT_MAX == 0x7FFF && UINT_MAX == 0xFFFF
typedef unsigned       int uint16_t;
typedef   signed       int  int16_t;
#define  INT16_C(c) c
#define UINT16_C(c) c##U
#elif LONG_MIN == ~0x7FFF && LONG_MAX == 0x7FFF && ULONG_MAX == 0xFFFF
typedef unsigned      long uint16_t;
typedef   signed      long  int16_t;
#define  INT16_C(c) c##L
#define UINT16_C(c) c##LU
#elif LLONG_MIN == ~0x7FFF && LLONG_MAX == 0x7FFF && ULLONG_MAX == 0xFFFF
typedef unsigned long long uint16_t;
typedef   signed long long  int16_t;
#define  INT16_C(c) c##LL
#define UINT16_C(c) c##LLU
#endif
#define  INT16_MIN (~INT16_C(0x7FFF))
#define  INT16_MAX ( INT16_C(0x7FFF))
#define UINT16_MAX ( INT16_C(0xFFFF))

#if SCHAR_MIN == ~0x7FFFFFFF && SCHAR_MAX == 0x7FFFFFFF && UCHAR_MAX == 0xFFFFFFFF
typedef unsigned      char uint32_t;
typedef   signed      char  int32_t;
#define  INT32_C(c) c
#define UINT32_C(c) c##U
#elif SHRT_MIN == ~0x7FFFFFFF && SHRT_MAX == 0x7FFFFFFF && USHRT_MAX == 0xFFFFFFFF
typedef unsigned     short uint32_t;
typedef   signed     short  int32_t;
#define  INT32_C(c) c
#define UINT32_C(c) c##U
#elif INT_MIN == ~0x7FFFFFFF && INT_MAX == 0x7FFFFFFF && UINT_MAX == 0xFFFFFFFF
typedef unsigned       int uint32_t;
typedef   signed       int  int32_t;
#define  INT32_C(c) c
#define UINT32_C(c) c##U
#elif LONG_MIN == ~0x7FFFFFFF && LONG_MAX == 0x7FFFFFFF && ULONG_MAX == 0xFFFFFFFF
typedef unsigned      long uint32_t;
typedef   signed      long  int32_t;
#define  INT32_C(c) c##L
#define UINT32_C(c) c##LU
#elif LLONG_MIN == ~0x7FFFFFFF && LLONG_MAX == 0x7FFFFFFF && ULLONG_MAX == 0xFFFFFFFF
typedef unsigned long long uint32_t;
typedef   signed long long  int32_t;
#define  INT32_C(c) c##LL
#define UINT32_C(c) c##LLU
#endif
#define  INT32_MIN (~INT32_C(0x7FFFFFFF))
#define  INT32_MAX ( INT32_C(0x7FFFFFFF))
#define UINT32_MAX ( INT32_C(0xFFFFFFFF))

#if SCHAR_MIN == ~0x7FFFFFFFFFFFFFFF && SCHAR_MAX == 0x7FFFFFFFFFFFFFFF && UCHAR_MAX == 0xFFFFFFFFFFFFFFFF
typedef unsigned      char uint64_t;
typedef   signed      char  int64_t;
#define  INT64_C(c) c
#define UINT64_C(c) c##U
#elif SHRT_MIN == ~0x7FFFFFFFFFFFFFFF && SHRT_MAX == 0x7FFFFFFFFFFFFFFF && USHRT_MAX == 0xFFFFFFFFFFFFFFFF
typedef unsigned     short uint64_t;
typedef   signed     short  int64_t;
#define  INT64_C(c) c
#define UINT64_C(c) c##U
#elif INT_MIN == ~0x7FFFFFFFFFFFFFFF && INT_MAX == 0x7FFFFFFFFFFFFFFF && UINT_MAX == 0xFFFFFFFFFFFFFFFF
typedef unsigned       int uint64_t;
typedef   signed       int  int64_t;
#define  INT64_C(c) c
#define UINT64_C(c) c##U
#elif LONG_MIN == ~0x7FFFFFFFFFFFFFFF && LONG_MAX == 0x7FFFFFFFFFFFFFFF && ULONG_MAX == 0xFFFFFFFFFFFFFFFF
typedef unsigned      long uint64_t;
typedef   signed      long  int64_t;
#define  INT64_C(c) c##L
#define UINT64_C(c) c##LU
#elif LLONG_MIN == ~0x7FFFFFFFFFFFFFFF && LLONG_MAX == 0x7FFFFFFFFFFFFFFF && ULLONG_MAX == 0xFFFFFFFFFFFFFFFF
typedef unsigned long long uint64_t;
typedef   signed long long  int64_t;
#define  INT64_C(c) c##LL
#define UINT64_C(c) c##LLU
#endif
#define  INT64_MIN (~INT64_C(0x7FFFFFFFFFFFFFFF))
#define  INT64_MAX ( INT64_C(0x7FFFFFFFFFFFFFFF))
#define UINT64_MAX ( INT64_C(0xFFFFFFFFFFFFFFFF))

typedef size_t uintptr_t;
typedef ptrdiff_t intptr_t;

// Copied from third-party/psp/upstream/pspdev/psp/include/stdint.h

#ifdef __INTPTR_TYPE__
#define INTPTR_MIN (-__INTPTR_MAX__ - 1)
#define INTPTR_MAX (__INTPTR_MAX__)
#define UINTPTR_MAX (__UINTPTR_MAX__)
#elif defined(__PTRDIFF_TYPE__)
#define INTPTR_MAX PTRDIFF_MAX
#define INTPTR_MIN PTRDIFF_MIN
#ifdef __UINTPTR_MAX__
#define UINTPTR_MAX (__UINTPTR_MAX__)
#else
#define UINTPTR_MAX (2UL * PTRDIFF_MAX + 1)
#endif
#else
/*
 * Fallback to hardcoded values, 
 * should be valid on cpu's with 32bit int/32bit void*
 */
#define INTPTR_MAX (__STDINT_EXP(LONG_MAX))
#define INTPTR_MIN (-__STDINT_EXP(LONG_MAX) - 1)
#define UINTPTR_MAX (__STDINT_EXP(LONG_MAX) * 2UL + 1)
#endif

#endif
