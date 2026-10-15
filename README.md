# RHINE MUSIC · 原生音乐播放器

SwiftUI + Metal + AVPlayer。音乐库每列对应一张歌单，列内循环浏览歌曲和封面；方向键左右切列、上下浏览。触控板 ↙↗ 换列、↖↘ 浏览同列歌曲。打开歌单后四个方向键分别控制上一首／下一首，保持当前歌单，封面收回与抽取、文字切换连续完成。暂停时换歌保持暂停。

主页支持按住鼠标连续拖动阵列，位移按当前镜头投影映射，松手后平滑停靠；详情封面在拖动期间快速跟手，松开后缓慢回正。浅色主页采用较轻的边缘淡化，保留底部与右侧唱片的可见层次。

启动已恢复完整权限、标志、圆环扫描和欢迎动画，支持浅色与深色；Enter／Esc 可跳过，设置可重播。播放页与音乐库、搜索、收藏、设置共用细线与章节标注风格，点击、按压、标签切换和搜索均有短促反馈。详见 [本轮验证](docs/terminal-restoration.md)。


播放页面和深色主题参考 RhineMusicV030，使用它的 CD 盒模型；封面拖动范围略大，双击／Home 复位，捏合只作轻微缩放。打开与返回始终使用同一三维场景，避免中途切换镜头。

内置示例：明日方舟（8 首）、流行精选（6 首）、钢琴与片刻（6 首）。明日方舟来自官方塞壬唱片的公开曲目和流媒体接口；另外两份使用网易云曲目元数据及已接入音源。启动不搜索歌曲；收藏、个人歌单数据保留，第三方服务可用性取决于服务状态。

默认清晰画质在 1440×810 点窗口绘制 2880×1620 像素，4× MSAA；主页面不使用景深模糊。画面移动时保持相同尺寸，打开歌单时不创建第二套查看场景。普通封面为 512 像素缩略，打开的封面按最大 1536 像素解码；高分辨率缓存仅保留最近两张。

封面下载最多同时三张，临时网络错误自动重试；坏图片不会堵住后面的请求。当前可见及选中的封面受到缓存保护，离开画面后收回至 24 张预算；纹理更新完成前保留旧封面，避免升级清晰度时短暂空白。

数据：`~/Library/Application Support/RhineLab/MusicLibrary-v4.json`。搜索结果作为临时歌单展示，不自动保存。构建使用 `scripts/build-app.sh`；默认包不含 WebKit、Node 或历史分类种子。原档案体验保留 `--archive`。

验证：`swift test`、`--render-check`、`--playlist-check 输出目录`、`--bench 2880x1620`。最新实现与验证见 [playlist-library-verification.md](docs/playlist-library-verification.md)，音源研究见 [audio-source-research.md](docs/audio-source-research.md)。

## 原档案体验

[RhineLabUI](https://github.com/LBEILC/RhineLabUI) 的 Swift / Metal 移植：把《明日方舟》特别映像「莱茵生命：访问」的终端界面做成可以操作的三维应用。SwiftUI 负责界面层，自研 Metal 延迟透射渲染器负责玻璃档案阵列。

## 运行

需要 macOS 14 与 Xcode 16（Swift 6 工具链）。

```sh
swift run -c release          # 直接运行
scripts/build-app.sh          # 打包 build/RhineMusic.app
```

## 功能

- 开场：按原片 25 fps 逐帧复刻（输入、标志描边、身份验证、权限扫描、欢迎页、白场），原片按键音与原创「观测室」三轨配乐。
- 档案阵列：五列循环档案，键盘 / 滚轮 / 点击切换，悬停抬起，抽取后对角线解密与正文揭示。
- 360° 查看器：拖动旋转、平移、缩放、复位，清晰 / 磨砂玻璃，六组部件拆解与重组。
- 检索、收藏、导出，亮 / 暗配色（玻璃阵列逐张过渡），音效与音乐设置，四档画质预设与九项精细参数，超级性能模式。

按键：`← →` 切列，`↑ ↓` 选档，`Enter` 读取，`/` 检索，`Esc` 返回；查看器中 `Home` 复位、`+ −` 缩放、方向键平移。

## 截图与验证

`RhineLab --shot out.png --ui <archive|detail|viewer|viewer-exploded|search|saved|settings|boot> [--dark] [--time T]` 离屏渲染场景并合成界面层。GitHub Actions 在 macOS runner 上构建、打包并把一组截图推到 `ci/shots` 分支。

## 致谢

界面、模型、动效与配乐设计来自 [LBEILC/RhineLabUI](https://github.com/LBEILC/RhineLabUI)（MIT，见 `LICENSE-RhineLabUI`）。字体 MiSans（小米），许可见 `Resources/Fonts`。开场按键短音取自原片，权利归原作者。
