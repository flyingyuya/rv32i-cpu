//=============================================================================
//  regfile.v  --  32 x 32bit 通用寄存器堆
//  - x0 恒为 0（写 x0 被忽略，读 x0 返回 0）
//  - 两个组合读端口（rs1/rs2），一个同步写端口（rd）
//=============================================================================
`timescale 1ns/1ps

module regfile (
    input  wire        clk,
    input  wire        we,        // 写使能
    input  wire [4:0]  ra1,       // 读地址 1 (rs1)
    input  wire [4:0]  ra2,       // 读地址 2 (rs2)
    input  wire [4:0]  wa,        // 写地址  (rd)
    input  wire [31:0] wd,        // 写数据
    output wire [31:0] rd1,       // 读数据 1
    output wire [31:0] rd2        // 读数据 2
);

    reg [31:0] regs [0:31];
    integer i;

    assign rd1 = (ra1 != 5'd0) ? regs[ra1] : 32'd0;
    assign rd2 = (ra2 != 5'd0) ? regs[ra2] : 32'd0;

    always @(posedge clk) begin
        if (we && (wa != 5'd0))
            regs[wa] <= wd;
    end

    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'd0;
    end

endmodule
