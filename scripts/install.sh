#!/bin/zsh
# 打包并装到 /Applications/DiskSlim.app，然后启动。不用 sudo，不改系统设置。
# 用法：scripts/install.sh
# 只会替换我们自己装的那份（按 bundle id 核对）；别的同名应用一律不动、直接退出。
set -euo pipefail
cd "$(dirname "$0")/.."

ID=local.nat.disk-slim
DEST=/Applications/DiskSlim.app

scripts/bundle.sh

if [[ -e "$DEST" ]]; then
  existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
  if [[ "$existing" != "$ID" ]]; then
    echo "停止：$DEST 已存在，但不是磁盘瘦身（bundle id 是 $existing），不覆盖。" >&2
    exit 1
  fi
fi

# 停掉正在运行的（dist 里的和已装的都算），免得两份同时在菜单栏
pkill -f "DiskSlim.app/Contents/MacOS/DiskSlimApp" 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -f "DiskSlim.app/Contents/MacOS/DiskSlimApp" >/dev/null || break; sleep 1; done

# 先装到临时名，成功后再换上，中途失败不会留下半个应用
TMP="/Applications/.DiskSlim.app.installing"
rm -rf "$TMP"
ditto dist/DiskSlim.app "$TMP"
rm -rf "$DEST"
mv "$TMP" "$DEST"

open "$DEST"
echo "已安装并启动：$DEST"
echo "以后更新也跑这个脚本。本机签名每次重新打包都会变，系统可能要你重新允许「完全磁盘访问权限」和通知。"
