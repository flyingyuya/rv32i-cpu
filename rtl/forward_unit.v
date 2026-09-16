//=============================================================================
//  forward_unit.v  --  数据前递单元（解决 RAW 数据冒险）
//
//  在 EX 级把后续指令需要的操作数，直接从流水线寄存器旁路过来，
//  避免插入停顿。
//
//  优先级：EX/MEM（更近）> MEM/WB（更远）
//
//  forward_a / forward_b 编码
//    2'b00 : 不转发，使用 ID/EX 中锁存的寄存器值
//    2'b01 : 从 EX/MEM 转发（上一条指令的 ALU 结果）
//    2'b10 : 从 MEM/WB 转发（上上条指令的写回值）
//=============================================================================
`timescale 1ns/1ps

module forward_unit (
    input  wire [4:0] idex_rs1_addr,
    input  wire [4:0] idex_rs2_addr,

    input  wire [4:0] exmem_rd_addr,
    input  wire       exmem_reg_write,

    input  wire [4:0] memwb_rd_addr,
    input  wire       memwb_reg_write,

    output reg  [1:0] forward_a,
    output reg  [1:0] forward_b
);

    always @(*) begin
        // ---- 操作数 A (rs1) ----
        if (exmem_reg_write && (exmem_rd_addr != 5'd0) &&
            (exmem_rd_addr == idex_rs1_addr))
            forward_a = 2'b01;                       // EX/MEM 优先
        else if (memwb_reg_write && (memwb_rd_addr != 5'd0) &&
                 (memwb_rd_addr == idex_rs1_addr))
            forward_a = 2'b10;
        else
            forward_a = 2'b00;

        // ---- 操作数 B (rs2) ----
        if (exmem_reg_write && (exmem_rd_addr != 5'd0) &&
            (exmem_rd_addr == idex_rs2_addr))
            forward_b = 2'b01;
        else if (memwb_reg_write && (memwb_rd_addr != 5'd0) &&
                 (memwb_rd_addr == idex_rs2_addr))
            forward_b = 2'b10;
        else
            forward_b = 2'b00;
    end

endmodule
