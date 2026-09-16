//=============================================================================
//  imm_gen.v  --  立即数生成单元
//  按指令类型从 32bit 指令中抽取立即数并做符号扩展
//    imm_type: 0=I  1=S  2=B  3=U  4=J
//=============================================================================
`timescale 1ns/1ps

module imm_gen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_type,
    output reg  [31:0] imm
);

    always @(*) begin
        case (imm_type)
            // I 型: addi/lw/jalr ...
            3'd0: imm = {{20{instr[31]}}, instr[31:20]};
            // S 型: sw/sh/sb
            3'd1: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            // B 型: beq/bne/...
            3'd2: imm = {{19{instr[31]}}, instr[31], instr[7],
                        instr[30:25], instr[11:8], 1'b0};
            // U 型: lui/auipc（已经左移 12 位）
            3'd3: imm = {instr[31:12], 12'b0};
            // J 型: jal
            3'd4: imm = {{11{instr[31]}}, instr[31], instr[19:12],
                        instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end

endmodule
