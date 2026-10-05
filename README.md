# RHINE LAB · ANALYSIS OS（macOS 原生版）

[RhineLabUI](https://github.com/LBEILC/RhineLabUI) 的 Swift / Metal 移植：把《明日方舟》特别映像「莱茵生命：访问」的终端界面做成可以操作的三维应用。SwiftUI 负责界面层，自研 Metal 延迟透射渲染器负责玻璃档案阵列。

## 运行

需要 macOS 14 与 Xcode 16（Swift 6 工具链）。

```sh
swift run -c release          # 直接运行
scripts/build-app.sh          # 打包 build/RhineLab.app
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
