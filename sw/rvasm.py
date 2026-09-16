#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rvasm.py —— 极简 RV32I 汇编器

用途：把手写的 RV32I 汇编测试程序汇编成 $readmemh 可直接读取的十六进制镜像。

支持：
  * RV32I 基础指令（R/I/S/B/U/J 型，含 ecall/ebreak）
  * 常用伪指令：li, la, mv, nop, j, jr, ret, not, neg, seqz, snez,
                beqz, bnez, blez, bgez, bltz, bgtz, ble, bgt
  * 段指示：.text（地址 0） / .data（地址 0x400） / .org <addr>
  * 数据指示：.word / .byte / .space / .align
  * 表达式：十进制 / 0x 十六进制 / 0b 二进制 / 'c' 字符 / 标签(+/-常量) / %hi() / %lo()

用法：
  python3 rvasm.py tests/test_arith.s -o build/program.hex --listing build/program.lst
"""

from __future__ import annotations

import argparse
import re
import sys

TEXT_BASE = 0x0000_0000
DATA_BASE = 0x0000_0400

# --------------------------------------------------------------------------
# 寄存器名 -> 编号
# --------------------------------------------------------------------------
ABI = {
    'zero': 0,  'ra': 1,  'sp': 2,  'gp': 3,  'tp': 4,
    't0': 5,    't1': 6,  't2': 7,
    's0': 8,    'fp': 8,  's1': 9,
    'a0': 10,   'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16,   'a7': 17,
    's2': 18,   's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24,   's9': 25, 's10': 26, 's11': 27,
    't3': 28,   't4': 29, 't5': 30, 't6': 31,
}
for _i in range(32):
    ABI[f'x{_i}'] = _i


class AsmError(Exception):
    pass


def parse_reg(tok: str) -> int:
    t = tok.strip().lower()
    if t in ABI:
        return ABI[t]
    raise AsmError(f'非法寄存器名: {tok}')


def parse_expr(tok: str, labels: dict, pc: int) -> int:
    """解析立即数/地址表达式。"""
    t = tok.strip()

    # %hi / %lo
    m = re.fullmatch(r'%(hi|lo)\s*\(\s*(.+?)\s*\)', t)
    if m:
        v = parse_expr(m.group(2), labels, pc)
        if m.group(1) == 'hi':
            return ((v + 0x800) >> 12) & 0xFFFFF
        return v & 0xFFF

    # 字符字面量
    m = re.fullmatch(r"'(.)'", t)
    if m:
        return ord(m.group(1))

    # 标签（可带 +/- 常量）
    m = re.fullmatch(r'([A-Za-z_.$][\w.$]*)\s*(?:([+-])\s*(.+))?', t)
    if m and m.group(1) in labels:
        v = labels[m.group(1)]
        if m.group(2):
            off = int(m.group(3), 0)
            v = v + off if m.group(2) == '+' else v - off
        return v

    # 纯数字
    try:
        return int(t, 0)
    except ValueError:
        pass

    if m:
        raise AsmError(f'未定义标签: {m.group(1)}')
    raise AsmError(f'无法解析表达式: {tok}')


def i12(v: int) -> int:
    """12bit 立即数：同时接受有符号(-2048..2047)与无符号位模式(0..4095)，统一转为 12bit 位模式。"""
    if not (-2048 <= v <= 4095):
        raise AsmError(f'I 型立即数越界: {v} (需 -2048..2047 或 0..4095)')
    return v & 0xFFF


# --------------------------------------------------------------------------
# 编码器
# --------------------------------------------------------------------------
def enc_r(opcode, f3, f7, rd, rs1, rs2):
    return ((f7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | \
           ((f3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_i(opcode, f3, rd, rs1, imm):
    return ((i12(imm)) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_s(opcode, f3, rs1, rs2, imm):
    v = i12(imm)
    return (((v >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | \
           ((f3 & 0x7) << 12) | ((v & 0x1F) << 7) | (opcode & 0x7F)


def enc_b(opcode, f3, rs1, rs2, imm):
    if imm % 2 != 0:
        raise AsmError(f'分支目标未对齐(必须为偶数): {imm}')
    if not (-4096 <= imm <= 4094):
        raise AsmError(f'分支偏移越界: {imm} (需 -4096..4094)')
    v = imm & 0x1FFF
    b12 = (v >> 12) & 1
    b11 = (v >> 11) & 1
    b10_5 = (v >> 5) & 0x3F
    b4_1 = (v >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | \
           ((f3 & 0x7) << 12) | (b4_1 << 8) | (b11 << 7) | (opcode & 0x7F)


def enc_u(opcode, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_j(opcode, rd, imm):
    if imm % 2 != 0:
        raise AsmError(f'跳转目标未对齐(必须为偶数): {imm}')
    if not (-1048576 <= imm <= 1048574):
        raise AsmError(f'跳转偏移越界: {imm}')
    v = imm & 0x1FFFFF
    b20 = (v >> 20) & 1
    b10_1 = (v >> 1) & 0x3FF
    b11 = (v >> 11) & 1
    b19_12 = (v >> 12) & 0xFF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)


# --------------------------------------------------------------------------
# 指令表： 助记符 -> (类型, opcode, funct3, funct7)
# --------------------------------------------------------------------------
OPC = {
    'R':      0b0110011,
    'I':      0b0010011,
    'LOAD':   0b0000011,
    'STORE':  0b0100011,
    'BRANCH': 0b1100011,
    'JAL':    0b1101111,
    'JALR':   0b1100111,
    'LUI':    0b0110111,
    'AUIPC':  0b0010111,
    'SYS':    0b1110011,
}

R_OPS = {
    'add': (0b000, 0b0000000), 'sub': (0b000, 0b0100000),
    'sll': (0b001, 0b0000000), 'slt': (0b010, 0b0000000),
    'sltu': (0b011, 0b0000000), 'xor': (0b100, 0b0000000),
    'srl': (0b101, 0b0000000), 'sra': (0b101, 0b0100000),
    'or':  (0b110, 0b0000000), 'and': (0b111, 0b0000000),
}
I_OPS = {
    'addi': 0b000, 'slti': 0b010, 'sltiu': 0b011, 'xori': 0b100,
    'ori':  0b110, 'andi': 0b111,
}
SHIFT_OPS = {'slli': (0b001, 0b0000000), 'srli': (0b101, 0b0000000),
             'srai': (0b101, 0b0100000)}
LOAD_OPS = {'lb': 0b000, 'lh': 0b001, 'lw': 0b010, 'lbu': 0b100, 'lhu': 0b101}
STORE_OPS = {'sb': 0b000, 'sh': 0b001, 'sw': 0b010}
BR_OPS = {'beq': 0b000, 'bne': 0b001, 'blt': 0b100,
          'bge': 0b101, 'bltu': 0b110, 'bgeu': 0b111}

# 伪指令 -> 单条等价指令
PSEUDO1 = {
    'nop':  ('addi', ['x0', 'x0', '0']),
    'ret':  ('jalr', ['x0', 'ra', '0']),
}

# 伪指令 -> 两条等价指令（跳转/条件）
PSEUDO2 = {
    'beqz': ('beq',  [0, 'x0']),   # beqz rs, L   -> beq  rs, x0, L
    'bnez': ('bne',  [0, 'x0']),
    'bltz': ('blt',  [0, 'x0']),
    'bgez': ('bge',  [0, 'x0']),
    'blez': ('bge',  ['x0', 0]),   # blez rs, L   -> bge  x0, rs, L
    'bgtz': ('blt',  ['x0', 0]),
    'ble':  ('bge',  [1, 0]),      # ble  a,b,L   -> bge  b, a, L
    'bgt':  ('blt',  [1, 0]),      # bgt  a,b,L   -> blt  b, a, L
}


# --------------------------------------------------------------------------
# 词法 / 语法
# --------------------------------------------------------------------------
def strip_comment(line: str) -> str:
    out = []
    in_str = False
    for ch in line:
        if ch == "'":
            in_str = not in_str
        if not in_str and ch in '#;':
            break
        out.append(ch)
    return ''.join(out).strip()


def split_operands(s: str):
    """按逗号切分操作数，但保留 'off(rs1)' 中的括号。"""
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
            continue
        cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_mem_operand(tok: str):
    """解析 'imm(rs1)' 形式，返回 (imm_str, rs1_str)。"""
    m = re.fullmatch(r'(.+?)\(\s*([^)]+)\s*\)', tok.strip())
    if not m:
        raise AsmError(f'访存操作数格式应为 imm(rs1): {tok}')
    return m.group(1).strip(), m.group(2).strip()


def li_plan(tok: str, labels: dict, pc: int):
    """决定 li 展开为几条指令，返回 (n, value) ；value 可能为 None（标签未知）。"""
    t = tok.strip()
    is_numeric = bool(re.fullmatch(r'[-+]?(0[xX][0-9a-fA-F]+|0[bB][01]+|\d+)', t))
    if is_numeric:
        v = int(t, 0)
        if -2048 <= v <= 2047:
            return 1, v
        return 2, v
    return 2, None


def size_of(mn: str, ops, labels, pc):
    """返回该语句展开后的指令条数。"""
    if mn == 'li':
        return li_plan(ops[1], labels, pc)[0]
    if mn == 'la':
        return 2
    return 1


# --------------------------------------------------------------------------
# 汇编主体
# --------------------------------------------------------------------------
def assemble(text: str):
    lines = text.splitlines()

    # ---------- PASS 1: 计算地址、收集标签 ----------
    labels = {}
    items = []          # (addr, mn, ops, srcline, raw)  指令
    datas = []          # (addr, dir, vals, srcline, raw) 数据
    addr = TEXT_BASE    # 当前地址（按字节）

    for lineno, raw in enumerate(lines, 1):
        line = strip_comment(raw)
        if not line:
            continue

        # 标签（可能一行多个/带指令）
        while True:
            m = re.match(r'^([A-Za-z_.$][\w.$]*)\s*:\s*', line)
            if not m:
                break
            name = m.group(1)
            if name in labels:
                raise AsmError(f'第 {lineno} 行: 标签重复定义 {name}')
            labels[name] = addr
            line = line[m.end():].strip()
        if not line:
            continue

        # 段指示
        if line.startswith('.'):
            parts = line.split(None, 1)
            d = parts[0].lower()
            arg = parts[1].strip() if len(parts) > 1 else ''
            if d == '.text':
                addr = TEXT_BASE
            elif d == '.data':
                addr = DATA_BASE
            elif d == '.org':
                addr = int(arg, 0)
            elif d == '.align':
                n = int(arg, 0)
                align = 1 << n
                addr = (addr + align - 1) // align * align
            elif d in ('.word', '.byte'):
                vals = split_operands(arg) if arg else []
                datas.append((addr, d, vals, lineno, raw))
                if d == '.word':
                    addr += 4 * len(vals)
                else:
                    addr += 1 * len(vals)
            elif d == '.space':
                addr += int(arg, 0)
            elif d in ('.globl', '.global'):
                pass
            else:
                raise AsmError(f'第 {lineno} 行: 未知指示符 {d}')
            continue

        # 指令
        parts = line.split(None, 1)
        mn = parts[0].lower()
        ops = split_operands(parts[1]) if len(parts) > 1 else []

        n = size_of(mn, ops, labels, addr)
        items.append((addr, mn, ops, lineno, raw))
        addr += 4 * n

    # ---------- PASS 2: 编码 ----------
    # 内存镜像：按字寻址，(addr, word)
    words = {}
    listing = []

    def emit(a, w):
        words[a >> 2] = w & 0xFFFFFFFF

    # ---- 发射数据段 ----
    for (a, d, vals, lineno, raw) in datas:
        if d == '.word':
            for k, v in enumerate(vals):
                w = parse_expr(v, labels, a + 4 * k) & 0xFFFFFFFF
                emit(a + 4 * k, w)
                listing.append((a + 4 * k, w, raw if k == 0 else ''))
        else:  # .byte
            for k, v in enumerate(vals):
                bv = parse_expr(v, labels, a + k) & 0xFF
                widx = (a + k) >> 2
                sh = 8 * ((a + k) & 3)
                words[widx] = (words.get(widx, 0) & ~(0xFF << sh)) | (bv << sh)

    for (a, mn, ops, lineno, raw) in items:
        try:
            # ---- 伪指令展开 ----
            if mn == 'li':
                rd = ops[0]
                n, v = li_plan(ops[1], labels, a)
                if n == 1:
                    w0 = enc_i(OPC['I'], I_OPS['addi'], parse_reg(rd), 0, v)
                    emit(a, w0)
                    listing.append((a, w0, raw))
                else:
                    val = parse_expr(ops[1], labels, a)
                    hi = ((val + 0x800) >> 12) & 0xFFFFF
                    lo = val & 0xFFF
                    w0 = enc_u(OPC['LUI'], parse_reg(rd), hi)
                    w1 = enc_i(OPC['I'], I_OPS['addi'], parse_reg(rd), parse_reg(rd), lo)
                    emit(a, w0); emit(a + 4, w1)
                    listing.append((a, w0, raw)); listing.append((a + 4, w1, ''))
                continue

            if mn == 'la':
                rd = parse_reg(ops[0])
                val = parse_expr(ops[1], labels, a)
                hi = ((val + 0x800) >> 12) & 0xFFFFF
                lo = val & 0xFFF
                w0 = enc_u(OPC['LUI'], rd, hi)
                w1 = enc_i(OPC['I'], I_OPS['addi'], rd, rd, lo)
                emit(a, w0); emit(a + 4, w1)
                listing.append((a, w0, raw)); listing.append((a + 4, w1, ''))
                continue

            if mn == 'mv':
                w = enc_i(OPC['I'], I_OPS['addi'], parse_reg(ops[0]), parse_reg(ops[1]), 0)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn in ('j',):
                off = parse_expr(ops[0], labels, a) - a
                w = enc_j(OPC['JAL'], 0, off)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'jal' and len(ops) == 1:
                off = parse_expr(ops[0], labels, a) - a
                w = enc_j(OPC['JAL'], 1, off)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'jr':
                w = enc_i(OPC['JALR'], 0b000, 0, parse_reg(ops[0]), 0)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'not':
                w = enc_i(OPC['I'], I_OPS['xori'], parse_reg(ops[0]), parse_reg(ops[1]), -1)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'neg':
                w = enc_r(OPC['R'], 0b000, 0b0100000, parse_reg(ops[0]), 0, parse_reg(ops[1]))
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'seqz':
                w = enc_i(OPC['I'], I_OPS['sltiu'], parse_reg(ops[0]), parse_reg(ops[1]), 1)
                emit(a, w); listing.append((a, w, raw)); continue

            if mn == 'snez':
                w = enc_r(OPC['R'], 0b011, 0b0000000, parse_reg(ops[0]), 0, parse_reg(ops[1]))
                emit(a, w); listing.append((a, w, raw)); continue

            if mn in PSEUDO1:
                tgt, o = PSEUDO1[mn]
                body = assemble_one(tgt, o, labels, a)
                emit(a, body); listing.append((a, body, raw)); continue

            if mn in PSEUDO2:
                tgt, idx = PSEUDO2[mn]
                if mn in ('ble', 'bgt'):
                    # ble a,b,L -> bge b,a,L ; bgt a,b,L -> blt b,a,L
                    rs1, rs2, lab = ops[0], ops[1], ops[2]
                    a_rs, b_rs = rs2, rs1
                    off = parse_expr(lab, labels, a) - a
                    w = enc_b(OPC['BRANCH'], BR_OPS[tgt], parse_reg(a_rs), parse_reg(b_rs), off)
                else:
                    rs, lab = ops[0], ops[1]
                    if idx[0] == 'x0':
                        a_rs, b_rs = 'x0', rs      # blez/bgtz
                    elif idx[1] == 'x0':
                        a_rs, b_rs = rs, 'x0'      # beqz/bnez/bltz/bgez
                    else:
                        raise AsmError('内部伪指令表错误')
                    off = parse_expr(lab, labels, a) - a
                    w = enc_b(OPC['BRANCH'], BR_OPS[tgt], parse_reg(a_rs), parse_reg(b_rs), off)
                emit(a, w); listing.append((a, w, raw)); continue

            # ---- 真实指令 ----
            w = assemble_one(mn, ops, labels, a)
            emit(a, w)
            listing.append((a, w, raw))

        except AsmError as e:
            raise AsmError(f'第 {lineno} 行 [{raw.strip()}]: {e}') from None

    listing.sort(key=lambda x: x[0])
    return words, labels, listing


def assemble_one(mn: str, ops, labels, pc) -> int:
    """编码单条真实指令，返回 32bit 机器码。"""
    # R 型
    if mn in R_OPS:
        f3, f7 = R_OPS[mn]
        rd, rs1, rs2 = parse_reg(ops[0]), parse_reg(ops[1]), parse_reg(ops[2])
        return enc_r(OPC['R'], f3, f7, rd, rs1, rs2)

    # I 型算术
    if mn in I_OPS:
        f3 = I_OPS[mn]
        rd, rs1 = parse_reg(ops[0]), parse_reg(ops[1])
        imm = parse_expr(ops[2], labels, pc)
        return enc_i(OPC['I'], f3, rd, rs1, imm)

    # 移位立即数
    if mn in SHIFT_OPS:
        f3, f7 = SHIFT_OPS[mn]
        rd, rs1 = parse_reg(ops[0]), parse_reg(ops[1])
        sh = parse_expr(ops[2], labels, pc)
        if not (0 <= sh <= 31):
            raise AsmError(f'移位量越界: {sh}')
        return ((f7 & 0x7F) << 25) | ((sh & 0x1F) << 20) | (rs1 << 15) | \
               ((f3 & 0x7) << 12) | (rd << 7) | OPC['I']

    # 载入
    if mn in LOAD_OPS:
        f3 = LOAD_OPS[mn]
        rd = parse_reg(ops[0])
        imm_s, rs1_s = parse_mem_operand(ops[1])
        imm = parse_expr(imm_s, labels, pc)
        return enc_i(OPC['LOAD'], f3, rd, parse_reg(rs1_s), imm)

    # 存储
    if mn in STORE_OPS:
        f3 = STORE_OPS[mn]
        rs2 = parse_reg(ops[0])
        imm_s, rs1_s = parse_mem_operand(ops[1])
        imm = parse_expr(imm_s, labels, pc)
        return enc_s(OPC['STORE'], f3, parse_reg(rs1_s), rs2, imm)

    # 分支
    if mn in BR_OPS:
        f3 = BR_OPS[mn]
        rs1, rs2 = parse_reg(ops[0]), parse_reg(ops[1])
        off = parse_expr(ops[2], labels, pc) - pc
        return enc_b(OPC['BRANCH'], f3, rs1, rs2, off)

    # U 型
    if mn == 'lui':
        return enc_u(OPC['LUI'], parse_reg(ops[0]), parse_expr(ops[1], labels, pc))
    if mn == 'auipc':
        return enc_u(OPC['AUIPC'], parse_reg(ops[0]), parse_expr(ops[1], labels, pc))

    # J 型
    if mn == 'jal':
        rd = parse_reg(ops[0])
        off = parse_expr(ops[1], labels, pc) - pc
        return enc_j(OPC['JAL'], rd, off)

    # JALR
    if mn == 'jalr':
        rd = parse_reg(ops[0])
        if len(ops) == 3:
            imm = parse_expr(ops[2], labels, pc)
            rs1 = parse_reg(ops[1])
        else:
            imm_s, rs1_s = parse_mem_operand(ops[1])
            imm = parse_expr(imm_s, labels, pc)
            rs1 = parse_reg(rs1_s)
        return enc_i(OPC['JALR'], 0b000, rd, rs1, imm)

    # 系统
    if mn == 'ecall':
        return 0x00000073
    if mn == 'ebreak':
        return 0x00100073

    raise AsmError(f'未知指令: {mn}')


# --------------------------------------------------------------------------
# 输出
# --------------------------------------------------------------------------
def write_hex(words: dict, path: str, depth_words: int = 1024):
    hi = max(words) if words else -1
    n = max(depth_words, hi + 1)
    with open(path, 'w') as f:
        for i in range(n):
            f.write(f'{words.get(i, 0):08x}\n')


def write_listing(listing, path: str):
    with open(path, 'w') as f:
        for addr, word, src in listing:
            f.write(f'{addr:08x}: {word:08x}    {src.rstrip()}\n')


def main():
    ap = argparse.ArgumentParser(description='极简 RV32I 汇编器')
    ap.add_argument('src', help='输入 .s 文件')
    ap.add_argument('-o', '--output', required=True, help='输出 .hex 镜像')
    ap.add_argument('--listing', help='输出带地址的列表文件')
    ap.add_argument('--depth', type=int, default=1024, help='镜像字数（默认 1024）')
    args = ap.parse_args()

    with open(args.src, 'r') as f:
        text = f.read()

    try:
        words, labels, listing = assemble(text)
    except AsmError as e:
        print(f'汇编错误: {e}', file=sys.stderr)
        sys.exit(1)

    write_hex(words, args.output, args.depth)
    if args.listing:
        write_listing(listing, args.listing)

    n_inst = len(listing)
    print(f'[rvasm] {args.src}: {n_inst} 条指令 -> {args.output}')
    if labels:
        for k, v in labels.items():
            print(f'         label {k:<16} = 0x{v:08x}')


if __name__ == '__main__':
    main()
