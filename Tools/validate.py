#!/usr/bin/env python3
"""按配置依次验证；任何命令失败立即停止。"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=root / 'validation.json')
    args = parser.parse_args()
    configuration = json.loads(args.config.read_text(encoding='utf-8'))
    output = root / 'work' / 'validation' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    steps = configuration['steps']
    if not steps:
        raise ValueError('验证配置没有任务')
    for index, step in enumerate(steps, 1):
        command = step['command']
        if not command:
            raise ValueError('验证命令不能为空')
        log = output / f'{index:02d}.log'
        print(f"开始验证：{step['name']}", flush=True)
        with log.open('w', encoding='utf-8') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=configuration['timeoutSeconds'], check=False)
        if result.returncode != 0:
            print(f"验证失败：{step['name']}，退出码 {result.returncode}，日志：{log}", file=sys.stderr)
            print('\n'.join(log.read_text(errors='replace').splitlines()[-30:]), file=sys.stderr)
            return result.returncode
        print(f"验证通过：{step['name']}", flush=True)
    print(f'全部验证通过，日志：{output}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f'验证已停止：{error}', file=sys.stderr)
        raise SystemExit(1)
