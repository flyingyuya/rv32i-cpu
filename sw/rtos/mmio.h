//=============================================================================
//  mmio.h  --  RV32I RTOS 平台的 MMIO 外设定义
//=============================================================================
#ifndef MMIO_H
#define MMIO_H

#include <stdint.h>

#define UART_TX     (*(volatile uint32_t *)0x10000000u)   // 写低 8 位 -> 输出字符
#define EXIT_REG    (*(volatile uint32_t *)0x10000004u)   // 写任意值 -> 结束仿真
#define MTIME       (*(volatile uint32_t *)0x20000000u)   // 只读，每周期 +1
#define MTIMECMP    (*(volatile uint32_t *)0x20000004u)   // 定时器比较值

static inline void uart_putc(char c)
{
    UART_TX = (uint32_t)(uint8_t)c;
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static inline void uart_puthex(uint32_t v)
{
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t d = (v >> i) & 0xF;
        uart_putc((char)(d < 10 ? '0' + d : 'a' + d - 10));
    }
}

static inline void uart_putu(uint32_t v)
{
    char buf[11];
    int i = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i--) uart_putc(buf[i]);
}

#endif /* MMIO_H */
