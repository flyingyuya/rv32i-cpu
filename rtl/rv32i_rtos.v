//=============================================================================
//  rv32i_rtos.v  --  面向 RTOS 的 RV32I 处理器
//
//  在单周期 RV32I 基础上增加：
//    1. Zicsr 指令与机器模式 CSR：mstatus / mie / mtvec / mepc / mcause / mip / mscratch
//    2. Trap 机制：ecall 同步异常 + 机器定时器中断，mret 返回
//    3. 内存映射外设（MMIO）
//         0x0000_0000 - 0x0000_3FFF  RAM (16KB)
//         0x1000_0000                UART TX  (写低 8 位即输出一个字符)
//         0x1000_0004                EXIT     (写入即结束仿真)
//         0x2000_0000                mtime    (只读，每周期 +1)
//         0x2000_0004                mtimecmp (读写)
//
//  设计说明：选择单周期而非流水线实现，是为了让 trap 天然精确
//  （每条指令原子完成，mepc = 当前 PC，无需冲刷流水线）。
//  流水线版本的精确中断留作后续工作。
//=============================================================================
`timescale 1ns/1ps

module rv32i_rtos #(
    parameter RAM_DEPTH = 4096,               // 字数 = 16KB
    parameter IMEM_INIT = "program.hex",
    parameter DMEM_INIT = "program.hex"
)(
    input  wire        clk,
    input  wire        rst_n,

    output wire        halt,                  // 写 EXIT 寄存器后拉高
    output wire        uart_valid,            // UART 写脉冲
    output wire [7:0]  uart_data,             // UART 输出字符

    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire [31:0] mcause_out,
    output wire        trap_out,              // trap 发生脉冲（调试用）
    output wire [31:0] mtime_out
);

    //-------------------------------------------------------------------------
    //  常量
    //-------------------------------------------------------------------------
    localparam [31:0] ADDR_UART     = 32'h1000_0000;
    localparam [31:0] ADDR_EXIT     = 32'h1000_0004;
    localparam [31:0] ADDR_MTIME    = 32'h2000_0000;
    localparam [31:0] ADDR_MTIMECMP = 32'h2000_0004;

    localparam [11:0] CSR_MSTATUS  = 12'h300;
    localparam [11:0] CSR_MIE      = 12'h304;
    localparam [11:0] CSR_MTVEC    = 12'h305;
    localparam [11:0] CSR_MSCRATCH = 12'h340;
    localparam [11:0] CSR_MEPC     = 12'h341;
    localparam [11:0] CSR_MCAUSE   = 12'h342;
    localparam [11:0] CSR_MIP      = 12'h344;

    //-------------------------------------------------------------------------
    //  信号声明
    //-------------------------------------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4, pc_next, pc_target;
    wire [31:0] instr;

    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [4:0]  rs1_addr, rs2_addr, rd_addr;
    wire [31:0] rs1_data, rs2_data, imm;
    wire [31:0] wb_data;

    wire        ctrl_reg_write, ctrl_mem_write, ctrl_branch, ctrl_jump, ctrl_halt;
    wire        alu_src_b;
    wire [1:0]  ctrl_result_src, alu_src_a, ctrl_alu_op;
    wire [2:0]  imm_type;
    wire [3:0]  alu_ctrl;

    wire [31:0] alu_a, alu_b, alu_result;
    wire        eq, lt, ltu;
    reg         branch_taken;

    wire [31:0] mem_rdata;
    wire [31:0] load_data;

    wire [31:0] mem_addr = alu_result;

    // CSR / trap
    reg  [31:0] r_mstatus, r_mie, r_mtvec, r_mscratch, r_mepc, r_mcause;
    reg  [31:0] csr_rdata;
    wire        mstatus_mie = r_mstatus[3];
    wire        mie_mtie    = r_mie[7];
    reg  [31:0] mtime, mtimecmp;
    wire        mtip        = (mtime >= mtimecmp) && (mtimecmp != 32'hFFFF_FFFF);
    wire        mip_mtip    = mtip;

    wire        is_csr, is_ecall, is_ebreak, is_mret;
    wire        wb_we;
    wire [1:0]  csr_op;
    wire [31:0] csr_wdata;
    wire        csr_we;
    wire        trap_take;
    wire [31:0] trap_cause;
    wire        int_pending;

    wire        is_ram, is_uart, is_exit, is_mtime, is_mtimecmp;
    wire        uart_wr, exit_wr, mtimecmp_wr;
    reg         halted;

    //-------------------------------------------------------------------------
    //  PC
    //-------------------------------------------------------------------------
    assign pc_plus4  = pc + 32'd4;
    assign pc_target = {alu_result[31:1], 1'b0};
    assign pc_next   = trap_take ? r_mtvec :
                       is_mret   ? r_mepc  :
                       (ctrl_jump | (ctrl_branch & branch_taken)) ? pc_target : pc_plus4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    pc <= 32'h0;
        else if (halt) pc <= pc;
        else           pc <= pc_next;
    end

    assign pc_out = pc;

    //-------------------------------------------------------------------------
    //  取指
    //-------------------------------------------------------------------------
    imem #(.DEPTH(RAM_DEPTH), .INIT(IMEM_INIT)) u_imem (.addr(pc), .rdata(instr));
    assign instr_out = instr;

    //-------------------------------------------------------------------------
    //  译码
    //-------------------------------------------------------------------------
    assign funct3   = instr[14:12];
    assign funct7   = instr[31:25];
    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    regfile u_regfile (
        .clk (clk),
        .we  (wb_we),
        .ra1 (rs1_addr), .ra2 (rs2_addr),
        .wa  (rd_addr),  .wd (wb_data),
        .rd1 (rs1_data), .rd2 (rs2_data)
    );

    imm_gen u_imm_gen (.instr(instr), .imm_type(imm_type), .imm(imm));

    control u_control (
        .opcode     (instr[6:0]),
        .funct3     (funct3),
        .funct7     (funct7),
        .reg_write  (ctrl_reg_write),
        .mem_write  (ctrl_mem_write),
        .result_src (ctrl_result_src),
        .alu_src_a  (alu_src_a),
        .alu_src_b  (alu_src_b),
        .alu_op     (ctrl_alu_op),
        .imm_type   (imm_type),
        .branch     (ctrl_branch),
        .jump       (ctrl_jump),
        .halt       (ctrl_halt),
        .alu_ctrl   (alu_ctrl)
    );

    //-------------------------------------------------------------------------
    //  CSR 指令译码（Zicsr）
    //-------------------------------------------------------------------------
    assign is_ecall  = (instr == 32'h0000_0073);
    assign is_ebreak = (instr == 32'h0010_0073);
    assign is_mret   = (instr == 32'h3020_0073);
    // opcode = 1110011 且 funct3 != 000 即为 Zicsr 指令
    assign is_csr    = (instr[6:0] == 7'b1110011) && (funct3 != 3'b000);

    // 写回使能：CSR 指令也要写 rd；trap / mret 时全部抑制
    assign wb_we     = (ctrl_reg_write | is_csr) & ~trap_take & ~is_mret;

    assign csr_op    = ((funct3 == 3'b001) || (funct3 == 3'b101)) ? 2'd0 :   // rw / rwi
                       ((funct3 == 3'b010) || (funct3 == 3'b110)) ? 2'd1 :   // rs / rsi
                                                                    2'd2;    // rc / rci
    assign csr_we    = is_csr;
    assign csr_wdata = instr[14] ? {27'b0, instr[19:15]} : rs1_data;

    //-------------------------------------------------------------------------
    //  Trap 判定
    //-------------------------------------------------------------------------
    assign int_pending = mstatus_mie & mie_mtie & mip_mtip;
    assign trap_take   = int_pending | is_ecall;
    assign trap_cause  = int_pending ? 32'h8000_0007 : 32'd11;   // 7=Machine timer, 11=ECALL
    assign trap_out    = trap_take;
    assign mcause_out  = r_mcause;

    //-------------------------------------------------------------------------
    //  CSR 寄存器组
    //-------------------------------------------------------------------------
    always @(*) begin
        case (instr[31:20])
            CSR_MSTATUS:  csr_rdata = r_mstatus;
            CSR_MIE:      csr_rdata = r_mie;
            CSR_MTVEC:    csr_rdata = r_mtvec;
            CSR_MSCRATCH: csr_rdata = r_mscratch;
            CSR_MEPC:     csr_rdata = r_mepc;
            CSR_MCAUSE:   csr_rdata = r_mcause;
            CSR_MIP:      csr_rdata = {24'b0, mip_mtip, 7'b0};
            default:      csr_rdata = 32'd0;
        endcase
    end

    wire [31:0] csr_wval = (csr_op == 2'd1) ? (csr_rdata | csr_wdata) :
                           (csr_op == 2'd2) ? (csr_rdata & ~csr_wdata) :
                                              csr_wdata;

    // mstatus 次态：trap 时 MPIE<=MIE、MIE<=0；mret 时 MIE<=MPIE、MPIE<=1
    wire [31:0] mstatus_next =
        trap_take ? {r_mstatus[31:8], r_mstatus[3], r_mstatus[6:4], 1'b0, r_mstatus[2:0]} :
        is_mret   ? {r_mstatus[31:8], 1'b1,         r_mstatus[6:4], r_mstatus[7], r_mstatus[2:0]} :
        (csr_we && (instr[31:20] == CSR_MSTATUS)) ? (csr_wval & 32'h0000_1888) :
                    r_mstatus;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_mstatus  <= 32'h0;
            r_mie      <= 32'h0;
            r_mtvec    <= 32'h0;
            r_mscratch <= 32'h0;
            r_mepc     <= 32'h0;
            r_mcause   <= 32'h0;
            mtime      <= 32'h0;
            mtimecmp   <= 32'hFFFF_FFFF;
        end else begin
            r_mstatus <= mstatus_next;

            // mepc
            if (trap_take)                              r_mepc <= pc;
            else if (csr_we && (instr[31:20] == CSR_MEPC)) r_mepc <= csr_wval & 32'hFFFF_FFFC;

            // mcause
            if (trap_take)                                r_mcause <= trap_cause;
            else if (csr_we && (instr[31:20] == CSR_MCAUSE)) r_mcause <= csr_wval;

            // 其余 CSR
            if (csr_we && !trap_take && !is_mret) begin
                case (instr[31:20])
                    CSR_MIE:      r_mie      <= csr_wval & 32'h0000_0888;
                    CSR_MTVEC:    r_mtvec    <= csr_wval & 32'hFFFF_FFFC;
                    CSR_MSCRATCH: r_mscratch <= csr_wval;
                    default: ;
                endcase
            end

            // 定时器
            mtime <= mtime + 32'd1;
            if (mtimecmp_wr) mtimecmp <= rs2_data;
        end
    end

    //-------------------------------------------------------------------------
    //  执行
    //-------------------------------------------------------------------------
    assign alu_a = (alu_src_a == 2'b00) ? rs1_data :
                   (alu_src_a == 2'b01) ? pc       : 32'd0;
    assign alu_b = alu_src_b ? imm : rs2_data;

    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_ctrl), .y(alu_result), .zero());

    assign eq  = (rs1_data == rs2_data);
    assign lt  = ($signed(rs1_data) < $signed(rs2_data));
    assign ltu = (rs1_data < rs2_data);

    always @(*) begin
        case (funct3)
            3'b000:  branch_taken = eq;
            3'b001:  branch_taken = ~eq;
            3'b100:  branch_taken = lt;
            3'b101:  branch_taken = ~lt;
            3'b110:  branch_taken = ltu;
            3'b111:  branch_taken = ~ltu;
            default: branch_taken = 1'b0;
        endcase
    end

    //-------------------------------------------------------------------------
    //  地址译码 / MMIO
    //-------------------------------------------------------------------------
    assign is_ram      = (mem_addr < 32'h0000_4000);
    assign is_uart     = (mem_addr == ADDR_UART);
    assign is_exit     = (mem_addr == ADDR_EXIT);
    assign is_mtime    = (mem_addr == ADDR_MTIME);
    assign is_mtimecmp = (mem_addr == ADDR_MTIMECMP);

    // trap / mret 时抑制访存与写回
    wire mem_en = ctrl_mem_write & ~trap_take & ~is_mret;
    wire ram_we = is_ram & mem_en;

    wire uart_wr_int     = is_uart     & mem_en;
    wire exit_wr_int     = is_exit     & mem_en;
    wire mtimecmp_wr_int = is_mtimecmp & mem_en;

    assign uart_wr     = uart_wr_int;
    assign exit_wr     = exit_wr_int;
    assign mtimecmp_wr = mtimecmp_wr_int;
    assign uart_valid  = uart_wr_int;
    assign uart_data   = rs2_data[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     halted <= 1'b0;
        else if (exit_wr) halted <= 1'b1;
    end
    assign halt = halted;

    dmem #(.DEPTH(RAM_DEPTH), .INIT(DMEM_INIT)) u_dmem (
        .clk (clk), .addr(mem_addr), .wdata(rs2_data),
        .we  (ram_we), .size(funct3), .rdata(mem_rdata)
    );

    //-------------------------------------------------------------------------
    //  读数据（RAM / MMIO 选择）
    //-------------------------------------------------------------------------
    wire [31:0] mmio_rdata = is_mtime    ? mtime :
                             is_mtimecmp ? mtimecmp : 32'd0;

    wire [31:0] mem_rdata_sel = is_ram ? mem_rdata : mmio_rdata;

    wire [31:0] mem_shift = mem_rdata_sel >> (8 * mem_addr[1:0]);

    assign load_data =
        (funct3 == 3'b000) ? {{24{mem_shift[7]}},  mem_shift[7:0]}  :
        (funct3 == 3'b001) ? {{16{mem_shift[15]}}, mem_shift[15:0]} :
        (funct3 == 3'b100) ? {24'b0, mem_shift[7:0]}                :
        (funct3 == 3'b101) ? {16'b0, mem_shift[15:0]}               :
                             mem_rdata_sel;

    //-------------------------------------------------------------------------
    //  写回
    //-------------------------------------------------------------------------
    assign wb_data = is_csr   ? csr_rdata :
                     (ctrl_result_src == 2'b00) ? alu_result :
                     (ctrl_result_src == 2'b01) ? load_data  : pc_plus4;

    assign mtime_out = mtime;

endmodule
