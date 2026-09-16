//=============================================================================
//  dmem.v  --  数据存储器（教学用，组合读 + 同步写 + 字节使能）
//  size (funct3): 000=SB  001=SH  010=SW
//  支持非对齐地址下的字节/半字写入（通过字节使能 + 数据左移实现）
//=============================================================================
`timescale 1ns/1ps

module dmem #(
    parameter DEPTH = 1024,     // 字数（word）
    parameter INIT  = ""
)(
    input  wire        clk,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire [2:0]  size,
    output wire [31:0] rdata
);

    localparam AW = $clog2(DEPTH);

    reg [31:0] mem [0:DEPTH-1];
    integer i;

    wire [AW-1:0] widx = addr[AW+1:2];
    wire [1:0]    boff = addr[1:0];

    // 字节使能：按写入宽度生成
    reg [3:0] be;
    always @(*) begin
        case (size)
            3'b000:  be = 4'b0001 << boff;   // SB
            3'b001:  be = 4'b0011 << boff;   // SH
            default: be = 4'b1111;           // SW
        endcase
    end

    // 待写数据按字节偏移对齐
    wire [31:0] wdata_shift = wdata << (8 * boff);

    always @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[widx][ 7: 0] <= wdata_shift[ 7: 0];
            if (be[1]) mem[widx][15: 8] <= wdata_shift[15: 8];
            if (be[2]) mem[widx][23:16] <= wdata_shift[23:16];
            if (be[3]) mem[widx][31:24] <= wdata_shift[31:24];
        end
    end

    assign rdata = mem[widx];

    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 32'd0;
        if (INIT != "")
            $readmemh(INIT, mem);
    end

endmodule
