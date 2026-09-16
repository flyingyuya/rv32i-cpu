#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bin2hex.py —— 把 ld.lld --oformat=binary 产出的扁平二进制镜像，
              转换成 iverilog $readmemh 可直接读取的十六进制文本。

用法：
  python3 bin2hex.py program.bin -o program.hex --words 4096
"""

import argparse


def main():
    ap = argparse.ArgumentParser(description='flat binary -> $readmemh hex image')
    ap.add_argument('binfile')
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--words', type=int, default=4096,
                    help='镜像字数（字 = 32bit），默认 4096 = 16KB')
    args = ap.parse_args()

    with open(args.binfile, 'rb') as f:
        data = f.read()

    if len(data) % 4:
        data += b'\x00' * (4 - len(data) % 4)

    words = [int.from_bytes(data[i:i + 4], 'little')
             for i in range(0, len(data), 4)]

    if len(words) > args.words:
        raise SystemExit(f'镜像过大: {len(words)} 字 > 上限 {args.words} 字')

    with open(args.output, 'w') as f:
        for i in range(args.words):
            f.write(f'{words[i] if i < len(words) else 0:08x}\n')

    print(f'[bin2hex] {args.binfile} ({len(data)} B) -> {args.output} '
          f'({args.words} 字 / {args.words * 4} B)')


if __name__ == '__main__':
    main()
