# Dualect

Dualect AI 文献翻译器是一款面向 Windows 的 Flutter 桌面应用，将 PDF 阅读、MinerU 文档提取、Markdown 正文、DeepSeek 翻译和阅读笔记放在同一个工作区中。

## 功能

- 文献库分类、元数据、备注和阅读进度管理
- PDF 阅读、缩放及 PDF 与正文段落联动
- MinerU 提取结果展示与 DeepSeek 流式翻译
- Markdown/LaTeX 公式、表格、图片和笔记
- 本地英汉词典及期刊分区查询
## 使用教程
1.在mineru官网注册账号并登录，申请api key并将其复制到软件设置的对应位置：
<img width="917" height="496" alt="image" src="https://github.com/user-attachments/assets/10998d92-144d-4916-bebe-71a89638f59b" />
这里注意申请的API有效期为90天，到期后需要再次申请，同时每日的解析文件数也有限制。
<img width="721" height="848" alt="image" src="https://github.com/user-attachments/assets/93d42d44-b675-4aac-9f65-926de1ed4a0c" />
2.前往deepseek开放平台注册账号并登录，在API keys中创建，复制到本软件对应位置：
https://platform.deepseek.com/api_keys
<img width="903" height="411" alt="image" src="https://github.com/user-attachments/assets/ad8f3aa5-8b96-4423-b052-bd3257d43de6" />
这里需要**充值**几块钱，通常使用flash模型完整翻译一篇文章仅需几毛钱甚至更低。
<img width="704" height="819" alt="image" src="https://github.com/user-attachments/assets/c1f5160a-3ff8-4d3f-862a-23043f138706" />
将api key粘贴过来后刷新一下会看到可用模型，选择flash即可。
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
