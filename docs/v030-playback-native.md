# RhineMusicV030 播放界面与原生场景联动

2026-10-14。按用户指定的 `/Users/lyx/Applications/RhineMusicV030.app` 实际界面、打开与详情换片过程，对照 WebPlayer 的详情取景和文字过渡。

## 本次修改

- 顶部品牌、副标题、昼夜滑块和轻量播放控件按参考版重新整理；主页阅读区右移，详情恢复两列真实资料、信息页签与曲目队列。
- 搜索试听接入 MusicPresentation：临时队列进入三维目录，自动选中当前歌曲；上一首、下一首与点击顶部歌名都能定位对应卡片。没有自动保存试听队列或增加预设歌单。
- 主场景和详情使用真实歌曲封面，邻近封面预取；缓存与请求限制保持，取消的旧请求不会覆盖新请求。封面始终保持原始比例。
- 主场景选中卡片更明显地抬起；播放时阵列轻微起伏，详情封面保持轻微呼吸，暂停后收敛停止。动画来自播放状态，不宣称是实际音频频谱。
- 详情保留阵列背景、参考版的斜视角度与页签层次；切歌时封面落下／抬起、文字过渡，保留用户的自由视角。主界面和详情的手势入口仍是原生 Metal。

## 验证

`swift test`：9 项通过。新增的两个检查覆盖搜索播放驱动场景、下一首／定位回到当前曲目、临时歌曲不写入歌单，以及暂停停止动画、换片不重置自由视角。

`build/RhineMusic.app/Contents/MacOS/RhineLab --music-scene-check /tmp/rhine-playing-scene-check` 完整流程通过：实际在线音频推进至少 1 秒，封面下载并解码，主场景选中歌曲，打开原生自由详情，下一首更换歌曲与封面，暂停使画面停止持续动画，返回阵列。此流程使用空的临时曲库，音量为零，不改动用户曲库和偏好。

配图由实际 AppModel、Metal 渲染器和隐藏的原生 SwiftUI 宿主渲染，1920 × 1080；没有通过图片编辑拼造界面内容。使用 NSHostingView 捕捉原生滚动区，避免 ImageRenderer 漏画队列。

- [播放中的主页](v030-playback-native/playing-main.png)
- [播放详情](v030-playback-native/playing-detail.png)
- [下一首](v030-playback-native/next-detail.png)
- [暂停](v030-playback-native/paused-detail.png)
- [返回主页](v030-playback-native/returned-main.png)

源解析和播放仍由 MusicService / AVPlayer 完成，默认包不含 WebKit 或 Node。画质像素上限和封面缩略／缓存上限保留。物理触控板多指手势仍需用户在设备上体验。
