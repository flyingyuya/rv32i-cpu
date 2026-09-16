# RV32I 单周期处理器 —— 设计说明

本文档记录数据通路设计、控制信号定义与常见面试追问的答案。

## 1. 总体结构

```
                    ┌────────────────────────────────────────────────┐
                    │                                                │
   ┌──────┐         ▼                                                │
   │  PC  │──────> IMEM ──> instr ──┬─> control  ──> 控制信号组        │
   └──┬───┘                        │                                │
      │                            └─> imm_gen  ──> imm              │
      │                                     │                        │
      │                     rs1/rs2          ▼                        │
      │        ┌────────┐  <──  regfile  <── wb_data                 │
      │        │  ALU   │                                             │
      │        └───┬────┘                                             │
      │            │ alu_result                                       │
      │            ├──────────> DMEM ──> mem_rdata                    │
      │            │                                                 │
      └────────────┘  (pc_next = 分支/跳转 ? alu_result : PC+4)       │
```

单周期：**一条指令在一个时钟周期内走完全部五个阶段**，CPI = 1。

## 2. 立即数编码

| 类型 | 指令 | 位拼接 |
|---|---|---|
| I | `addi lw jalr` | `{{20{instr[31]}}, instr[31:20]}` |
| S | `sw sh sb` | `{{20{instr[31]}}, instr[31:25], instr[11:7]}` |
| B | `beq bne ...` | `{{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}` |
| U | `lui auipc` | `{instr[31:12], 12'b0}` |
| J | `jal` | `{{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}` |

RV32I 的立即数被打散存放，目的是**让 rs1/rs2/rd 在各类指令中保持固定位置**，简化译码。

## 3. 控制信号表（主译码器）

| 指令 | reg_write | mem_write | result_src | alu_src_a | alu_src_b | alu_op | imm_type | branch | jump |
|---|---|---|---|---|---|---|---|---|---|
| R 型 `add/sub/...` | 1 | 0 | ALU | rs1 | rs2 | R | – | 0 | 0 |
| I 型 `addi/andi/...` | 1 | 0 | ALU | rs1 | imm | I | I | 0 | 0 |
| `load` | 1 | 0 | MEM | rs1 | imm | ADD | I | 0 | 0 |
| `store` | 0 | 1 | – | rs1 | imm | ADD | S | 0 | 0 |
| `branch` | 0 | 0 | – | PC | imm | ADD | B | 1 | 0 |
| `jal` | 1 | 0 | PC+4 | PC | imm | ADD | J | 0 | 1 |
| `jalr` | 1 | 0 | PC+4 | rs1 | imm | ADD | I | 0 | 1 |
| `lui` | 1 | 0 | ALU | 0 | imm | ADD | U | 0 | 0 |
| `auipc` | 1 | 0 | ALU | PC | imm | ADD | U | 0 | 0 |
| `fence` | 0 | 0 | – | – | – | – | – | 0 | 0 |
| `ecall/ebreak` | 0 | 0 | – | – | – | – | – | 0 | 0 |

编码含义：
- `result_src`：`00`=ALU，`01`=存储器，`10`=PC+4
- `alu_src_a`：`00`=rs1，`01`=PC，`10`=0
- `alu_src_b`：`0`=rs2，`1`=imm
- `alu_op`：`00`=ADD，`01`=SUB，`10`=按 funct3/funct7 译码（R 型），`11`=按 funct3 译码（I 型）

**设计要点**：`lui` 用「0 + imm」、`auipc` 用「PC + imm」、`branch/jal` 用「PC + imm」、
`jalr` 用「rs1 + imm」，全部复用同一个 ALU 加法器 —— 这就是把 `alu_src_a` 做成三选一的原因。

## 4. 分支与跳转

分支条件不经过 ALU，而是直接用 `rs1`/`rs2` 做比较后按 `funct3` 选择：

```
beq : rs1 == rs2      bne : rs1 != rs2
blt : $signed(rs1) <  $signed(rs2)      有符号
bge : $signed(rs1) >= $signed(rs2)
bltu: rs1 <  rs2                         无符号
bgeu: rs1 >= rs2
```

PC 更新：

```
pc_target = {alu_result[31:1], 1'b0}     // 清 bit0，满足 jalr 的规范要求
pc_next   = (jump | (branch & branch_taken)) ? pc_target : pc + 4
```

## 5. 访存细节

- **写**：由 `funct3` 生成字节使能 `be`，写入数据先左移 `8*addr[1:0]`，
  再按 `be` 分字节写入 → 支持任意字节偏移的 `sb/sh`；
- **读**：先按 `addr[1:0]` 把整字右移，再抽取对应字节/半字并扩展。

> 实现中曾出现的 bug：只做了扩展、漏了**字内右移**，导致 `lb x, 3(base)` 读到的是第 0 字节。
> 该 bug 被 `test_mem.s` 精确捕获（`x6`、`x8` 两个寄存器不匹配）。

## 6. 常见面试追问

**Q：单周期 CPU 的致命缺点是什么？**
A：时钟周期必须覆盖最慢指令（通常是 load：取指→译码→读寄存器→ALU→读存储器→写回）的完整路径，
导致周期长、所有指令都被拖慢。改进方向是流水线 / 多周期。

**Q：为什么用哈佛结构？**
A：单周期下取指和访存发生在同一周期，若用冯诺依曼结构会产生结构冒险；分开后 IMEM/DMEM 可同时访问。

**Q：`jalr` 为什么要清 bit0？**
A：RISC-V 指令长度至少 2 字节，目标地址最低位恒为 0；规范要求 `jalr` 将结果最低位清零，
从而支持未来的 16 位压缩指令扩展。

**Q：`x0` 为什么要硬连 0？**
A：它是 RV32I 的"零寄存器"，`addi x0, x0, 0` 即 `nop`，`jal x0` 即无条件跳转，可简化指令集。

**Q：写回时为什么需要三选一 mux？**
A：三类指令的"结果"来源不同：ALU 结果（算术）、存储器数据（load）、PC+4（跳转链接地址）。

**Q：怎么验证 CPU 是对的？**
A：双实现交叉验证 —— 独立写的 Python 指令级模型与 Verilog RTL 执行同一段程序，
逐个比对寄存器/存储器；再配合定向边界测试（负数移位、无符号比较、非对齐访存）。

## 7. 后续可扩展方向

1. **五级流水线**：IF-ID-EX-MEM-WB，加入流水寄存器；
2. **冒险处理**：RAW 数据冒险用前递（forwarding）+ 停顿（stall），分支用预测/冲刷；
3. **总线与外设**：把 IMEM/DMEM 换成 AXI-Lite，接入 UART / SPI / GPIO，上板跑裸机程序；
4. **扩展指令**：RV32M（乘除法）、RV32C（压缩）、CSR 与异常/中断；
5. **上板**：Xilinx/Intel FPGA 上做时序约束与综合，观察资源占用与最高频率。
