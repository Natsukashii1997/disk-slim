#!/bin/zsh
# 打包并装到 /Applications/DiskSlim.app，然后启动。不用 sudo，不改系统设置。
# 用法：scripts/install.sh
# - 只替换我们自己装的那份（按 bundle id 核对）；别的同名应用一律不动、直接退出。
# - 先把新版完整复制好，再停旧进程、换上；换的时候失败就把旧版放回去。
# - 应用正在清理时不会被停掉（它收到退出信号会拒绝），脚本这时停下，等清理完再装。
set -euo pipefail
cd "$(dirname "$0")/.."

ID=local.nat.disk-slim
DEST=/Applications/DiskSlim.app
TMP=/Applications/.DiskSlim.app.installing
OLD=/Applications/.DiskSlim.app.old
REPO_BIN="$PWD/dist/DiskSlim.app/Contents/MacOS/DiskSlimApp"
DEST_BIN="$DEST/Contents/MacOS/DiskSlimApp"

bundle_id() {
  [[ -f "$1/Contents/Info.plist" ]] || { echo "?"; return; }
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

# 我们自己的进程：名字是 DiskSlimApp，且可执行文件是已装的那份或本仓库 dist 里的那份
our_pids() {
  for pid in $(pgrep -x DiskSlimApp 2>/dev/null || true); do
    # C 区域设置下 ps 会把路径里的中文转义成 M-dM-8…，对不上，要按 UTF-8 输出
    exe=$(LC_ALL=en_US.UTF-8 ps -p "$pid" -o comm= 2>/dev/null || true)
    [[ "$exe" == "$DEST_BIN" || "$exe" == "$REPO_BIN" ]] && echo "$pid"
  done
  return 0
}

if [[ -e "$DEST" || -L "$DEST" ]]; then
  if [[ -L "$DEST" || "$(bundle_id "$DEST")" != "$ID" ]]; then
    echo "停止：$DEST 已存在，但不是磁盘瘦身（或是个链接），不覆盖。" >&2
    exit 1
  fi
fi
# 上次中途失败留下的残件只会是我们自己的临时目录，清掉
for leftover in "$TMP" "$OLD"; do
  if [[ -e "$leftover" ]]; then
    [[ "$(bundle_id "$leftover")" == "$ID" || ! -f "$leftover/Contents/Info.plist" ]] || { echo "停止：$leftover 不是磁盘瘦身的残件" >&2; exit 1; }
    rm -rf "$leftover"
  fi
done

scripts/bundle.sh

# 1. 先把新版完整复制到临时名；失败就删掉半成品，旧版照常运行
trap 'rm -rf "$TMP"' EXIT
ditto dist/DiskSlim.app "$TMP"
[[ "$(bundle_id "$TMP")" == "$ID" ]] || { echo "停止：复制出来的新版不完整" >&2; exit 1; }

# 2. 请旧进程退出（SIGTERM；应用正在清理时会拒绝），最多等 10 秒
was_running=0
pids=($(our_pids))
if (( ${#pids} )); then
  was_running=1
  kill -TERM $pids 2>/dev/null || true
  for _ in {1..10}; do (( ${#$(our_pids)} )) || break; sleep 1; done
  if (( ${#$(our_pids)} )); then
    echo "停止：磁盘瘦身还在运行（多半正在清理），没有替换。等它清理完再跑一次。" >&2
    exit 1
  fi
fi

# 3. 换上：旧版先挪开，新版挪进来；挪新版失败就把旧版放回去并重新打开
if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
if ! mv "$TMP" "$DEST"; then
  [[ -e "$OLD" ]] && mv "$OLD" "$DEST"
  (( was_running )) && open "$DEST"
  echo "停止：新版没能放进 /Applications，已恢复旧版。" >&2
  exit 1
fi
rm -rf "$OLD" || echo "提示：旧版 $OLD 没删干净，下次安装会再清。" >&2
trap - EXIT

# dist 里那份和已装的是同一个 bundle id，留着系统可能打开错的那份；装好后删掉（下次 bundle.sh 会重新生成）
rm -rf dist/DiskSlim.app

open "$DEST"
echo "已安装并启动：$DEST"
echo "本机签名每次重新打包都会变：如果「完全磁盘访问权限」列表里已经有磁盘瘦身，先用「−」删掉再重新加。"
