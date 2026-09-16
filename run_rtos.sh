#!/usr/bin/env bash
#=============================================================================
#  run_rtos.sh  --  构建并仿真 RTOS 演示程序
#
#    ./run_rtos.sh                  # 默认 RTOS 演示
#    ./run_rtos.sh sw/rtos/csr_test.c  # 指定程序
#=============================================================================
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

MAIN=${1:-sw/rtos/rtos_demo.c}
BUILD=build-rtos

echo "==== [1/3] 构建裸机程序 ===="
./sw/rtos/build.sh "$MAIN" "$BUILD/program.hex"

echo
echo "==== [2/3] 编译 RTL + testbench ===="
iverilog -g2012 -o "$BUILD/tb_rtos.vvp" -s tb_rtos sim/tb_rtos.v rtl/*.v
echo "      编译通过"

echo
echo "==== [3/3] 仿真 ===="
cd "$BUILD"
vvp tb_rtos.vvp
