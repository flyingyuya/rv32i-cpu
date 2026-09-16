//=============================================================================
//  tb_rtos.v  --  RTOS 仿真测试平台
//
//  监控 MMIO UART 写操作，把 CPU 输出的字符打印到仿真终端，
//  并在写 EXIT 寄存器（halt）或超过周期上限后结束。
//=============================================================================
`timescale 1ns/1ps

module tb_rtos;

    localparam MAX_CYCLES = 1000000;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;

    wire        halt;
    wire        uart_valid;
    wire [7:0]  uart_data;
    wire [31:0] pc_out;
    wire [31:0] instr_out;
    wire [31:0] mcause_out;
    wire        trap_out;
    wire [31:0] mtime_out;

    integer cycles;
    integer nchar;

    rv32i_rtos #(
        .RAM_DEPTH (4096),
        .IMEM_INIT ("program.hex"),
        .DMEM_INIT ("program.hex")
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .halt       (halt),
        .uart_valid (uart_valid),
        .uart_data  (uart_data),
        .pc_out     (pc_out),
        .instr_out  (instr_out),
        .mcause_out (mcause_out),
        .trap_out   (trap_out),
        .mtime_out  (mtime_out)
    );

    always #5 clk = ~clk;

    // UART 输出
    initial nchar = 0;
    always @(posedge clk) begin
        if (uart_valid) begin
            $write("%c", uart_data);
            nchar = nchar + 1;
        end
    end

    initial begin
        $dumpfile("wave_rtos.vcd");
        $dumpvars(0, tb_rtos);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        cycles = 0;
        while (!halt && (cycles < MAX_CYCLES)) begin
            @(negedge clk);
            cycles = cycles + 1;
        end

        $write("\n");
        $display("--------------------------------------------------");
        if (halt)
            $display("==== 仿真结束: 程序写 EXIT 寄存器 ====");
        else
            $display("==== 超时: %0d 周期仍未结束 ====", cycles);
        $display("  周期数 = %0d,  UART 输出字符数 = %0d", cycles, nchar);
        $display("  最终 PC = 0x%08x,  mtime = %0d", pc_out, mtime_out);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
