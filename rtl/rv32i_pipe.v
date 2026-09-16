//=============================================================================
//  rv32i_pipe.v  --  RV32I 五级流水线处理器
//
//  流水级：IF -> ID -> EX -> MEM -> WB
//  冒险处理：
//    * RAW 数据冒险 —— EX 级前递（EX/MEM、MEM/WB 两级旁路）
//    * load-use 冒险 —— 停顿一拍（冻结 PC/IF-ID，向 ID-EX 插气泡）
//    * WB->ID 同拍写读 —— ID 级旁路（寄存器堆同拍写读的经典冲突）
//    * 控制冒险     —— EX 级解析分支/跳转，命中则冲刷 IF/ID 与 ID/EX
//
//  与单周期版本使用同一套 RTL 子模块（control/alu/imm_gen/regfile/imem/dmem），
//  因此可以直接用同一份测试程序与黄金模型做交叉验证。
//=============================================================================
`timescale 1ns/1ps

module rv32i_pipe #(
    parameter IMEM_DEPTH = 1024,
    parameter DMEM_DEPTH = 1024,
    parameter IMEM_INIT  = "program.hex",
    parameter DMEM_INIT  = "program.hex",
    parameter [31:0] RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire        halt,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);

    localparam [31:0] NOP = 32'h0000_0013;    // addi x0, x0, 0

    //=========================================================================
    //  信号声明（全部前置）
    //=========================================================================
    // ---- IF ----
    reg  [31:0] pc;
    wire [31:0] pc_plus4, pc_next, ex_target;
    wire        ex_take, flush, stall;
    wire [31:0] if_instr;

    // ---- IF/ID ----
    reg  [31:0] ifid_pc, ifid_instr;

    // ---- ID 译码 ----
    wire [2:0]  id_funct3;
    wire [6:0]  id_funct7;
    wire [4:0]  id_rs1_addr, id_rs2_addr, id_rd_addr;
    wire [31:0] id_rs1_raw, id_rs2_raw, id_imm;
    wire [31:0] id_rs1_data, id_rs2_data;
    wire        id_reg_write, id_mem_write, id_branch, id_jump, id_halt;
    wire        id_alu_src_b;
    wire [1:0]  id_result_src, id_alu_src_a, id_alu_op;
    wire [2:0]  id_imm_type;
    wire [3:0]  id_alu_ctrl;
    wire        wb_to_id_rs1, wb_to_id_rs2;

    // ---- ID/EX ----
    reg  [31:0] idex_pc, idex_pc_plus4, idex_rs1_data, idex_rs2_data, idex_imm;
    reg  [4:0]  idex_rs1_addr, idex_rs2_addr, idex_rd_addr;
    reg  [2:0]  idex_funct3;
    reg  [3:0]  idex_alu_ctrl;
    reg  [1:0]  idex_result_src, idex_alu_src_a;
    reg         idex_alu_src_b, idex_reg_write, idex_mem_write;
    reg         idex_branch, idex_jump, idex_halt;

    // ---- EX ----
    wire [1:0]  forward_a, forward_b;
    wire [31:0] ex_rs1_data, ex_rs2_data, ex_alu_a, ex_alu_b, ex_alu_result;
    wire        ex_eq, ex_lt, ex_ltu;
    reg         ex_branch_taken;
    wire        idex_mem_read;

    // ---- EX/MEM ----
    reg  [31:0] exmem_alu_result, exmem_rs2_data, exmem_pc_plus4;
    reg  [4:0]  exmem_rd_addr;
    reg  [2:0]  exmem_funct3;
    reg  [1:0]  exmem_result_src;
    reg         exmem_reg_write, exmem_mem_write, exmem_halt;

    // ---- MEM ----
    wire [31:0] mem_rdata;

    // ---- MEM/WB ----
    reg  [31:0] memwb_alu_result, memwb_mem_rdata, memwb_pc_plus4;
    reg  [4:0]  memwb_rd_addr;
    reg  [2:0]  memwb_funct3;
    reg  [1:0]  memwb_result_src;
    reg         memwb_reg_write, memwb_halt;
    wire [31:0] memwb_load_data, memwb_wb_data, memwb_shift;

    //=========================================================================
    //  IF 级：取指与 PC
    //=========================================================================
    assign flush   = ex_take;                              // 分支/跳转命中
    assign pc_next = flush ? ex_target : pc_plus4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          pc <= RESET_PC;
        else if (halt)       pc <= pc;                     // 停机冻结
        else if (stall)      pc <= pc;                     // load-use 停顿
        else                 pc <= pc_next;
    end

    assign pc_plus4 = pc + 32'd4;
    assign pc_out   = pc;

    imem #(.DEPTH(IMEM_DEPTH), .INIT(IMEM_INIT)) u_imem (
        .addr  (pc),
        .rdata (if_instr)
    );

    //=========================================================================
    //  IF/ID 流水寄存器
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifid_pc    <= 32'd0;
            ifid_instr <= NOP;
        end else if (halt || stall) begin
            // 冻结：保持当前值
        end else if (flush) begin
            ifid_pc    <= 32'd0;
            ifid_instr <= NOP;
        end else begin
            ifid_pc    <= pc;
            ifid_instr <= if_instr;
        end
    end

    assign instr_out = ifid_instr;

    //=========================================================================
    //  ID 级：译码 + 读寄存器
    //=========================================================================
    assign id_funct3   = ifid_instr[14:12];
    assign id_funct7   = ifid_instr[31:25];
    assign id_rs1_addr = ifid_instr[19:15];
    assign id_rs2_addr = ifid_instr[24:20];
    assign id_rd_addr  = ifid_instr[11:7];

    control u_control (
        .opcode     (ifid_instr[6:0]),
        .funct3     (id_funct3),
        .funct7     (id_funct7),
        .reg_write  (id_reg_write),
        .mem_write  (id_mem_write),
        .result_src (id_result_src),
        .alu_src_a  (id_alu_src_a),
        .alu_src_b  (id_alu_src_b),
        .alu_op     (id_alu_op),
        .imm_type   (id_imm_type),
        .branch     (id_branch),
        .jump       (id_jump),
        .halt       (id_halt),
        .alu_ctrl   (id_alu_ctrl)
    );

    imm_gen u_imm_gen (
        .instr    (ifid_instr),
        .imm_type (id_imm_type),
        .imm      (id_imm)
    );

    regfile u_regfile (
        .clk (clk),
        .we  (memwb_reg_write),
        .ra1 (id_rs1_addr),
        .ra2 (id_rs2_addr),
        .wa  (memwb_rd_addr),
        .wd  (memwb_wb_data),
        .rd1 (id_rs1_raw),
        .rd2 (id_rs2_raw)
    );

    // WB -> ID 旁路：寄存器堆同拍"写后读"必须把写回值直接旁路给 ID
    assign wb_to_id_rs1 = memwb_reg_write && (memwb_rd_addr != 5'd0) &&
                          (memwb_rd_addr == id_rs1_addr);
    assign wb_to_id_rs2 = memwb_reg_write && (memwb_rd_addr != 5'd0) &&
                          (memwb_rd_addr == id_rs2_addr);

    assign id_rs1_data = wb_to_id_rs1 ? memwb_wb_data : id_rs1_raw;
    assign id_rs2_data = wb_to_id_rs2 ? memwb_wb_data : id_rs2_raw;

    assign idex_mem_read = (idex_result_src == 2'b01);     // EX 级是 load

    hazard_unit u_hazard (
        .ifid_rs1_addr (id_rs1_addr),
        .ifid_rs2_addr (id_rs2_addr),
        .idex_rd_addr  (idex_rd_addr),
        .idex_mem_read (idex_mem_read),
        .stall         (stall)
    );

    //=========================================================================
    //  ID/EX 流水寄存器（停顿或冲刷时插入气泡）
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idex_pc         <= 32'd0;
            idex_pc_plus4   <= 32'd0;
            idex_rs1_data   <= 32'd0;
            idex_rs2_data   <= 32'd0;
            idex_imm        <= 32'd0;
            idex_rs1_addr   <= 5'd0;
            idex_rs2_addr   <= 5'd0;
            idex_rd_addr    <= 5'd0;
            idex_funct3     <= 3'd0;
            idex_alu_ctrl   <= 4'd0;
            idex_result_src <= 2'b00;
            idex_alu_src_a  <= 2'b00;
            idex_alu_src_b  <= 1'b0;
            idex_reg_write  <= 1'b0;
            idex_mem_write  <= 1'b0;
            idex_branch     <= 1'b0;
            idex_jump       <= 1'b0;
            idex_halt       <= 1'b0;
        end else if (halt) begin
            // 冻结
        end else if (stall || flush) begin
            // 气泡
            idex_reg_write  <= 1'b0;
            idex_mem_write  <= 1'b0;
            idex_branch     <= 1'b0;
            idex_jump       <= 1'b0;
            idex_halt       <= 1'b0;
            idex_result_src <= 2'b00;
            idex_alu_src_a  <= 2'b00;
            idex_alu_src_b  <= 1'b0;
            idex_alu_ctrl   <= 4'd0;
            idex_rd_addr    <= 5'd0;
            idex_funct3     <= 3'd0;
            idex_rs1_addr   <= 5'd0;
            idex_rs2_addr   <= 5'd0;
        end else begin
            idex_pc         <= ifid_pc;
            idex_pc_plus4   <= ifid_pc + 32'd4;
            idex_rs1_data   <= id_rs1_data;
            idex_rs2_data   <= id_rs2_data;
            idex_imm        <= id_imm;
            idex_rs1_addr   <= id_rs1_addr;
            idex_rs2_addr   <= id_rs2_addr;
            idex_rd_addr    <= id_rd_addr;
            idex_funct3     <= id_funct3;
            idex_alu_ctrl   <= id_alu_ctrl;
            idex_result_src <= id_result_src;
            idex_alu_src_a  <= id_alu_src_a;
            idex_alu_src_b  <= id_alu_src_b;
            idex_reg_write  <= id_reg_write;
            idex_mem_write  <= id_mem_write;
            idex_branch     <= id_branch;
            idex_jump       <= id_jump;
            idex_halt       <= id_halt;
        end
    end

    //=========================================================================
    //  EX 级：前递 + 执行 + 分支解析
    //=========================================================================
    forward_unit u_forward (
        .idex_rs1_addr  (idex_rs1_addr),
        .idex_rs2_addr  (idex_rs2_addr),
        .exmem_rd_addr  (exmem_rd_addr),
        .exmem_reg_write(exmem_reg_write),
        .memwb_rd_addr  (memwb_rd_addr),
        .memwb_reg_write(memwb_reg_write),
        .forward_a      (forward_a),
        .forward_b      (forward_b)
    );

    assign ex_rs1_data = (forward_a == 2'b01) ? exmem_alu_result :
                         (forward_a == 2'b10) ? memwb_wb_data    : idex_rs1_data;
    assign ex_rs2_data = (forward_b == 2'b01) ? exmem_alu_result :
                         (forward_b == 2'b10) ? memwb_wb_data    : idex_rs2_data;

    assign ex_alu_a = (idex_alu_src_a == 2'b00) ? ex_rs1_data :
                      (idex_alu_src_a == 2'b01) ? idex_pc      : 32'd0;
    assign ex_alu_b = idex_alu_src_b ? idex_imm : ex_rs2_data;

    alu u_alu (
        .a    (ex_alu_a),
        .b    (ex_alu_b),
        .op   (idex_alu_ctrl),
        .y    (ex_alu_result),
        .zero ()
    );

    assign ex_eq  = (ex_rs1_data == ex_rs2_data);
    assign ex_lt  = ($signed(ex_rs1_data) < $signed(ex_rs2_data));
    assign ex_ltu = (ex_rs1_data < ex_rs2_data);

    always @(*) begin
        case (idex_funct3)
            3'b000:  ex_branch_taken = ex_eq;
            3'b001:  ex_branch_taken = ~ex_eq;
            3'b100:  ex_branch_taken = ex_lt;
            3'b101:  ex_branch_taken = ~ex_lt;
            3'b110:  ex_branch_taken = ex_ltu;
            3'b111:  ex_branch_taken = ~ex_ltu;
            default: ex_branch_taken = 1'b0;
        endcase
    end

    assign ex_take   = idex_jump | (idex_branch & ex_branch_taken);
    assign ex_target = {ex_alu_result[31:1], 1'b0};

    //=========================================================================
    //  EX/MEM 流水寄存器
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_alu_result <= 32'd0;
            exmem_rs2_data   <= 32'd0;
            exmem_pc_plus4   <= 32'd0;
            exmem_rd_addr    <= 5'd0;
            exmem_funct3     <= 3'd0;
            exmem_result_src <= 2'b00;
            exmem_reg_write  <= 1'b0;
            exmem_mem_write  <= 1'b0;
            exmem_halt       <= 1'b0;
        end else if (halt) begin
            // 冻结
        end else begin
            exmem_alu_result <= ex_alu_result;
            exmem_rs2_data   <= ex_rs2_data;
            exmem_pc_plus4   <= idex_pc_plus4;
            exmem_rd_addr    <= idex_rd_addr;
            exmem_funct3     <= idex_funct3;
            exmem_result_src <= idex_result_src;
            exmem_reg_write  <= idex_reg_write;
            exmem_mem_write  <= idex_mem_write;
            exmem_halt       <= idex_halt;
        end
    end

    //=========================================================================
    //  MEM 级：数据存储器访问
    //=========================================================================
    dmem #(.DEPTH(DMEM_DEPTH), .INIT(DMEM_INIT)) u_dmem (
        .clk   (clk),
        .addr  (exmem_alu_result),
        .wdata (exmem_rs2_data),
        .we    (exmem_mem_write),
        .size  (exmem_funct3),
        .rdata (mem_rdata)
    );

    //=========================================================================
    //  MEM/WB 流水寄存器
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_alu_result <= 32'd0;
            memwb_mem_rdata  <= 32'd0;
            memwb_pc_plus4   <= 32'd0;
            memwb_rd_addr    <= 5'd0;
            memwb_funct3     <= 3'd0;
            memwb_result_src <= 2'b00;
            memwb_reg_write  <= 1'b0;
            memwb_halt       <= 1'b0;
        end else if (halt) begin
            // 冻结
        end else begin
            memwb_alu_result <= exmem_alu_result;
            memwb_mem_rdata  <= mem_rdata;
            memwb_pc_plus4   <= exmem_pc_plus4;
            memwb_rd_addr    <= exmem_rd_addr;
            memwb_funct3     <= exmem_funct3;
            memwb_result_src <= exmem_result_src;
            memwb_reg_write  <= exmem_reg_write;
            memwb_halt       <= exmem_halt;
        end
    end

    //=========================================================================
    //  WB 级：写回
    //=========================================================================
    assign memwb_shift = memwb_mem_rdata >> (8 * memwb_alu_result[1:0]);

    assign memwb_load_data =
        (memwb_funct3 == 3'b000) ? {{24{memwb_shift[7]}},  memwb_shift[7:0]}  :
        (memwb_funct3 == 3'b001) ? {{16{memwb_shift[15]}}, memwb_shift[15:0]} :
        (memwb_funct3 == 3'b100) ? {24'b0, memwb_shift[7:0]}                  :
        (memwb_funct3 == 3'b101) ? {16'b0, memwb_shift[15:0]}                 :
                                   memwb_mem_rdata;

    assign memwb_wb_data =
        (memwb_result_src == 2'b00) ? memwb_alu_result :
        (memwb_result_src == 2'b01) ? memwb_load_data  : memwb_pc_plus4;

    assign halt = memwb_halt;

endmodule
