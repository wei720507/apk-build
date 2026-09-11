#!/usr/bin/env bash
# 本地构建(Android Studio) 时使用的 overlay 脚本。
# 用法:
#   bash apply_overlay.sh <rustdesk源码根目录>
# 例:
#   git clone https://github.com/rustdesk/rustdesk.git ~/rustdesk
#   cd ~/rustdesk
#   bash /path/to/this/repo/customization/apply_overlay.sh ~/rustdesk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_ROOT="${1:?用法: apply_overlay.sh <rustdesk源码根目录>}"

PY="${PYTHON:-python3}"

echo "[*] 复制定制 Dart 模块 -> $RD_ROOT/flutter/lib/custom/"
mkdir -p "$RD_ROOT/flutter/lib/custom"
cp -r "$SCRIPT_DIR/flutter/lib/custom/." "$RD_ROOT/flutter/lib/custom/"

echo "[*] 注入定制层补丁 ..."
"$PY" "$SCRIPT_DIR/apply_overlay.py" "$RD_ROOT"

echo "[*] 完成。接下来在 $RD_ROOT/flutter 里按 RustDesk 官方方式编译即可。"
