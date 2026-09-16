#include "rtos.h"
#include "mmio.h"

extern void trap_entry(void);
static volatile uint32_t g_n;
static volatile uint32_t g_irq;

uint32_t *trap_handler(uint32_t *sp)
{
    uint32_t cause = CSR_READ(mcause);
    g_n++;
    if (cause == 11u) {
        sp[FRAME_MEPC_WORD] += 4;          /* 跳过 ecall */
        uart_puts("[trap] ecall caught, mcause=");
    } else {
        g_irq++;
        MTIMECMP = MTIME + 100000u;        /* 关掉后续定时器中断 */
        uart_puts("[trap] timer irq, mcause=");
    }
    uart_puthex(cause);
    uart_putc('\n');
    if (g_n >= 3) EXIT_REG = 1;
    return sp;
}

int main(void)
{
    uart_puts("[trap] install mtvec\n");
    CSR_WRITE(mtvec, (uint32_t)(uintptr_t)trap_entry);

    uart_puts("[trap] ecall #1\n");
    __asm__ volatile("ecall");
    uart_puts("[trap] back from #1\n");

    __asm__ volatile("ecall");
    uart_puts("[trap] back from #2\n");

    uart_puts("[trap] enable timer, wait...\n");
    MTIMECMP = MTIME + 200u;
    CSR_WRITE(mie, 0x80u);
    irq_enable();
    for (volatile int k = 0; k < 2000; k++) ;

    uart_puts("[trap] irq count = "); uart_putu(g_irq); uart_putc('\n');
    uart_puts("[trap] done\n");
    EXIT_REG = 1;
    return 0;
}
