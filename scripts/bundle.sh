#!/bin/zsh
# 把桌面应用打包成 dist/DiskSlim.app，并做本机签名（ad-hoc）。不安装、不启动。
# 用法：scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DiskSlimApp 2>&1 | grep -v "ld: warning: search path"

APP=dist/DiskSlim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskSlimApp "$APP/Contents/MacOS/DiskSlimApp"
# 桌面悬浮球的图标（定稿图见 design/fuyou-icon/）
cp assets/floating-ball.png "$APP/Contents/Resources/ball.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.nat.disk-slim</string>
  <key>CFBundleName</key><string>DiskSlim</string>
  <key>CFBundleDisplayName</key><string>磁盘瘦身</string>
  <key>CFBundleExecutable</key><string>DiskSlimApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <!-- 第 9 批：驿窗侧栏挂件用 diskslim://panel/toggle?x=…&y=…&w=…&h=… 叫开面板 -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>local.nat.disk-slim.panel</string>
      <key>CFBundleURLSchemes</key><array><string>diskslim</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>常浩自用</string>
</dict>
</plist>
PLIST

# 第四批 ⑨：写进是哪个提交打的包、什么时候打的；工作区有没提交的改动时提交号后面加「-改动未提交」
# `diskslim doctor` 和提醒设置页底部会显示
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo 未知)
[ -z "$(git status --porcelain -- Sources Package.swift assets 2>/dev/null)" ] || COMMIT="$COMMIT-改动未提交"
plutil -insert DiskSlimCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -insert DiskSlimBuiltAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null
echo "已打包：$APP（提交 $COMMIT）"
