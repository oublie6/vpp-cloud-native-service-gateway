#!/usr/bin/env python3
"""为缺少 getsubids 的 Ubuntu 20.04 实验主机读取本地 subordinate ID。"""

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="查询本地 /etc/subuid 或 /etc/subgid")
    parser.add_argument("-g", action="store_true", help="查询 group ID")
    parser.add_argument("user")
    args = parser.parse_args()
    path = Path("/etc/subgid" if args.g else "/etc/subuid")
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        print(f"getsubids-compat: {path}: {exc}", file=sys.stderr)
        return 1
    matches = [line.split(":") for line in rows if line.split(":", 1)[0] == args.user]
    for index, fields in enumerate(matches):
        if len(fields) != 3 or not all(value.isdecimal() for value in fields[1:]):
            print(f"getsubids-compat: {path}: invalid entry for {args.user}", file=sys.stderr)
            return 1
        print(f"{index}: {args.user} {fields[1]} {fields[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
