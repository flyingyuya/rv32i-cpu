//=============================================================================
//  mini_test.c  --  工具链端到端自检
//  验证：C 编译 -> 链接 -> hex -> iverilog 仿真 -> MMIO UART 输出
//=============================================================================
#include "mmio.h"

int main(void)
{
    uart_puts("=== toolchain OK ===\n");

    uart_puts("add  2+3 = ");
    uart_putu(2 + 3);
    uart_putc('\n');

    uart_puts("loop sum 1..10 = ");
    uint32_t s = 0;
    for (int i = 1; i <= 10; i++)
        s += (uint32_t)i;
    uart_putu(s);
    uart_putc('\n');

    uart_puts("mtime = ");
    uart_putu(MTIME);
    uart_putc('\n');

    uart_puts("=== done ===\n");
    EXIT_REG = 1;
    return 0;
}
