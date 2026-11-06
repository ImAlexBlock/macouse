#!/bin/bash
# 构建 Macouse.app：release 构建 → 组装 bundle → ad-hoc 签名。
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Macouse.app"
CONTENTS="$APP/Contents"

swift build -c release --product Macouse
BIN_PATH=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/Macouse" "$CONTENTS/MacOS/Macouse"
cp Resources/Info.plist "$CONTENTS/Info.plist"

codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"

echo "$(pwd)/$APP"
