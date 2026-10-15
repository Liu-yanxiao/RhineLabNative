#!/bin/zsh
# Package the already-built app without changing the verified executable.
set -euo pipefail
cd "$(dirname "$0")/.."
RHINE_DMG_OUTPUT=${1:-"$PWD/build/RhineMusic-0.4-preview-arm64.dmg"}
RHINE_DMG_APP="$PWD/build/RhineMusic.app"
[[ -d "$RHINE_DMG_APP" ]] || { print -u2 'Build the app with scripts/build-app.sh first.'; exit 1; }
[[ ! -e "$RHINE_DMG_OUTPUT" ]] || { print -u2 "Output already exists: $RHINE_DMG_OUTPUT"; exit 1; }
RHINE_DMG_STAGE=$(mktemp -d /tmp/rhine-dmg.XXXXXX)
trap 'rm -rf "$RHINE_DMG_STAGE"' EXIT
ditto --norsrc --noextattr "$RHINE_DMG_APP" "$RHINE_DMG_STAGE/RhineMusic.app"
codesign --verify --deep --strict "$RHINE_DMG_STAGE/RhineMusic.app"
ln -s /Applications "$RHINE_DMG_STAGE/Applications"
mkdir -p "$RHINE_DMG_STAGE/Licenses"
cp LICENSE-RhineLabUI Resources/Fonts/NOTICE.txt Resources/Fonts/MiSans-license.pdf "$RHINE_DMG_STAGE/Licenses/"
cat > "$RHINE_DMG_STAGE/安装与试用说明.txt" <<'TXT'
RHINE MUSIC 0.4 · 朋友试用版

适用：Apple Silicon Mac（M 系列芯片），macOS 14 或更新版本。

安装：
1. 打开 DMG。
2. 将 RhineMusic.app 拖入 Applications 文件夹。
3. 从“应用程序”打开 RhineMusic。

本试用版尚未使用 Apple Developer ID 签名和公证。
若首次打开时 macOS 提示开发者无法验证，可参考 Apple 官方说明：
https://support.apple.com/zh-cn/guide/mac-help/mh40616/mac

使用：
启动动画可按 Enter / Esc 跳过。
主界面触控板 ↙↗ 切换歌单列，↖↘ 浏览同列歌曲。
Enter 打开播放页，Esc 返回，空格播放或暂停。
播放页方向键切换上一首 / 下一首，拖动封面可轻微转动。
内置明日方舟、流行精选、钢琴与片刻；也可搜索歌曲试听。
在线搜索、封面和播放需要联网，第三方音源可能暂时不可用。

此包包含最新搜索后封面频闪修复。
歌单与收藏保存在试用者自己的 Mac，本安装包不包含开发机的个人歌单、收藏或设置。

遇到问题请记录 Mac 芯片、macOS 版本、操作步骤和截图/录屏。
界面与模型致谢及字体许可见 Licenses 文件夹。
TXT
hdiutil create -volname 'Rhine Music' -srcfolder "$RHINE_DMG_STAGE" -format UDZO -fs HFS+ -imagekey zlib-level=9 "$RHINE_DMG_OUTPUT"
hdiutil verify "$RHINE_DMG_OUTPUT"
print "Built $RHINE_DMG_OUTPUT"
