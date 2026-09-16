/*=============================================================================
  rtos.h  --  微型抢占式 RTOS 内核接口
=============================================================================*/
#ifndef RTOS_H
#define RTOS_H

#include <stdint.h>

/* ---- 配置 ---- */
#define RTOS_MAX_TASKS    6
#define RTOS_STACK_WORDS  256        /* 每任务栈 1KB */
#define RTOS_TICK_CYCLES  2000       /* 定时器中断间隔（CPU 周期） */

/* 上下文帧：33 个字 = 31 个通用寄存器 + sp 槽 + mepc 槽
   布局必须与 trap.S 完全一致 */
#define FRAME_WORDS      33
#define FRAME_MEPC_WORD  32          /* 字下标 32 存放 mepc */

/* 任务状态 */
#define TASK_READY    0
#define TASK_SLEEPING 1
#define TASK_DEAD     2

/* 系统调用号 */
#define SYS_YIELD  0
#define SYS_SLEEP  1
#define SYS_EXIT   2

typedef void (*task_fn_t)(void);

/* 任务控制块。sp 必须是第一个字段：上下文切换直接访问它。 */
typedef struct {
    uint32_t *sp;
    uint32_t  prio;        /* 数值越小优先级越高 */
    uint32_t  state;
    uint32_t  delay;       /* 剩余睡眠 tick */
    char      tag;
} tcb_t;

extern tcb_t    g_tcb[RTOS_MAX_TASKS];
extern int      g_ntasks;
extern int      g_cur;
extern uint32_t g_switches;
extern uint32_t g_ticks;

void  rtos_init(void);
int   task_create(task_fn_t fn, uint32_t prio, char tag);
void  rtos_start(int first_task);
void  rtos_enable_timer(void);
void  task_exit(void);

/* 系统调用（由 trap.S 触发 ecall 进入内核） */
void  task_yield(void);
void  task_sleep(uint32_t ticks);

/* 由 trap.S 调用的 C 侧陷阱处理程序，返回下一个任务的栈指针 */
uint32_t *trap_handler(uint32_t *sp);

/* ---- CSR 访问 ---- */
#define CSR_READ(name) ({                        \
        uint32_t __v;                            \
        __asm__ volatile ("csrr %0, " #name      \
                          : "=r"(__v));          \
        __v; })

#define CSR_WRITE(name, val)                     \
    __asm__ volatile ("csrw " #name ", %0" :: "r"((uint32_t)(val)))

#define MSTATUS_MIE   0x8u
#define MSTATUS_MPIE  0x80u

static inline void irq_enable(void)  { CSR_WRITE(mstatus, CSR_READ(mstatus) | MSTATUS_MIE); }
static inline void irq_disable(void) { CSR_WRITE(mstatus, CSR_READ(mstatus) & ~MSTATUS_MIE); }

#endif /* RTOS_H */
