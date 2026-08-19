#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Утилита для частичного добавления (partial stage) изменений в git.
Позволяет выбрать только те хунки, которые относятся к указанным маркерам 
или попадают в диапазоны строк.

Использование:
  python git-partial-stage.py path/to/file.bsl --markers №%change1 №%change2
  python git-partial-stage.py path/to/file.bsl --lines 10-20 45-50
"""

import sys
import re
import subprocess
import argparse
import os

def get_marker_ranges(filepath, markers):
    if not os.path.exists(filepath):
        return []
        
    try:
        with open(filepath, 'r', encoding='utf-8-sig') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Ошибка чтения {filepath}: {e}", file=sys.stderr)
        return []
    
    ranges = []
    
    for i, line in enumerate(lines):
        line_num = i + 1
        has_marker = any(marker.lower() in line.lower() for marker in markers)
        
        if has_marker:
            start_line = line_num
            end_line = len(lines)
            
            # scan forward to find the end
            for j in range(i + 1, len(lines)):
                next_line = lines[j]
                
                # if another marker starts, end here
                if '№%' in next_line:
                    end_line = j
                    break
                
                # if end of procedure/function/region
                if re.match(r'^\s*(КонецПроцедуры|КонецФункции|#КонецОбласти|EndProcedure|EndFunction|#EndRegion)', next_line, re.IGNORECASE):
                    end_line = j + 1
                    break
            
            ranges.append((start_line, end_line))
            
    return ranges

def parse_diff(filepath, patch_file=None):
    if patch_file:
        try:
            with open(patch_file, 'rb') as f:
                patch_bytes = f.read()
        except OSError as e:
            print(f"Ошибка чтения {patch_file}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        cmd = ['git', 'diff', '-U0', '--', filepath]
        result = subprocess.run(cmd, capture_output=True)
        if result.returncode != 0:
            print(f"Ошибка git diff: {result.stderr.decode('utf-8', 'replace')}", file=sys.stderr)
            sys.exit(1)
        patch_bytes = result.stdout

    if not patch_bytes:
        return None, []

    patch = patch_bytes.decode('utf-8', 'replace')
    
    lines = patch.splitlines(keepends=True)
    header = []
    hunks = []
    current_hunk = None
    
    for line in lines:
        if line.startswith('@@ '):
            if current_hunk:
                hunks.append(current_hunk)
            current_hunk = {'header': line, 'lines': [], 'added': [], 'removed': []}
            
            m = re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
            if m:
                current_hunk['old_start'] = int(m.group(1))
                current_hunk['old_len'] = int(m.group(2)) if m.group(2) is not None else 1
                current_hunk['new_start'] = int(m.group(3))
                current_hunk['new_len'] = int(m.group(4)) if m.group(4) is not None else 1
        elif current_hunk is not None:
            current_hunk['lines'].append(line)
            if line.startswith('+'):
                current_hunk['added'].append(line[1:])
            elif line.startswith('-'):
                current_hunk['removed'].append(line[1:])
        else:
            header.append(line)
            
    if current_hunk:
        hunks.append(current_hunk)
        
    return "".join(header), hunks

def is_hunk_kept(hunk, ranges, markers, line_intervals):
    # 1. Если хунк явно добавляет или удаляет маркер
    for line in hunk['added'] + hunk['removed']:
        if any(marker.lower() in line.lower() for marker in markers):
            return True
            
    new_start = hunk['new_start']
    new_len = hunk['new_len']
    hunk_end = new_start + new_len - 1 if new_len > 0 else new_start
    
    # 2. Если хунк попадает в диапазоны маркеров
    for start, end in ranges:
        if new_start <= end and hunk_end >= start:
            return True
            
    # 3. Если хунк попадает в явно указанные диапазоны строк
    for start, end in line_intervals:
        if new_start <= end and hunk_end >= start:
            return True
            
    return False

def main():
    parser = argparse.ArgumentParser(description="Partial stage files based on markers or line ranges.")
    parser.add_argument("filepath", help="Path to the file to stage")
    parser.add_argument("--markers", nargs='+', default=[], help="List of markers (e.g. №%%change-id)")
    parser.add_argument("--lines", nargs='+', default=[], help="List of line ranges (e.g. 10-20 40-50)")
    parser.add_argument("--patch-file", default=None,
                        help="Unified diff from host (rtk git diff -U0); для песочницы без git")
    parser.add_argument("--emit-patch", action="store_true",
                        help="Вывести отфильтрованный патч в stdout (git apply --cached на хосте)")
    
    args = parser.parse_args()
    
    if not args.markers and not args.lines:
        print("Ошибка: Необходимо указать --markers или --lines", file=sys.stderr)
        sys.exit(1)
        
    filepath = args.filepath
    
    # Parse line intervals
    line_intervals = []
    for lr in args.lines:
        parts = lr.split('-')
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            line_intervals.append((int(parts[0]), int(parts[1])))
        elif len(parts) == 1 and parts[0].isdigit():
            line_intervals.append((int(parts[0]), int(parts[0])))
            
    ranges = get_marker_ranges(filepath, args.markers)
    
    header, hunks = parse_diff(filepath, args.patch_file)
    if not header:
        print(f"Нет изменений для файла: {filepath}", file=sys.stderr)
        sys.exit(1 if args.emit_patch else 0)

    kept_hunks = []
    for hunk in hunks:
        if is_hunk_kept(hunk, ranges, args.markers, line_intervals):
            kept_hunks.append(hunk)

    if not kept_hunks:
        print(f"Нет хунков, подходящих под критерии, для файла: {filepath}", file=sys.stderr)
        sys.exit(1)

    # Сборка патча
    patch_lines = [header]
    for hunk in kept_hunks:
        patch_lines.append(hunk['header'])
        patch_lines.extend(hunk['lines'])

    final_patch = "".join(patch_lines)

    if args.emit_patch:
        sys.stdout.write(final_patch)
        return

    # Применение патча к индексу (требует git в PATH)
    apply_cmd = ['git', 'apply', '--cached', '--unidiff-zero']
    process = subprocess.run(apply_cmd, input=final_patch.encode('utf-8'), capture_output=True)

    if process.returncode == 0:
        print(f"Успешно проиндексировано {len(kept_hunks)} из {len(hunks)} хунков для {filepath}")
    else:
        print(f"Ошибка при git apply: {process.stderr.decode('utf-8', 'replace')}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
