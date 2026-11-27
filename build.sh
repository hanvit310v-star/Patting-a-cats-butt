#!/bin/bash
# 고양이 궁디팡팡 앱을 만듭니다. 결과: build/고양이 궁디팡팡.app
set -e
cd "$(dirname "$0")"
APP="build/고양이 궁디팡팡.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library Sources/main.swift -o "$APP/Contents/MacOS/CatPang"
cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "완료: $APP"
