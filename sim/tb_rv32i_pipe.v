//=============================================================================
//  tb_rv32i_pipe.v  --  五级流水线自检测试平台
//
//  与 tb_rv32i_cpu.v 使用同一套 program.hex / program.expected，
//  用于验证流水线版本与单周期版本、以及独立的 Python 功能模型三者一致。
//=============================================================================
`timescale 1ns/1ps

module tb_rv32i_pipe;

    localparam MAX_CYCLES = 300000;

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    wire        halt;
    wire [31:0] pc_out;
    wire [31:0] instr_out;

    integer i;
    integer errors;
    integer cycles;
    reg [31:0] expected [0:31];

    rv32i_pipe #(
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

    always #5 clk = ~clk;

    initial begin
        $dumpfile("wave_pipe.vcd");
        $dumpvars(0, tb_rv32i_pipe);

        $readmemh("program.expected", expected);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        cycles = 0;
        while (!halt && (cycles < MAX_CYCLES)) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        if (!halt) begin
            $display("==== FAIL: TIMEOUT after %0d cycles (流水线未停机) ====", cycles);
            $display("        PC = 0x%08x", pc_out);
            $finish;
        end

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
