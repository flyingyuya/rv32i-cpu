# RTOS 设计说明

在自研 RV32I CPU 上运行的**抢占式微型 RTOS**。整个系统从硬件到操作系统全部自研：

```
Verilog CPU (rv32i_rtos.v)  ──  自研 CSR / trap / 定时器 / MMIO
        ▲
        │  clang 交叉编译 (rv32i) + ld.lld 链接 + 自研 bin2hex
        ▼
C 内核 (rtos.c) + 汇编上下文切换 (trap.S / switch.S)
```

## 1. 硬件平台（CPU 侧新增）

在单周期 RV32I 基础上增加了运行 RTOS 所必需的特权机制：

| 部件 | 说明 |
|---|---|
| CSR 寄存器 | `mstatus` `mie` `mtvec` `mepc` `mcause` `mip` `mscratch` |
| Zicsr 指令 | `csrrw/csrrs/csrrc` 及其立即数形式 |
| Trap | `ecall` 同步异常（`mcause=11`）+ 机器定时器中断（`mcause=0x80000007`） |
| `mret` | 恢复 `pc ← mepc`，`MIE ← MPIE`，`MPIE ← 1` |
| 定时器 | MMIO `mtime`（每周期 +1）/ `mtimecmp`，`mip.MTIP = mtime >= mtimecmp` |
| UART | 写 `0x1000_0000` 低 8 位即输出一个字符 |
| EXIT | 写 `0x1000_0004` 结束仿真 |

### 内存映射

| 地址 | 用途 |
|---|---|
| `0x0000_0000 - 0x0000_3FFF` | RAM 16KB（代码 / 数据 / 各任务栈） |
| `0x1000_0000` | UART TX |
| `0x1000_0004` | EXIT |
| `0x2000_0000` | `mtime`（只读） |
| `0x2000_0004` | `mtimecmp`（读写） |

> **为什么用单周期而不是五级流水线？**
> 单周期下 trap 天然精确：每条指令原子完成，`mepc = 当前 PC`，无需冲刷流水线。
> 流水线的精确中断需要额外处理"取指/译码级未提交指令"的冲刷与恢复，留作后续工作。

## 2. 上下文帧布局

陷阱入口在**当前任务的栈**上压入完整的 33 字上下文帧：

| 字下标 | 字节偏移 | 内容 |
|---|---|---|
| 1 | 4 | `x1` (ra) |
| 2 | 8 | `x2` (原始 sp) |
| N | 4N | `xN` |
| 31 | 124 | `x31` |
| 32 | 128 | `mepc`（返回地址） |

任务创建时由 C 侧**手工构造**这样一个帧：`mepc = 任务入口`、`ra = task_entry_trampoline`、
`x2 = 栈顶`。于是第一次 `mret` 就直接跳入任务函数，且任务函数返回时会走到 `task_exit()`。

## 3. 调度

```
schedule():
    从 g_cur 的下一项开始扫描所有任务
    跳过非 READY 的
    取优先级数值最小的（最高优先级）
    同优先级下，因为从 cur+1 开始且比较用严格小于，所以会轮到下一个任务
```

- **优先级抢占**：更高优先级任务一旦就绪立即抢占；
- **同优先级轮转**：定时器 tick 到达时轮转到下一个同优先级任务；
- **阻塞**：`task_sleep(n)` 把任务置为 `SLEEPING` 并记录剩余 tick，每次定时器中断递减，
  减到 0 时重新置为 `READY`。

## 4. 系统调用

任务通过 `ecall` 陷入内核，系统调用号放在 `a0`、参数放在 `a1`：

| 号 | 名称 | 语义 |
|---|---|---|
| 0 | `SYS_YIELD` | 主动让出 CPU，调度器轮转 |
| 1 | `SYS_SLEEP` | 睡眠 `a1` 个 tick |
| 2 | `SYS_EXIT` | 任务结束，状态置 `DEAD` |

内核在返回前把保存的 `mepc` 加 4，因此任务从 `ecall` 之后继续执行。

## 5. 运行结果

```
$ ./run_rtos.sh
[rtos] tasks: A(sleep) B(compute,no-yield) C(yield) M(monitor)
[rtos] timer tick = 2000 cycles
[rtos] schedule:  ACBCCACCABABBAB

[rtos] ticks          = 17
[rtos] context switch = 22
[rtos] tasks finished = 3
[rtos] RESULT: PASS
```

输出中的 `A/B/C` 交错即为调度生效的证据：

- **A** 每轮 `task_sleep(3)`，验证阻塞与定时唤醒；
- **B** 是纯计算任务，**整个生命周期从不主动让出 CPU**，它还能被交替执行，
  唯一原因就是定时器中断抢占；
- **C** 主动 `task_yield()`，验证同优先级时间片轮转；
- **M** 优先级最低（9），只有在其他任务全部阻塞时才运行，负责统计与判定。

## 6. 后续工作

1. 五级流水线版本的精确中断（把 RTOS 移植到 `rv32i_pipe`）；
2. 信号量 / 互斥量 + 优先级继承；
3. 任务动态创建与回收（当前是静态栈）；
4. 栈溢出检测（栈魔数 / 栈水位统计）；
5. Tickless 低功耗模式；
6. 接真实外设（UART 中断收发、SPI 传感器）并与 FreeRTOS 做对比。
