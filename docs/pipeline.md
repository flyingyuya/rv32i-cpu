# 五级流水线设计说明

单周期版本见 [design.md](design.md)。本文件只说流水线新增的部分。

## 1. 流水级划分

```
        IF            ID              EX             MEM            WB
   ┌─────────┐  ┌───────────┐  ┌────────────┐  ┌───────────┐  ┌──────────┐
   │  PC/IMEM│─>│ 译码/读寄存器│─>│ 前递 + ALU │─>│   DMEM    │─>│   写回   │
   └─────────┘  └───────────┘  └────────────┘  └───────────┘  └──────────┘
        │              │              │              │              │
     IF/ID          ID/EX          EX/MEM        MEM/WB
```

| 流水寄存器 | 主要字段 |
|---|---|
| IF/ID | `pc`, `instr` |
| ID/EX | 控制信号组、`pc`、`pc+4`、`rs1_data`、`rs2_data`、`imm`、`rd/rs1/rs2` 地址、`funct3` |
| EX/MEM | `alu_result`、`rs2_data`（存储数据）、`pc+4`、`rd`、`funct3`、`reg_write`、`mem_write`、`result_src` |
| MEM/WB | `alu_result`、`mem_rdata`、`pc+4`、`rd`、`funct3`、`reg_write`、`result_src` |

流水寄存器在两种情况被改写：
- **停顿（stall）**：PC 与 IF/ID 冻结，ID/EX 插入气泡；
- **冲刷（flush）**：分支命中时，IF/ID 与 ID/EX 插入气泡，PC 跳到目标。

气泡统一用 `NOP = 32'h0000_0013`（`addi x0, x0, 0`），它不写寄存器、不写内存、与任何源寄存器都不同名，因此不会再引入新的冒险。

## 2. 三类冒险与处理

### 2.1 RAW 数据冒险 —— 前递（forwarding）

| 生产者位置 | 消费者位置 | 处理 |
|---|---|---|
| EX/MEM（上一条指令刚算完） | EX | 从 `exmem_alu_result` 前递 |
| MEM/WB（上上条指令即将写回） | EX | 从 `memwb_wb_data` 前递 |
| MEM/WB（同拍写回） | **ID** | WB→ID 旁路 |

前递优先级：**EX/MEM > MEM/WB**（越近的越新）。

### 2.2 load-use 冒险 —— 停顿一拍

load 的数据要到 **MEM 级末端**才从存储器读出，而它的下一条指令在下一拍就进入 EX，
此时数据还不存在，**前递无法解决**，必须停顿：

```
add x1, ...        IF  ID  EX  MEM WB
lw  x2, 0(x1)          IF  ID  EX  MEM WB
add x3, x2, x1             IF  ID  --  EX  MEM WB     <-- 停顿一拍（气泡）
```

判定条件：

```
stall = idex_mem_read && (idex_rd != 0)
        && (idex_rd == id_rs1 || idex_rd == id_rs2)
```

本实现采用保守判定（不区分 ID 级指令是否真的使用该源寄存器），保证正确性优先。

### 2.3 WB → ID 同拍写读

当写回级（WB）要写的寄存器和译码级（ID）要读的寄存器相同时，ID 读到的是**旧值**；
等到该指令进入 EX 时写回指令早已流走，前递路径也够不到它。因此必须在 ID 级再加一条旁路：

```
id_rs1_data = (memwb_reg_write && memwb_rd == id_rs1) ? memwb_wb_data : id_rs1_raw;
```

> 这一条最容易被漏掉：只做 EX/MEM 与 MEM/WB 前递的教科书简版流水线，
> 在某些寄存器距离下会得到错误结果。本项目用 `test_hazard.s` 专门覆盖了这个距离。

### 2.4 控制冒险 —— EX 级解析 + 冲刷

分支/跳转在 **EX 级**解析（`jal`/`jalr` 恒跳转，条件分支比较前递后的 `rs1`/`rs2`）。
命中时：

```
pc       <= ex_target           // {alu_result[31:1], 1'b0}
IF/ID    <= NOP                 // 冲刷
ID/EX    <= 气泡                 // 冲刷
```

代价是每个命中分支 **2 拍**。这是"静态预测不跳转 + 冲刷"策略。

## 3. 实测数据（iverilog 仿真）

| 测试 | 指令数(静态) | 单周期周期数 | 流水线周期数 | 流水线额外开销 |
|---|---:|---:|---:|---:|
| test_arith | 28 | 28 | 32 | +4（流水线填充） |
| test_mem | 25 | 25 | 29 | +4（流水线填充） |
| test_hazard | 26 | 24 | 33 | +9（4 填充 + 5 次停顿） |
| test_branch | 30 | 51 | 83 | +32（分支冲刷） |
| test_sort | 36 | 303 | 439 | +136（分支 + 停顿） |
| test_jump | 31 | 1687 | 2759 | +1072（递归调用分支密集） |

## 4. 下一步优化清单

1. 分支解析前移到 ID 级，惩罚 2 拍 → 1 拍；
2. 加两位饱和计数器分支预测器 + BTB，减少冲刷频率；
3. 冒险检测精确化：只在该指令确实读 rs1/rs2 时才停顿；
4. 把 IMEM/DMEM 改成同步读的 Block RAM，提高可综合性与主频；
5. 加 CSR、异常/中断、RV32M（乘除法）扩展；
6. 接 AXI-Lite 总线与外设（UART/SPI/GPIO），上板跑裸机程序。
