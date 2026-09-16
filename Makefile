# =============================================================================
#  RV32I 处理器 —— 构建 / 仿真
#
#    make sim TEST=sw/tests/test_arith.s TB=tb_rv32i_pipe   # 单个测试 + 指定 DUT
#    make all-tests                                          # 全量回归（两个 DUT）
#    make list / make clean
#
#  TB 可选: tb_rv32i_cpu(单周期, 默认) / tb_rv32i_pipe(五级流水线)
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

BUILD    := build
RTL      := $(wildcard rtl/*.v)
TB       ?= tb_rv32i_cpu
TEST     ?= sw/tests/test_arith.s
TESTS    := $(wildcard sw/tests/*.s)

.PHONY: all sim all-tests clean list

all: sim

$(BUILD):
	@mkdir -p $(BUILD)

# 1) 汇编 + 生成黄金参考（Python 功能模型）
$(BUILD)/program.expected: $(TEST) sw/rvasm.py sw/rvsim.py | $(BUILD)
	@$(PYTHON) sw/rvasm.py $(TEST) -o $(BUILD)/program.hex --listing $(BUILD)/program.lst
	@$(PYTHON) sw/rvsim.py $(BUILD)/program.hex -o $@ --dump-mem > $(BUILD)/iss.log
	@echo "[iss] 黄金参考已生成，运行日志见 $(BUILD)/iss.log"

# 2) 编译 RTL + 指定 testbench
$(BUILD)/$(TB).vvp: $(RTL) sim/$(TB).v | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s $(TB) sim/$(TB).v $(RTL)

# 3) 单测试仿真
sim: $(BUILD)/$(TB).vvp $(BUILD)/program.expected
	@cd $(BUILD) && $(VVP) $(TB).vvp

# 4) 全量回归
all-tests:
	@./run_tests.sh

wave: sim
	@gtkwave $(BUILD)/wave.vcd &

list:
	@echo "可用测试:"
	@for t in $(TESTS); do echo "  $$t"; done

clean:
	rm -rf $(BUILD)
