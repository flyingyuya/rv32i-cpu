# =============================================================
#  test_branch.s  --  RV32I 条件分支测试
#  覆盖: beq bne blt bge bltu bgeu
#  含一个累加循环（验证分支回跳）
# =============================================================
.text

    # ---- 循环: sum(1..10) ----
    li   x1, 0                # i
    li   x2, 0                # sum
    li   x3, 10               # n
loop:
    addi x1, x1, 1
    add  x2, x2, x1
    blt  x1, x3, loop         # sum = 55
    li   x4, 55
    bne  x2, x4, fail         # 校验失败则跳到 fail

    # ---- beq / bne ----
    li   x5, 0
    li   x6, 5
    beq  x5, x6, t_beq
    li   x7, 111              # 应当执行
t_beq:
    bne  x5, x6, t_bne
    li   x7, 999              # 不应执行
t_bne:
    li   x8, 1                # x7 应为 111

    # ---- 有符号比较 ----
    li   x9,  -1
    li   x10,  1
    blt  x9,  x10, t_blt
    li   x11, 1000            # 不应执行
t_blt:
    bge  x10, x9,  t_bge
    li   x11, 1000            # 不应执行
t_bge:
    li   x11, 7               # 应当执行

    # ---- 无符号比较: 0xFFFFFFFF > 1 ----
    bltu x9,  x10, t_bltu
    li   x12, 8               # 应当执行（-1 无符号是最大值，不小于 1）
t_bltu:
    bgeu x9,  x10, t_bgeu
    li   x12, 1000            # 不应执行
t_bgeu:

    j    done

fail:
    li   x31, 0xDEAD
done:
    ecall
