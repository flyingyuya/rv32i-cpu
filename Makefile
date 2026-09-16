# =============================================================================
#  RV32I 单周期处理器 —— 构建 / 仿真
#
#    make sim TEST=sw/tests/test_arith.s   # 跑单个测试
#    make all-tests                        # 跑全部测试（回归）
#    make wave                             # 打开波形（需 gtkwave）
#    make list                             # 列出所有测试
#    make clean
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

BUILD    := build
RTL      := $(wildcard rtl/*.v)
TB       := sim/tb_rv32i_cpu.v
TEST     ?= sw/tests/test_arith.s
TESTS    := $(wildcard sw/tests/*.s)

.PHONY: all sim all-tests clean wave list

all: sim

$(BUILD):
	@mkdir -p $(BUILD)

# 1) 汇编 + 生成黄金参考（Python 功能模型）
$(BUILD)/program.expected: $(TEST) sw/rvasm.py sw/rvsim.py | $(BUILD)
	@$(PYTHON) sw/rvasm.py $(TEST) -o $(BUILD)/program.hex --listing $(BUILD)/program.lst
	@$(PYTHON) sw/rvsim.py $(BUILD)/program.hex -o $@ --dump-mem > $(BUILD)/iss.log
	@echo "[iss] 黄金参考已生成，运行日志见 $(BUILD)/iss.log"

# 2) 编译 RTL + testbench
$(BUILD)/tb.vvp: $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_rv32i_cpu $(TB) $(RTL)

# 3) 单测试仿真
sim: $(BUILD)/tb.vvp $(BUILD)/program.expected
	@cd $(BUILD) && $(VVP) tb.vvp

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
