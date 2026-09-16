/*=============================================================================
  rtos.c  --  微型抢占式 RTOS 内核
  ---------------------------------------------------------------------------
  功能：
    * 任务创建（静态栈 + 手工构造初始上下文帧）
    * 优先级抢占调度 + 同优先级时间片轮转
    * 基于 ecall 的系统调用：task_yield / task_sleep / task_exit
    * 基于机器定时器中断的抢占
    * 上下文切换（trap.S 保存/恢复 31 个通用寄存器 + mepc）
=============================================================================*/
#include "rtos.h"
#include "mmio.h"

/*----------------------------------------------------------------------------
  全局状态
----------------------------------------------------------------------------*/
tcb_t    g_tcb[RTOS_MAX_TASKS];
int      g_ntasks;
int      g_cur;
uint32_t g_switches;
uint32_t g_ticks;

static uint32_t g_stacks[RTOS_MAX_TASKS][RTOS_STACK_WORDS];

extern void rtos_start_asm(int idx);
extern void trap_entry(void);
extern void task_entry_trampoline(void);

/*----------------------------------------------------------------------------
  调度器：优先级抢占 + 同优先级轮转
    从 g_cur 的下一项开始扫描，保证同优先级任务轮流获得 CPU；
    遇到优先级数值更小的（更高优先级）任务则抢占。
----------------------------------------------------------------------------*/
static void schedule(void)
{
    int best = -1;

    for (int k = 1; k <= g_ntasks; k++) {
        int i = (g_cur + k) % g_ntasks;
        if (g_tcb[i].state != TASK_READY)
            continue;
        if (best < 0 || g_tcb[i].prio < g_tcb[best].prio)
            best = i;
    }

    if (best < 0)
        return;                       /* 没有就绪任务 */

    if (best != g_cur) {
        g_switches++;
        g_cur = best;
    }
}

/*----------------------------------------------------------------------------
  陷阱处理程序（由 trap.S 调用）
    入参 sp   : 当前任务被中断时的上下文帧
    返回值    : 下一个任务的上下文帧（可能还是同一个任务）
----------------------------------------------------------------------------*/
uint32_t *trap_handler(uint32_t *sp)
{
    uint32_t cause = CSR_READ(mcause);

    g_tcb[g_cur].sp = sp;

    if (cause == 0x80000007u) {
        /* ---- 机器定时器中断 ---- */
        g_ticks++;

        for (int i = 0; i < g_ntasks; i++) {
            if (g_tcb[i].state == TASK_SLEEPING) {
                if (g_tcb[i].delay > 0)
                    g_tcb[i].delay--;
                if (g_tcb[i].delay == 0)
                    g_tcb[i].state = TASK_READY;
            }
        }

    } else if (cause == 11u) {
        /* ---- ecall 系统调用 ---- */
        uint32_t num = sp[10];        /* a0 = 系统调用号 */
        uint32_t arg = sp[11];        /* a1 = 参数 */

        sp[FRAME_MEPC_WORD] += 4;     /* 返回时跳过 ecall 指令 */

        if (num == SYS_SLEEP) {
            g_tcb[g_cur].state = TASK_SLEEPING;
            g_tcb[g_cur].delay = arg;
        } else if (num == SYS_EXIT) {
            g_tcb[g_cur].state = TASK_DEAD;
        }
        /* SYS_YIELD：状态不变，交给调度器轮转 */
    }

    schedule();

    /* 关键：定时器必须在 ISR 末尾重新装载。
       若在开头装载，当 ISR 自身耗时超过 tick 间隔时，
       mret 之前 mtip 已再次置位，会导致 trap 活锁、任务永远得不到执行。 */
    if (cause == 0x80000007u)
        MTIMECMP = MTIME + RTOS_TICK_CYCLES;

    return g_tcb[g_cur].sp;
}

/*----------------------------------------------------------------------------
  初始化
----------------------------------------------------------------------------*/
void rtos_init(void)
{
    for (int i = 0; i < RTOS_MAX_TASKS; i++) {
        g_tcb[i].sp    = 0;
        g_tcb[i].prio  = 0;
        g_tcb[i].state = TASK_DEAD;
        g_tcb[i].delay = 0;
        g_tcb[i].tag   = '?';
    }
    g_ntasks   = 0;
    g_cur      = 0;
    g_switches = 0;
    g_ticks    = 0;

    CSR_WRITE(mtvec, (uint32_t)(uintptr_t)trap_entry);
}

/*----------------------------------------------------------------------------
  创建任务：在静态栈顶手工构造一个上下文帧，
  使第一次 mret 直接跳入任务入口，sp 指向栈顶。
----------------------------------------------------------------------------*/
int task_create(task_fn_t fn, uint32_t prio, char tag)
{
    if (g_ntasks >= RTOS_MAX_TASKS)
        return -1;

    int i = g_ntasks++;

    g_tcb[i].prio  = prio;
    g_tcb[i].state = TASK_READY;
    g_tcb[i].delay = 0;
    g_tcb[i].tag   = tag;

    uintptr_t top = (uintptr_t)&g_stacks[i][RTOS_STACK_WORDS];
    top &= ~(uintptr_t)7;                                  /* 8 字节对齐 */
    uint32_t *f = (uint32_t *)(top - FRAME_WORDS * 4);

    for (int k = 0; k < FRAME_WORDS; k++)
        f[k] = 0;

    f[1]                = (uint32_t)(uintptr_t)task_entry_trampoline;  /* x1 = ra */
    f[2]                = (uint32_t)top;                               /* x2 = 初始 sp */
    f[FRAME_MEPC_WORD]  = (uint32_t)(uintptr_t)fn;                     /* 任务入口 */

    g_tcb[i].sp = f;
    return i;
}

/*----------------------------------------------------------------------------
  使能定时器中断
----------------------------------------------------------------------------*/
void rtos_enable_timer(void)
{
    MTIMECMP = MTIME + RTOS_TICK_CYCLES;
    CSR_WRITE(mie, 0x80);                 /* MTIE */
}

/*----------------------------------------------------------------------------
  启动调度：进入第一个任务后不再返回
----------------------------------------------------------------------------*/
void rtos_start(int first_task)
{
    g_cur = first_task;
    rtos_start_asm(first_task);
}

/*----------------------------------------------------------------------------
  系统调用封装
----------------------------------------------------------------------------*/
static inline void syscall(uint32_t num, uint32_t arg)
{
    register uint32_t a0 __asm__("a0") = num;
    register uint32_t a1 __asm__("a1") = arg;
    __asm__ volatile ("ecall" : "+r"(a0) : "r"(a1) : "memory");
}

void task_yield(void)
{
    syscall(SYS_YIELD, 0);
}

void task_sleep(uint32_t ticks)
{
    syscall(SYS_SLEEP, ticks);
}

void task_exit(void)
{
    syscall(SYS_EXIT, 0);
    for (;;)
        ;
}
