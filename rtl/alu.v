//=============================================================================
//  alu.v  --  RV32I 算术逻辑单元
//  支持 ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND
//  - SLT  : 有符号比较   - SLTU : 无符号比较
//  - SRL  : 逻辑右移     - SRA  : 算术右移（符号扩展）
//=============================================================================
`timescale 1ns/1ps

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y,
    output wire        zero
);

    localparam ALU_ADD  = 4'd0,
               ALU_SUB  = 4'd1,
               ALU_SLL  = 4'd2,
               ALU_SLT  = 4'd3,
               ALU_SLTU = 4'd4,
               ALU_XOR  = 4'd5,
               ALU_SRL  = 4'd6,
               ALU_SRA  = 4'd7,
               ALU_OR   = 4'd8,
               ALU_AND  = 4'd9;

    always @(*) begin
        case (op)
            ALU_ADD : y = a + b;
            ALU_SUB : y = a - b;
            ALU_SLL : y = a << b[4:0];
            ALU_SLT : y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
            ALU_XOR : y = a ^ b;
            ALU_SRL : y = a >> b[4:0];
            ALU_SRA : y = $signed(a) >>> b[4:0];
            ALU_OR  : y = a | b;
            ALU_AND : y = a & b;
            default : y = 32'd0;
        endcase
    end

    assign zero = (y == 32'd0);

endmodule
