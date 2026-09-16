#!/usr/bin/env bash
#=============================================================================
#  run_tests.sh  --  一键回归
#  对「单周期」与「五级流水线」两个实现，跑同一套汇编测试，
#  并与独立的 Python 功能模型（黄金参考）逐寄存器比对。
#  退出码 0 表示全部通过。
#=============================================================================
set -u
cd "$(dirname "$0")"

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
PYTHON=${PYTHON:-python3}
BUILD=build

TBS="tb_rv32i_cpu tb_rv32i_pipe"

mkdir -p "$BUILD"

echo "[1/3] 编译两个 DUT + testbench ..."
for tb in $TBS; do
    if ! $IVERILOG -g2012 -o "$BUILD/$tb.vvp" -s "$tb" "sim/$tb.v" rtl/*.v; then
        echo "  编译失败: $tb"; exit 2
    fi
done
echo "      编译通过"

echo "[2/3] 汇编所有测试并生成黄金参考 ..."
for t in sw/tests/*.s; do
    name=$(basename "$t" .s)
    if ! $PYTHON sw/rvasm.py "$t" -o "$BUILD/program.hex" \
            --listing "$BUILD/$name.lst" > "$BUILD/asm.log" 2>&1; then
        echo "  汇编失败: $name"; cat "$BUILD/asm.log"; exit 2
    fi
    if ! $PYTHON sw/rvsim.py "$BUILD/program.hex" -o "$BUILD/$name.expected" \
            > "$BUILD/$name.iss.log" 2>&1; then
        echo "  ISS 失败: $name"; cat "$BUILD/$name.iss.log"; exit 2
    fi
    cp "$BUILD/$name.expected" "$BUILD/program.expected"
done
echo "      完成"

echo "[3/3] 运行测试 ..."
pass=0; fail=0
for t in sw/tests/*.s; do
    name=$(basename "$t" .s)
    cp "$BUILD/$name.expected" "$BUILD/program.expected"
    cp "$BUILD/$name.lst"      "$BUILD/program.lst"
    $PYTHON sw/rvasm.py "$t" -o "$BUILD/program.hex" >/dev/null 2>&1

    for tb in $TBS; do
        dut=${tb#tb_}
        ( cd "$BUILD" && $VVP "$tb.vvp" > "run_$dut.log" 2>&1 )
        if grep -q "==== PASS" "$BUILD/run_$dut.log"; then
            cyc=$(grep -oE '[0-9]+ cycles' "$BUILD/run_$dut.log" | head -1)
            printf "  \033[32mPASS\033[0m  %-16s %-18s %s\n" "$name" "$dut" "$cyc"
            pass=$((pass+1))
        else
            printf "  \033[31mFAIL\033[0m  %-16s %-18s\n" "$name" "$dut"
            grep -E "MISMATCH|FAIL|TIMEOUT" "$BUILD/run_$dut.log" | head -8
            fail=$((fail+1))
        fi
    done
done

echo "---------------------------------------------------------------"
printf "  合计: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n" "$pass" "$fail"
echo "---------------------------------------------------------------"
[ "$fail" -eq 0 ]
