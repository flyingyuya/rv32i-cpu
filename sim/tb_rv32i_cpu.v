//=============================================================================
//  tb_rv32i_cpu.v  --  自检测试平台
//
//  流程：
//    1. imem/dmem 通过 $readmemh 载入 program.hex
//    2. 复位若干周期后释放
//    3. 运行直到 CPU 执行 ecall/ebreak 拉高 halt（带超时保护）
//    4. 把 32 个寄存器与 program.expected 逐一比对，输出 PASS/FAIL
//
//  该 .expected 由 rvsim.py（独立实现的 RV32I 功能模型）生成，
//  两个独立实现互相交叉验证（cross-check）。
//=============================================================================
`timescale 1ns/1ps

module tb_rv32i_cpu;

    localparam MAX_CYCLES = 200000;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    wire        halt;
    wire [31:0] pc_out;
    wire [31:0] instr_out;

    integer i;
    integer errors;
    integer cycles;
    reg [31:0] expected [0:31];

    // ---------------- DUT ----------------
    rv32i_cpu #(
        .IMEM_DEPTH (1024),
        .DMEM_DEPTH (1024),
        .IMEM_INIT  ("program.hex"),
        .DMEM_INIT  ("program.hex")
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .halt      (halt),
        .pc_out    (pc_out),
        .instr_out (instr_out)
    );

    // 100 MHz
    always #5 clk = ~clk;

    // ---------------- 激励与自检 ----------------
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_rv32i_cpu);

        $readmemh("program.expected", expected);

        // 复位
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // 运行直到 halt（在负边沿采样，避开非阻塞赋值竞争）
        cycles = 0;
        while (!halt && (cycles < MAX_CYCLES)) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        if (!halt) begin
            $display("==== FAIL: TIMEOUT after %0d cycles (CPU 未停机) ====", cycles);
            $display("        PC = 0x%08x", pc_out);
            $finish;
        end

        // 寄存器比对
        errors = 0;
        for (i = 1; i < 32; i = i + 1) begin
            if (dut.u_regfile.regs[i] !== expected[i]) begin
                $display("  MISMATCH x%-2d: got 0x%08x  expected 0x%08x",
                         i, dut.u_regfile.regs[i], expected[i]);
                errors = errors + 1;
            end
        end

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("==== PASS: %0d cycles, 31/31 寄存器全部匹配 ====", cycles);
        else
            $display("==== FAIL: %0d 个寄存器不匹配 ====", errors);
        $display("--------------------------------------------------");

        $finish;
    end

endmodule
