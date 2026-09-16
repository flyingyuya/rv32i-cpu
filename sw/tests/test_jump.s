# =============================================================
#  test_jump.s  --  RV32I 跳转 / 函数调用测试
#  覆盖: jal jalr 以及通过栈帧实现的递归调用
#  计算 fib(10) = 55
# =============================================================
.text

    li   sp, 0x800            # 初始化栈指针
    li   a0, 10
    jal  ra, fib              # a0 = fib(10)

    li   x5, 55
    bne  a0, x5, fail

    # 再测一次 jalr 直接返回
    jal  ra, leaf
    j    done

# ---- 递归斐波那契 ----
# a0 = n
fib:
    li   t0, 2
    blt  a0, t0, fib_base     # if n < 2 return n

    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   a0, 4(sp)            # 保存 n

    addi a0, a0, -1
    jal  ra, fib              # fib(n-1)
    sw   a0, 8(sp)            # 保存 fib(n-1)

    lw   a0, 4(sp)
    addi a0, a0, -2
    jal  ra, fib              # fib(n-2)

    lw   t1, 8(sp)
    add  a0, a0, t1           # fib(n-1) + fib(n-2)

    lw   ra, 0(sp)
    addi sp, sp, 12
    jalr x0, ra, 0            # ret

fib_base:
    jalr x0, ra, 0            # ret

# ---- 一个叶子函数 ----
leaf:
    li   x6, 0x1E             # 30
    addi x6, x6, 12           # 42
    jalr x0, ra, 0

fail:
    li   x31, 0xDEAD
done:
    ecall
