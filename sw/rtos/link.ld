/*=============================================================================
  link.ld  --  RV32I RTOS 裸机链接脚本
  内存布局（16KB RAM，从 0x0 开始）：
      .text / .rodata      代码与只读数据
      .data                已初始化数据（由 hex 镜像直接载入，无需搬运）
      .bss                 零初始化数据（启动代码清零）
      栈区                  每个任务独立栈，见 rtos_config.h
=============================================================================*/
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > RAM

    .data : {
        . = ALIGN(4);
        *(.sdata*)
        *(.data*)
        . = ALIGN(4);
    } > RAM

    _bss_start = .;
    .bss : {
        . = ALIGN(4);
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
    } > RAM
    _bss_end = .;

    /* 内核栈（陷阱处理程序在用户栈之外使用的应急栈） */
    . = ALIGN(16);
    _stack_bottom = .;
    . = . + 0x400;
    _stack_top = .;

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) *(.eh_frame) }
}
