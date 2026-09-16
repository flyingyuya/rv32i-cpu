//=============================================================================
//  imem.v  --  指令存储器（教学用，组合读 + $readmemh 初始化）
//  真实 FPGA 上应替换为 Block RAM（同步读）或由 SoC 提供总线接口
//=============================================================================
`timescale 1ns/1ps

module imem #(
    parameter DEPTH = 1024,     // 字数（word）
    parameter INIT  = ""        // 十六进制镜像文件
)(
    input  wire [31:0] addr,
    output wire [31:0] rdata
);

    localparam AW = $clog2(DEPTH);

    reg [31:0] mem [0:DEPTH-1];
    integer i;

    assign rdata = mem[addr[AW+1:2]];

    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 32'd0;
        if (INIT != "")
            $readmemh(INIT, mem);
    end

endmodule
