import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_markdown_reader/main.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  const missingPdfPath = 'missing-test-document.pdf';

  testWidgets('shows a clear message when the PDF is missing', (tester) async {
    await tester.pumpWidget(const PdfReaderApp(pdfPath: missingPdfPath));

    expect(find.text('PDF file not found'), findsOneWidget);
    expect(find.text(missingPdfPath), findsWidgets);
    expect(find.byIcon(Icons.translate_outlined), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
  });

  test('reconstructs translation markdown from MinerU content items', () async {
    final title = MineruContentItem.fromJson(
      {
        'type': 'title',
        'content': {
          'title_content': [
            {'type': 'text', 'content': 'Demo Title'},
          ],
          'level': 2,
        },
      },
      rawIndex: 0,
      contentIndex: 0,
    );
    final paragraph = MineruContentItem.fromJson(
      {
        'type': 'paragraph',
        'content': {
          'paragraph_content': [
            {'type': 'text', 'content': 'Use'},
            {'type': 'equation_inline', 'content': r'a_i'},
            {'type': 'text', 'content': 'for training.'},
          ],
        },
      },
      rawIndex: 1,
      contentIndex: 1,
    );
    final image = MineruContentItem.fromJson(
      {
        'type': 'image',
        'content': {
          'image_source': {'path': 'images/demo.jpg'},
        },
      },
      rawIndex: 2,
      contentIndex: 2,
    );

    expect(title.translationMarkdown, '## Demo Title');
    expect(paragraph.translationMarkdown, contains(r'$a_i$'));
    expect(image.translationMarkdown, isNull);
  });

  test('saves and removes translation cache entries', () async {
    final dir = await Directory.systemTemp.createTemp('translation_cache_');
    try {
      await MineruPaper.saveTranslation(dir.path, 3, r'译文 $a_i$');
      var translations = await MineruPaper.loadTranslations(dir.path);
      expect(translations['3'], r'译文 $a_i$');

      await MineruPaper.removeTranslation(dir.path, 3);
      translations = await MineruPaper.loadTranslations(dir.path);
      expect(translations.containsKey('3'), isFalse);
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('parses streamed batch translation marker results', () {
    final parsed = parseBatchTranslationResults(
      '[PARA 0]\n\u7b2c\u4e00\u6bb5 \$a_i\$\n[PARA 1]\n\u7b2c\u4e8c\u6bb5\n\n[PARA 2]\n\u7b2c\u4e09\u6bb5',
      3,
    );

    expect(parsed[0], r'第一段 $a_i$');
    expect(parsed[1], '第二段');
    expect(parsed[2], '第三段');
  });

  test('parses official DeepSeek model list without duplicates', () {
    final models = parseDeepSeekModelIds({
      'object': 'list',
      'data': [
        {'id': 'deepseek-v4-flash', 'object': 'model', 'owned_by': 'deepseek'},
        {'id': 'deepseek-v4-pro', 'object': 'model', 'owned_by': 'deepseek'},
        {'id': 'deepseek-v4-flash'},
        {'id': '  '},
      ],
    });

    expect(models, ['deepseek-v4-flash', 'deepseek-v4-pro']);
  });

  test('rejects malformed DeepSeek model list payloads', () {
    expect(parseDeepSeekModelIds(null), isEmpty);
    expect(parseDeepSeekModelIds({'data': 'not-a-list'}), isEmpty);
    expect(
      parseDeepSeekModelIds({
        'data': [null, 'deepseek-v4-flash', {}],
      }),
      isEmpty,
    );
  });

  test('keeps document math rendering lazy', () async {
    final source = await File('lib/main.dart').readAsString();

    expect(source, contains('new IntersectionObserver'));
    expect(source, contains('blocks.forEach(queueMathRendering)'));
    expect(source, contains('queueMathRendering(translation)'));
    expect(source, isNot(contains('renderMath(document.body)')));
  });

  test('provides distinct persisted reader font presets', () {
    expect(ReaderFontPreset.values, hasLength(3));
    expect(ReaderFontPreset.comfortable.label, '舒适阅读');
    expect(ReaderFontPreset.academic.label, '论文排版');
    expect(ReaderFontPreset.book.label, '书籍阅读');
    expect(
      ReaderFontPreset.academic.bodyCssFamily,
      startsWith('"Times New Roman", SimSun'),
    );
    expect(
      ReaderFontPreset.book.bodyCssFamily,
      contains('Source Han Serif SC'),
    );
  });

  test(
    'switches document typography without overriding math or code fonts',
    () async {
      final source = await File('lib/main.dart').readAsString();

      expect(source, contains('window.setReaderTypography'));
      expect(source, contains("--reader-body-font"));
      expect(source, contains('font-family: KaTeX_Main'));
      expect(source, contains('font-family: Consolas, "Cascadia Mono"'));
    },
  );

  test('keeps Markdown WebView surfaces aligned to physical pixels', () async {
    final source = await File('lib/main.dart').readAsString();
    final pluginSource = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'custom_platform_view/custom_platform_view.cc',
    ).readAsString();
    final nativeViewSource = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'in_app_webview/in_app_webview.cpp',
    ).readAsString();

    expect(source, contains('_snapToPhysicalPixel'));
    expect(source, contains('transparentBackground: false'));
    expect(pluginSource, contains('view->setSurfaceSize(width, height'));
    expect(pluginSource, isNot(contains('static_cast<size_t>(width)')));
    expect(nativeViewSource, contains('std::lround(width * scale_factor)'));
    expect(nativeViewSource, contains('std::lround(x * scale_factor)'));
  });

  test('preserves precision touchpad scrolling in Markdown', () async {
    final appSource = await File('lib/main.dart').readAsString();
    final nativeViewSource = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'in_app_webview/in_app_webview.cpp',
    ).readAsString();
    final nativeViewHeader = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'in_app_webview/in_app_webview.h',
    ).readAsString();

    expect(appSource, contains("addEventListener('wheel'"));
    expect(appSource, contains("tooltip: '关闭'"));
    expect(appSource, isNot(contains('鍏抽棴')));
    expect(appSource, contains('window.dualectPanScroll = function'));
    expect(appSource, contains('queueDocumentScroll(-(Number(x) || 0)'));
    expect(appSource, contains('pendingScrollY += y * speed'));
    expect(appSource, contains('requestAnimationFrame(flushDocumentScroll)'));
    expect(appSource, contains('isPrecisionGesture ? 3.0 : 0.46'));
    expect(appSource, contains('precisionGestureUntil = now + 180'));
    expect(
      appSource,
      contains('documentScrollActiveUntil = performance.now() + 160'),
    );
    expect(appSource, contains('requestIdleCallback(run'));
    expect(appSource, contains('mathRenderQueue.push(container)'));
    expect(appSource, contains('overflow-anchor: none'));
    final platformViewSource = await File(
      'third_party/flutter_inappwebview_windows/lib/src/'
      'in_app_webview/custom_platform_view.dart',
    ).readAsString();
    expect(platformViewSource, contains('onPointerSignal:'));
    expect(platformViewSource, contains('onPointerPanZoomUpdate:'));
    expect(platformViewSource, contains('source: 0'));
    expect(platformViewSource, contains('source: 1'));
    expect(nativeViewSource, contains('kMouseWheelMultiplier = 6.0'));
    expect(nativeViewSource, contains('kPrecisionTouchpadMultiplier = 6.0'));
    expect(nativeViewSource, contains('std::trunc(scaledDelta)'));
    expect(
      nativeViewSource,
      contains('remainder = scaledDelta - boundedDelta'),
    );
    expect(nativeViewHeader, contains('horizontalScrollRemainder_'));
    expect(nativeViewHeader, contains('verticalScrollRemainder_'));
    expect(nativeViewHeader, contains('void scrollBy(double delta_x'));
    expect(nativeViewSource, contains('window.dualectPanScroll'));
    final platformViewNativeSource = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'custom_platform_view/custom_platform_view.cc',
    ).readAsString();
    expect(platformViewNativeSource, isNot(contains('LogScrollInput')));
    expect(
      platformViewNativeSource,
      isNot(contains('Dualect-scroll-input.log')),
    );
  });

  test('ties the Markdown WebView host to the app window', () async {
    final managerSource = await File(
      'third_party/flutter_inappwebview_windows/windows/'
      'in_app_webview/in_app_webview_manager.cpp',
    ).readAsString();
    final runnerSource = await File(
      'windows/runner/win32_window.cpp',
    ).readAsString();

    expect(managerSource, contains('GetAncestor(flutterViewHwnd, GA_ROOT)'));
    expect(managerSource, contains('WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW'));
    expect(managerSource, contains('WS_POPUP'));
    expect(managerSource, contains('flutterWindowHwnd'));
    expect(runnerSource, contains('kMarkdownWebViewHostClassName'));
    expect(runnerSource, contains('kWebViewBrowserWindowClassName'));
    expect(runnerSource, contains('Chrome_WidgetWin_1'));
    expect(runnerSource, contains('GetDescendantProcessIds'));
    expect(runnerSource, contains('CreateToolhelp32Snapshot'));
    expect(runnerSource, contains('g_hidden_webview_windows'));
    expect(runnerSource, contains('SyncWebViewHostVisibility'));
    expect(
      runnerSource,
      contains(
        'if (message == WM_SIZE) {\n'
        '      SyncWebViewHostVisibility(wparam != SIZE_MINIMIZED);',
      ),
    );
    expect(runnerSource, contains('wparam != SIZE_MINIMIZED'));
    expect(runnerSource, contains('ShowWindow(window, SW_HIDE)'));
    expect(runnerSource, contains('ShowWindow(window, SW_SHOWNOACTIVATE)'));
  });

  test('keeps WebView2 user data outside the release bundle', () async {
    final appSource = await File('lib/main.dart').readAsString();
    final cmakeSource = await File('windows/CMakeLists.txt').readAsString();

    expect(appSource, contains("Platform.environment['LOCALAPPDATA']"));
    expect(appSource, contains("'Dualect'"));
    expect(appSource, contains("'WebView2'"));
    expect(appSource, contains('webViewEnvironment: _appWebViewEnvironment'));
    expect(cmakeSource, contains(r'${BINARY_NAME}.exe.WebView2'));
    expect(cmakeSource, contains('file(REMOVE_RECURSE'));
  });

  test(
    'uses the Dualect product name across Flutter and Windows metadata',
    () async {
      final appSource = await File('lib/main.dart').readAsString();
      final runnerSource = await File('windows/runner/main.cpp').readAsString();
      final resourceSource = await File(
        'windows/runner/Runner.rc',
      ).readAsString();

      expect(
        appSource,
        contains("Dualect AI\\u6587\\u732e\\u7ffb\\u8bd1\\u5668"),
      );
      expect(appSource, isNot(contains('\\u971c\\u6708')));
      expect(appSource, isNot(contains('Dualect ·')));
      expect(
        runnerSource,
        contains('Dualect AI\\u6587\\u732E\\u7FFB\\u8BD1\\u5668'),
      );
      expect(resourceSource, contains('Dualect AI文献翻译器'));
      expect(resourceSource, isNot(contains('霜月')));
    },
  );

  test(
    'packages read-only research databases without development wording',
    () async {
      final appSource = await File('lib/main.dart').readAsString();
      final cmakeSource = await File('windows/CMakeLists.txt').readAsString();

      expect(appSource, contains('mode: sqlite.OpenMode.readOnly'));
      expect(
        appSource,
        contains('File(Platform.resolvedExecutable).parent.path'),
      );
      expect(appSource, isNot(contains('Flutter \\u7248')));
      expect(appSource, isNot(contains('\\u65e7\\u9879\\u76ee')));
      expect(cmakeSource, contains('APP_PROJECT_ROOT'));
      expect(cmakeSource, contains(r'${APP_PROJECT_ROOT}/ecdict_light.db'));
      expect(cmakeSource, contains(r'${APP_PROJECT_ROOT}/jcr.db'));
      expect(cmakeSource, contains('message(FATAL_ERROR'));
      expect(await File('ecdict_light.db').exists(), isTrue);
      expect(await File('jcr.db').exists(), isTrue);
    },
  );

  test('looks up dictionary entries from the local ECDICT database', () async {
    final dir = await Directory.systemTemp.createTemp('dict_db_');
    try {
      final db = sqlite.sqlite3.open(_joinPath(dir.path, 'ecdict_light.db'));
      db
        ..execute(
          'CREATE TABLE dict (word TEXT PRIMARY KEY, translation TEXT, definition TEXT)',
        )
        ..execute('CREATE TABLE aliases (variant TEXT PRIMARY KEY, lemma TEXT)')
        ..execute('INSERT INTO dict VALUES (?, ?, ?)', [
          'model',
          '模型',
          'a representation',
        ])
        ..execute('INSERT INTO aliases VALUES (?, ?)', ['models', 'model'])
        ..execute('INSERT INTO dict VALUES (?, ?, ?)', [
          'federated',
          '联邦的',
          'distributed learning related',
        ])
        ..close();

      final database = LocalResearchDatabase(dir.path);
      final exact = await database.lookupWord('MODEL');
      final alias = await database.lookupWord('models');
      final fuzzy = await database.lookupWord('feder');

      expect(exact.single.word, 'model');
      expect(alias.single.translation, '模型');
      expect(fuzzy.single.word, 'federated');
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('builds journal badges from local partition rows', () {
    final badges = buildJournalBadges([
      const JournalInfoRow(
        table: 'JCR2024',
        fields: [JournalField(label: 'IF Quartile(2024)', value: 'Q1')],
      ),
      const JournalInfoRow(
        table: 'FQBJCR2025',
        fields: [
          JournalField(label: '大类分区', value: '1区'),
          JournalField(label: 'Top', value: '是'),
        ],
      ),
      const JournalInfoRow(
        table: 'CCF2026',
        fields: [JournalField(label: 'CCF推荐类型', value: 'A类')],
      ),
    ]);

    expect(badges, containsAll(['JCR Q1', '中科院 1区', 'CCF A类', 'Top 期刊']));
  });

  test('normalizes DOI input variants', () {
    expect(
      ResearchMetadataService.normalizeDoi('https://doi.org/10.1145/123456'),
      '10.1145/123456',
    );
    expect(
      ResearchMetadataService.normalizeDoi('doi: 10.1000/demo'),
      '10.1000/demo',
    );
    expect(
      ResearchMetadataService.normalizeDoi('arXiv:2401.01234'),
      '10.48550/arXiv.2401.01234',
    );
  });

  test('loads MinerU content list files with space-separated names', () async {
    final dir = await Directory.systemTemp.createTemp('mineru_space_name_');
    try {
      final mineruDir = Directory(_joinPath(dir.path, 'mineru-output'));
      await mineruDir.create(recursive: true);
      await File(
        _joinPath(mineruDir.path, 'content list v2.json'),
      ).writeAsString(jsonEncode(<Object>[]));
      await File(
        _joinPath(mineruDir.path, 'layout.json'),
      ).writeAsString(jsonEncode({'pdf_info': <Object>[]}));

      final paper = await MineruPaper.load(dir.path);

      expect(paper.items, isEmpty);
      expect(paper.contentListPath, contains('content list v2.json'));
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test(
    'preserves legacy translation indexes for hidden empty text blocks',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'mineru_legacy_translation_index_',
      );
      try {
        final mineruDir = Directory(_joinPath(dir.path, 'mineru-output'));
        await mineruDir.create(recursive: true);
        final content = <Object>[];
        for (var index = 0; index < 32; index++) {
          content.add({
            'type': 'text',
            'text': index == 23 || index == 31 ? '' : 'Paragraph $index',
            'page_idx': 0,
            'bbox': [100, 100, 900, 160],
          });
        }
        content.addAll([
          {
            'type': 'text',
            'text': 'In a standard FL system',
            'page_idx': 1,
            'bbox': [100, 100, 900, 160],
          },
          {
            'type': 'equation',
            'text': r'$$O(w, D)=L(w, D)$$',
            'page_idx': 1,
            'bbox': [100, 180, 900, 240],
          },
          {
            'type': 'header',
            'text': 'Running header',
            'page_idx': 2,
            'bbox': [100, 20, 900, 50],
          },
          {
            'type': 'text',
            'text': 'where L represents the empirical loss function',
            'page_idx': 2,
            'bbox': [100, 100, 900, 160],
          },
        ]);
        await File(
          _joinPath(mineruDir.path, 'content_list_v2.json'),
        ).writeAsString(jsonEncode(content));
        await File(_joinPath(mineruDir.path, 'layout.json')).writeAsString(
          jsonEncode({
            'pdf_info': [{}, {}, {}],
          }),
        );
        await File(_joinPath(dir.path, 'translations.json')).writeAsString(
          jsonEncode({'32': '在标准的联邦学习系统中', '34': '其中 L 表示经验损失函数'}),
        );

        final paper = await MineruPaper.load(dir.path);
        final standard = paper.items.firstWhere(
          (item) => item.primaryText.startsWith('In a standard FL system'),
        );
        final empirical = paper.items.firstWhere(
          (item) => item.primaryText.startsWith('where L represents'),
        );

        expect(paper.items.any((item) => item.primaryText.isEmpty), isFalse);
        expect(standard.contentIndex, 32);
        expect(empirical.contentIndex, 34);
        expect(
          paper.translations[empirical.contentIndex.toString()],
          '其中 L 表示经验损失函数',
        );
      } finally {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    },
  );

  test('prefers UUID-prefixed MinerU content list v2 files', () async {
    final dir = await Directory.systemTemp.createTemp('mineru_prefixed_name_');
    try {
      final mineruDir = Directory(_joinPath(dir.path, 'mineru-output'));
      await mineruDir.create(recursive: true);
      await File(
        _joinPath(
          mineruDir.path,
          '0f6435f0-bf27-4c4e-bdb0-4cec8cf446ff_content_list.json',
        ),
      ).writeAsString(jsonEncode(<Object>[]));
      await File(
        _joinPath(
          mineruDir.path,
          '0f6435f0-bf27-4c4e-bdb0-4cec8cf446ff_content_list_v2.json',
        ),
      ).writeAsString(
        jsonEncode([
          [
            {
              'type': 'paragraph',
              'content': {
                'paragraph_content': [
                  {'type': 'text', 'content': 'Loaded from v2'},
                ],
              },
              'bbox': [100, 100, 900, 160],
            },
          ],
        ]),
      );
      await File(
        _joinPath(mineruDir.path, 'layout.json'),
      ).writeAsString(jsonEncode({'pdf_info': <Object>[]}));

      final paper = await MineruPaper.load(dir.path);

      expect(paper.contentListPath, contains('_content_list_v2.json'));
      expect(paper.items.single.primaryText, 'Loaded from v2');
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('loads page-grouped MinerU content list v2 files', () async {
    final dir = await Directory.systemTemp.createTemp('mineru_v2_grouped_');
    try {
      final mineruDir = Directory(_joinPath(dir.path, 'mineru-output'));
      await mineruDir.create(recursive: true);
      await File(
        _joinPath(mineruDir.path, 'content_list_v2.json'),
      ).writeAsString(
        jsonEncode([
          [
            {
              'type': 'title',
              'content': {
                'title_content': [
                  {'type': 'text', 'content': 'Nested Paper'},
                ],
                'level': 1,
              },
              'bbox': [100, 100, 900, 160],
            },
            {
              'type': 'paragraph',
              'content': {'paragraph_content': <Object>[]},
              'bbox': [100, 165, 900, 175],
            },
            {
              'type': 'paragraph',
              'content': {
                'paragraph_content': [
                  {'type': 'text', 'content': 'The ring'},
                  {'type': 'equation_inline', 'content': r'R=\mathbb{Z}'},
                  {'type': 'text', 'content': 'is used.'},
                ],
              },
              'bbox': [100, 180, 900, 230],
            },
            {
              'type': 'page_number',
              'content': {
                'page_number_content': [
                  {'type': 'text', 'content': '1'},
                ],
              },
              'bbox': [480, 960, 520, 980],
            },
          ],
          [
            {
              'type': 'equation_interline',
              'content': {'math_content': r'a \ne b'},
              'bbox': [100, 100, 900, 160],
            },
            {
              'type': 'table',
              'content': {
                'html': '<table><tr><td>\$M\$</td></tr></table>',
                'table_caption': [
                  {'type': 'text', 'content': 'TABLE 1. Demo'},
                ],
                'image_source': {'path': 'images/table.jpg'},
              },
              'bbox': [100, 200, 900, 400],
            },
          ],
        ]),
      );
      await File(_joinPath(mineruDir.path, 'layout.json')).writeAsString(
        jsonEncode({
          'pdf_info': [{}, {}],
        }),
      );

      final paper = await MineruPaper.load(dir.path);

      expect(paper.pageCount, 2);
      expect(paper.items, hasLength(4));
      expect(paper.items.first.primaryText, 'Nested Paper');
      expect(paper.items.first.textLevel, 1);
      expect(paper.items[1].primaryText, contains(r'$R=\mathbb{Z}$'));
      expect(paper.items[1].pageIndex, 0);
      expect(paper.items[1].contentIndex, 2);
      expect(paper.items[2].type, 'equation');
      expect(paper.items[2].contentIndex, 3);
      expect(paper.items[2].primaryText, r'a \ne b');
      expect(paper.items[3].type, 'table');
      expect(paper.items[3].contentIndex, 4);
      expect(paper.items[3].tableRows.single.single, r'$M$');
      expect(paper.items[3].tableCaption.single, 'TABLE 1. Demo');
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('loads the legacy library storage format', () async {
    final dir = await Directory.systemTemp.createTemp('legacy_library_');
    try {
      await File(_joinPath(dir.path, 'index.json')).writeAsString(
        jsonEncode([
          {
            'id': 'paper-a',
            'title': 'Original Title',
            'importedAt': '2026-01-02T03:04:00.000Z',
            'hasExtracted': true,
            'chineseName': '中文标题',
            'folderId': 'folder-1',
            'lastReadAt': '2026-01-03T03:04:00.000Z',
            'pageCount': 12,
            'metaJournal': 'Test Journal',
            'metaBadges': ['JCR Q1', 'Top 期刊'],
          },
        ]),
      );
      await File(_joinPath(dir.path, 'folders.json')).writeAsString(
        jsonEncode([
          {'id': 'folder-1', 'name': '隐私计算'},
        ]),
      );
      await Directory(
        _joinPath(_joinPath(dir.path, 'papers'), 'paper-a'),
      ).create(recursive: true);

      final snapshot = await LibraryStore(dir.path).load();

      expect(snapshot.papers, hasLength(1));
      expect(snapshot.folders.single.name, '隐私计算');
      expect(snapshot.papers.single.extractStatus, 'pending_read');
      expect(snapshot.papers.single.displayTitle, '中文标题');
      expect(snapshot.papers.single.metaBadges, contains('JCR Q1'));
      expect(
        LibraryStore.paperDir(dir.path, 'paper-a'),
        endsWith(_joinPath('papers', 'paper-a')),
      );
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('loads an empty work directory as an empty library', () async {
    final dir = await Directory.systemTemp.createTemp('empty_library_');
    try {
      final snapshot = await LibraryStore(dir.path).load();

      expect(snapshot.workDir, dir.path);
      expect(snapshot.papers, isEmpty);
      expect(snapshot.folders, isEmpty);
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('imports PDFs into the selected legacy folder', () async {
    final dir = await Directory.systemTemp.createTemp('library_import_');
    final sourceDir = await Directory.systemTemp.createTemp('source_pdf_');
    try {
      final store = LibraryStore(dir.path);
      final folder = await store.createFolder('\u9690\u79c1\u8ba1\u7b97');
      final pdf = File(_joinPath(sourceDir.path, 'Demo Paper.pdf'));
      await pdf.writeAsBytes([0x25, 0x50, 0x44, 0x46]);

      final imported = await store.importPdfs([pdf.path], folderId: folder.id);
      final snapshot = await store.load();

      expect(imported, hasLength(1));
      expect(snapshot.papers, hasLength(1));
      expect(snapshot.papers.single.folderId, folder.id);
      expect(snapshot.papers.single.title, 'Demo Paper');
      expect(
        await File(
          _joinPath(
            _joinPath(_joinPath(dir.path, 'papers'), imported.single.id),
            'paper.pdf',
          ),
        ).exists(),
        isTrue,
      );
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      if (await sourceDir.exists()) {
        await sourceDir.delete(recursive: true);
      }
    }
  });

  test('moves papers between legacy folders and back to unfiled', () async {
    final dir = await Directory.systemTemp.createTemp('library_move_paper_');
    try {
      final store = LibraryStore(dir.path);
      final first = await store.createFolder('第一类');
      final second = await store.createFolder('第二类');
      await File(_joinPath(dir.path, 'index.json')).writeAsString(
        jsonEncode([
          {
            'id': 'paper-a',
            'title': 'A',
            'importedAt': '2026-01-02T03:04:00.000Z',
            'extractStatus': 'none',
            'folderId': first.id,
          },
        ]),
      );

      await store.movePaper('paper-a', second.id);
      var snapshot = await store.load();
      expect(snapshot.papers.single.folderId, second.id);

      await store.movePaper('paper-a', null);
      snapshot = await store.load();
      expect(snapshot.papers.single.folderId, isNull);
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('deletes folders and moves nested papers back to unfiled', () async {
    final dir = await Directory.systemTemp.createTemp('library_delete_folder_');
    try {
      final store = LibraryStore(dir.path);
      final parent = await store.createFolder('\u9690\u79c1\u8ba1\u7b97');
      final child = await store.createFolder(
        '\u540c\u6001\u52a0\u5bc6',
        parentId: parent.id,
      );
      await File(_joinPath(dir.path, 'index.json')).writeAsString(
        jsonEncode([
          {
            'id': 'paper-a',
            'title': 'A',
            'importedAt': '2026-01-02T03:04:00.000Z',
            'extractStatus': 'none',
            'folderId': child.id,
          },
        ]),
      );

      final removed = await store.deleteFolder(parent.id);
      final snapshot = await store.load();

      expect(removed, containsAll([parent.id, child.id]));
      expect(snapshot.folders, isEmpty);
      expect(snapshot.papers.single.folderId, isNull);
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('updates extraction status in the legacy index format', () async {
    final dir = await Directory.systemTemp.createTemp(
      'library_extract_status_',
    );
    try {
      final indexFile = File(_joinPath(dir.path, 'index.json'));
      await indexFile.writeAsString(
        jsonEncode([
          {
            'id': 'paper-a',
            'title': 'A',
            'importedAt': '2026-01-02T03:04:00.000Z',
            'extractStatus': 'none',
          },
        ]),
      );

      await LibraryStore(dir.path).updateExtractStatus('paper-a', 'done');
      final snapshot = await LibraryStore(dir.path).load();

      expect(snapshot.papers.single.extractStatus, 'done');
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('updates Chinese name in the legacy index format', () async {
    final dir = await Directory.systemTemp.createTemp('legacy_library_rename_');
    try {
      final indexFile = File(_joinPath(dir.path, 'index.json'));
      await indexFile.writeAsString(
        jsonEncode([
          {
            'id': 'paper-a',
            'title': 'Original Title',
            'importedAt': '2026-01-02T03:04:00.000Z',
            'extractStatus': 'done',
            'metaBadges': ['JCR Q1'],
          },
        ]),
      );

      await LibraryStore(
        dir.path,
      ).updateChineseName('paper-a', '\u65b0\u4e2d\u6587\u540d');

      final decoded = jsonDecode(await indexFile.readAsString()) as List;
      final entry = decoded.single as Map<String, dynamic>;
      expect(entry['chineseName'], '\u65b0\u4e2d\u6587\u540d');
      expect(entry['metaBadges'], contains('JCR Q1'));

      await LibraryStore(dir.path).updateChineseName('paper-a', '');
      final cleared =
          (jsonDecode(await indexFile.readAsString()) as List).single
              as Map<String, dynamic>;
      expect(cleared.containsKey('chineseName'), isFalse);
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  testWidgets('renders the default Markdown note in the note panel', (
    tester,
  ) async {
    await tester.pumpWidget(_markdownNoteTestApp());

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);

    await tester.tap(find.text('预览').last);
    await tester.pumpAndSettle();

    expect(find.text('预览'), findsWidgets);
    expect(find.text('Reading Notes'), findsOneWidget);
    expect(find.text('Comparison Table'), findsOneWidget);
    expect(find.text('Baseline'), findsOneWidget);
    expect(find.text('Improved'), findsOneWidget);
  });

  testWidgets('renders custom Markdown table content after editing', (
    tester,
  ) async {
    await tester.pumpWidget(_markdownNoteTestApp());

    await tester.enterText(find.byType(EditableText), '''
# Custom Note

Inline math: \$a^2 + b^2 = c^2\$.

| Symbol | Meaning |
| --- | --- |
| alpha | learning rate |
| beta | momentum |
''');

    await tester.tap(find.text('预览').last);
    await tester.pumpAndSettle();

    expect(find.text('Custom Note'), findsOneWidget);
    expect(find.text('Symbol'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('momentum'), findsOneWidget);
  });

  testWidgets('can switch rendered Markdown back to source editing', (
    tester,
  ) async {
    await tester.pumpWidget(_markdownNoteTestApp());

    await tester.tap(find.text('预览').last);
    await tester.pumpAndSettle();
    expect(find.text('预览'), findsWidgets);

    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsWidgets);
    expect(find.byType(EditableText), findsOneWidget);
  });

  testWidgets(
    'keeps adjacent inline formulas separated around CJK punctuation',
    (tester) async {
      await tester.pumpWidget(_markdownNoteTestApp());

      await tester.enterText(
        find.byType(EditableText),
        r'''
Cipher text should remain a tuple form, like $ (\cdot + \cdot s) $\uFF09. Then linearize $ t_2 s^2 $ into the contribution of s.
'''
            .replaceAll(r'\uFF09', '\uFF09'),
      );

      await tester.tap(find.text('预览').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('Parser Error'), findsNothing);
      expect(find.textContaining('linearize'), findsOneWidget);
    },
  );
}

Widget _markdownNoteTestApp() {
  return const MaterialApp(home: Scaffold(body: MarkdownNotePanel()));
}

String _joinPath(String first, String second) {
  if (first.endsWith(r'\') || first.endsWith('/')) {
    return '$first$second';
  }
  return '$first${Platform.pathSeparator}$second';
}
