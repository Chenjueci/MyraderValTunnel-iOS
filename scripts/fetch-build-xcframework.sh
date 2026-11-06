#!/bin/bash
# 在 macOS 上运行：拉取 hev-socks5-tunnel（MIT）源码并构建 XCFramework。
# 依赖：Xcode 命令行工具（xcode-select --install）、git。
#
# 用法：
#   bash scripts/fetch-build-xcframework.sh            # 全平台（本地 Mac 开发用）
#   IOS_ONLY=1 bash scripts/fetch-build-xcframework.sh # 仅 iphoneos/arm64（CI 出真机 IPA，快很多）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build"
SRC="$WORK/hev-socks5-tunnel"
XCFW="$ROOT/HevSocks5Tunnel.xcframework"
IOS_ONLY="${IOS_ONLY:-0}"

echo "==> 工作目录: $ROOT (IOS_ONLY=$IOS_ONLY)"

# 1. 递归克隆（含 lwip / yaml / hev-task-system 子模块）
if [ ! -d "$SRC" ]; then
  echo "==> 克隆 hev-socks5-tunnel (--recursive)"
  git clone --recursive --depth 1 https://github.com/heiher/hev-socks5-tunnel.git "$SRC"
else
  echo "==> 已存在源码，跳过克隆"
fi

cd "$SRC"

if [ "$IOS_ONLY" = "1" ]; then
  # 上游 build-apple.sh 会构建 9 个切片（含 tvOS / macOS / 模拟器），
  # 出真机 IPA 只需要 iphoneos/arm64，这里走等价的快速路径。
  echo "==> 仅构建 iphoneos/arm64（CI 快速路径）"
  make PP="xcrun --sdk iphoneos --toolchain iphoneos clang" \
       CC="xcrun --sdk iphoneos --toolchain iphoneos clang" \
       CFLAGS="-arch arm64 -mios-version-min=15.0" \
       LFLAGS="-arch arm64 -mios-version-min=15.0 -Wl,-Bsymbolic-functions" \
       static

  mkdir -p apple_xcframework/iphoneos-arm64 apple_xcframework/include/HevSocks5Tunnel
  libtool -static -o apple_xcframework/iphoneos-arm64/libhev-socks5-tunnel.a \
      bin/libhev-socks5-tunnel.a \
      third-part/lwip/bin/liblwip.a \
      third-part/yaml/bin/libyaml.a \
      third-part/hev-task-system/bin/libhev-task-system.a
  cp src/hev-main.h module.modulemap apple_xcframework/include/HevSocks5Tunnel/

  rm -rf HevSocks5Tunnel.xcframework
  xcodebuild -create-xcframework \
      -library apple_xcframework/iphoneos-arm64/libhev-socks5-tunnel.a \
      -headers apple_xcframework/include \
      -output HevSocks5Tunnel.xcframework
else
  echo "==> 构建全平台 XCFramework（上游 build-apple.sh）"
  bash build-apple.sh
fi

if [ ! -d "$SRC/HevSocks5Tunnel.xcframework" ]; then
  echo "错误：未生成 $SRC/HevSocks5Tunnel.xcframework" >&2
  exit 1
fi

rm -rf "$XCFW"
cp -R "$SRC/HevSocks5Tunnel.xcframework" "$XCFW"
echo "==> 已生成: $XCFW"
echo "    含 hev-main.h 与 module.modulemap，Swift 可直接 import HevSocks5Tunnel"
