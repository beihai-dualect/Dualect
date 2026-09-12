# Dualect

Dualect AI 文献翻译器是一款面向 Windows 的 Flutter 桌面应用，将 PDF 阅读、MinerU 文档提取、Markdown 正文、DeepSeek 翻译和阅读笔记放在同一个工作区中。

## 功能

- 文献库分类、元数据、备注和阅读进度管理
- PDF 阅读、缩放及 PDF 与正文段落联动
- MinerU 提取结果展示与 DeepSeek 流式翻译
- Markdown/LaTeX 公式、表格、图片和笔记
- 本地英汉词典及期刊分区查询

## 构建

需要 Flutter stable、Visual Studio 的“使用 C++ 的桌面开发”工作负载，以及可在 `PATH` 中调用的 NuGet。

```powershell
flutter pub get
flutter build windows --release
```

应用运行时需要 Microsoft Edge WebView2 Runtime。翻译和文档提取分别需要用户自行配置 DeepSeek API Key 与 MinerU API Token；请求内容会发送到对应服务，请遵守其服务条款并妥善保管凭据。

## 致谢

感谢以下项目与数据资源：

- [MinerU](https://github.com/opendatalab/MinerU)：PDF 内容提取与结构化结果
- [DeepSeek API](https://api-docs.deepseek.com/zh-cn/)：文献翻译服务
- [ECDICT](https://github.com/skywind3000/ECDICT)：本地英汉词典数据
- [ShowJCR](https://github.com/hitfyd/ShowJCR)：期刊分区数据库及数据来源整理
- [pdfrx](https://github.com/espresso3389/pdfrx) 与 [PDFium](https://pdfium.googlesource.com/pdfium/)：PDF 渲染
- [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) 与 Microsoft WebView2：Markdown 阅读视图
- [KaTeX](https://github.com/KaTeX/KaTeX)：数学公式渲染
- [Flutter](https://github.com/flutter/flutter) 及其开源生态

期刊分区、影响因子及预警数据仅供参考，请以相关机构发布的最新信息为准。完整的第三方许可与修改说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可

Dualect 采用 [GNU General Public License v3.0](LICENSE) 开源。
