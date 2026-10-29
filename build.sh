#!/bin/bash
#
# 构建 loopbackPost（macOS / CoreAudio Process Tap）
#
# 只需要 Command Line Tools 里的 clang++，不需要 Xcode。
# 用法：./build.sh [--debug]
#
# 关键：产物必须放在 .app bundle 里。
# 系统音频采集的 TCC 服务是 kTCCServiceAudioCapture，它要求程序的 Info.plist
# 里有 NSAudioCaptureUsageDescription。裸命令行二进制没有 Info.plist，
# 于是所有 CoreAudio 调用都返回 noErr、回调照跑，但每个 buffer 全是 0。
#
set -euo pipefail

cd "$(dirname "$0")"

APP="loopbackPost.app"
BIN="${APP}/Contents/MacOS/loopbackPost"
CXX="${CXX:-clang++}"
OPT="-O2 -DNDEBUG"

if [[ "${1:-}" == "--debug" ]]; then
    OPT="-O0 -g"
fi

echo "==> 生成 app bundle"
mkdir -p "${APP}/Contents/MacOS"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>loopbackPost</string>
    <key>CFBundleIdentifier</key>
    <string>com.loopbackpost.audiopusher</string>
    <key>CFBundleName</key>
    <string>loopbackPost</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDisplayName</key>
    <string>loopbackPost</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 这一条是系统音频采集授权弹窗里的说明文字，也是拿到权限的前提 -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>loopbackPost 需要录制系统正在播放的声音，才能把它实时推送到局域网音箱。</string>
</dict>
</plist>
PLIST

echo "==> 安装 app 图标"
RES="${APP}/Contents/Resources"
mkdir -p "${RES}"
if [[ -f AppIcon.icns ]]; then
    cp -f AppIcon.icns "${RES}/AppIcon.icns"
    echo "    ${RES}/AppIcon.icns"
else
    echo "    警告: 缺少 AppIcon.icns，app 会显示系统默认图标"
fi

echo "==> compiling ${BIN}"
$CXX -std=c++17 -fobjc-arc -pthread \
     -mmacosx-version-min=14.0 \
     -Wall -Wextra -Wno-unused-parameter \
     ${OPT} \
     -framework AppKit \
     -framework CoreAudio \
     -framework AudioToolbox \
     -framework CoreFoundation \
     -framework CoreGraphics \
     -framework Foundation \
     -o "${BIN}" \
     loopbackPost.mm

# 命令行入口：让 ./loopbackPost xxx 仍然可用，实际执行 bundle 里的二进制
cat > loopbackPost <<'SH'
#!/bin/bash
exec "$(cd "$(dirname "$0")" && pwd)/loopbackPost.app/Contents/MacOS/loopbackPost" "$@"
SH
chmod +x loopbackPost

echo "==> ad-hoc 签名（让系统隐私授权记住这个 app 的身份）"
codesign --force --sign - --timestamp=none "${APP}" 2>/dev/null \
    || echo "    (codesign 失败，可忽略)"

echo "==> 校验 Info.plist 里的授权说明"
plutil -extract NSAudioCaptureUsageDescription raw "${APP}/Contents/Info.plist" \
    || echo "    警告: 没读到 NSAudioCaptureUsageDescription"

echo "==> done: ./${APP}"
