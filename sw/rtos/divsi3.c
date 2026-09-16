/*=============================================================================
  divsi3.c  --  自研整数除法律例
  ---------------------------------------------------------------------------
  交叉工具链未提供 riscv32 版 compiler-rt，而 C 语言的 / 与 % 会被编译成
  对 __udivsi3 / __umodsi3 等例程的调用。这里用"移位-相减"算法自行实现，
  既补齐了运行时，也避免了对 libgcc / compiler-rt 的依赖。

  注意：实现内部不能使用 / 和 %，否则会自我递归。
=============================================================================*/

typedef unsigned int u32;
typedef int          s32;

/* 无符号除法：逐位试商（移位-相减） */
u32 __udivsi3(u32 n, u32 d)
{
    u32 q = 0;
    u32 r = 0;
    int i;

    if (d == 0)
        return 0xFFFFFFFFu;          /* 除零：返回全 1，不触发异常 */

    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            q |= (1u << i);
        }
    }
    return q;
}

u32 __umodsi3(u32 n, u32 d)
{
    u32 r = 0;
    int i;

    if (d == 0)
        return n;

    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d)
            r -= d;
    }
    return r;
}

/* 有符号版本：取绝对值后调用无符号版本，再修正符号 */
s32 __divsi3(s32 n, s32 d)
{
    int neg = 0;
    u32 un, ud;
    u32 q;

    if (n < 0) { un = (u32)(-(u32)n); neg ^= 1; } else un = (u32)n;
    if (d < 0) { ud = (u32)(-(u32)d); neg ^= 1; } else ud = (u32)d;

    q = __udivsi3(un, ud);
    return neg ? -(s32)q : (s32)q;
}

s32 __modsi3(s32 n, s32 d)
{
    int neg = 0;
    u32 un, ud;
    u32 r;

    if (n < 0) { un = (u32)(-(u32)n); neg = 1; } else un = (u32)n;
    if (d < 0) { ud = (u32)(-(u32)d); } else ud = (u32)d;

    r = __umodsi3(un, ud);
    return neg ? -(s32)r : (s32)r;
}
