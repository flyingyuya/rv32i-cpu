# RV32I 单周期处理器（Verilog）

用 Verilog 从零实现的 **RV32I 单周期 CPU**，配套自研汇编器与 Python 指令级功能模型（Golden Model），
通过 **交叉验证** 保证 RTL 与参考模型行为一致：5 组测试程序全部通过，31/31 通用寄存器逐一比对。

```
取指(IMEM) → 译码(control / imm_gen) → 执行(ALU) → 访存(DMEM) → 写回
```

## 特性

| 项目 | 说明 |
|---|---|
| 指令集 | RV32I 基础整数指令（算术/逻辑/移位/访存/分支/跳转/CSR 外） |
| 微架构 | 单周期，哈佛结构（IMEM / DMEM 独立） |
| 立即数 | I / S / B / U / J 五种编解码，统一符号扩展 |
| 访存 | 支持 byte / half / word 读写，含符号扩展与零扩展，字节使能写入 |
| 跳转 | `jal` / `jalr`，目标地址 `(rs1+imm) & ~1` |
| 停机 | 执行 `ecall` / `ebreak` 时拉高 `halt`，供仿真判断结束 |
| 复位 | 低有效异步复位，复位后 `PC = 0` |

## 目录结构

```
rv32i-cpu/
├── rtl/                     # RTL 源码
│   ├── rv32i_cpu.v          #   顶层数据通路
│   ├── control.v            #   主控制器 + ALU 控制器
│   ├── alu.v                #   算术逻辑单元
│   ├── imm_gen.v            #   立即数生成
│   ├── regfile.v            #   32×32 寄存器堆
│   ├── imem.v               #   指令存储器
│   └── dmem.v               #   数据存储器（字节使能）
├── sim/
│   └── tb_rv32i_cpu.v       # 自检测试平台（对比 Golden Model）
├── sw/
│   ├── rvasm.py             # 迷你 RV32I 汇编器（标签/伪指令/多段）
│   ├── rvsim.py             # RV32I 指令级功能模型（Golden ISS）
│   └── tests/
│       ├── test_arith.s     # 算术/逻辑/移位/立即数/U 型
│       ├── test_mem.s       # 访存：符号/零扩展、字节对齐
│       ├── test_branch.s    # 条件分支 + 循环
│       ├── test_jump.s      # jal/jalr + 递归 fib(10)
│       └── test_sort.s      # 冒泡排序 + 求和（综合演示）
├── docs/design.md           # 设计说明 / 控制信号表 / 面试问答
├── run_tests.sh             # 一键回归
└── Makefile
```

## 快速开始

依赖：`iverilog`（仿真）、`python3`。**无需 RISC-V 工具链**（汇编器自带）。

```bash
# Arch
sudo pacman -S iverilog gtkwave

# Ubuntu/Debian
sudo apt install iverilog gtkwave
```

```bash
# 全量回归
./run_tests.sh

# 或指定单个测试
make sim TEST=sw/tests/test_sort.s

# 看波形
make wave
```

回归输出示例：

```
[1/2] 编译 RTL + testbench ...
      编译通过
[2/2] 运行测试 ...
  PASS  test_arith     28 cycles
  PASS  test_mem       25 cycles
  PASS  test_branch    51 cycles
  PASS  test_jump      1687 cycles
  PASS  test_sort      303 cycles
------------------------------------------------------
  合计: 5 通过 / 0 失败
------------------------------------------------------
```

## 验证方法：双实现交叉验证

单靠"跑出结果"不足以说明正确性。本项目用两条独立实现互相印证：

```
   .s 汇编源码
        │
        ├──> rvasm.py ──> program.hex ──┬──> rv32i_cpu.v (Verilog RTL) ──> 仿真寄存器值
        │                               │                                       │
        └──>                             └──> rvsim.py   (Python ISS)  ──> program.expected
                                                                                │
                                            testbench 逐寄存器比对  <───────────┘
```

- `rvasm.py` 与 `rvsim.py` 是**独立于 RTL 的另一套实现**，若 RTL 有 bug，两边结果必然分叉；
- testbench 在 `halt` 后对 `x1..x31` 逐一比对，任何一位不同即报 `MISMATCH`；
- 测试覆盖算术、访存边界、分支方向、递归调用栈、排序算法，而非只跑一条 `add`。

## 已验证的边界条件

- 负数的算术右移 `sra` 与逻辑右移 `srl` 行为差异（`0xFFFFFFF8`）；
- `slt` 有符号 vs `sltu` 无符号比较（`-1` 的无符号值是最大数）；
- 字节/半字载入的字内偏移与符号/零扩展（`lb/lbu/lh/lhu`）；
- 部分字节写入不影响同字内其他字节（验证字节使能逻辑）；
- 递归函数通过栈帧保存/恢复 `ra`、局部变量（`fib(10)` = 55）。

## 已知限制与后续方向

- 单周期，CPI = 1 但关键路径长；后续可升级为**五级流水线 + 数据冒险前递/停顿**；
- IMEM/DMEM 为仿真用组合读存储，上板需替换为 Block RAM 或接入 AXI 总线；
- 未实现 CSR、异常/中断、`fence.i`、压缩指令（RV32C）、乘除法（M 扩展）。
