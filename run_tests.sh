#!/usr/bin/env bash
#=============================================================================
#  run_tests.sh  --  一键回归：汇编 -> 生成黄金参考 -> 仿真 -> 比对
#  退出码 0 表示全部通过
#=============================================================================
set -u
cd "$(dirname "$0")"

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PYTHON=${PYTHON:-python3}
BUILD=build

mkdir -p "$BUILD"

echo "[1/2] 编译 RTL + testbench ..."
if ! $IVERILOG -g2012 -o "$BUILD/tb.vvp" -s tb_rv32i_cpu sim/tb_rv32i_cpu.v rtl/*.v; then
    echo "编译失败"; exit 2
fi
echo "      编译通过"
echo "[2/2] 运行测试 ..."

pass=0; fail=0
for t in sw/tests/*.s; do
    name=$(basename "$t" .s)

    if ! $PYTHON sw/rvasm.py "$t" -o "$BUILD/program.hex" \
            --listing "$BUILD/program.lst" > "$BUILD/asm.log" 2>&1; then
        printf "  \033[31mASM-FAIL\033[0m  %s\n" "$name"
        cat "$BUILD/asm.log"; fail=$((fail+1)); continue
    fi

    if ! $PYTHON sw/rvsim.py "$BUILD/program.hex" -o "$BUILD/program.expected" \
            --dump-mem > "$BUILD/iss.log" 2>&1; then
        printf "  \033[31mISS-FAIL\033[0m  %s\n" "$name"
        cat "$BUILD/iss.log"; fail=$((fail+1)); continue
    fi

    ( cd "$BUILD" && $VVP tb.vvp > run.log 2>&1 )

    if grep -q "==== PASS" "$BUILD/run.log"; then
        cyc=$(grep -oE '[0-9]+ cycles' "$BUILD/run.log" | head -1)
        nins=$(grep -c . "$BUILD/program.lst" 2>/dev/null || echo 0)
        printf "  \033[32mPASS\033[0m  %-14s %-12s\n" "$name" "$cyc"
        pass=$((pass+1))
    else
        printf "  \033[31mFAIL\033[0m  %-14s\n" "$name"
        grep -E "MISMATCH|FAIL|TIMEOUT" "$BUILD/run.log" | head -10
        fail=$((fail+1))
    fi
done

echo "------------------------------------------------------"
printf "  合计: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$pass" "$fail"
echo "------------------------------------------------------"
[ "$fail" -eq 0 ]
