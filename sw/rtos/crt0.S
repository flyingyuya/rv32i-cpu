/*=============================================================================
  crt0.S  --  RTOS 启动代码
    1. 设置栈指针
    2. 清零 .bss
    3. 调用 main
    4. main 返回后写 EXIT 寄存器结束仿真
=============================================================================*/
    .section .text.start, "ax"
    .globl _start
    .type  _start, @function

_start:
    la      sp, _stack_top

    /* 清零 .bss */
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    /* main 返回：写 EXIT 寄存器，仿真结束 */
    li      t0, 0x10000004
    sw      zero, 0(t0)
3:
    j       3b

    .size _start, . - _start

/* 栈顶由链接脚本定义 */
    .section .text, "ax"
    .globl _stack_top
