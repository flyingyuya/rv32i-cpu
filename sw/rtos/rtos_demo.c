//=============================================================================
//  rtos_demo.c  --  RTOS 演示程序
//
//  四个任务，分别演示 RTOS 的三类调度行为：
//    A(prio 1)  sleep 阻塞   -> 验证 task_sleep 与唤醒
//    B(prio 1)  纯计算不让出 -> 验证定时器抢占（它从不主动 yield）
//    C(prio 1)  显式 yield   -> 验证同优先级时间片轮转
//    M(prio 9)  监视任务     -> 最低优先级，统计并判定结果
//=============================================================================
#include "rtos.h"
#include "mmio.h"

static volatile uint32_t g_done;

//-----------------------------------------------------------------------------
// A：打印后睡眠，演示阻塞与定时唤醒
//-----------------------------------------------------------------------------
static void task_a(void)
{
    for (int i = 0; i < 5; i++) {
        uart_putc('A');
        task_sleep(3);
    }
    g_done++;
    task_exit();
}

//-----------------------------------------------------------------------------
// B：纯计算任务，整个生命周期从不主动让出 CPU
//    它还能被打断，唯一原因就是定时器中断抢占
//-----------------------------------------------------------------------------
static void task_busy(void)
{
    for (int i = 0; i < 120; i++) {
        for (volatile int k = 0; k < 20; k++)
            ;
        if ((i % 25) == 0)
            uart_putc('B');
    }
    g_done++;
    task_exit();
}

//-----------------------------------------------------------------------------
// C：显式让出，演示同优先级轮转
//-----------------------------------------------------------------------------
static void task_c(void)
{
    for (int i = 0; i < 5; i++) {
        uart_putc('C');
        task_yield();
    }
    g_done++;
    task_exit();
}

//-----------------------------------------------------------------------------
// M：监视任务（最低优先级），等待所有任务结束后统计并退出
//-----------------------------------------------------------------------------
static void monitor(void)
{
    while (g_done < 3) {
        uart_putc('.');
        task_sleep(4);
    }

    uart_puts("\n\n[rtos] ticks          = ");
    uart_putu(g_ticks);
    uart_puts("\n[rtos] context switch = ");
    uart_putu(g_switches);
    uart_puts("\n[rtos] tasks finished = 3\n");

    uart_puts("[rtos] RESULT: ");
    if (g_switches >= 20)
        uart_puts("PASS\n");
    else
        uart_puts("FAIL\n");

    EXIT_REG = 1;
    for (;;)
        task_yield();
}

//-----------------------------------------------------------------------------
int main(void)
{
    rtos_init();

    task_create(monitor,   9, 'M');     // 最低优先级：只有别人都阻塞时才运行
    task_create(task_a,    1, 'A');
    task_create(task_busy, 1, 'B');
    task_create(task_c,    1, 'C');

    rtos_enable_timer();

    uart_puts("[rtos] tasks: A(sleep) B(compute,no-yield) C(yield) M(monitor)\n");
    uart_puts("[rtos] timer tick = ");
    uart_putu(RTOS_TICK_CYCLES);
    uart_puts(" cycles\n[rtos] schedule:  ");

    rtos_start(1);                       // 从 task_a 开始，不返回
    return 0;
}
