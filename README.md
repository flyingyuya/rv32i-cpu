# RV32I 处理器（Verilog）：单周期 + 五级流水线

用 Verilog 从零实现的 **RV32I CPU**，包含**单周期**与**五级流水线**两个版本。
配套自研汇编器与 Python 指令级功能模型（Golden Model），通过**双实现交叉验证**
保证 RTL 与参考模型行为一致：6 组测试 × 2 个 DUT 全部通过，31/31 通用寄存器逐一比对。

```
单周期 : 取指 → 译码 → 执行 → 访存 → 写回      （CPI = 1，周期长）
流水线 : IF → ID → EX → MEM → WB              （CPI > 1，周期短、主频高）
         + 前递 / 停顿 / 冲刷 / ID 旁路
```

## 特性

| 项目 | 单周期 (`rv32i_cpu`) | 五级流水线 (`rv32i_pipe`) |
|---|---|---|
| 指令集 | RV32I 基础整数指令 | 同左 |
| 存储 | 哈佛结构（IMEM / DMEM 独立） | 同左 |
| RAW 冒险 | 不存在 | EX/MEM、MEM/WB 两级前递 + WB→ID 旁路 |
| load-use 冒险 | 不存在 | 停顿一拍（冻结 PC/IF-ID，插气泡） |
| 控制冒险 | 不存在 | EX 级解析，命中冲刷 2 拍 |
| 停机 | `ecall` / `ebreak` → `halt` | 同左（`halt` 随流水下传至 WB） |

## 目录结构

```
rv32i-cpu/
├── rtl/
│   ├── rv32i_cpu.v          # 单周期顶层数据通路
│   ├── rv32i_pipe.v         # 五级流水线顶层
│   ├── forward_unit.v       # 前递单元（RAW 数据冒险）
│   ├── hazard_unit.v        # 冒险检测单元（load-use 停顿）
│   ├── control.v            # 主控制器 + ALU 控制器
│   ├── alu.v                # 算术逻辑单元
│   ├── imm_gen.v            # 立即数生成（I/S/B/U/J）
│   ├── regfile.v            # 32×32 寄存器堆
│   ├── imem.v               # 指令存储器
│   └── dmem.v               # 数据存储器（字节使能）
├── sim/
│   ├── tb_rv32i_cpu.v       # 单周期自检测试平台
│   └── tb_rv32i_pipe.v      # 流水线自检测试平台
├── sw/
│   ├── rvasm.py             # 迷你 RV32I 汇编器（标签/伪指令/多段）
│   ├── rvsim.py             # RV32I 指令级功能模型（Golden ISS）
│   └── tests/
│       ├── test_arith.s     # 算术/逻辑/移位/立即数/U 型
│       ├── test_mem.s       # 访存：符号/零扩展、字内偏移
│       ├── test_branch.s    # 条件分支 + 循环
│       ├── test_jump.s      # jal/jalr + 递归 fib(10)
│       ├── test_hazard.s    # 专测流水线冒险（含 WB→ID 距离）
│       └── test_sort.s      # 冒泡排序（综合演示）
├── docs/
│   ├── design.md            # 单周期设计 / 控制信号表 / 面试问答
│   └── pipeline.md          # 流水线冒险分析 / CPI 实测 / 面试问答
├── run_tests.sh             # 一键回归
└── Makefile
```

## 快速开始

依赖：`iverilog`（仿真）、`python3`。**无需 RISC-V 工具链**（汇编器自带）。

```bash
# Arch
sudo pacman -S iverilog gtkwave
# Ubuntu / Debian
sudo apt install iverilog gtkwave

# 全量回归（两个 DUT × 全部测试）
./run_tests.sh
```

回归输出：

```
[3/3] 运行测试 ...
  PASS  test_arith       rv32i_cpu          28 cycles
  PASS  test_arith       rv32i_pipe         32 cycles
  PASS  test_branch      rv32i_cpu          51 cycles
  PASS  test_branch      rv32i_pipe         83 cycles
  PASS  test_hazard      rv32i_cpu          24 cycles
  PASS  test_hazard      rv32i_pipe         33 cycles
  PASS  test_jump        rv32i_cpu          1687 cycles
  PASS  test_jump        rv32i_pipe         2759 cycles
  PASS  test_mem         rv32i_cpu          25 cycles
  PASS  test_mem         rv32i_pipe         29 cycles
  PASS  test_sort        rv32i_cpu          303 cycles
  PASS  test_sort        rv32i_pipe         439 cycles
---------------------------------------------------------------
  合计: 12 通过 / 0 失败
---------------------------------------------------------------
```

单独跑某一个（以流水线为例）：

```bash
cd build
iverilog -g2012 -o tb_rv32i_pipe.vvp -s tb_rv32i_pipe ../sim/tb_rv32i_pipe.v ../rtl/*.v
vvp tb_rv32i_pipe.vvp
gtkwave wave_pipe.vcd
```

## 验证方法：双实现交叉验证

单靠"跑出结果"不足以说明正确性。本项目用**三条独立路径**互相印证：

```
   .s 汇编源码
        │
        ├── rvasm.py ──> program.hex ──┬──> rv32i_cpu.v  (单周期 RTL) ──┐
        │                              │                               ├─> 逐寄存器比对
        └── rvsim.py ──> program.expected ──────────────────────────────┤
                                       └──> rv32i_pipe.v (流水线 RTL) ──┘
```

- `rvasm.py` / `rvsim.py` 是**独立于 RTL 的另一套实现**，RTL 有 bug 两边必然分叉；
- **单周期与流水线是两个独立 RTL 实现**，它们必须给出完全相同的结果；
- testbench 在 `halt` 后对 `x1..x31` 逐一比对，任何一位不同即报 `MISMATCH`；
- `test_hazard.s` 专门构造了三种寄存器依赖距离、load-use、load→分支、load→存储 六类冒险，
  确保前递/停顿/旁路逻辑被真正执行到，而不是"碰巧没触发"。

## 已验证的边界条件

- 负数算术右移 `sra` 与逻辑右移 `srl` 的行为差异（`0xFFFFFFF8`）；
- `slt` 有符号 vs `sltu` 无符号比较（`-1` 的无符号值是最大值）；
- 字节/半字载入的**字内偏移**与符号/零扩展（`lb/lbu/lh/lhu`）；
- 部分字节写入不影响同字内其他字节（字节使能逻辑）；
- 递归函数通过栈帧保存/恢复 `ra` 与局部变量（`fib(10)` = 55）；
- 流水线：相邻依赖、隔一条依赖、隔两条依赖（WB→ID）、load-use、load→分支、load→存储。

## 已知限制与后续方向

- 分支在 EX 级解析且无预测器，分支密集代码 CPI 上升（见 `docs/pipeline.md` 第 3、4 节）；
- 冒险检测偏保守，会产生多余停顿；
- IMEM/DMEM 为仿真用组合读存储，上板需替换为 Block RAM 或接入 AXI 总线；
- 未实现 CSR、异常/中断、`fence.i`、压缩指令（RV32C）、乘除法（M 扩展）。
