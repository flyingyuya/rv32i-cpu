# =============================================================
#  test_sort.s  --  冒泡排序 + 求和（综合性演示程序）
#  数据段存放未排序数组，程序原地排序并统计结果
#  预期: 排序后 [1,2,3,4,5,7,8,9]，和 = 39，首 = 1，末 = 9
# =============================================================
.data
arr:
    .word 5, 3, 9, 1, 7, 2, 8, 4

.text
    li   a0, 0x400            # 数组基址
    li   a1, 8                # 元素个数

    # ---------------- 冒泡排序 ----------------
    addi a2, a1, -1           # a2 = n-1
outer:
    li   a3, 0                # i = 0
inner:
    slli t0, a3, 2
    add  t0, a0, t0           # &arr[i]
    lw   t1, 0(t0)            # arr[i]
    lw   t2, 4(t0)            # arr[i+1]
    ble  t1, t2, no_swap
    sw   t2, 0(t0)            # 交换
    sw   t1, 4(t0)
no_swap:
    addi a3, a3, 1
    blt  a3, a2, inner
    addi a2, a2, -1
    bgtz a2, outer

    # ---------------- 求排序后数组的和 ----------------
    li   a3, 0
    li   s0, 0                # 累加和
sum_loop:
    slli t0, a3, 2
    add  t0, a0, t0
    lw   t1, 0(t0)
    add  s0, s0, t1
    addi a3, a3, 1
    blt  a3, a1, sum_loop

    lw   s1, 0(a0)            # 首元素
    slli t0, a1, 2
    add  t0, a0, t0
    lw   s2, -4(t0)           # 末元素

    ecall
