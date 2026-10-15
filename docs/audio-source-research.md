# 星海 / HYW 音源研究

核查日期：2026-10-13（Asia/Shanghai）。目的：评估 RhineLabNative 能否实现“选择古风 DJ、开车小曲、热血、流行等频道，随机听，不喜欢就换”。本轮没有修改播放器。

## 结论

两个 LX 插件主要都是播放地址解析器，但它们运营方的网页服务另有搜索和歌单接口。不能把“插件没有搜索动作”扩大成“整个服务没有搜索能力”。目前星海的匿名搜索、推荐歌单、歌单曲目三段元数据流程均取得成功响应；HYW 的匿名歌曲和歌单搜索取得成功响应，歌单曲目接口要求登录。完整音频播放、授权范围、长期可靠性尚未验证。

从当前证据看，星海更适合继续做无需平台账号的频道原型研究；HYW 的歌单搜索与用户的氛围关键词更贴近，但登录环节需要进一步核实。这是工程可行性判断，不是内容授权结论。

## 原始入口和脚本获取

- [玉宁熙原入口](http://ynx.de5.net/API/lx-ynx.php?APIKEY=CERU) 当前 HTTP 响应只有 409 字节停用说明，含两个替代音源链接。重复请求结果相同；HTTPS 路径返回 400 `host not found`。该结论仅针对本次请求结果。
- [星海推荐脚本](https://zrcdy.dpdns.org/lx/xinghai-music-sourcev2.3.15.js) 取得 38,858 字节 JS。文件名带 v2.3.15，但头部及 `SCRIPT_VERSION` 为 v3.2.15，头部日期 2026-10-02；不能只用文件名识别版本。SHA-256：`807d6157e4fd7cdd05b8727efd73778b54a3b05a0b5e4c6bb28dedc0668e94e9`。
- [HYW 原推荐入口](https://103.79.184.97/api/releases?script=HYWmusic_%E5%85%AC%E7%9B%8A%E7%89%88&scriptType=free&releaseType=lx&version=v1.2.0) 是更新检查，传当前版本返回 `code:0`、“已是最新版本”。[去掉 version 的发行接口](https://103.79.184.97/api/releases?script=HYWmusic_%E5%85%AC%E7%9B%8A%E7%89%88&scriptType=free&releaseType=lx) 返回下载地址。取得 HYWmusic_公益版 v1.2.0、12,211 字节 JS，生成时间 2026-10-08。SHA-256：`9f1cb9791c9abda54b34f5c5b945fa7e0b992702523694f66d6128a655492f86`。

本轮只阅读脚本，没有执行下载的 JS。脚本和临时响应置于 /tmp，不把其中的卡密值或上游代码复制进项目。

## 插件层比较

| 项目 | 星海推荐脚本 | HYW 公益版 v1.2.0 |
| --- | --- | --- |
| 宿主依赖 | `globalThis.lx` 的事件、HTTP 请求和 buffer 工具 | `globalThis.lx` 的事件、HTTP 请求与环境信息 |
| 声明平台 | 网易云、QQ、酷我、酷狗、咪咕、汽水 | 上述平台另加 B 站、YouTube、喜马拉雅 |
| 核心输入 | 平台、歌曲 ID/信息、音质 | 平台、歌曲信息、音质 |
| 核心输出 | HTTP(S) 音频地址 | 后端返回的音频地址 |
| 搜索/歌单动作 | 没有 | 没有 |
| 歌词/封面 | 声明 lyric/pic，但主要读取解析时的附加缓存 | 有处理函数，但非 local 平台初始化声明仅 musicUrl |
| 服务依赖 | 自建聚合后端、GD API、可选 ChKSz，酷我另有直连路径 | 统一后端 /api/music/url；脚本含发行时注入的卡密 |

来源：[星海实际脚本](https://zrcdy.dpdns.org/lx/xinghai-music-sourcev2.3.15.js)、[星海作者仓库](https://github.com/cdyUuu/lx-music-xinghai-source)、[HYW 发行接口](https://103.79.184.97/api/releases?script=HYWmusic_%E5%85%AC%E7%9B%8A%E7%89%88&scriptType=free&releaseType=lx)、[HYW 作者仓库](https://github.com/Macrohard0001/HYWmusic_source)。平台列表是代码声明，不代表本轮逐个平台播放验证。

星海的网易云路径依次尝试可选 ChKSz、自建聚合、GD；ChKSz 默认 key 为空。自建聚合遇到 403 会在当前脚本运行期标记阻断。酷我的加密格式默认未开放，需要额外服务；本轮没有启用或测试解密。星海有部分降级路径，因此请求的音质标签不能证明返回音频的实际音质。来源同上实际脚本。

[LX 官方接口规范](https://lxmusic.toside.cn/desktop/custom-source) 只列 kw/kg/tx/wy/mg/local，非 local 源动作固定 musicUrl、音质标准集为 128k/320k/flac/flac24bit。两个脚本的额外平台，以及星海额外动作/音质标识，需要核实目标 LX 版本的接受情况。它们也不能直接当成独立 Swift API 使用。

## 网页服务层：这是频道功能的重要发现

### 星海

[运营方网页播放器](https://yy.zddyr.top/web/) 的 [搜索模块](https://yy.zddyr.top/web/js/api/search.js?v=6.34) 实际调用 `GET /web/api/search.php`，传 source、keyword、page、count；返回歌曲 ID、标题、歌手、专辑、时长和封面等统一字段。注释中的简写 `/api/search` 与实际代码路径不同，本文以实际代码为准。

[歌单模块](https://yy.zddyr.top/web/js/api/playlist.js?v=6.34) 调用 `POST /web/api/playlist.php`，JSON action 为 hot/detail/daily/my。分别表示推荐歌单、歌单详情、每日推荐、个人歌单。当前模块没有提供按“古风 DJ”关键词搜索歌单的方法，也没有证明热门歌单接口支持氛围分类参数。

无需账号的有限只读元数据检查：

| 请求 | 本次结果 |
| --- | --- |
| source=wy，keyword=古风DJ，page=1，count=3 | JSON code=200，3 条歌曲，含 ID、标题、歌手、封面与时长 |
| action=hot，source=wy，page=1，limit=3，cookie为空 | JSON code=200，3 张推荐歌单 |
| action=detail，source=wy，id=6671216522，page=1，limit=3，cookie为空 | JSON code=200，total=197，返回 3 条曲目 |
| 主/备用版本查询，ver=v3.2.15 | 两者均返回“你已是最新版本” |

注意 Cookie 数据流：[歌单模块](https://yy.zddyr.top/web/js/api/playlist.js?v=6.34) 的注释称 Cookie 只在本机，但 `post(payload)` 实际把保存的 Cookie 放进 JSON 请求体发送到运营方服务器。不能把此功能描述为凭据完全不离开本机。本轮所有请求均不含用户 Cookie，未测试 daily/my。

### HYW

[运营方音乐搜索页](https://103.79.184.97/music-search) 提供歌曲、歌单、歌手搜索。前端调用 `GET /api/music/search`，歌曲请求带 keyword、platform、mode=lx；歌单请求带 type=playlist。歌单曲目入口是 `/api/music/playlist/parse`，按 platform/pid 或 input 获取。

有限只读元数据检查：

| 请求 | 本次结果 |
| --- | --- |
| keyword=古风DJ，platform=wy，mode=lx，limit=3 | HTTP 200，code=200，3 条歌曲元数据 |
| keyword=开车小曲，platform=wy，type=playlist，limit=3 | HTTP 200，code=200，3 张歌单；其中“开车の小曲”显示 83 首 |
| platform=wy，pid=10173700431 的歌单解析 | HTTP 401，code=401，提示未登录或会话已过期 |

搜索成功不等于歌单曲目可匿名读取，更不等于歌曲完整可播。脚本中 `/api/music/info` 的处理也不代表该功能通过宿主初始化声明对外开放。来源：[搜索页](https://103.79.184.97/music-search)、[发行脚本](https://103.79.184.97/api/releases?script=HYWmusic_%E5%85%AC%E7%9B%8A%E7%89%88&scriptType=free&releaseType=lx)。

## 对 RhineLabNative 的适配判断

频道播放至少包含四层：

1. 频道内容：为古风 DJ、开车、热血、流行选择歌单或候选作品。
2. 曲目队列：读取歌单、去重、随机排序，记录跳过和喜欢。
3. 音源适配：以平台歌曲 ID 获取可播放地址，处理失效、限流、离线和取消。
4. 原生播放与界面：显示当前作品，暂停/继续/下一首，保持档案浏览与播放状态独立。

这些来源主要覆盖第 3 层，网页服务额外覆盖第 1/2 层的一部分。关键词搜索结果不等于个性化推荐；第一版可以用人工选择的频道歌单，不必先训练推荐算法。

工程上可通过 URLSession 适配经过验证的 JSON 接口，避免把远程 JS 直接执行在应用中；另一种方式是建立受限 LX 脚本宿主，但复杂度更高。上述是设计推断，尚未实现。必须保持平台和歌曲 ID 配对，不能只凭标题跨源换歌；播放地址不能视为长期稳定地址。实现前仍需验证完整音频、地址有效期、错误行为、Range/跳转及 macOS 解码能力。

## 许可及证据边界

- [星海作者说明](https://github.com/cdyUuu/lx-music-xinghai-source) 限个人学习交流，禁止商业用途；本轮未见明确许可支持将整段代码并入现有 MIT 原生项目。
- HYW 脚本头部标 MIT；[运营方 about 页](https://103.79.184.97/about) 有学习交流、禁止商业/大规模分发的说明。脚本代码许可与远端服务使用条件要分别看。
- 本轮未取得音乐作品版权方对这些服务的授权材料。接口能返回元数据或音频 URL，不构成授权证明。也不能反过来只凭未取得证明就认定每首内容未经授权。

没有下载/播放完整歌曲，没有运行远程 JS，没有使用真实用户账号、Cookie、付费密钥，没有测试加密音频处理或规避访问限制。验证的是本次脚本内容、网页前端及少量元数据响应，不是长期稳定性、全平台兼容性或内容授权保证。

上述为第一轮静态与元数据研究的范围。用户随后明确要求实际验证音源，补充结果如下；项目播放器功能仍未改动。

## 第二轮：播放地址、音频片段和 macOS 解码实测

日期仍为 2026-10-13。用户明确指出可以自行维护歌单并随机播放，本轮不再把平台推荐或歌单读取作为播放可用性的前提。

使用此前网易云搜索返回的三首样本，逐首请求 128k：

| 样本 | 星海地址解析 | HYW 地址解析 | 两者音频 Range | 两者原生识别与解码 |
| --- | --- | --- | --- | --- |
| 八千里路明月照（挥笔生花问桀骜） | HTTP 200 / code 200 | HTTP 200 / code 200 | HTTP 206，65,536 字节 | isPlayable=true，1 音轨，199.44 秒；片段解码 1,024 PCM 帧 |
| 琵琶曲 (DJ筱轩版) | HTTP 200 / code 200 | HTTP 200 / code 200 | HTTP 206，65,536 字节 | isPlayable=true，1 音轨，173.69 秒；片段解码 1,024 PCM 帧 |
| 牵丝戏 (DJ版) | HTTP 200 / code 200 | HTTP 200 / code 200 | HTTP 206，65,536 字节 | isPlayable=true，1 音轨，164.26 秒；片段解码 1,024 PCM 帧 |

测试按现有脚本正常路径请求：星海使用自建聚合接口和脚本规定的客户端字段，三个样本均由主后端成功返回，未触发 GD 或 ChKSz 备用路径；HYW 使用发行脚本默认公益配置，未使用用户账号或私人密钥，没有绕过鉴权失败、付费限制或加密处理。没有执行远程 JS，检查程序仅发送对应 HTTP 请求。

从解析结果读取临时地址后，请求 bytes=0-65535；两者六个样本均返回 206 和正确 Content-Range。文件头均为 ID3，AVAudioFile 读取片段成功，故不只是取得一个看似正确的 URL。星海服务器部分返回 application/octet-stream、部分 audio/mpeg；HYW 样本返回 audio/mpeg。因此播放器不应仅凭 Content-Type 字符串判定能否播放。

AVURLAsset 加载远端媒体，确认 isPlayable、音轨与时长；AVAudioFile 对已取得的有限片段解码为 PCM。未向扬声器播放声音、未主动下载完整歌曲，未验证整首连续播放或实际下一首操作。请求 128k 不代表已经严格验证文件实际码率；HYW 响应的 qualityVerified 为 false。

本轮可以确定：**两个音源在当前网络环境下，对这三首网易云 128k 样本的解析、片段读取和 macOS 原生媒体识别/解码均成功。** 不能据此保证其他平台、其他音质、所有歌曲、地址长期有效或服务长期稳定；内容授权结论未变化。

临时证据：星海 /tmp/rhine-xinghai-live/summary.json、各 audio-*.headers/body、/tmp/rhine-xinghai-native.swift；HYW /tmp/hyw-playback-probe-{1,2,3}.json、/tmp/hyw-audio-probe-{1,2,3}.bin、/tmp/hyw-native-probe.swift、/tmp/rhine-hyw-decode.swift。解析响应包含时效签名地址，仅置于临时目录，不复制到仓库或报告。

对产品的更新判断：可先自己维护频道歌单，保存平台和歌曲 ID，随机/跳过/喜欢由应用管理，播放时即时解析地址。这样无需先接平台的个性化推荐，也无需用户导入音频。整首播放、快进、连续切歌、超时和失效处理仍需在原生播放器实现时验证。
