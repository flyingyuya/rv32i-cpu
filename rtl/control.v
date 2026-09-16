//=============================================================================
//  control.v  --  主控制器 + ALU 控制器
//  输入: 指令的 opcode / funct3 / funct7
//  输出: 数据通路所需的全部控制信号
//
//  控制信号语义
//    reg_write   : 写回寄存器堆
//    mem_write   : 数据存储器写使能
//    result_src  : 写回数据来源  0=ALU  1=存储器  2=PC+4
//    alu_src_a   : ALU A 口来源  0=rs1  1=PC  2=0
//    alu_src_b   : ALU B 口来源  0=rs2  1=imm
//    alu_op      : ALU 译码组    0=ADD 1=SUB 2=R型 3=I型
//    imm_type    : 立即数类型    0=I 1=S 2=B 3=U 4=J
//    branch/jump : 跳转类指令
//    halt        : 执行到 ecall/ebreak，停机
//=============================================================================
`timescale 1ns/1ps

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,

    output reg        reg_write,
    output reg        mem_write,
    output reg  [1:0] result_src,
    output reg  [1:0] alu_src_a,
    output reg        alu_src_b,
    output reg  [1:0] alu_op,
    output reg  [2:0] imm_type,
    output reg        branch,
    output reg        jump,
    output reg        halt,
    output reg  [3:0] alu_ctrl
);

    // ---- opcode ----
    localparam OPC_R      = 7'b0110011,   // OP
               OPC_I      = 7'b0010011,   // OP-IMM
               OPC_LOAD   = 7'b0000011,   // LOAD
               OPC_STORE  = 7'b0100011,   // STORE
               OPC_BRANCH = 7'b1100011,   // BRANCH
               OPC_JAL    = 7'b1101111,   // JAL
               OPC_JALR   = 7'b1100111,   // JALR
               OPC_LUI    = 7'b0110111,   // LUI
               OPC_AUIPC  = 7'b0010111,   // AUIPC
               OPC_FENCE  = 7'b0001111,   // MISC-MEM
               OPC_SYS    = 7'b1110011;   // SYSTEM (ecall/ebreak)

    // ---- ALU 运算编码 ----
    localparam A_ADD  = 4'd0, A_SUB  = 4'd1, A_SLL  = 4'd2, A_SLT  = 4'd3,
               A_SLTU = 4'd4, A_XOR  = 4'd5, A_SRL  = 4'd6, A_SRA  = 4'd7,
               A_OR   = 4'd8, A_AND  = 4'd9;

    // ---- ALU 译码组 ----
    localparam ALU_ADD = 2'b00,
               ALU_SUB = 2'b01,
               ALU_R   = 2'b10,
               ALU_I   = 2'b11;

    //------------------------------------------------------------------
    //  主译码器
    //------------------------------------------------------------------
    always @(*) begin
        // 默认值（防止锁存器）
        reg_write  = 1'b0;
        mem_write  = 1'b0;
        result_src = 2'b00;
        alu_src_a  = 2'b00;
        alu_src_b  = 1'b0;
        alu_op     = ALU_ADD;
        imm_type   = 3'd0;
        branch     = 1'b0;
        jump       = 1'b0;
        halt       = 1'b0;

        case (opcode)
            OPC_R: begin                       // add/sub/and/or/...
                reg_write = 1'b1;
                alu_src_a = 2'b00;             // rs1
                alu_src_b = 1'b0;              // rs2
                alu_op    = ALU_R;
            end
            OPC_I: begin                       // addi/slti/andi/...
                reg_write = 1'b1;
                alu_src_a = 2'b00;             // rs1
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_I;
                imm_type  = 3'd0;              // I
            end
            OPC_LOAD: begin                    // lb/lh/lw/lbu/lhu
                reg_write = 1'b1;
                alu_src_a = 2'b00;             // rs1
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 地址 = rs1 + imm
                result_src= 2'b01;             // 写回存储器数据
                imm_type  = 3'd0;
            end
            OPC_STORE: begin                   // sb/sh/sw
                mem_write = 1'b1;
                alu_src_a = 2'b00;             // rs1
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 地址 = rs1 + imm
                imm_type  = 3'd1;              // S
            end
            OPC_BRANCH: begin                  // beq/bne/blt/...
                branch    = 1'b1;
                alu_src_a = 2'b01;             // PC
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 目标 = PC + imm
                imm_type  = 3'd2;              // B
            end
            OPC_JAL: begin                     // jal
                reg_write = 1'b1;
                jump      = 1'b1;
                result_src= 2'b10;             // 链接 = PC+4
                alu_src_a = 2'b01;             // PC
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 目标 = PC + imm
                imm_type  = 3'd4;              // J
            end
            OPC_JALR: begin                    // jalr
                reg_write = 1'b1;
                jump      = 1'b1;
                result_src= 2'b10;             // 链接 = PC+4
                alu_src_a = 2'b00;             // rs1
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 目标 = rs1 + imm
                imm_type  = 3'd0;              // I
            end
            OPC_LUI: begin                     // lui
                reg_write = 1'b1;
                alu_src_a = 2'b10;             // 0
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 结果 = imm
                imm_type  = 3'd3;              // U
            end
            OPC_AUIPC: begin                   // auipc
                reg_write = 1'b1;
                alu_src_a = 2'b01;             // PC
                alu_src_b = 1'b1;              // imm
                alu_op    = ALU_ADD;           // 结果 = PC + imm
                imm_type  = 3'd3;              // U
            end
            OPC_FENCE: begin
                // 单核顺序执行，fence 视作 nop
            end
            OPC_SYS: begin
                // ecall / ebreak：本设计用作仿真停机
                halt = 1'b1;
            end
            default: ;
        endcase
    end

    //------------------------------------------------------------------
    //  ALU 控制器
    //------------------------------------------------------------------
    always @(*) begin
        case (alu_op)
            ALU_ADD: alu_ctrl = A_ADD;
            ALU_SUB: alu_ctrl = A_SUB;
            ALU_R: begin
                case (funct3)
                    3'b000:  alu_ctrl = funct7[5] ? A_SUB : A_ADD;  // add/sub
                    3'b001:  alu_ctrl = A_SLL;
                    3'b010:  alu_ctrl = A_SLT;
                    3'b011:  alu_ctrl = A_SLTU;
                    3'b100:  alu_ctrl = A_XOR;
                    3'b101:  alu_ctrl = funct7[5] ? A_SRA : A_SRL;  // srl/sra
                    3'b110:  alu_ctrl = A_OR;
                    3'b111:  alu_ctrl = A_AND;
                    default: alu_ctrl = A_ADD;
                endcase
            end
            ALU_I: begin
                case (funct3)
                    3'b000:  alu_ctrl = A_ADD;                      // addi
                    3'b001:  alu_ctrl = A_SLL;                      // slli
                    3'b010:  alu_ctrl = A_SLT;                      // slti
                    3'b011:  alu_ctrl = A_SLTU;                     // sltiu
                    3'b100:  alu_ctrl = A_XOR;                      // xori
                    3'b101:  alu_ctrl = funct7[5] ? A_SRA : A_SRL;  // srli/srai
                    3'b110:  alu_ctrl = A_OR;                       // ori
                    3'b111:  alu_ctrl = A_AND;                      // andi
                    default: alu_ctrl = A_ADD;
                endcase
            end
            default: alu_ctrl = A_ADD;
        endcase
    end

endmodule
