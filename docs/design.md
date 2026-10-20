# RV32I 单周期处理器 —— 设计说明

本文档记录数据通路设计、控制信号定义。

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

