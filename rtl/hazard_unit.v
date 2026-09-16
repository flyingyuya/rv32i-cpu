//=============================================================================
//  hazard_unit.v  --  冒险检测单元（解决 load-use 数据冒险）
//
//  load 指令的数据在 MEM 级末端才可用，无法通过前递在下一拍的 EX 级拿到，
//  因此必须停顿一拍：冻结 PC 与 IF/ID，并向 ID/EX 插入气泡。
//
//  本实现采用保守判定：只要 ID 级指令的 rs1/rs2 与 EX 级 load 的 rd 相同
//  就停顿（不区分该指令是否真的使用该源寄存器），保证正确性优先。
//=============================================================================
`timescale 1ns/1ps

module hazard_unit (
    input  wire [4:0] ifid_rs1_addr,
    input  wire [4:0] ifid_rs2_addr,
    input  wire [4:0] idex_rd_addr,
    input  wire       idex_mem_read,     // EX 级指令是 load（写回来源为存储器）
    output wire       stall
);

    assign stall = idex_mem_read &&
                   (idex_rd_addr != 5'd0) &&
                   ((idex_rd_addr == ifid_rs1_addr) ||
                    (idex_rd_addr == ifid_rs2_addr));

endmodule
