#include "rtos.h"
#include "mmio.h"

int main(void)
{
    uart_puts("[csr] mscratch wr/rd = ");
    CSR_WRITE(mscratch, 0x12345678u);
    uart_puthex(CSR_READ(mscratch)); uart_putc('\n');

    uart_puts("[csr] mtvec    wr/rd = ");
    CSR_WRITE(mtvec, 0x100u);
    uart_puthex(CSR_READ(mtvec)); uart_putc('\n');

    uart_puts("[csr] mstatus  wr/rd = ");
    CSR_WRITE(mstatus, 0x88u);
    uart_puthex(CSR_READ(mstatus)); uart_putc('\n');

    uart_puts("[csr] mie      wr/rd = ");
    CSR_WRITE(mie, 0x80u);
    uart_puthex(CSR_READ(mie)); uart_putc('\n');

    uart_puts("[csr] mip      rd    = ");
    uart_puthex(CSR_READ(mip)); uart_putc('\n');

    uart_puts("[csr] mtime    rd    = ");
    uart_puthex(MTIME); uart_putc('\n');

    uart_puts("[csr] mtimecmp wr/rd = ");
    MTIMECMP = 0xDEADBEEFu;
    uart_puthex(MTIMECMP); uart_putc('\n');

    uart_puts("[csr] done\n");
    EXIT_REG = 1;
    return 0;
}
