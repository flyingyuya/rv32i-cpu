#!/usr/bin/env bash
#=============================================================================
#  build.sh  --  裸机 RTOS 构建脚本
#
#    ./sw/rtos/build.sh [主程序.c] [输出hex]
#    默认: sw/rtos/rtos_demo.c  ->  build-rtos/program.hex
#
#  流程: clang 交叉编译 -> ld.lld 链接为 flat binary -> bin2hex
#=============================================================================
set -eu
cd "$(dirname "$0")/../.."

MAIN=${1:-sw/rtos/rtos_demo.c}
OUTHEX=${2:-build-rtos/program.hex}
CC=${CC:-rvcc}
PYTHON=${PYTHON:-python3}

TARGET="--target=riscv32-unknown-elf -march=rv32i -mabi=ilp32"
CFLAGS="$TARGET -ffreestanding -nostdlib -fno-builtin -fno-stack-protector -mno-relax \
        -Os -Wall -Wextra -Wno-unused-parameter -I sw/rtos"
LDFLAGS="$TARGET -nostdlib -fuse-ld=lld -mno-relax \
         -Wl,-T,sw/rtos/link.ld -Wl,--oformat=binary"

BUILD=$(dirname "$OUTHEX")
mkdir -p "$BUILD"

CORE_SRCS=${CORE_SRCS:-"sw/rtos/crt0.S sw/rtos/divsi3.c sw/rtos/rtos.c sw/rtos/trap.S sw/rtos/switch.S"}
SRCS="$CORE_SRCS $MAIN"
OBJS=""
for s in $SRCS; do
    o="$BUILD/$(basename "$s").o"
    echo "[build] $s"
    $CC $CFLAGS -c "$s" -o "$o"
    OBJS="$OBJS $o"
done

echo "[build] 链接"
$CC $LDFLAGS -Wl,-Map,"$BUILD/map.txt" -o "$BUILD/app.bin" $OBJS

echo "[build] 生成 hex 镜像"
$PYTHON sw/bin2hex.py "$BUILD/app.bin" -o "$OUTHEX" --words 4096
echo "[build] 完成: $OUTHEX ($(stat -c%s "$BUILD/app.bin") 字节)"
