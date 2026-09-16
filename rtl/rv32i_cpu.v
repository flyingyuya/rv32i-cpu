//=============================================================================
//  rv32i_cpu.v  --  RV32I 单周期处理器（顶层数据通路）
//
//  结构：取指(IMEM) -> 译码(control/imm_gen) -> 执行(ALU) -> 访存(DMEM) -> 写回
//  存储：哈佛结构，IMEM/DMEM 各自独立（教学简化）
//
//  数据通路要点
//    - 分支/JAL  目标地址 = PC + imm      （ALU: A=PC , B=imm , ADD）
//    - JALR      目标地址 = (rs1 + imm) & ~1
//    - LUI       结果 = imm
//    - AUIPC     结果 = PC + imm
//    - 写回来源由 result_src 三选一：ALU / 存储器 / PC+4
//    - 地址计算统一走 ALU，故 load/store/branch/jump 共用加法器
//=============================================================================
`timescale 1ns/1ps

module rv32i_cpu #(
    parameter IMEM_DEPTH = 1024,
    parameter DMEM_DEPTH = 1024,
    parameter IMEM_INIT  = "program.hex",
    parameter DMEM_INIT  = "program.hex",
    parameter [31:0] RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst_n,       // 低有效复位
    output wire        halt,        // 执行到 ecall/ebreak
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);

    //-------------------------------------------------------------
    //  信号声明（全部前置，避免 Verilog 先使用后声明）
    //-------------------------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4;
    wire [31:0] pc_next;
    wire [31:0] pc_target;
    wire [31:0] alu_result;

    wire [31:0] instr;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [4:0]  rs1_addr, rs2_addr, rd_addr;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] imm;

    wire        reg_write;
    wire        mem_write;
    wire [1:0]  result_src;
    wire [1:0]  alu_src_a;
    wire        alu_src_b;
    wire [1:0]  alu_op;
    wire [2:0]  imm_type;
    wire        branch;
    wire        jump;
    wire [3:0]  alu_ctrl;

    wire [31:0] alu_a, alu_b;

    wire eq, lt, ltu;
    reg  branch_taken;

    wire [31:0] mem_rdata;
    wire [1:0]  mem_boff;
    wire [31:0] mem_shift;
    wire [31:0] load_data;
    wire [31:0] wb_data;

    //-------------------------------------------------------------
    //  PC
    //-------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pc <= RESET_PC;
        else if (!halt)  pc <= pc_next;     // 停机后冻结 PC
    end

    assign pc_plus4  = pc + 32'd4;
    assign pc_target = {alu_result[31:1], 1'b0};   // 清除 bit0（JALR 要求）
    assign pc_next   = (jump | (branch & branch_taken)) ? pc_target : pc_plus4;

    assign pc_out    = pc;
    assign instr_out = instr;

    //-------------------------------------------------------------
    //  取指
    //-------------------------------------------------------------
    imem #(.DEPTH(IMEM_DEPTH), .INIT(IMEM_INIT)) u_imem (
        .addr  (pc),
        .rdata (instr)
    );

    //-------------------------------------------------------------
    //  译码
    //-------------------------------------------------------------
    assign funct3   = instr[14:12];
    assign funct7   = instr[31:25];
    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    regfile u_regfile (
        .clk (clk),
        .we  (reg_write),
        .ra1 (rs1_addr),
        .ra2 (rs2_addr),
        .wa  (rd_addr),
        .wd  (wb_data),
        .rd1 (rs1_data),
        .rd2 (rs2_data)
    );

    imm_gen u_imm_gen (
        .instr    (instr),
        .imm_type (imm_type),
        .imm      (imm)
    );

    control u_control (
        .opcode     (instr[6:0]),
        .funct3     (funct3),
        .funct7     (funct7),
        .reg_write  (reg_write),
        .mem_write  (mem_write),
        .result_src (result_src),
        .alu_src_a  (alu_src_a),
        .alu_src_b  (alu_src_b),
        .alu_op     (alu_op),
        .imm_type   (imm_type),
        .branch     (branch),
        .jump       (jump),
        .halt       (halt),
        .alu_ctrl   (alu_ctrl)
    );

    //-------------------------------------------------------------
    //  执行
    //-------------------------------------------------------------
    assign alu_a = (alu_src_a == 2'b00) ? rs1_data :
                   (alu_src_a == 2'b01) ? pc       : 32'd0;
    assign alu_b = alu_src_b ? imm : rs2_data;

    alu u_alu (
        .a    (alu_a),
        .b    (alu_b),
        .op   (alu_ctrl),
        .y    (alu_result),
        .zero ()
    );

    // 分支条件比较（直接使用 rs1/rs2）
    assign eq  = (rs1_data == rs2_data);
    assign lt  = ($signed(rs1_data) < $signed(rs2_data));
    assign ltu = (rs1_data < rs2_data);

    always @(*) begin
        case (funct3)
            3'b000:  branch_taken = eq;         // beq
            3'b001:  branch_taken = ~eq;        // bne
            3'b100:  branch_taken = lt;         // blt
            3'b101:  branch_taken = ~lt;        // bge
            3'b110:  branch_taken = ltu;        // bltu
            3'b111:  branch_taken = ~ltu;       // bgeu
            default: branch_taken = 1'b0;
        endcase
    end

    //-------------------------------------------------------------
    //  访存
    //-------------------------------------------------------------
    dmem #(.DEPTH(DMEM_DEPTH), .INIT(DMEM_INIT)) u_dmem (
        .clk   (clk),
        .addr  (alu_result),
        .wdata (rs2_data),
        .we    (mem_write),
        .size  (funct3),
        .rdata (mem_rdata)
    );

    // 载入数据的符号/零扩展
    // 注意：字节/半字载入需先按地址低 2 位对齐到字内的正确字节位置
    assign mem_boff = alu_result[1:0];
    assign mem_shift = mem_rdata >> (8 * mem_boff);

    assign load_data =
        (funct3 == 3'b000) ? {{24{mem_shift[7]}},  mem_shift[7:0]}  :  // LB
        (funct3 == 3'b001) ? {{16{mem_shift[15]}}, mem_shift[15:0]} :  // LH
        (funct3 == 3'b100) ? {24'b0, mem_shift[7:0]}                :  // LBU
        (funct3 == 3'b101) ? {16'b0, mem_shift[15:0]}               :  // LHU
                             mem_rdata;                                 // LW

    //-------------------------------------------------------------
    //  写回
    //-------------------------------------------------------------
    assign wb_data =
        (result_src == 2'b00) ? alu_result :
        (result_src == 2'b01) ? load_data  : pc_plus4;

endmodule
