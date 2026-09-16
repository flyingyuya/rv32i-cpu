# =============================================================
#  test_arith.s  --  RV32I 算术 / 逻辑 / 移位 / 立即数 指令测试
#  覆盖: add sub sll slt sltu xor srl sra or and
#        addi slti sltiu xori ori andi slli srli srai
#        lui auipc
# =============================================================
.text

    li   x1, 5
    li   x2, 3

    # ---- R 型 ----
    add  x3,  x1, x2          # 8
    sub  x4,  x1, x2          # 2
    sll  x5,  x1, x2          # 40
    slt  x6,  x1, x2          # 0
    sltu x7,  x1, x2          # 0
    xor  x8,  x1, x2          # 6
    srl  x9,  x1, x2          # 0
    sra  x10, x1, x2          # 0
    or   x11, x1, x2          # 7
    and  x12, x1, x2          # 1

    # ---- 负数移位：验证算术右移 ----
    li   x13, -8              # 0xfffffff8
    li   x14, 2
    sra  x15, x13, x14        # 0xfffffffe  (-2)
    srl  x16, x13, x14        # 0x3ffffffe

    # ---- I 型 ----
    addi  x17, x1, 100        # 105
    slti  x18, x1, 3          # 0
    sltiu x19, x1, 3          # 0
    xori  x20, x1, 0xF        # 10
    ori   x21, x1, 0x10       # 21
    andi  x22, x1, 0x1        # 1
    slli  x23, x1, 4          # 80
    srli  x24, x13, 1         # 0x7ffffffc
    srai  x25, x13, 1         # 0xfffffffc

    # ---- U 型 ----
    lui   x26, 0x12345        # 0x12345000
    auipc x27, 0              # 本条指令的 PC

    ecall
