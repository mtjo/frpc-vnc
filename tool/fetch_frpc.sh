#!/usr/bin/env bash
# 下载 frp 官方二进制到 assets/frpc/bin/（桌面端随应用分发用）。
# 用法: ./tool/fetch_frpc.sh [版本号，默认 v0.61.1]

set -euo pipefail

VERSION="${1:-v0.61.1}"
VER="${VERSION#v}"
BASE="https://github.com/fatedier/frp/releases/download/${VERSION}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/assets/frpc/bin"
mkdir -p "$OUT_DIR"

fetch() {
  local asset="$1" out="$2" kind="$3"
  if [ -s "$OUT_DIR/$out" ]; then
    echo "已存在: $out"
    return
  fi
  echo "下载 $asset ..."
  local tmp
  tmp=$(mktemp -d)
  curl -fL --retry 3 --max-time 600 -o "$tmp/dl" "$BASE/$asset"
  case "$kind" in
    tgz) tar -xzf "$tmp/dl" -C "$tmp" ;;
    zip) unzip -o -q "$tmp/dl" -d "$tmp" ;;
  esac
  find "$tmp" \( -name 'frpc' -o -name 'frpc.exe' \) -type f -exec mv {} "$OUT_DIR/$out" \;
  rm -rf "$tmp"
  echo "完成: $out"
}

fetch "frp_${VER}_darwin_arm64.tar.gz"  "frpc-macos-arm64" tgz
fetch "frp_${VER}_darwin_amd64.tar.gz"  "frpc-macos-amd64" tgz
fetch "frp_${VER}_windows_amd64.zip"    "frpc-windows-amd64.exe" zip
fetch "frp_${VER}_linux_amd64.tar.gz"   "frpc-linux-amd64" tgz

chmod +x "$OUT_DIR"/frpc-* 2>/dev/null || true
ls -la "$OUT_DIR"
echo "全部完成"
