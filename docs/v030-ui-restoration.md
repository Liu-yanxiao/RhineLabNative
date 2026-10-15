> 历史原型记录：当前入口已改为原生 SwiftUI + Metal + AVPlayer，现状见 [native-music-verification.md](native-music-verification.md)。

# V0.3.0 界面恢复及在线播放验证

日期：2026-10-14。

上一版擅自以 SwiftUI 重排音乐界面，加入大播放栏、自绘封套和另一套开场。用户要求参考 V0.3.0 的现有交互，本次撤下该默认入口，音乐界面直接使用 V0.3.0 的原实现。

## 保留的代码

以下文件与旁边 V0.3.0 的源文件逐字节一致：music.css、music-navigation-ruler.css、music-theme-switch.css、music-transport-title.css、music-title-reels.ts、music-presentation.ts、music-camera.ts、music-model.ts、scene.ts、music-boot.ts。

因此保留原布局、顶部播放/停止、底部滑尺、字轮、昼夜滑块、CD 盒模型、封面比例、阵列取景、进场、详情页签和连续换片。WebPlayer/LICENSE、NOTICE.md 及 public/licenses 保留原署名与许可；原 V0.3.0 项目未修改。

## 接入方式

macOS 窗口通过 WebKit 承载原界面，应用内置 Node.js 24 运行时和只监听 127.0.0.1 的音乐服务，不要求用户安装运行时。默认端口 57563，冲突时使用空闲端口。退出应用时停止内置服务。

新增服务适配原界面的 /api/library、/api/audio、/api/artwork 和配置接口。频道歌单使用在线元数据，音频地址即时解析，HTTPS 和过期地址检查沿用前一轮验证成果；支持 Range，解析失败尝试备用音源。音乐库面板的目录导入改为在线搜索/加入自建歌单，设置面板增加音源及随机选择，其余界面结构沿用原版。

原生试听版的已保存曲目会读取迁移到独立的 online-player 数据目录，不改写旧 MusicLibrary.json。自动更新不再执行原本扫描完成后的页面重载，避免打断播放。

## 实际检查

- TypeScript 检查与 Vite 构建成功，Swift release 构建成功。
- 复制的原播放状态测试 4 项通过；原展示/换片测试 21 项通过，包括详情换片不返回阵列、搜索先返回阵列再打开、快速输入保留最新目标和旧回调取消。
- 在线服务请求音频片段，返回 HTTP 206、65,536 字节、ID3 文件头。
- 原界面实际点歌后，DOM 播放状态为 playing，播放时间推进至 56 秒；点击暂停后状态 paused，时间保持 56 秒。
- 详情内点下一张后，标题切到“国风混音”，data-mode 仍为 detail，播放状态仍为 paused。
- 最终 macOS 应用打开原界面，实际点歌后顶部控件显示“暂停”且 pressed/on；点击后恢复“播放”。截图见 v030-native-detail.png。
- 退出应用后，127.0.0.1:57563 不再接受连接，内置服务生命周期正常。

这里验证的是本次歌曲及交互链路。部分频道更新曾超时，已有歌单仍保留；没有承诺所有歌曲、所有平台或服务长期稳定。该情况以简短中文提示展示，不影响已有曲目的播放。

交付：`/Users/lyx/Applications/RhineMusicV030.app`。旧的自绘 UI 试听副本不会覆盖此版本；以此路径为当前音乐入口。
