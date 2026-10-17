#!/usr/bin/env bash
# 构建 frpc 移动端桥接库（gomobile bind）。
#
# 前置要求：
#   go >= 1.24
#   gomobile:   go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
#   Android:    ANDROID_NDK_HOME 已设置（构建 .aar）
#   iOS:        Xcode 已安装（构建 .xcframework）
#
# 产物：
#   build/frpcbridge.aar              → 放入 android/app/libs/
#   build/FrpcBridge.xcframework      → 拖入 ios/Runner（Embed & Sign）
#
# 用法:
#   ./build.sh android
#   ./build.sh ios
#   ./build.sh all

set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-all}"
OUT=build
mkdir -p "$OUT"

if ! command -v gomobile >/dev/null; then
  echo "错误: 未安装 gomobile。执行:"
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest"
  echo "  gomobile init"
  exit 1
fi

case "$TARGET" in
  android)
    gomobile bind -target=android -androidapi 26 \
      -o "$OUT/frpcbridge.aar" .
    echo "完成: $OUT/frpcbridge.aar"
    ;;
  ios)
    gomobile bind -target=ios -iosversion 13.0 \
      -o "$OUT/FrpcBridge.xcframework" .
    echo "完成: $OUT/FrpcBridge.xcframework"
    ;;
  all)
    "$0" android
    "$0" ios
    ;;
  *)
    echo "用法: $0 [android|ios|all]"
    exit 1
    ;;
esac
