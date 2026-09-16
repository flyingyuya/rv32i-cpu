# RV32I 处理器与微型 RTOS（Verilog + C）

从门电路到操作系统的完整自研：**RV32I 处理器（单周期 + 五级流水线）**，
以及**跑在该处理器上的抢占式微型 RTOS**。全部验证可在本机复现，无需任何开发板。

```
┌──────────────────────────────────────────────────────────────┐
│  应用层      rtos_demo.c     A(sleep) / B(compute) / C(yield) │
├──────────────────────────────────────────────────────────────┤
│  内核层      rtos.c         任务创建 / 调度 / 系统调用 / tick  │
│              trap.S         上下文保存恢复                     │
│              switch.S       首次启动 / 任务出口                │
├──────────────────────────────────────────────────────────────┤
│  硬件层      rv32i_rtos.v   CSR / trap / mret / 定时器 / MMIO │
│              rv32i_cpu.v    单周期 RV32I                      │
│              rv32i_pipe.v   五级流水线 RV32I                   │
└──────────────────────────────────────────────────────────────┘
```

## 目录结构

```
rv32i-cpu/
├── rtl/
│   ├── rv32i_rtos.v         # 面向 RTOS 的 CPU：CSR + trap + 定时器 + MMIO
│   ├── rv32i_cpu.v          # 单周期 RV32I
│   ├── rv32i_pipe.v         # 五级流水线 RV32I
│   ├── forward_unit.v       # 前递单元（RAW 数据冒险）
│   ├── hazard_unit.v        # 冒险检测（load-use 停顿）
│   ├── control.v  alu.v  imm_gen.v  regfile.v  imem.v  dmem.v
├── sim/
│   ├── tb_rv32i_cpu.v       # 单周期自检测试平台
│   ├── tb_rv32i_pipe.v      # 流水线自检测试平台
│   └── tb_rtos.v            # RTOS 仿真平台（打印 MMIO UART 输出）
├── sw/
│   ├── rvasm.py             # 迷你 RV32I 汇编器
│   ├── rvsim.py             # RV32I 指令级功能模型（黄金参考）
│   ├── bin2hex.py           # flat binary -> $readmemh 镜像
│   ├── tests/               # 6 组汇编测试（含流水线冒险专项）
│   └── rtos/                # 裸机 RTOS
│       ├── rtos.h  rtos.c   #   内核：TCB / 调度 / 系统调用
│       ├── trap.S  switch.S #   上下文保存恢复 / 首次启动
│       ├── crt0.S  link.ld  #   启动代码与内存布局
│       ├── divsi3.c         #   自研整数除法律例（工具链无 riscv compiler-rt）
│       ├── mmio.h           #   MMIO 外设封装
│       ├── build.sh         #   裸机构建脚本
│       └── rtos_demo.c      #   演示程序
├── docs/
│   ├── design.md            # 单周期设计 / 控制信号表 / 面试问答
│   ├── pipeline.md          # 流水线冒险分析 / CPI 实测 / 面试问答
│   └── rtos.md              # RTOS 架构 / 踩坑复盘 / 面试问答
├── run_tests.sh             # CPU 回归（2 个 DUT × 6 组测试）
└── run_rtos.sh              # RTOS 构建 + 仿真
```

## 一、CPU 部分

```bash
./run_tests.sh     # 单周期 + 流水线 × 6 组测试 = 12 项，全部自检
```

```
  PASS  test_arith    rv32i_cpu   28 cycles  |  rv32i_pipe   32 cycles
  PASS  test_branch   rv32i_cpu   51 cycles  |  rv32i_pipe   83 cycles
  PASS  test_hazard   rv32i_cpu   24 cycles  |  rv32i_pipe   33 cycles
  PASS  test_jump     rv32i_cpu 1687 cycles  |  rv32i_pipe 2759 cycles
  PASS  test_mem      rv32i_cpu   25 cycles  |  rv32i_pipe   29 cycles
  PASS  test_sort     rv32i_cpu  303 cycles  |  rv32i_pipe  439 cycles
  合计: 12 通过 / 0 失败
```

**验证方法：三方交叉验证。** Python 指令级功能模型、单周期 RTL、流水线 RTL
是三条独立实现，跑同一份程序必须给出完全相同的 31 个通用寄存器结果。

**流水线实现要点**：IF/ID/EX/MEM/WB 五级；EX/MEM 与 MEM/WB 两级前递解决 RAW；
load-use 冒险停顿插入气泡；分支 EX 级解析并冲刷两级；并额外补上最容易漏掉的
**WB→ID 同拍写读旁路**（相隔三条指令时才暴露，由 `test_hazard.s` 专门覆盖）。

详见 [docs/design.md](docs/design.md)、[docs/pipeline.md](docs/pipeline.md)。

## 二、RTOS 部分

```bash
./run_rtos.sh
```

```
[rtos] tasks: A(sleep) B(compute,no-yield) C(yield) M(monitor)
[rtos] timer tick = 2000 cycles
[rtos] schedule:  ACBCCACCABABBAB

[rtos] ticks          = 17
[rtos] context switch = 22
[rtos] tasks finished = 3
[rtos] RESULT: PASS
```

**硬件侧新增**：CSR（`mstatus/mie/mtvec/mepc/mcause/mip/mscratch`）、
Zicsr 指令、`ecall` 同步异常、机器定时器中断、`mret`、
MMIO（UART / EXIT / mtime / mtimecmp）。

**内核侧**：静态栈任务创建（手工构造初始上下文帧）、优先级抢占调度、
同优先级时间片轮转、`ecall` 系统调用（yield / sleep / exit）、
31 个通用寄存器 + `mepc` 的上下文切换。

`ACBCCACCABABBAB` 的交错输出即为调度生效的证据：其中 **B 是纯计算任务，
整个生命周期从不主动让出 CPU**，它能被交替执行只能靠定时器抢占。

**踩坑复盘**：定时器最初在 ISR 开头重新装载，而 ISR 自身耗时超过 tick 间隔，
导致 `mret` 前 `mtip` 已再次置位，形成 trap 活锁、任务一条指令都执行不了。
定位过程与修复见 [docs/rtos.md](docs/rtos.md) 第 6 节。

## 环境准备

```bash
# 仿真器
sudo pacman -S iverilog gtkwave     # Arch
sudo apt install iverilog gtkwave   # Ubuntu/Debian

# RISC-V 交叉编译（RTOS 部分需要）
#   本机用 ziglang/clang 亦可；仓库脚本默认调用 PATH 中的 rvcc
```

CPU 部分只需 `iverilog` + `python3`，**无需 RISC-V 工具链**（汇编器自带）。

## 已知限制与后续方向

- 流水线分支在 EX 级解析且无预测器，分支密集代码 CPI 上升；
- RTOS 跑在单周期 CPU 上（trap 天然精确）；流水线版精确中断待做；
- RTOS 暂无信号量/互斥量，因而也没有优先级继承；
- IMEM/DMEM 为仿真用组合读存储，上板需替换为 Block RAM 或接入 AXI 总线；
- 未实现 CSR 之外的异常（缺页/非法指令）、RV32C、RV32M、中断控制器（PLIC）。
