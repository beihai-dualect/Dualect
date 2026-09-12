# Third-Party Notices

Dualect 感谢并使用了以下开源项目、数据集和在线服务。各项目的名称、商标及内容权利归其各自所有者所有。

## 随项目分发

### ShowJCR

- 项目：https://github.com/hitfyd/ShowJCR
- 许可：GNU General Public License v3.0
- 用途：`jcr.db` 期刊、会议、分区、影响因子及预警信息数据库
- 说明：数据库还汇集或整理了新锐期刊分区表、中科院分区表升级版、JCR、国际期刊预警名单及 CCF 目录等公开数据。查询结果仅供参考，具体来源和口径请以 ShowJCR 的数据说明及原发布机构为准。

### ECDICT

- 项目：https://github.com/skywind3000/ECDICT
- 许可：MIT License
- 作者：Linwei 及 ECDICT contributors
- 用途：`ecdict_light.db` 本地英汉词典数据库

### pdfrx

- 项目：https://github.com/espresso3389/pdfrx
- 许可：MIT License
- Copyright (c) 2018 @espresso3389 (Takashi Kawasaki)
- 用途：PDF 阅读与渲染
- 修改：本仓库内置修改版本，差异见 `third_party/pdfrx/DUALECT_PATCHES.md`。

### flutter_inappwebview_windows

- 项目：https://github.com/pichillilorenzo/flutter_inappwebview
- 许可：Apache License 2.0
- Copyright 2023 Lorenzo Pichilli
- 用途：Windows Markdown 阅读视图
- 修改：本仓库内置修改版本，差异见 `third_party/flutter_inappwebview_windows/DUALECT_PATCHES.md`。

### KaTeX

- 项目：https://github.com/KaTeX/KaTeX
- 许可：MIT License
- Copyright (c) 2013-2020 Khan Academy and other contributors
- 用途：Markdown 中的 LaTeX 数学公式渲染
- 许可全文见 `assets/katex/LICENSE`。

### PDFium

- 项目：https://pdfium.googlesource.com/pdfium/
- 许可：BSD-style License
- 用途：由 pdfrx 相关依赖提供 PDF 渲染能力

Flutter 构建会在发布目录的 `data/flutter_assets/NOTICES.Z` 中包含 Dart/Flutter 依赖生成的许可声明。

## 在线服务

- [MinerU](https://github.com/opendatalab/MinerU)：Dualect 调用其开放 API 获取文档提取结果；MinerU 当前采用基于 Apache License 2.0 并附加条款的 MinerU Open Source License。
- [DeepSeek API](https://api-docs.deepseek.com/zh-cn/)：Dualect 调用其 API 完成流式翻译和模型列表查询。

在线服务不随本项目分发，使用时受各自最新服务条款、隐私政策和许可约束。
