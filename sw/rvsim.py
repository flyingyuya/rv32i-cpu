#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rvsim.py —— RV32I 指令级功能模型（Golden ISS）

作用：在 Python 中执行与 Verilog 完全相同的程序，输出最终寄存器状态，
      作为 Verilog testbench 自检对比的“标准答案”。

用法：
  python3 rvsim.py build/program.hex -o build/program.expected [--dump-mem]
"""

from __future__ import annotations

import argparse
import sys

XLEN = 32
MASK = (1 << XLEN) - 1


def sext(v: int, bits: int) -> int:
    """把 bits 位的有符号数扩展到 32bit。"""
    sign = 1 << (bits - 1)
    v &= (1 << bits) - 1
    return ((v ^ sign) - sign) & MASK


def s32(v: int) -> int:
    """截断为 32bit 有符号。"""
    v &= MASK
    return v - (1 << 32) if v & 0x8000_0000 else v


class RV32I:
    def __init__(self, mem_words=None, mem_size=1024):
        self.regs = [0] * 32
        self.pc = 0
        self.mem = [0] * mem_size          # 按字寻址
        if mem_words:
            for i, w in enumerate(mem_words):
                if i < mem_size:
                    self.mem[i] = w & MASK
        self.halt = False
        self.cycles = 0
        self.max_cycles = 1_000_000

    # -------------------- 存储器 --------------------
    def read_word(self, addr):
        return self.mem[(addr >> 2) % len(self.mem)]

    def write_word(self, addr, val):
        self.mem[(addr >> 2) % len(self.mem)] = val & MASK

    def read_byte(self, addr):
        w = self.read_word(addr & ~0x3)
        return (w >> (8 * (addr & 0x3))) & 0xFF

    def write_byte(self, addr, val):
        widx = (addr >> 2) % len(self.mem)
        sh = 8 * (addr & 0x3)
        self.mem[widx] = (self.mem[widx] & ~(0xFF << sh)) | ((val & 0xFF) << sh)

    def read_half(self, addr):
        w = self.read_word(addr & ~0x3)
        return (w >> (8 * (addr & 0x3))) & 0xFFFF

    def write_half(self, addr, val):
        widx = (addr >> 2) % len(self.mem)
        sh = 8 * (addr & 0x3)
        self.mem[widx] = (self.mem[widx] & ~(0xFFFF << sh)) | ((val & 0xFFFF) << sh)

    # -------------------- 寄存器 --------------------
    def rs(self, i):
        return self.regs[i] if i != 0 else 0

    def wr(self, i, v):
        if i != 0:
            self.regs[i] = v & MASK

    # -------------------- 执行一条指令 --------------------
    def step(self):
        instr = self.read_word(self.pc)
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        f7 = (instr >> 25) & 0x7F

        # 立即数
        imm_i = s32(sext(instr >> 20, 12))
        imm_s = s32(sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12))
        imm_b = s32(sext(((instr >> 31) << 12) | (((instr >> 7) & 1) << 11) |
                         (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13))
        imm_u = instr & 0xFFFFF000
        imm_j = s32(sext(((instr >> 31) << 20) | (((instr >> 12) & 0xFF) << 12) |
                         (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21))

        a = self.rs(rs1)
        b = self.rs(rs2)
        pc = self.pc
        nxt = (pc + 4) & MASK

        if opcode == 0b0110011:                      # R 型
            if f3 == 0b000:
                r = (a - b) if f7 >> 5 else (a + b)
            elif f3 == 0b001:
                r = a << (b & 31)
            elif f3 == 0b010:
                r = 1 if s32(a) < s32(b) else 0
            elif f3 == 0b011:
                r = 1 if a < b else 0
            elif f3 == 0b100:
                r = a ^ b
            elif f3 == 0b101:
                r = (s32(a) >> (b & 31)) & MASK if f7 >> 5 else (a >> (b & 31))
            elif f3 == 0b110:
                r = a | b
            else:
                r = a & b
            self.wr(rd, r)

        elif opcode == 0b0010011:                    # I 型算术
            if f3 == 0b000:
                r = a + imm_i
            elif f3 == 0b010:
                r = 1 if s32(a) < s32(imm_i) else 0
            elif f3 == 0b011:
                r = 1 if a < (imm_i & MASK) else 0
            elif f3 == 0b100:
                r = a ^ imm_i
            elif f3 == 0b110:
                r = a | imm_i
            elif f3 == 0b111:
                r = a & imm_i
            elif f3 == 0b001:
                r = a << ((instr >> 20) & 31)
            elif f3 == 0b101:
                sh = (instr >> 20) & 31
                r = (s32(a) >> sh) & MASK if (instr >> 30) & 1 else (a >> sh)
            else:
                r = 0
            self.wr(rd, r)

        elif opcode == 0b0000011:                    # 载入
            addr = (a + imm_i) & MASK
            if f3 == 0b000:
                r = sext(self.read_byte(addr), 8)
            elif f3 == 0b001:
                r = sext(self.read_half(addr), 16)
            elif f3 == 0b100:
                r = self.read_byte(addr)
            elif f3 == 0b101:
                r = self.read_half(addr)
            else:
                r = self.read_word(addr & ~0x3)
            self.wr(rd, r)

        elif opcode == 0b0100011:                    # 存储
            addr = (a + imm_s) & MASK
            if f3 == 0b000:
                self.write_byte(addr, b & 0xFF)
            elif f3 == 0b001:
                self.write_half(addr, b & 0xFFFF)
            else:
                self.write_word(addr & ~0x3, b)

        elif opcode == 0b1100011:                    # 分支
            if f3 == 0b000:
                take = a == b
            elif f3 == 0b001:
                take = a != b
            elif f3 == 0b100:
                take = s32(a) < s32(b)
            elif f3 == 0b101:
                take = s32(a) >= s32(b)
            elif f3 == 0b110:
                take = a < b
            else:
                take = a >= b
            if take:
                nxt = (pc + imm_b) & MASK

        elif opcode == 0b1101111:                    # JAL
            self.wr(rd, nxt)
            nxt = (pc + imm_j) & MASK

        elif opcode == 0b1100111:                    # JALR
            self.wr(rd, nxt)
            nxt = (a + imm_i) & ~1 & MASK

        elif opcode == 0b0110111:                    # LUI
            self.wr(rd, imm_u)

        elif opcode == 0b0010111:                    # AUIPC
            self.wr(rd, pc + imm_u)

        elif opcode == 0b0001111:                    # FENCE -> nop
            pass

        elif opcode == 0b1110011:                    # ecall / ebreak
            self.halt = True

        else:
            raise RuntimeError(f'非法指令 @0x{pc:08x}: 0x{instr:08x}')

        self.pc = nxt
        self.cycles += 1

    def run(self):
        while not self.halt:
            if self.cycles >= self.max_cycles:
                raise RuntimeError(f'超过最大周期数 {self.max_cycles}，可能死循环')
            self.step()


def load_hex(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//') or line.startswith('#'):
                continue
            for tok in line.split():
                words.append(int(tok, 16))
    return words


def main():
    ap = argparse.ArgumentParser(description='RV32I 指令级功能模型')
    ap.add_argument('hexfile')
    ap.add_argument('-o', '--output', help='输出期望寄存器文件')
    ap.add_argument('--dump-mem', action='store_true', help='打印数据区内容')
    ap.add_argument('--max-cycles', type=int, default=200000)
    args = ap.parse_args()

    words = load_hex(args.hexfile)
    cpu = RV32I(words, mem_size=max(1024, len(words)))
    cpu.max_cycles = args.max_cycles

    try:
        cpu.run()
    except RuntimeError as e:
        print(f'[rvsim] 运行错误: {e}', file=sys.stderr)
        sys.exit(1)

    lines = [f'{cpu.regs[i]:08x}' for i in range(32)]
    if args.output:
        with open(args.output, 'w') as f:
            f.write('\n'.join(lines) + '\n')

    print(f'[rvsim] 停机 @PC=0x{cpu.pc:08x}，共 {cpu.cycles} 个周期')
    print('[rvsim] 最终寄存器:')
    for i in range(0, 32, 4):
        print('        ' + '  '.join(f'x{j}={cpu.regs[j]:08x}' for j in range(i, i + 4)))

    if args.dump_mem:
        print('[rvsim] 数据区 [0x400, 0x440):')
        for w in range(0x400 >> 2, 0x440 >> 2, 4):
            print('        ' + '  '.join(f'{cpu.mem[k]:08x}' for k in range(w, w + 4)))


if __name__ == '__main__':
    main()
