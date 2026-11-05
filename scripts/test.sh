#!/bin/zsh
# 跑 Swift 单元测试。只有命令行工具、没有完整 Xcode 时，SwiftPM 不会把 Swift Testing 的宏插件路径传给编译器，
# 偶发「plugin for module 'TestingMacros' not found」（docs/LESSONS.md L-04），这里显式补上。
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$PLUGINS" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  exec swift test "$@"
fi
