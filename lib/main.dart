import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:window_manager/window_manager.dart';

const _appDisplayName = 'Dualect AI\u6587\u732e\u7ffb\u8bd1\u5668';
const _pdfPreviewMaxSide = 2400.0;
const _maxPageImageCacheBytes = 88 * 1024 * 1024;
const _pdfVisibleRenderScaleFactor = 1.12;
const _pdfHighQualityRenderDelay = Duration(milliseconds: 100);
const _thumbnailHeight = 220.0;
const _thumbnailCacheWidth = 760;
const _katexAssetBase = 'assets/katex';
const _appFontFamily = 'Segoe UI';
const _appFontFallbacks = <String>['Microsoft YaHei UI'];
WebViewEnvironment? _appWebViewEnvironment;
Object? _appWebViewEnvironmentError;

double _snapToPhysicalPixel(double value, double devicePixelRatio) {
  return (value * devicePixelRatio).round() / devicePixelRatio;
}

double _floorToPhysicalPixel(double value, double devicePixelRatio) {
  return (value * devicePixelRatio).floor() / devicePixelRatio;
}

const _windowsLibraryChannel = MethodChannel(
  'pdf_markdown_reader/windows_library',
);
const _pdfNightInvertMatrix = <double>[
  -1,
  0,
  0,
  0,
  255,
  0,
  -1,
  0,
  0,
  255,
  0,
  0,
  -1,
  0,
  255,
  0,
  0,
  0,
  1,
  0,
];
const _deepSeekApiUrl = 'https://api.deepseek.com/chat/completions';
const _deepSeekModelsUrl = 'https://api.deepseek.com/models';
const _defaultDeepSeekModel = 'deepseek-v4-flash';
const _deepSeekSystemPrompt = '''
You are an academic translator that converts English text to Chinese.
Your task is to translate ONLY the natural language parts, and you MUST preserve the following Markdown and LaTeX elements EXACTLY as they appear, without any modification, translation, or reordering:

- Inline math: \$...\$
- Display math: \$\$...\$\$
- Bold, italic, and other inline formatting: **...**, *...*, `...`, ~~...~~
- Links and images: [text](url), ![alt](url) - keep the URL and alt text unchanged; do not translate the URL or the alt text inside the brackets.
- Citation markers: [@...], \\cite{...}, [^...]  (or any similar reference markers)
- Any HTML tags like <sup>, <sub>, <i> etc.
- Tables: If the paragraph contains a Markdown table, keep the entire table structure (pipes |, dashes -, alignment colons) completely untouched. Translate only the cell contents, keeping the cell boundaries identical.
- Any placeholder enclosed in angle brackets like <TABLE_xxx>, <CODE_xxx>, <CITE_xxx> (if present) must be left completely untouched.

Rules:
1. Do not add or delete any spaces inside the preserved elements.
2. Do not convert LaTeX delimiters (e.g., \$ to \\(\\)).
3. Return ONLY the translated paragraph with all formatting intact.
4. If you are unsure about a mathematical expression, keep it as-is.
5. Do not add any explanations, notes, or extra text beyond the translation.
''';
const _deepSeekBatchSystemPrompt = '''
You are an academic translator that converts English text to Chinese.
Your task is to translate ONLY the natural language parts, and you MUST preserve Markdown and LaTeX elements EXACTLY as they appear.

You will receive MULTIPLE paragraphs at once. Each paragraph is preceded by a marker like [PARA 0], [PARA 1], etc.
Translate EACH paragraph and return them WITH THE SAME MARKERS in the same order.
Your response MUST contain exactly the same set of markers as the input.

Preserve inline math \$...\$, display math \$\$...\$\$, citation markers, links, HTML tags, and table structure.
Return ONLY the translated paragraphs with markers. Do not add explanations.
''';
const _sampleMarkdownNote = r'''
# Reading Notes

This panel renders Markdown without WebView. Edit the source, then press **Render**.

## Inline and Block Math

Inline energy equation: $E = mc^2$.

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

Matrix example:

$$
A =
\begin{bmatrix}
1 & 2 & 3 \\
4 & 5 & 6
\end{bmatrix}
$$

## Comparison Table

| Method | Formula | Notes |
| --- | --- | --- |
| Baseline | $O(n^2)$ | easy to implement |
| Improved | $O(n \log n)$ | better for large inputs |
| Approximation | $\hat{y}=Wx+b$ | useful for quick estimates |

## Code

```dart
double gaussian(double x) => exp(-x * x);
```

> Later we can bind this note to the current PDF and save it as a `.md` file.
''';

enum PdfContentLinkMode { none, page, zoom }

enum LibrarySortField { importedAt, title, lastReadAt }

enum AppColorTheme { sage, night, ocean, forest, indigo, wine, amber }

enum ReaderFontPreset { comfortable, academic, book }

class LibraryPreferences {
  const LibraryPreferences._();

  static const _configFileName = 'library_preferences.json';
  static const _workDirKey = 'workDir';
  static const _deepSeekApiKey = 'deepSeekApiKey';
  static const _deepSeekModelKey = 'deepSeekModel';
  static const _deepSeekThinkingKey = 'deepSeekEnableThinking';
  static const _mineruApiTokenKey = 'mineruApiToken';
  static const _bodyFontSizeKey = 'readerBodyFontSize';
  static const _translationFontSizeKey = 'readerTranslationFontSize';
  static const _readerFontPresetKey = 'readerFontPreset';
  static const _librarySortFieldKey = 'librarySortField';
  static const _librarySortDescendingKey = 'librarySortDescending';
  static const _appThemeKey = 'appTheme';

  static Future<String?> readWorkDir() async {
    try {
      final config = await _readConfig();
      return _readOptionalString(config[_workDirKey]);
    } catch (_) {}
    return null;
  }

  static Future<void> saveWorkDir(String workDir) async {
    final config = await _readConfig();
    config[_workDirKey] = workDir;
    await _writeConfig(config);
  }

  static Future<AppApiSettings> readApiSettings() async {
    final config = await _readConfig();
    return AppApiSettings(
      deepSeekApiKey: _readOptionalString(config[_deepSeekApiKey]) ?? '',
      deepSeekModel:
          _readOptionalString(config[_deepSeekModelKey]) ??
          _defaultDeepSeekModel,
      deepSeekEnableThinking: config[_deepSeekThinkingKey] == true,
      mineruApiToken: _readOptionalString(config[_mineruApiTokenKey]) ?? '',
    );
  }

  static Future<void> saveApiSettings(AppApiSettings settings) async {
    final config = await _readConfig();
    config[_deepSeekApiKey] = settings.deepSeekApiKey.trim();
    config[_deepSeekModelKey] = settings.deepSeekModel.trim();
    config[_deepSeekThinkingKey] = settings.deepSeekEnableThinking;
    config[_mineruApiTokenKey] = settings.mineruApiToken.trim();
    await _writeConfig(config);
  }

  static Future<ReaderFontSettings> readReaderFontSettings() async {
    final config = await _readConfig();
    final presetName = _readOptionalString(config[_readerFontPresetKey]);
    return ReaderFontSettings(
      bodyFontSize: _readDouble(config[_bodyFontSizeKey]) ?? 14,
      translationFontSize: _readDouble(config[_translationFontSizeKey]) ?? 13,
      preset: ReaderFontPreset.values.firstWhere(
        (value) => value.name == presetName,
        orElse: () => ReaderFontPreset.comfortable,
      ),
    );
  }

  static Future<void> saveReaderFontSettings(
    ReaderFontSettings settings,
  ) async {
    final config = await _readConfig();
    config[_bodyFontSizeKey] = settings.bodyFontSize;
    config[_translationFontSizeKey] = settings.translationFontSize;
    config[_readerFontPresetKey] = settings.preset.name;
    await _writeConfig(config);
  }

  static Future<LibrarySortSettings> readLibrarySortSettings() async {
    final config = await _readConfig();
    final fieldName = _readOptionalString(config[_librarySortFieldKey]);
    final field = LibrarySortField.values.firstWhere(
      (value) => value.name == fieldName,
      orElse: () => LibrarySortField.importedAt,
    );
    return LibrarySortSettings(
      field: field,
      descending: config[_librarySortDescendingKey] != false,
    );
  }

  static Future<void> saveLibrarySortSettings(
    LibrarySortSettings settings,
  ) async {
    final config = await _readConfig();
    config[_librarySortFieldKey] = settings.field.name;
    config[_librarySortDescendingKey] = settings.descending;
    await _writeConfig(config);
  }

  static Future<AppColorTheme> readAppTheme() async {
    final config = await _readConfig();
    final themeName = _readOptionalString(config[_appThemeKey]);
    return AppColorTheme.values.firstWhere(
      (value) => value.name == themeName,
      orElse: () => AppColorTheme.sage,
    );
  }

  static Future<void> saveAppTheme(AppColorTheme theme) async {
    final config = await _readConfig();
    config[_appThemeKey] = theme.name;
    await _writeConfig(config);
  }

  static Future<Map<String, dynamic>> _readConfig() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  static Future<void> _writeConfig(Map<String, dynamic> config) async {
    final file = await _configFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  static Future<File> _configFile() async {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.current.path;
    return File(
      _joinPath(_joinPath(base, 'PdfMarkdownReader'), _configFileName),
    );
  }
}

class AppApiSettings {
  const AppApiSettings({
    required this.deepSeekApiKey,
    required this.deepSeekModel,
    required this.deepSeekEnableThinking,
    required this.mineruApiToken,
  });

  final String deepSeekApiKey;
  final String deepSeekModel;
  final bool deepSeekEnableThinking;
  final String mineruApiToken;
}

class ReaderFontSettings {
  const ReaderFontSettings({
    this.bodyFontSize = 14,
    this.translationFontSize = 13,
    this.preset = ReaderFontPreset.comfortable,
  });

  final double bodyFontSize;
  final double translationFontSize;
  final ReaderFontPreset preset;
}

class LibrarySortSettings {
  const LibrarySortSettings({required this.field, required this.descending});

  final LibrarySortField field;
  final bool descending;
}

class LibraryStore {
  const LibraryStore(this.workDir);

  static final _indexLocks = <String, Future<void>>{};

  final String workDir;

  static String paperDir(String workDir, String paperId) {
    return _joinPath(_joinPath(workDir, 'papers'), paperId);
  }

  Future<LibrarySnapshot> load() async {
    await Directory(workDir).create(recursive: true);
    final indexFile = File(_joinPath(workDir, 'index.json'));
    var entries = <LibraryPaperEntry>[];
    if (await indexFile.exists()) {
      final entriesJson = await _readJsonFileRecovering(indexFile);
      entries = entriesJson is List
          ? entriesJson
                .whereType<Map<String, dynamic>>()
                .map(LibraryPaperEntry.fromJson)
                .toList(growable: false)
          : <LibraryPaperEntry>[];
      for (var index = 0; index < entries.length; index++) {
        final paper = entries[index];
        if (paper.extractStatus != 'extracting') {
          continue;
        }
        if (await MineruPaper.hasExtractedContent(paperDirPath(paper.id))) {
          await updatePaperFields(paper.id, {
            'extractStatus': 'pending_read',
            'extractProgress': 1,
            'extractMessage': '提取完成',
          });
          entries[index] = paper.copyWith(
            extractStatus: 'pending_read',
            extractProgress: 1,
            extractMessage: '提取完成',
          );
        }
      }
    }

    final foldersFile = File(_joinPath(workDir, 'folders.json'));
    var folders = <LibraryFolder>[];
    if (await foldersFile.exists()) {
      final foldersJson = await _readJsonFileRecovering(foldersFile);
      if (foldersJson is List) {
        folders = foldersJson
            .whereType<Map<String, dynamic>>()
            .map(LibraryFolder.fromJson)
            .toList(growable: false);
      }
    }

    return LibrarySnapshot(workDir: workDir, papers: entries, folders: folders);
  }

  Future<LibraryFolder> createFolder(String name, {String? parentId}) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Folder name is empty');
    }
    final folders = await _readFolderMaps();
    final folder = {'id': _generateLibraryId(), 'name': normalized};
    if (parentId != null) {
      folder['parentId'] = parentId;
    }
    folders.add(folder);
    await _writeFolders(folders);
    return LibraryFolder.fromJson(folder);
  }

  Future<List<String>> deleteFolder(String folderId) async {
    final folders = await _readFolderMaps();
    final ids = <String>{
      folderId,
      ..._collectChildFolderIds(folders, folderId),
    };
    final remaining = folders
        .where((folder) => !ids.contains(folder['id']?.toString()))
        .toList(growable: false);
    if (remaining.length == folders.length) {
      return ids.toList(growable: false);
    }
    await _writeFolders(remaining);

    final entries = await _readIndexMaps();
    var changed = false;
    for (final entry in entries) {
      final paperFolderId = entry['folderId']?.toString();
      if (paperFolderId != null && ids.contains(paperFolderId)) {
        entry.remove('folderId');
        changed = true;
      }
    }
    if (changed) {
      await _writeIndex(entries);
    }
    return ids.toList(growable: false);
  }

  Future<List<LibraryPaperEntry>> importPdfs(
    List<String> pdfPaths, {
    String? folderId,
  }) async {
    if (pdfPaths.isEmpty) {
      return const [];
    }

    await Directory(_joinPath(workDir, 'papers')).create(recursive: true);
    final imported = <LibraryPaperEntry>[];
    final prepared = <Map<String, dynamic>>[];
    final createdPaperDirs = <Directory>[];

    try {
      for (final sourcePath in pdfPaths.where(
        (path) => path.toLowerCase().endsWith('.pdf'),
      )) {
        final source = File(sourcePath);
        if (!await source.exists()) {
          throw FileSystemException('PDF 文件不存在', sourcePath);
        }
        final id = _generateLibraryId();
        final paperDir = Directory(paperDirPath(id));
        await paperDir.create(recursive: true);
        createdPaperDirs.add(paperDir);
        await source.copy(_joinPath(paperDir.path, 'paper.pdf'));

        final title = _fileNameWithoutExtension(source.path);
        final entry = {
          'id': id,
          'title': title,
          'importedAt': DateTime.now().toUtc().toIso8601String(),
          'extractStatus': 'none',
        };
        if (folderId != null) {
          entry['folderId'] = folderId;
        }
        prepared.add(entry);
        imported.add(LibraryPaperEntry.fromJson(entry));
      }

      if (imported.isNotEmpty) {
        await _withIndexLock(() async {
          final entries = await _readIndexMaps();
          entries.addAll(prepared);
          await _writeIndex(entries);
        });
      }
      return imported;
    } catch (_) {
      for (final directory in createdPaperDirs.reversed) {
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } catch (_) {}
      }
      rethrow;
    }
  }

  String paperDirPath(String paperId) {
    return paperDir(workDir, paperId);
  }

  Future<void> updateChineseName(String paperId, String name) async {
    await _withIndexLock(() async {
      final decoded = await _readIndexMaps();

      var changed = false;
      final normalized = name.trim();
      for (final item in decoded) {
        if (item['id']?.toString() == paperId) {
          if (normalized.isEmpty) {
            item.remove('chineseName');
          } else {
            item['chineseName'] = normalized;
          }
          changed = true;
          break;
        }
      }

      if (changed) {
        await _writeIndex(decoded);
      }
    });
  }

  Future<void> updatePaperFields(
    String paperId,
    Map<String, Object?> updates,
  ) async {
    await _withIndexLock(() async {
      final decoded = await _readIndexMaps();
      var changed = false;
      for (final item in decoded) {
        if (item['id']?.toString() == paperId) {
          for (final entry in updates.entries) {
            final value = entry.value;
            if (value == null) {
              item.remove(entry.key);
            } else {
              item[entry.key] = value;
            }
          }
          changed = true;
          break;
        }
      }
      if (changed) {
        await _writeIndex(decoded);
      }
    });
  }

  Future<void> updateExtractStatus(String paperId, String status) {
    return updatePaperFields(paperId, {'extractStatus': status});
  }

  Future<void> movePaper(String paperId, String? folderId) {
    return updatePaperFields(paperId, {'folderId': folderId});
  }

  Future<void> deletePaper(String paperId) async {
    var deleted = false;
    await _withIndexLock(() async {
      final entries = await _readIndexMaps();
      final remaining = entries
          .where((entry) => entry['id']?.toString() != paperId)
          .toList(growable: false);
      if (remaining.length == entries.length) {
        return;
      }
      await _writeIndex(remaining);
      deleted = true;
    });
    if (!deleted) {
      return;
    }
    final dir = Directory(paperDirPath(paperId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<List<Map<String, dynamic>>> _readIndexMaps() async {
    final indexFile = File(_joinPath(workDir, 'index.json'));
    if (!await indexFile.exists()) {
      return <Map<String, dynamic>>[];
    }
    final decoded = await _readJsonFileRecovering(indexFile);
    if (decoded is! List) {
      return <Map<String, dynamic>>[];
    }
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<List<Map<String, dynamic>>> _readFolderMaps() async {
    final foldersFile = File(_joinPath(workDir, 'folders.json'));
    if (!await foldersFile.exists()) {
      return <Map<String, dynamic>>[];
    }
    final decoded = await _readJsonFileRecovering(foldersFile);
    if (decoded is! List) {
      return <Map<String, dynamic>>[];
    }
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<String> _collectChildFolderIds(
    List<Map<String, dynamic>> folders,
    String folderId,
  ) {
    final ids = <String>[];
    void walk(String parentId) {
      for (final folder in folders) {
        if (folder['parentId']?.toString() == parentId) {
          final id = folder['id']?.toString();
          if (id == null || ids.contains(id)) {
            continue;
          }
          ids.add(id);
          walk(id);
        }
      }
    }

    walk(folderId);
    return ids;
  }

  Future<void> _writeIndex(List<Map<String, dynamic>> entries) async {
    final indexFile = File(_joinPath(workDir, 'index.json'));
    await _writeJsonFile(indexFile, entries);
  }

  Future<void> _writeFolders(List<Map<String, dynamic>> folders) async {
    final foldersFile = File(_joinPath(workDir, 'folders.json'));
    await _writeJsonFile(foldersFile, folders);
  }

  Future<T> _withIndexLock<T>(Future<T> Function() action) {
    final key = File(_joinPath(workDir, 'index.json')).absolute.path;
    final previous = _indexLocks[key] ?? Future<void>.value();
    final completer = Completer<void>();
    final current = completer.future;
    _indexLocks[key] = current;

    return previous.catchError((_) {}).then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
        if (identical(_indexLocks[key], current)) {
          _indexLocks.remove(key);
        }
      }
    });
  }

  Future<Object?> _readJsonFileRecovering(File file) async {
    final text = await file.readAsString();
    try {
      return jsonDecode(text);
    } on FormatException {
      final recovered = _tryRecoverTrailingJson(text);
      if (recovered == null) {
        rethrow;
      }
      await _writeJsonFile(file, recovered);
      return recovered;
    }
  }

  Object? _tryRecoverTrailingJson(String text) {
    for (var end = text.length - 1; end >= 0; end--) {
      final char = text.codeUnitAt(end);
      if (char != 0x5d && char != 0x7d) {
        continue;
      }
      try {
        return jsonDecode(text.substring(0, end + 1));
      } catch (_) {
        // Keep scanning backward; concurrent writes usually leave a valid JSON
        // document followed by a short stale suffix.
      }
    }
    return null;
  }

  Future<void> _writeJsonFile(File file, Object? value) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
  }
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.translation,
    required this.definition,
  });

  final String word;
  final String translation;
  final String definition;
}

class JournalField {
  const JournalField({required this.label, required this.value});

  final String label;
  final String value;
}

class JournalInfoRow {
  const JournalInfoRow({required this.table, required this.fields});

  final String table;
  final List<JournalField> fields;

  Map<String, String> get fieldMap => {
    for (final field in fields) field.label: field.value,
  };
}

class PaperMetadata {
  const PaperMetadata({
    required this.title,
    required this.journal,
    required this.year,
    required this.authors,
  });

  final String title;
  final String journal;
  final String year;
  final String authors;
}

class LocalResearchDatabase {
  const LocalResearchDatabase(this.workDir);

  static const _journalTables = [
    'JCR2024',
    'JCR2023',
    'FQBJCR2025',
    'CCF2026',
    'CCFT2025',
    'XR2026',
    'XR2026Conferences',
    'GJQKYJMD2025',
    'GJQKYJMD2024',
  ];

  static const _journalSearchTables = [
    'JCR2024',
    'JCR2023',
    'FQBJCR2025',
    'CCF2026',
    'CCFT2025',
    'XR2026',
    'XR2026Conferences',
  ];

  final String workDir;

  Future<List<DictionaryEntry>> lookupWord(String word) async {
    final normalized = _normalizeLookupWord(word);
    if (normalized.isEmpty) {
      return const [];
    }
    final dbFile = await _findDatabaseFile('ecdict_light.db');
    if (dbFile == null) {
      throw const FileSystemException('程序数据文件 ecdict_light.db 缺失，请重新安装完整版本。');
    }

    final db = sqlite.sqlite3.open(dbFile.path, mode: sqlite.OpenMode.readOnly);
    try {
      var results = _queryDictionaryRows(
        db,
        'SELECT word, translation, definition FROM dict WHERE word = ? COLLATE NOCASE LIMIT 1',
        [normalized],
      );
      if (results.isNotEmpty) {
        return results;
      }

      final aliases = db.select(
        'SELECT lemma FROM aliases WHERE variant = ? LIMIT 1',
        [normalized],
      );
      for (final row in aliases) {
        final lemma = row['lemma']?.toString() ?? '';
        if (lemma.isEmpty) {
          continue;
        }
        results = _queryDictionaryRows(
          db,
          'SELECT word, translation, definition FROM dict WHERE word = ? LIMIT 1',
          [lemma],
        );
        if (results.isNotEmpty) {
          return results;
        }
      }

      return _queryDictionaryRows(
        db,
        'SELECT word, translation, definition FROM dict WHERE word LIKE ? LIMIT 8',
        ['%$normalized%'],
      );
    } finally {
      db.close();
    }
  }

  List<DictionaryEntry> _queryDictionaryRows(
    sqlite.Database db,
    String sql,
    List<Object?> parameters,
  ) {
    return db
        .select(sql, parameters)
        .map(
          (row) => DictionaryEntry(
            word: row['word']?.toString() ?? '',
            translation: row['translation']?.toString() ?? '',
            definition: row['definition']?.toString() ?? '',
          ),
        )
        .where((entry) => entry.word.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<String>> searchJournalNames(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final dbFile = await _findDatabaseFile('jcr.db');
    if (dbFile == null) {
      throw const FileSystemException('程序数据文件 jcr.db 缺失，请重新安装完整版本。');
    }

    final db = sqlite.sqlite3.open(dbFile.path, mode: sqlite.OpenMode.readOnly);
    try {
      final namesByKey = <String, String>{};
      final like = '%$normalized%';
      for (final table in _journalSearchTables) {
        try {
          final rows = db.select(
            'SELECT "Journal" FROM "$table" WHERE "Journal" LIKE ? LIMIT 15',
            [like],
          );
          for (final row in rows) {
            final name = row['Journal']?.toString() ?? '';
            if (name.isNotEmpty) {
              final key = name.trim().toLowerCase();
              namesByKey[key] = _preferJournalDisplayName(
                namesByKey[key],
                name.trim(),
              );
            }
          }
        } catch (_) {}
      }
      final result = namesByKey.values.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return result.take(30).toList(growable: false);
    } finally {
      db.close();
    }
  }

  Future<List<JournalInfoRow>> queryJournal(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final dbFile = await _findDatabaseFile('jcr.db');
    if (dbFile == null) {
      throw const FileSystemException('程序数据文件 jcr.db 缺失，请重新安装完整版本。');
    }

    final db = sqlite.sqlite3.open(dbFile.path, mode: sqlite.OpenMode.readOnly);
    try {
      final results = <JournalInfoRow>[];
      for (final table in _journalTables) {
        try {
          final columns = db
              .select('PRAGMA table_info("$table")')
              .map((row) => row['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList(growable: false);
          final rows = db.select(
            'SELECT * FROM "$table" WHERE "Journal" = ? COLLATE NOCASE LIMIT 1',
            [normalized],
          );
          if (rows.isEmpty) {
            continue;
          }
          final row = rows.first;
          final fields = <JournalField>[];
          for (final column in columns) {
            final value = row[column]?.toString() ?? '';
            if (value.isNotEmpty) {
              fields.add(JournalField(label: column, value: value));
            }
          }
          if (fields.isNotEmpty) {
            results.add(JournalInfoRow(table: table, fields: fields));
          }
        } catch (_) {}
      }
      return results;
    } finally {
      db.close();
    }
  }

  Future<File?> _findDatabaseFile(String fileName) async {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      File(_joinPath(executableDir, fileName)),
      File(_joinPath(workDir, fileName)),
    ];
    for (final candidate in candidates) {
      if (await candidate.exists()) {
        return candidate;
      }
    }
    return null;
  }
}

class ResearchMetadataService {
  const ResearchMetadataService();

  static final _doiPattern = RegExp(
    r'10\.\d{4,9}/[-._;()/:A-Z0-9]+',
    caseSensitive: false,
  );

  static String normalizeDoi(String value) {
    var doi = value.trim();
    doi = doi.replaceFirst(
      RegExp(r'^(https?://)?(dx\.)?doi\.org/', caseSensitive: false),
      '',
    );
    doi = doi.replaceFirst(RegExp(r'^doi:\s*', caseSensitive: false), '');
    doi = doi.replaceFirst(
      RegExp(r'^arXiv:\s*', caseSensitive: false),
      '10.48550/arXiv.',
    );
    return doi.trim();
  }

  Future<String?> extractDoiFromPdf(String pdfPath) async {
    PdfDocument? document;
    try {
      document = await PdfDocument.openFile(pdfPath);
      final pages = math.min(3, document.pages.length);
      final buffer = StringBuffer();
      for (var i = 0; i < pages; i++) {
        final text = await document.pages[i].loadStructuredText();
        buffer.writeln(text.fullText);
      }
      final match = _doiPattern.firstMatch(buffer.toString());
      return match == null ? null : normalizeDoi(match.group(0)!);
    } catch (_) {
      return null;
    } finally {
      await document?.dispose();
    }
  }

  Future<PaperMetadata?> fetchMetadataByDoi(String doi) async {
    final normalized = normalizeDoi(doi);
    if (normalized.isEmpty) {
      return null;
    }
    return await _queryCrossref(normalized) ?? await _queryDataCite(normalized);
  }

  Future<PaperMetadata?> _queryCrossref(String doi) async {
    try {
      final uri = Uri.parse(
        'https://api.crossref.org/works/${Uri.encodeComponent(doi)}',
      );
      final decoded = await _getJson(uri);
      final message = decoded['message'];
      if (message is! Map) {
        return null;
      }
      final title = _firstString(message['title']);
      final journal = _firstString(message['container-title']);
      final year = _firstDatePartYear(message['published']);
      final authors = _formatCrossrefAuthors(message['author']);
      return PaperMetadata(
        title: title,
        journal: journal,
        year: year,
        authors: authors,
      );
    } catch (_) {
      return null;
    }
  }

  Future<PaperMetadata?> _queryDataCite(String doi) async {
    try {
      final uri = Uri.parse(
        'https://api.datacite.org/dois/${Uri.encodeComponent(doi)}',
      );
      final decoded = await _getJson(uri);
      final data = decoded['data'];
      final attrs = data is Map ? data['attributes'] : null;
      if (attrs is! Map) {
        return null;
      }
      final titles = attrs['titles'];
      var title = '';
      if (titles is List && titles.isNotEmpty && titles.first is Map) {
        title = (titles.first as Map)['title']?.toString() ?? '';
      }
      final year = (attrs['published'] ?? attrs['created'] ?? '').toString();
      return PaperMetadata(
        title: title,
        journal: attrs['publisher']?.toString() ?? '',
        year: year,
        authors: _formatDataCiteAuthors(attrs['author']),
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw const FormatException('Unexpected JSON response');
    } finally {
      client.close(force: true);
    }
  }

  String _firstString(Object? value) {
    if (value is List && value.isNotEmpty) {
      return value.first?.toString() ?? '';
    }
    return value?.toString() ?? '';
  }

  String _firstDatePartYear(Object? value) {
    if (value is Map) {
      final parts = value['date-parts'];
      if (parts is List && parts.isNotEmpty && parts.first is List) {
        final first = parts.first as List;
        if (first.isNotEmpty) {
          return first.first.toString();
        }
      }
    }
    return '';
  }

  String _formatCrossrefAuthors(Object? value) {
    if (value is! List) {
      return '';
    }
    final names = value
        .take(3)
        .whereType<Map>()
        .map((author) {
          return [
            author['given']?.toString() ?? '',
            author['family']?.toString() ?? '',
          ].where((part) => part.isNotEmpty).join(' ');
        })
        .where((name) => name.isNotEmpty)
        .join(', ');
    return names + (value.length > 3 && names.isNotEmpty ? ' et al.' : '');
  }

  String _formatDataCiteAuthors(Object? value) {
    if (value is! List) {
      return '';
    }
    final names = value
        .take(3)
        .whereType<Map>()
        .map((author) {
          return [
            author['givenName']?.toString() ?? '',
            author['familyName']?.toString() ?? '',
          ].where((part) => part.isNotEmpty).join(' ');
        })
        .where((name) => name.isNotEmpty)
        .join(', ');
    return names + (value.length > 3 && names.isNotEmpty ? ' et al.' : '');
  }
}

List<String> buildJournalBadges(List<JournalInfoRow> data) {
  final badges = <String>[];
  var hasTop = false;
  for (final row in data) {
    final values = row.fieldMap;
    if (row.table == 'JCR2024') {
      final quartile = values['IF Quartile(2024)'];
      if (quartile != null && quartile.isNotEmpty && quartile != 'N/A') {
        badges.add('JCR $quartile');
      }
    }
    if (row.table == 'CCF2026') {
      final ccf = values['CCF推荐类型'];
      if (ccf != null && ccf.isNotEmpty) {
        badges.add('CCF $ccf');
      }
    }
    if (row.table == 'FQBJCR2025') {
      final partition = values['大类分区'];
      if (partition != null && partition.isNotEmpty) {
        final tier = RegExp(r'^\d+').firstMatch(partition)?.group(0) ?? '';
        badges.add(tier.isEmpty ? '中科院 $partition' : '中科院 $tier区');
      }
      if (values['Top'] == '是') {
        hasTop = true;
      }
    }
    if (row.table.startsWith('GJQKYJMD')) {
      badges.add('预警');
    }
  }
  if (hasTop) {
    badges.add('Top 期刊');
  }
  return {...badges}.toList(growable: false);
}

String _normalizeLookupWord(String value) {
  final trimmed = value.trim();
  final match = RegExp(r"[A-Za-z][A-Za-z\-']*").firstMatch(trimmed);
  return (match?.group(0) ?? '').trim();
}

String _preferJournalDisplayName(String? current, String candidate) {
  if (current == null || current.isEmpty) {
    return candidate;
  }

  int score(String value) {
    final letters = value.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.isEmpty) {
      return 0;
    }
    final allUpper = letters == letters.toUpperCase();
    final allLower = letters == letters.toLowerCase();
    if (!allUpper && !allLower) {
      return 3;
    }
    if (allUpper) {
      return 2;
    }
    return 1;
  }

  final currentScore = score(current);
  final candidateScore = score(candidate);
  if (candidateScore != currentScore) {
    return candidateScore > currentScore ? candidate : current;
  }
  return candidate.length < current.length ? candidate : current;
}

class LibrarySnapshot {
  const LibrarySnapshot({
    required this.workDir,
    required this.papers,
    required this.folders,
  });

  final String workDir;
  final List<LibraryPaperEntry> papers;
  final List<LibraryFolder> folders;
}

class LibraryPaperEntry {
  const LibraryPaperEntry({
    required this.id,
    required this.title,
    required this.importedAt,
    required this.extractStatus,
    this.extractProgress,
    this.extractMessage,
    this.chineseName,
    this.folderId,
    this.lastReadAt,
    this.pageCount,
    this.doi,
    this.metaTitle,
    this.metaAuthors,
    this.metaJournal,
    this.metaYear,
    this.metaBadges = const [],
  });

  final String id;
  final String title;
  final String importedAt;
  final String extractStatus;
  final double? extractProgress;
  final String? extractMessage;
  final String? chineseName;
  final String? folderId;
  final String? lastReadAt;
  final int? pageCount;
  final String? doi;
  final String? metaTitle;
  final String? metaAuthors;
  final String? metaJournal;
  final String? metaYear;
  final List<String> metaBadges;

  String get displayTitle {
    final cn = chineseName?.trim();
    if (cn != null && cn.isNotEmpty) {
      return cn;
    }
    return title;
  }

  LibraryPaperEntry copyWith({
    String? chineseName,
    bool clearChineseName = false,
    String? folderId,
    bool clearFolderId = false,
    String? extractStatus,
    double? extractProgress,
    String? extractMessage,
    String? lastReadAt,
    int? pageCount,
    String? doi,
    String? metaTitle,
    String? metaAuthors,
    String? metaJournal,
    String? metaYear,
    List<String>? metaBadges,
  }) {
    return LibraryPaperEntry(
      id: id,
      title: title,
      importedAt: importedAt,
      extractStatus: extractStatus ?? this.extractStatus,
      extractProgress: extractProgress ?? this.extractProgress,
      extractMessage: extractMessage ?? this.extractMessage,
      chineseName: clearChineseName ? null : chineseName ?? this.chineseName,
      folderId: clearFolderId ? null : folderId ?? this.folderId,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      pageCount: pageCount ?? this.pageCount,
      doi: doi ?? this.doi,
      metaTitle: metaTitle ?? this.metaTitle,
      metaAuthors: metaAuthors ?? this.metaAuthors,
      metaJournal: metaJournal ?? this.metaJournal,
      metaYear: metaYear ?? this.metaYear,
      metaBadges: metaBadges ?? this.metaBadges,
    );
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return true;
    }
    return title.toLowerCase().contains(q) ||
        (chineseName?.toLowerCase().contains(q) ?? false) ||
        (metaTitle?.toLowerCase().contains(q) ?? false) ||
        (metaJournal?.toLowerCase().contains(q) ?? false) ||
        (metaAuthors?.toLowerCase().contains(q) ?? false);
  }

  static LibraryPaperEntry fromJson(Map<String, dynamic> json) {
    final hasExtracted = json['hasExtracted'];
    final status =
        json['extractStatus']?.toString() ??
        (hasExtracted == true ? 'pending_read' : 'none');

    return LibraryPaperEntry(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Untitled',
      importedAt: json['importedAt']?.toString() ?? '',
      extractStatus: status,
      extractProgress: _readDouble(json['extractProgress']),
      extractMessage: _readOptionalString(json['extractMessage']),
      chineseName: _readOptionalString(json['chineseName']),
      folderId: _readOptionalString(json['folderId']),
      lastReadAt: _readOptionalString(json['lastReadAt']),
      pageCount: _readInt(json['pageCount']),
      doi: _readOptionalString(json['doi']),
      metaTitle: _readOptionalString(json['metaTitle']),
      metaAuthors: _readOptionalString(json['metaAuthors']),
      metaJournal: _readOptionalString(json['metaJournal']),
      metaYear: _readOptionalString(json['metaYear']),
      metaBadges: _readStringList(json['metaBadges']),
    );
  }
}

class LibraryFolder {
  const LibraryFolder({required this.id, required this.name, this.parentId});

  final String id;
  final String name;
  final String? parentId;

  static LibraryFolder fromJson(Map<String, dynamic> json) {
    return LibraryFolder(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Untitled',
      parentId: _readOptionalString(json['parentId']),
    );
  }
}

class LibraryFolderNode {
  const LibraryFolderNode({required this.folder, required this.depth});

  final LibraryFolder folder;
  final int depth;
}

class MineruExtractionProgress {
  const MineruExtractionProgress({
    required this.state,
    required this.message,
    this.extractedPages,
    this.totalPages,
  });

  final String state;
  final String message;
  final int? extractedPages;
  final int? totalPages;
}

double _progressValueForState(
  MineruExtractionProgress progress, [
  double current = 0,
]) {
  switch (progress.state) {
    case 'uploading':
      return progress.message.contains('PDF') ? 0.1 : 0.05;
    case 'pending':
      return 0.15;
    case 'running':
      final extracted = progress.extractedPages;
      final total = progress.totalPages;
      if (extracted != null && total != null && total > 0) {
        return 0.2 + (extracted / total).clamp(0, 1) * 0.6;
      }
      return math.max(current, 0.2);
    case 'converting':
      return 0.85;
    case 'downloading':
      return 0.92;
    case 'done':
      return 0.96;
    default:
      return current;
  }
}

class MineruExtractionService {
  const MineruExtractionService();

  static const _apiBase = 'https://mineru.net/api/v4';

  Future<void> submit({
    required String workDir,
    required String paperId,
    required void Function(MineruExtractionProgress progress) onProgress,
    bool Function()? isCancelled,
  }) async {
    void checkCancelled() {
      if (isCancelled?.call() == true) {
        throw const _ExtractionCancelledException();
      }
    }

    final settings = await LibraryPreferences.readApiSettings();
    final token = settings.mineruApiToken.trim();
    if (token.isEmpty) {
      throw Exception(
        '\u8bf7\u5148\u5728\u8bbe\u7f6e\u4e2d\u914d\u7f6e MinerU API Token',
      );
    }

    checkCancelled();
    final paperDir = LibraryStore.paperDir(workDir, paperId);
    final pdfFile = File(_joinPath(paperDir, 'paper.pdf'));
    if (!await pdfFile.exists()) {
      throw Exception('paper.pdf not found');
    }

    onProgress(
      const MineruExtractionProgress(
        state: 'uploading',
        message: '\u83b7\u53d6\u4e0a\u4f20\u5730\u5740...',
      ),
    );
    final uploadInfo = await _getUploadUrl(token);
    checkCancelled();

    onProgress(
      const MineruExtractionProgress(
        state: 'uploading',
        message: '\u4e0a\u4f20 PDF \u6587\u4ef6...',
      ),
    );
    await _uploadFile(uploadInfo.uploadUrl, await pdfFile.readAsBytes());
    checkCancelled();

    onProgress(
      const MineruExtractionProgress(
        state: 'pending',
        message: '\u7b49\u5f85 MinerU \u89e3\u6790...',
      ),
    );
    final zipUrl = await _pollBatch(
      uploadInfo.batchId,
      token,
      onProgress,
      checkCancelled,
    );
    checkCancelled();

    onProgress(
      const MineruExtractionProgress(
        state: 'downloading',
        message: '\u4e0b\u8f7d\u89e3\u6790\u7ed3\u679c...',
      ),
    );
    final zipBytes = await _downloadBytes(zipUrl);
    checkCancelled();
    await _extractZip(zipBytes, paperDir);
  }

  Future<_MineruUploadInfo> _getUploadUrl(String token) async {
    final json = await _requestJson(
      method: 'POST',
      url: Uri.parse('$_apiBase/file-urls/batch'),
      token: token,
      body: {
        'files': [
          {'name': 'paper.pdf', 'data_id': 'paper.pdf'},
        ],
        'model_version': 'vlm',
      },
    );
    if (json['code'] != 0) {
      throw Exception(
        json['msg']?.toString() ??
            '\u83b7\u53d6\u4e0a\u4f20\u5730\u5740\u5931\u8d25',
      );
    }
    final data = json['data'];
    if (data is! Map) {
      throw Exception(
        '\u4e0a\u4f20\u5730\u5740\u54cd\u5e94\u683c\u5f0f\u5f02\u5e38',
      );
    }
    final batchId = data['batch_id']?.toString();
    final urls = data['file_urls'];
    final uploadUrl = urls is List && urls.isNotEmpty
        ? urls.first?.toString()
        : null;
    if (batchId == null || uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception(
        '\u4e0a\u4f20\u5730\u5740\u54cd\u5e94\u7f3a\u5c11\u5fc5\u8981\u5b57\u6bb5',
      );
    }
    return _MineruUploadInfo(batchId: batchId, uploadUrl: uploadUrl);
  }

  Future<String> _pollBatch(
    String batchId,
    String token,
    void Function(MineruExtractionProgress progress) onProgress,
    VoidCallback checkCancelled,
  ) async {
    final url = Uri.parse('$_apiBase/extract-results/batch/$batchId');
    for (var attempt = 0; attempt < 600; attempt++) {
      checkCancelled();
      final json = await _requestJson(method: 'GET', url: url, token: token);
      if (json['code'] != 0) {
        throw Exception(
          json['msg']?.toString() ?? '\u67e5\u8be2\u4efb\u52a1\u5931\u8d25',
        );
      }
      final data = json['data'];
      final results = data is Map ? data['extract_result'] : null;
      final result = results is List && results.isNotEmpty
          ? results.first
          : null;
      if (result is! Map) {
        if (attempt > 0 && attempt % 10 == 0) {
          onProgress(
            MineruExtractionProgress(
              state: 'pending',
              message: '\u6392\u961f\u4e2d... ${attempt ~/ 10}s',
            ),
          );
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }

      final state = result['state']?.toString() ?? 'pending';
      switch (state) {
        case 'done':
          final zipUrl = result['full_zip_url']?.toString();
          if (zipUrl == null || zipUrl.isEmpty) {
            throw Exception(
              '\u4efb\u52a1\u5b8c\u6210\u4f46\u6ca1\u6709\u8fd4\u56de\u4e0b\u8f7d\u94fe\u63a5',
            );
          }
          onProgress(
            const MineruExtractionProgress(
              state: 'done',
              message: '\u89e3\u6790\u5b8c\u6210',
            ),
          );
          return zipUrl;
        case 'failed':
          throw Exception(
            result['err_msg']?.toString() ?? '\u89e3\u6790\u5931\u8d25',
          );
        case 'running':
          final progress = result['extract_progress'];
          final extracted = progress is Map
              ? _readInt(progress['extracted_pages'])
              : null;
          final total = progress is Map
              ? _readInt(progress['total_pages'])
              : null;
          onProgress(
            MineruExtractionProgress(
              state: 'running',
              message: extracted != null && total != null
                  ? '\u89e3\u6790\u4e2d $extracted/$total \u9875'
                  : '\u89e3\u6790\u4e2d...',
              extractedPages: extracted,
              totalPages: total,
            ),
          );
          break;
        case 'converting':
          onProgress(
            const MineruExtractionProgress(
              state: 'converting',
              message: '\u683c\u5f0f\u8f6c\u6362\u4e2d...',
            ),
          );
          break;
        default:
          onProgress(
            MineruExtractionProgress(
              state: state,
              message: '\u5904\u7406\u4e2d... $state',
            ),
          );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw Exception(
      '\u89e3\u6790\u8d85\u65f6\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5',
    );
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required Uri url,
    required String token,
    Map<String, Object?>? body,
  }) async {
    final client = HttpClient();
    try {
      final request = method == 'POST'
          ? await client.postUrl(url)
          : await client.getUrl(url);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        final bytes = utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw Exception('\u54cd\u5e94\u683c\u5f0f\u5f02\u5e38');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _uploadFile(String uploadUrl, List<int> bytes) async {
    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(uploadUrl));
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $text');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _downloadBytes(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await utf8.decoder.bind(response).join();
        throw Exception('HTTP ${response.statusCode}: $text');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _extractZip(List<int> zipBytes, String paperDir) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final mineruDir = _joinPath(paperDir, 'mineru-output');
    await Directory(_joinPath(mineruDir, 'images')).create(recursive: true);

    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }
      final relativePath = entry.name.replaceAll('\\', '/');
      if (relativePath.contains('_model.') || relativePath == 'full.md') {
        continue;
      }

      String saveName;
      String root;
      if (relativePath.startsWith('images/')) {
        saveName = relativePath.substring('images/'.length);
        root = _joinPath(mineruDir, 'images');
      } else {
        final fileName = relativePath.split('/').last;
        if (_isMineruContentListName(fileName)) {
          saveName = 'content_list_v2.json';
        } else if (_isMineruLayoutName(fileName)) {
          saveName = 'layout.json';
        } else {
          saveName = relativePath;
        }
        root = mineruDir;
      }
      if (saveName.isEmpty) {
        continue;
      }
      final target = _safeRelativeFile(root, saveName);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.content, flush: true);
    }
  }
}

class _MineruUploadInfo {
  const _MineruUploadInfo({required this.batchId, required this.uploadUrl});

  final String batchId;
  final String uploadUrl;
}

class _ExtractionCancelledException implements Exception {
  const _ExtractionCancelledException();

  @override
  String toString() => '\u63d0\u53d6\u5df2\u7ec8\u6b62';
}

class ExtractionTaskState {
  const ExtractionTaskState({
    required this.workDir,
    required this.paperId,
    required this.status,
    required this.progress,
    required this.message,
    this.logs = const [],
  });

  final String workDir;
  final String paperId;
  final String status;
  final double progress;
  final String message;
  final List<String> logs;

  bool get extracting => status == 'extracting';
  bool get completed => status == 'pending_read';
  bool get failed => status == 'none' && message.startsWith('提取失败');

  LibraryPaperEntry applyTo(LibraryPaperEntry paper) {
    return paper.copyWith(
      extractStatus: status,
      extractProgress: progress,
      extractMessage: message,
    );
  }
}

class ExtractionManager extends ChangeNotifier {
  final _tasks = <String, ExtractionTaskState>{};
  final _running = <String, Future<void>>{};
  final _cancelled = <String>{};

  ExtractionTaskState? stateFor(String? workDir, String? paperId) {
    if (workDir == null || paperId == null) {
      return null;
    }
    return _tasks[_key(workDir, paperId)];
  }

  LibraryPaperEntry mergePaper(String workDir, LibraryPaperEntry paper) {
    return stateFor(workDir, paper.id)?.applyTo(paper) ?? paper;
  }

  bool isRunning(String workDir, String paperId) {
    return _running.containsKey(_key(workDir, paperId));
  }

  void markRead(String workDir, String paperId) {
    final key = _key(workDir, paperId);
    _tasks[key] = ExtractionTaskState(
      workDir: workDir,
      paperId: paperId,
      status: 'done',
      progress: 1,
      message: '',
    );
    notifyListeners();
  }

  Future<void> start({required String workDir, required String paperId}) {
    final key = _key(workDir, paperId);
    final running = _running[key];
    if (running != null) {
      return running;
    }

    _cancelled.remove(key);
    final task = _run(workDir: workDir, paperId: paperId, key: key);
    _running[key] = task;
    task.whenComplete(() {
      if (identical(_running[key], task)) {
        _running.remove(key);
      }
    });
    return task;
  }

  void cancel(String workDir, String paperId) {
    _cancelled.add(_key(workDir, paperId));
  }

  Future<void> _run({
    required String workDir,
    required String paperId,
    required String key,
  }) async {
    await _persist(
      key,
      workDir,
      paperId,
      status: 'extracting',
      progress: 0.05,
      message: '开始提取...',
      resetLogs: true,
    );
    try {
      await const MineruExtractionService().submit(
        workDir: workDir,
        paperId: paperId,
        onProgress: (progress) {
          final current = _tasks[key]?.progress ?? 0;
          final next = math.max(
            current,
            _progressValueForState(progress, current),
          );
          unawaited(
            _persist(
              key,
              workDir,
              paperId,
              status: 'extracting',
              progress: next,
              message: progress.message,
            ),
          );
        },
        isCancelled: () => _cancelled.contains(key),
      );
      await _persist(
        key,
        workDir,
        paperId,
        status: 'pending_read',
        progress: 1,
        message: '提取完成',
      );
    } catch (error) {
      if (await MineruPaper.hasExtractedContent(
        LibraryStore.paperDir(workDir, paperId),
      )) {
        await _persist(
          key,
          workDir,
          paperId,
          status: 'pending_read',
          progress: 1,
          message: '提取完成',
        );
        return;
      }
      final message = error is _ExtractionCancelledException
          ? '提取已终止'
          : '提取失败: $error';
      await _persist(
        key,
        workDir,
        paperId,
        status: 'none',
        progress: 0,
        message: message,
      );
    } finally {
      _cancelled.remove(key);
    }
  }

  Future<void> _persist(
    String key,
    String workDir,
    String paperId, {
    required String status,
    required double progress,
    required String message,
    bool resetLogs = false,
  }) async {
    final previous = _tasks[key];
    final normalizedProgress = status == 'extracting' && previous != null
        ? math.max(previous.progress, progress)
        : progress;
    final logs = resetLogs
        ? <String>[message]
        : <String>[...?previous?.logs, message];
    final state = ExtractionTaskState(
      workDir: workDir,
      paperId: paperId,
      status: status,
      progress: normalizedProgress.clamp(0, 1).toDouble(),
      message: message,
      logs: logs.length <= 80 ? logs : logs.sublist(logs.length - 80),
    );
    _tasks[key] = state;
    notifyListeners();
    await LibraryStore(workDir).updatePaperFields(paperId, {
      'extractStatus': status,
      'extractProgress': status == 'done' ? null : state.progress,
      'extractMessage': status == 'done' ? null : message,
    });
  }

  String _key(String workDir, String paperId) {
    return '${File(workDir).absolute.path}::$paperId';
  }
}

class DeepSeekModelService {
  const DeepSeekModelService();

  Future<List<String>> fetchModels({required String apiKey}) async {
    final normalizedKey = apiKey.trim();
    if (normalizedKey.isEmpty) {
      throw const DeepSeekModelException('请先输入 DeepSeek API Key');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(Uri.parse(_deepSeekModelsUrl))
          .timeout(const Duration(seconds: 15));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $normalizedKey',
      );
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      request.headers.set(HttpHeaders.userAgentHeader, 'Dualect/1.0 (Windows)');

      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final responseText = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DeepSeekModelException(
          _deepSeekModelHttpError(response.statusCode),
        );
      }

      final models = parseDeepSeekModelIds(jsonDecode(responseText));
      if (models.isEmpty) {
        throw const DeepSeekModelException('DeepSeek 未返回可用模型，请稍后重试');
      }
      return models;
    } on DeepSeekModelException {
      rethrow;
    } on FormatException {
      throw const DeepSeekModelException('DeepSeek 返回的模型列表格式异常');
    } on TimeoutException {
      throw const DeepSeekModelException('连接 DeepSeek 超时，请检查网络后重试');
    } on HandshakeException {
      throw const DeepSeekModelException('无法建立安全连接，请检查网络或代理设置');
    } on SocketException {
      throw const DeepSeekModelException('无法连接 DeepSeek，请检查网络后重试');
    } catch (_) {
      throw const DeepSeekModelException('获取模型失败，请稍后重试');
    } finally {
      client.close(force: true);
    }
  }
}

class DeepSeekModelException implements Exception {
  const DeepSeekModelException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<String> parseDeepSeekModelIds(Object? responseBody) {
  if (responseBody is! Map) {
    return const [];
  }
  final data = responseBody['data'];
  if (data is! List) {
    return const [];
  }

  final seen = <String>{};
  final models = <String>[];
  for (final entry in data) {
    if (entry is! Map) {
      continue;
    }
    final id = entry['id']?.toString().trim() ?? '';
    if (id.isNotEmpty && seen.add(id)) {
      models.add(id);
    }
  }
  return models;
}

String _deepSeekModelHttpError(int statusCode) {
  return switch (statusCode) {
    401 => 'API Key 无效，请检查后重试',
    402 => 'DeepSeek 账户余额不足',
    429 => '请求过于频繁，请稍后重试',
    >= 500 => 'DeepSeek 服务暂时不可用，请稍后重试',
    _ => '获取模型失败（HTTP $statusCode）',
  };
}

class DeepSeekTranslationService {
  const DeepSeekTranslationService();

  Future<void> translateStream({
    required String markdown,
    required AppApiSettings settings,
    required ValueChanged<String> onChunk,
    bool Function()? isCancelled,
  }) async {
    if (settings.deepSeekApiKey.trim().isEmpty) {
      throw const FormatException('DeepSeek API Key is empty');
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(_deepSeekApiUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.deepSeekApiKey.trim()}',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      );

      final body = <String, Object?>{
        'model': settings.deepSeekModel.trim().isEmpty
            ? _defaultDeepSeekModel
            : settings.deepSeekModel.trim(),
        'messages': [
          {'role': 'system', 'content': _deepSeekSystemPrompt},
          {'role': 'user', 'content': markdown},
        ],
        'stream': true,
        'temperature': 0.3,
        'max_tokens': 4096,
      };
      body['thinking'] = {
        'type': settings.deepSeekEnableThinking ? 'enabled' : 'disabled',
      };

      final payload = utf8.encode(jsonEncode(body));
      request.contentLength = payload.length;
      request.add(payload);

      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await utf8.decoder.bind(response).join();
        throw Exception('DeepSeek HTTP ${response.statusCode}: $text');
      }

      var fullText = '';
      var buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        if (isCancelled?.call() == true) {
          throw const _TranslationCancelledException();
        }
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) {
            continue;
          }
          final payload = trimmed.substring(6).trim();
          if (payload == '[DONE]') {
            continue;
          }

          try {
            final parsed = jsonDecode(payload);
            if (parsed is! Map) {
              continue;
            }
            final choices = parsed['choices'];
            if (choices is! List || choices.isEmpty) {
              continue;
            }
            final choice = choices.first;
            if (choice is! Map) {
              continue;
            }
            final delta = choice['delta'];
            if (delta is! Map) {
              continue;
            }
            final content = delta['content']?.toString() ?? '';
            if (content.isEmpty) {
              continue;
            }
            fullText += content;
            onChunk(fullText);
          } catch (_) {
            // Ignore partial or non-JSON SSE lines.
          }
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<List<String>> batchTranslateStream({
    required List<String> markdowns,
    required AppApiSettings settings,
    required ValueChanged<List<String?>> onProgress,
    bool Function()? isCancelled,
  }) async {
    if (settings.deepSeekApiKey.trim().isEmpty) {
      throw const FormatException('DeepSeek API Key is empty');
    }
    if (markdowns.isEmpty) {
      return const [];
    }

    final combinedInput = [
      for (var i = 0; i < markdowns.length; i++) '[PARA $i]\n${markdowns[i]}',
    ].join('\n\n');

    var fullText = '';
    await _postChatStream(
      settings: settings,
      systemPrompt: _deepSeekBatchSystemPrompt,
      userContent: combinedInput,
      maxTokens: 4096 * math.min(markdowns.length, 10),
      onContent: (content) {
        fullText += content;
        onProgress(parseBatchTranslationResults(fullText, markdowns.length));
      },
      isCancelled: isCancelled,
    );

    final parsed = parseBatchTranslationResults(fullText, markdowns.length);
    return [
      for (var i = 0; i < markdowns.length; i++)
        parsed[i] ??
            '*\u7ffb\u8bd1\u5931\u8d25: \u6a21\u578b\u672a\u8fd4\u56de\u7b2c ${i + 1} \u6bb5*',
    ];
  }

  Future<void> _postChatStream({
    required AppApiSettings settings,
    required String systemPrompt,
    required String userContent,
    required int maxTokens,
    required ValueChanged<String> onContent,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(_deepSeekApiUrl));
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.deepSeekApiKey.trim()}',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      );

      final body = <String, Object?>{
        'model': settings.deepSeekModel.trim().isEmpty
            ? _defaultDeepSeekModel
            : settings.deepSeekModel.trim(),
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userContent},
        ],
        'stream': true,
        'temperature': 0.3,
        'max_tokens': maxTokens,
      };
      body['thinking'] = {
        'type': settings.deepSeekEnableThinking ? 'enabled' : 'disabled',
      };

      final payload = utf8.encode(jsonEncode(body));
      request.contentLength = payload.length;
      request.add(payload);

      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await utf8.decoder.bind(response).join();
        throw Exception('DeepSeek HTTP ${response.statusCode}: $text');
      }

      var buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        if (isCancelled?.call() == true) {
          throw const _TranslationCancelledException();
        }
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        for (final line in lines) {
          final content = _readDeepSeekSseContent(line);
          if (content != null && content.isNotEmpty) {
            onContent(content);
          }
        }
      }
    } finally {
      client.close(force: true);
    }
  }
}

class _TranslationCancelledException implements Exception {
  const _TranslationCancelledException();

  @override
  String toString() => '\u7ffb\u8bd1\u5df2\u7ec8\u6b62';
}

String? _readDeepSeekSseContent(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('data: ')) {
    return null;
  }
  final payload = trimmed.substring(6).trim();
  if (payload == '[DONE]') {
    return null;
  }

  try {
    final parsed = jsonDecode(payload);
    if (parsed is! Map) {
      return null;
    }
    final choices = parsed['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }
    final choice = choices.first;
    if (choice is! Map) {
      return null;
    }
    final delta = choice['delta'];
    if (delta is! Map) {
      return null;
    }
    return delta['content']?.toString();
  } catch (_) {
    return null;
  }
}

List<String?> parseBatchTranslationResults(String fullContent, int count) {
  final results = List<String?>.filled(count, null);
  final matches = RegExp(
    r'\[PARA\s+(\d+)\]\s*([\s\S]*?)(?=\[PARA\s+\d+\]|$)',
  ).allMatches(fullContent);
  for (final match in matches) {
    final index = int.tryParse(match.group(1) ?? '');
    if (index == null || index < 0 || index >= count) {
      continue;
    }
    final text = (match.group(2) ?? '').trim();
    if (text.isNotEmpty) {
      results[index] = text;
    }
  }
  return results;
}

Future<void> _initializeWindowsWebViewEnvironment() async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw const FileSystemException('LOCALAPPDATA is unavailable');
    }
    final userDataDir = Directory(
      _joinPath(_joinPath(localAppData, 'Dualect'), 'WebView2'),
    );
    await userDataDir.create(recursive: true);
    _appWebViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: userDataDir.path),
    );
  } catch (error) {
    _appWebViewEnvironmentError = error;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeWindowsWebViewEnvironment();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setTitle(_appDisplayName);
    await windowManager.setMinimumSize(const Size(860, 520));
  }
  runApp(const PdfReaderApp());
}

class PdfReaderApp extends StatefulWidget {
  const PdfReaderApp({super.key, this.pdfPath, this.paperDir});

  final String? pdfPath;
  final String? paperDir;

  @override
  State<PdfReaderApp> createState() => _PdfReaderAppState();
}

class _PdfReaderAppState extends State<PdfReaderApp> {
  AppColorTheme _theme = AppColorTheme.sage;

  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    final theme = await LibraryPreferences.readAppTheme();
    if (!mounted) {
      return;
    }
    setState(() {
      _theme = theme;
    });
  }

  Future<void> _setTheme(AppColorTheme theme) async {
    if (_theme != theme && mounted) {
      setState(() {
        _theme = theme;
      });
    }
    await LibraryPreferences.saveAppTheme(theme);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _appDisplayName,
      theme: _buildAppTheme(_theme),
      home: AppThemeScope(
        theme: _theme,
        onThemeChanged: _setTheme,
        child: widget.pdfPath == null
            ? const LibraryShell()
            : PdfReaderPage(
                pdfPath: widget.pdfPath!,
                paperDir: widget.paperDir ?? File(widget.pdfPath!).parent.path,
              ),
      ),
    );
  }
}

class AppThemeScope extends InheritedWidget {
  const AppThemeScope({
    super.key,
    required this.theme,
    required this.onThemeChanged,
    required super.child,
  });

  final AppColorTheme theme;
  final Future<void> Function(AppColorTheme theme) onThemeChanged;

  static AppThemeScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppThemeScope>();
  }

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) {
    return theme != oldWidget.theme;
  }
}

extension AppColorThemeLabel on AppColorTheme {
  String get label => switch (this) {
    AppColorTheme.sage => '青藤浅色',
    AppColorTheme.night => '黑夜模式',
    AppColorTheme.ocean => '海盐蓝',
    AppColorTheme.forest => '松林深绿',
    AppColorTheme.indigo => '靛蓝科技',
    AppColorTheme.wine => '酒红书房',
    AppColorTheme.amber => '琥珀暖调',
  };
}

extension ReaderFontPresetStyle on ReaderFontPreset {
  String get label => switch (this) {
    ReaderFontPreset.comfortable => '舒适阅读',
    ReaderFontPreset.academic => '论文排版',
    ReaderFontPreset.book => '书籍阅读',
  };

  String get bodyCssFamily => switch (this) {
    ReaderFontPreset.comfortable =>
      '"Segoe UI", "Microsoft YaHei UI", "Noto Sans SC", Arial, sans-serif',
    ReaderFontPreset.academic => '"Times New Roman", SimSun, "宋体", serif',
    ReaderFontPreset.book =>
      'Georgia, "Noto Serif CJK SC", "Source Han Serif SC", STSong, SimSun, serif',
  };

  String get headingCssFamily => switch (this) {
    ReaderFontPreset.comfortable => bodyCssFamily,
    ReaderFontPreset.academic =>
      '"Times New Roman", SimHei, "Microsoft YaHei UI", sans-serif',
    ReaderFontPreset.book => bodyCssFamily,
  };
}

@immutable
class ReaderColors extends ThemeExtension<ReaderColors> {
  const ReaderColors({
    required this.brightness,
    required this.appBackground,
    required this.surface,
    required this.surfaceAlt,
    required this.glass,
    required this.border,
    required this.accent,
    required this.accentSoft,
    required this.pdfBackground,
    required this.editorFill,
    required this.codeFill,
    required this.tableHeader,
    required this.shadow,
  });

  final Brightness brightness;
  final Color appBackground;
  final Color surface;
  final Color surfaceAlt;
  final Color glass;
  final Color border;
  final Color accent;
  final Color accentSoft;
  final Color pdfBackground;
  final Color editorFill;
  final Color codeFill;
  final Color tableHeader;
  final Color shadow;

  static ReaderColors of(BuildContext context) {
    return Theme.of(context).extension<ReaderColors>() ??
        _readerPalette(AppColorTheme.sage);
  }

  @override
  ReaderColors copyWith({
    Brightness? brightness,
    Color? appBackground,
    Color? surface,
    Color? surfaceAlt,
    Color? glass,
    Color? border,
    Color? accent,
    Color? accentSoft,
    Color? pdfBackground,
    Color? editorFill,
    Color? codeFill,
    Color? tableHeader,
    Color? shadow,
  }) {
    return ReaderColors(
      brightness: brightness ?? this.brightness,
      appBackground: appBackground ?? this.appBackground,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      glass: glass ?? this.glass,
      border: border ?? this.border,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      pdfBackground: pdfBackground ?? this.pdfBackground,
      editorFill: editorFill ?? this.editorFill,
      codeFill: codeFill ?? this.codeFill,
      tableHeader: tableHeader ?? this.tableHeader,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  ReaderColors lerp(ThemeExtension<ReaderColors>? other, double t) {
    if (other is! ReaderColors) {
      return this;
    }
    return ReaderColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      appBackground: Color.lerp(appBackground, other.appBackground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      border: Color.lerp(border, other.border, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      pdfBackground: Color.lerp(pdfBackground, other.pdfBackground, t)!,
      editorFill: Color.lerp(editorFill, other.editorFill, t)!,
      codeFill: Color.lerp(codeFill, other.codeFill, t)!,
      tableHeader: Color.lerp(tableHeader, other.tableHeader, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

ReaderColors _readerPalette(AppColorTheme theme) {
  return switch (theme) {
    AppColorTheme.sage => const ReaderColors(
      brightness: Brightness.light,
      appBackground: Color(0xFFF0F3F1),
      surface: Color(0xFFFCFDFC),
      surfaceAlt: Color(0xFFF4F7F5),
      glass: Color(0xF2F9FBFA),
      border: Color(0xFFCBD6D1),
      accent: Color(0xFF246D66),
      accentSoft: Color(0xFFE0EEEA),
      pdfBackground: Color(0xFFE4E9E6),
      editorFill: Color(0xFFF8FAF9),
      codeFill: Color(0xFFE9EFEC),
      tableHeader: Color(0xFFE3ECE8),
      shadow: Color(0x1A111814),
    ),
    AppColorTheme.night => const ReaderColors(
      brightness: Brightness.dark,
      appBackground: Color(0xFF0F1214),
      surface: Color(0xFF171B1E),
      surfaceAlt: Color(0xFF1D2327),
      glass: Color(0xF21A1F22),
      border: Color(0xFF354047),
      accent: Color(0xFF72C5B5),
      accentSoft: Color(0xFF213A36),
      pdfBackground: Color(0xFF090B0D),
      editorFill: Color(0xFF131719),
      codeFill: Color(0xFF222A2E),
      tableHeader: Color(0xFF273238),
      shadow: Color(0x52000000),
    ),
    AppColorTheme.ocean => const ReaderColors(
      brightness: Brightness.light,
      appBackground: Color(0xFFF1F4F6),
      surface: Color(0xFFFCFDFE),
      surfaceAlt: Color(0xFFF3F7F9),
      glass: Color(0xF2F8FBFC),
      border: Color(0xFFC9D6DC),
      accent: Color(0xFF176B8A),
      accentSoft: Color(0xFFDDEEF4),
      pdfBackground: Color(0xFFE1E8EC),
      editorFill: Color(0xFFF8FAFC),
      codeFill: Color(0xFFE6EEF2),
      tableHeader: Color(0xFFDDEAF0),
      shadow: Color(0x1A131A1E),
    ),
    AppColorTheme.forest => const ReaderColors(
      brightness: Brightness.dark,
      appBackground: Color(0xFF0D1512),
      surface: Color(0xFF14201B),
      surfaceAlt: Color(0xFF192A23),
      glass: Color(0xF217251F),
      border: Color(0xFF344C40),
      accent: Color(0xFF78C99B),
      accentSoft: Color(0xFF214331),
      pdfBackground: Color(0xFF090E0C),
      editorFill: Color(0xFF111A16),
      codeFill: Color(0xFF203128),
      tableHeader: Color(0xFF294034),
      shadow: Color(0x52000000),
    ),
    AppColorTheme.indigo => const ReaderColors(
      brightness: Brightness.light,
      appBackground: Color(0xFFF1F2F7),
      surface: Color(0xFFFDFDFF),
      surfaceAlt: Color(0xFFF5F5FA),
      glass: Color(0xF2F9F9FD),
      border: Color(0xFFCACDE0),
      accent: Color(0xFF4657B8),
      accentSoft: Color(0xFFE2E5F7),
      pdfBackground: Color(0xFFE3E5EE),
      editorFill: Color(0xFFF9F9FC),
      codeFill: Color(0xFFE9EAF3),
      tableHeader: Color(0xFFE2E4F1),
      shadow: Color(0x1A101426),
    ),
    AppColorTheme.wine => const ReaderColors(
      brightness: Brightness.light,
      appBackground: Color(0xFFF5F2F3),
      surface: Color(0xFFFFFDFE),
      surfaceAlt: Color(0xFFF8F4F6),
      glass: Color(0xF2FCF9FA),
      border: Color(0xFFDACDD2),
      accent: Color(0xFF963451),
      accentSoft: Color(0xFFF2E1E7),
      pdfBackground: Color(0xFFE8E1E3),
      editorFill: Color(0xFFFCF9FA),
      codeFill: Color(0xFFF0E8EB),
      tableHeader: Color(0xFFEBDDE2),
      shadow: Color(0x1A1F1015),
    ),
    AppColorTheme.amber => const ReaderColors(
      brightness: Brightness.light,
      appBackground: Color(0xFFF5F3EE),
      surface: Color(0xFFFFFEFB),
      surfaceAlt: Color(0xFFF8F5EE),
      glass: Color(0xF2FCFAF5),
      border: Color(0xFFD8D0BE),
      accent: Color(0xFFA4620B),
      accentSoft: Color(0xFFF3E6CB),
      pdfBackground: Color(0xFFE9E4D8),
      editorFill: Color(0xFFFCFAF5),
      codeFill: Color(0xFFF0EBDF),
      tableHeader: Color(0xFFEAE1CC),
      shadow: Color(0x1A1C1408),
    ),
  };
}

ThemeData _buildAppTheme(AppColorTheme theme) {
  final readerColors = _readerPalette(theme);
  final generatedScheme = ColorScheme.fromSeed(
    seedColor: readerColors.accent,
    brightness: readerColors.brightness,
  );
  final scheme = generatedScheme.copyWith(
    primary: readerColors.accent,
    primaryContainer: readerColors.accentSoft,
    onPrimaryContainer: generatedScheme.onSurface,
    surface: readerColors.surface,
    surfaceContainerLow: readerColors.surface,
    surfaceContainer: readerColors.surfaceAlt,
    surfaceContainerHigh: readerColors.surfaceAlt,
    surfaceContainerHighest: readerColors.surfaceAlt,
    outline: readerColors.border,
    outlineVariant: readerColors.border,
  );
  final base = ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: readerColors.appBackground,
    useMaterial3: true,
    fontFamily: _appFontFamily,
    extensions: [readerColors],
  );
  final textTheme = base.textTheme
      .copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 14,
          letterSpacing: 0,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          letterSpacing: 0,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          letterSpacing: 0,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
      )
      .apply(fontFamily: _appFontFamily, fontFamilyFallback: _appFontFallbacks);
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(7),
    borderSide: BorderSide(color: readerColors.border),
  );
  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: _appFontFamily,
      fontFamilyFallback: _appFontFallbacks,
    ),
    dividerTheme: DividerThemeData(
      color: readerColors.border,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: readerColors.surface,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(
        readerColors.accent.withValues(alpha: 0.45),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        textStyle: textTheme.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: textTheme.labelLarge,
        side: BorderSide(color: readerColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: textTheme.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        maximumSize: const Size(36, 36),
        padding: const EdgeInsets.all(7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: readerColors.editorFill,
      isDense: true,
      labelStyle: textTheme.bodyMedium,
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: base.colorScheme.onSurfaceVariant,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: readerColors.accent, width: 1.4),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: readerColors.surface,
      elevation: 4,
      shadowColor: readerColors.shadow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: readerColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: readerColors.surface,
      elevation: 4,
      shadowColor: readerColors.shadow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: readerColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(5),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: readerColors.accent,
      linearTrackColor: readerColors.accentSoft,
    ),
  );
}

class LibraryShell extends StatefulWidget {
  const LibraryShell({super.key});

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  final _extractionManager = ExtractionManager();
  LibraryPaperEntry? _activePaper;
  String? _activeWorkDir;
  String? _activeFolderId;
  String? _activeSelectedPaperId;
  double _activeListScrollOffset = 0;
  List<LibraryPaperEntry> _recentPapers = const [];

  @override
  void initState() {
    super.initState();
    _restoreActiveWorkDir();
  }

  Future<void> _restoreActiveWorkDir() async {
    final workDir = await LibraryPreferences.readWorkDir();
    if (!mounted || workDir == null || workDir.trim().isEmpty) {
      return;
    }
    setState(() {
      _activeWorkDir ??= workDir;
    });
  }

  void _openPaper(String workDir, LibraryPaperEntry paper) {
    final lastReadAt = DateTime.now().toUtc().toIso8601String();
    unawaited(
      LibraryStore(
        workDir,
      ).updatePaperFields(paper.id, {'lastReadAt': lastReadAt}),
    );
    setState(() {
      _activeWorkDir = workDir;
      _activeSelectedPaperId = paper.id;
      _activePaper = paper.copyWith(lastReadAt: lastReadAt);
    });
  }

  Future<void> _switchPaper(String paperId) async {
    final workDir = _activeWorkDir;
    if (workDir == null) {
      return;
    }
    final snapshot = await LibraryStore(workDir).load();
    final paper = _findPaperById(snapshot.papers, paperId);
    if (paper != null && mounted) {
      _recentPapers = _recentPapersFor(snapshot.papers, paper.id);
      _openPaper(workDir, paper);
    }
  }

  void _closePaper() {
    setState(() {
      _activePaper = null;
    });
  }

  @override
  void dispose() {
    _extractionManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paper = _activePaper;
    final workDir = _activeWorkDir;
    if (paper == null || workDir == null) {
      return LiteratureLibraryPage(
        initialWorkDir: workDir,
        initialFolderId: _activeFolderId,
        initialSelectedPaperId: _activeSelectedPaperId,
        initialListScrollOffset: _activeListScrollOffset,
        extractionManager: _extractionManager,
        onFolderChanged: (folderId) {
          if (_activeFolderId != folderId) {
            _activeListScrollOffset = 0;
          }
          _activeFolderId = folderId;
        },
        onSelectionChanged: (paperId) {
          _activeSelectedPaperId = paperId;
        },
        onListScrollChanged: (offset) {
          _activeListScrollOffset = offset;
        },
        onOpenPaper: (workDir, paper) {
          _activeSelectedPaperId = paper.id;
          _recentPapers = const [];
          _openPaper(workDir, paper);
        },
      );
    }

    if (_recentPapers.isEmpty) {
      unawaited(
        LibraryStore(workDir).load().then((snapshot) {
          if (!mounted) return;
          setState(() {
            _recentPapers = _recentPapersFor(snapshot.papers, paper.id);
          });
        }),
      );
    }

    final paperDir = LibraryStore.paperDir(workDir, paper.id);
    return PdfReaderPage(
      key: ValueKey(paper.id),
      pdfPath: _joinPath(paperDir, 'paper.pdf'),
      paperDir: paperDir,
      displayTitle: paper.displayTitle,
      workDir: workDir,
      paperId: paper.id,
      extractionManager: _extractionManager,
      onBack: _closePaper,
      recentPapers: _recentPapers,
      onSwitchPaper: _switchPaper,
    );
  }

  List<LibraryPaperEntry> _recentPapersFor(
    List<LibraryPaperEntry> papers,
    String currentId,
  ) {
    final sorted = [...papers]
      ..sort((a, b) {
        if (a.id == currentId) return -1;
        if (b.id == currentId) return 1;
        return (b.lastReadAt ?? '').compareTo(a.lastReadAt ?? '');
      });
    return sorted
        .where((paper) => paper.lastReadAt != null || paper.id == currentId)
        .take(10)
        .toList(growable: false);
  }
}

class LiteratureLibraryPage extends StatefulWidget {
  const LiteratureLibraryPage({
    super.key,
    this.initialWorkDir,
    this.initialFolderId,
    this.initialSelectedPaperId,
    this.initialListScrollOffset = 0,
    required this.extractionManager,
    required this.onFolderChanged,
    required this.onSelectionChanged,
    required this.onListScrollChanged,
    required this.onOpenPaper,
  });

  final String? initialWorkDir;
  final String? initialFolderId;
  final String? initialSelectedPaperId;
  final double initialListScrollOffset;
  final ExtractionManager extractionManager;
  final ValueChanged<String?> onFolderChanged;
  final ValueChanged<String?> onSelectionChanged;
  final ValueChanged<double> onListScrollChanged;
  final void Function(String workDir, LibraryPaperEntry paper) onOpenPaper;

  @override
  State<LiteratureLibraryPage> createState() => _LiteratureLibraryPageState();
}

class _LiteratureLibraryPageState extends State<LiteratureLibraryPage> {
  final _workDirController = TextEditingController();
  final _searchController = TextEditingController();
  late final ScrollController _paperListController;

  Future<LibrarySnapshot>? _snapshotFuture;
  LibrarySnapshot? _snapshot;
  LibraryPaperEntry? _selectedPaper;
  String? _currentFolderId;
  String _search = '';
  LibrarySortField _sortField = LibrarySortField.importedAt;
  var _sortDescending = true;
  var _importingPdfs = false;

  @override
  void initState() {
    super.initState();
    _paperListController = ScrollController(
      initialScrollOffset: widget.initialListScrollOffset,
    )..addListener(_rememberPaperListScroll);
    if (Platform.isWindows) {
      _windowsLibraryChannel.setMethodCallHandler(_handleWindowsLibraryMethod);
    }
    _restoreSortSettings();
    _currentFolderId = widget.initialFolderId;
    final initialWorkDir = widget.initialWorkDir?.trim();
    if (initialWorkDir != null && initialWorkDir.isNotEmpty) {
      _workDirController.text = initialWorkDir;
      unawaited(_loadWorkDir(savePreference: false));
    } else {
      _restoreSavedWorkDir();
    }
  }

  @override
  void didUpdateWidget(LiteratureLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initialWorkDir = widget.initialWorkDir?.trim();
    if (initialWorkDir == null ||
        initialWorkDir.isEmpty ||
        initialWorkDir == oldWidget.initialWorkDir ||
        initialWorkDir == _snapshot?.workDir) {
      return;
    }
    _workDirController.text = initialWorkDir;
    _currentFolderId = widget.initialFolderId;
    unawaited(_loadWorkDir(savePreference: false));
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _windowsLibraryChannel.setMethodCallHandler(null);
    }
    _paperListController
      ..removeListener(_rememberPaperListScroll)
      ..dispose();
    _workDirController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _rememberPaperListScroll() {
    if (_paperListController.hasClients) {
      widget.onListScrollChanged(_paperListController.offset);
    }
  }

  Future<Object?> _handleWindowsLibraryMethod(MethodCall call) async {
    if (call.method != 'filesDropped') {
      return null;
    }
    final paths =
        (call.arguments as List?)
            ?.map((value) => value.toString())
            .toList(growable: false) ??
        const <String>[];
    await _importPdfPaths(paths, source: '拖入');
    return null;
  }

  Future<void> _restoreSavedWorkDir() async {
    final saved = await LibraryPreferences.readWorkDir();
    if (!mounted || saved == null) {
      return;
    }
    _workDirController.text = saved;
    await _loadWorkDir(savePreference: false);
  }

  Future<void> _restoreSortSettings() async {
    final settings = await LibraryPreferences.readLibrarySortSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _sortField = settings.field;
      _sortDescending = settings.descending;
    });
  }

  Future<void> _loadWorkDir({bool savePreference = true}) async {
    final path = _workDirController.text.trim();
    if (path.isEmpty) {
      return;
    }
    if (savePreference) {
      await LibraryPreferences.saveWorkDir(path);
    }
    final future = LibraryStore(path).load();
    setState(() {
      _snapshotFuture = future;
      _snapshot = null;
      _selectedPaper = null;
    });
    try {
      final snapshot = await future;
      if (!mounted) {
        return;
      }
      final folderIds = snapshot.folders.map((folder) => folder.id).toSet();
      final restoredFolderId =
          _currentFolderId != null && folderIds.contains(_currentFolderId)
          ? _currentFolderId
          : null;
      final visiblePapers = restoredFolderId == null
          ? snapshot.papers
          : snapshot.papers
                .where((paper) => paper.folderId == restoredFolderId)
                .toList(growable: false);
      final restoredPaper = widget.initialSelectedPaperId == null
          ? null
          : _findPaperById(visiblePapers, widget.initialSelectedPaperId!);
      setState(() {
        _snapshot = snapshot;
        _currentFolderId = restoredFolderId;
        _selectedPaper =
            restoredPaper ??
            (visiblePapers.isEmpty ? null : visiblePapers.first);
      });
      widget.onFolderChanged(restoredFolderId);
      widget.onSelectionChanged(_selectedPaper?.id);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = null;
      });
    }
  }

  void _refresh() {
    if (_snapshot?.workDir != null) {
      _workDirController.text = _snapshot!.workDir;
    }
    _loadWorkDir();
  }

  Future<void> _reloadSnapshot({String? selectedPaperId}) async {
    final workDir = _snapshot?.workDir ?? _workDirController.text.trim();
    if (workDir.isEmpty) {
      return;
    }
    final snapshot = await LibraryStore(workDir).load();
    if (!mounted) {
      return;
    }
    final nextSelected = selectedPaperId == null
        ? _selectedPaper == null
              ? null
              : _findPaperById(snapshot.papers, _selectedPaper!.id)
        : _findPaperById(snapshot.papers, selectedPaperId);
    setState(() {
      _snapshot = snapshot;
      _selectedPaper = nextSelected;
    });
    widget.onSelectionChanged(nextSelected?.id);
  }

  Future<void> _renamePaper(
    LibrarySnapshot snapshot,
    LibraryPaperEntry paper,
    String chineseName,
  ) async {
    final normalized = chineseName.trim();
    final updated = paper.copyWith(
      chineseName: normalized,
      clearChineseName: normalized.isEmpty,
    );
    setState(() {
      final papers = [
        for (final item in snapshot.papers)
          if (item.id == paper.id) updated else item,
      ];
      final updatedSnapshot = LibrarySnapshot(
        workDir: snapshot.workDir,
        papers: papers,
        folders: snapshot.folders,
      );
      _snapshot = updatedSnapshot;
      if (_selectedPaper?.id == paper.id) {
        _selectedPaper = updated;
      }
    });

    try {
      await LibraryStore(
        snapshot.workDir,
      ).updateChineseName(paper.id, normalized);
    } catch (_) {}
  }

  void _updatePaperInSnapshot(LibraryPaperEntry updated) {
    final snapshot = _snapshot;
    if (snapshot == null || !mounted) {
      return;
    }
    final papers = [
      for (final paper in snapshot.papers)
        if (paper.id == updated.id) updated else paper,
    ];
    final updatedSnapshot = LibrarySnapshot(
      workDir: snapshot.workDir,
      papers: papers,
      folders: snapshot.folders,
    );
    setState(() {
      _snapshot = updatedSnapshot;
      if (_selectedPaper?.id == updated.id) {
        _selectedPaper = updated;
      }
    });
  }

  Future<void> _createFolder({String? parentId}) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    final name = await _promptText(
      context,
      title: '\u65b0\u5efa\u5206\u7c7b',
      hintText: '\u8f93\u5165\u5206\u7c7b\u540d\u79f0',
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }

    var targetParentId = parentId;
    if (targetParentId != null &&
        _folderDepth(snapshot.folders, targetParentId) >= 2) {
      targetParentId = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '\u5f53\u524d\u5206\u7c7b\u5df2\u662f\u7b2c\u4e09\u7ea7\uff0c\u5df2\u65b0\u5efa\u4e3a\u4e00\u7ea7\u5206\u7c7b',
            ),
          ),
        );
      }
    }

    final folder = await LibraryStore(
      snapshot.workDir,
    ).createFolder(name, parentId: targetParentId);
    await _reloadSnapshot();
    if (!mounted) {
      return;
    }
    setState(() {
      _currentFolderId = folder.id;
    });
    widget.onFolderChanged(folder.id);
  }

  Future<void> _deleteFolder(LibraryFolder folder) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    final ok = await _confirmDialog(
      context,
      title: '\u5220\u9664\u5206\u7c7b',
      message:
          '\u786e\u5b9a\u5220\u9664\u201c${folder.name}\u201d\u5417\uff1f\u5b50\u5206\u7c7b\u4f1a\u4e00\u5e76\u5220\u9664\uff0c\u5176\u4e2d\u7684\u6587\u732e\u4f1a\u79fb\u56de\u672a\u5206\u7c7b\u3002',
      confirmLabel: '\u5220\u9664',
      destructive: true,
    );
    if (!ok) {
      return;
    }
    final removedIds = await LibraryStore(
      snapshot.workDir,
    ).deleteFolder(folder.id);
    if (removedIds.contains(_currentFolderId)) {
      _currentFolderId = null;
      widget.onFolderChanged(null);
    }
    await _reloadSnapshot();
  }

  Future<void> _importPdfs() async {
    final snapshot = _snapshot;
    if (snapshot == null || _importingPdfs) {
      return;
    }
    final paths = await _pickPdfFilesWithSystemDialog(
      initialDirectory: snapshot.workDir,
    );
    if (paths.isEmpty) {
      return;
    }
    await _importPdfPaths(paths, source: '选择');
  }

  Future<void> _importPdfPaths(
    List<String> paths, {
    required String source,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null || _importingPdfs) {
      return;
    }
    final pdfPaths = paths
        .map((path) => path.trim())
        .where((path) => path.toLowerCase().endsWith('.pdf'))
        .toSet()
        .toList(growable: false);
    if (pdfPaths.isEmpty) {
      _showLibraryMessage('没有找到可导入的 PDF 文件');
      return;
    }

    final targetFolderId = _currentFolderId;
    setState(() {
      _importingPdfs = true;
    });
    try {
      final imported = await LibraryStore(
        snapshot.workDir,
      ).importPdfs(pdfPaths, folderId: targetFolderId);
      if (imported.isEmpty) {
        throw const FileSystemException('没有成功复制任何 PDF 文件');
      }
      await _reloadSnapshot(selectedPaperId: imported.first.id);
      if (!mounted) {
        return;
      }
      final folderName = targetFolderId == null
          ? '所有文献'
          : _findFolderById(snapshot.folders, targetFolderId)?.name ?? '当前分类';
      _showLibraryMessage('$source导入 ${imported.length} 篇文献，已归入“$folderName”');
    } catch (error) {
      _showLibraryMessage('导入失败：$error', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _importingPdfs = false;
        });
      }
    }
  }

  void _showLibraryMessage(String message, {bool error = false}) {
    if (!mounted) {
      return;
    }
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? colorScheme.error : null,
      ),
    );
  }

  Future<void> _deletePaper(LibraryPaperEntry paper) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    final ok = await _confirmDialog(
      context,
      title: '删除文献',
      message: '确定删除“${paper.displayTitle}”吗？该文献的 PDF、提取结果和笔记都会被删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) {
      return;
    }
    await LibraryStore(snapshot.workDir).deletePaper(paper.id);
    await _reloadSnapshot();
  }

  Future<void> _movePaperToFolder(
    LibraryPaperEntry paper,
    String? folderId,
  ) async {
    final snapshot = _snapshot;
    if (snapshot == null || paper.folderId == folderId) {
      return;
    }
    try {
      await LibraryStore(snapshot.workDir).movePaper(paper.id, folderId);
      if (!mounted) {
        return;
      }
      final updated = paper.copyWith(
        folderId: folderId,
        clearFolderId: folderId == null,
      );
      final updatedSnapshot = LibrarySnapshot(
        workDir: snapshot.workDir,
        papers: [
          for (final item in snapshot.papers)
            if (item.id == paper.id) updated else item,
        ],
        folders: snapshot.folders,
      );
      var nextSelected = _selectedPaper;
      if (_selectedPaper?.id == paper.id) {
        final movedOutOfCurrentFolder =
            _currentFolderId != null && folderId != _currentFolderId;
        final visible = _filteredPapers(updatedSnapshot);
        nextSelected = movedOutOfCurrentFolder
            ? (visible.isEmpty ? null : visible.first)
            : updated;
      }
      setState(() {
        _snapshot = updatedSnapshot;
        _selectedPaper = nextSelected;
      });
      widget.onSelectionChanged(nextSelected?.id);
      final targetName = folderId == null
          ? '所有文献'
          : _findFolderById(snapshot.folders, folderId)?.name ?? '目标分类';
      _showLibraryMessage('已将“${paper.displayTitle}”移动到“$targetName”');
    } catch (error) {
      _showLibraryMessage('移动失败：$error', error: true);
    }
  }

  Future<void> _openPaperFolder(LibraryPaperEntry paper) async {
    final snapshot = _snapshot;
    if (snapshot == null || !Platform.isWindows) {
      return;
    }
    final dir = LibraryStore.paperDir(snapshot.workDir, paper.id);
    try {
      await Process.start('explorer.exe', [dir]);
    } catch (_) {}
  }

  Future<void> _extractPaperFromLibrary(LibraryPaperEntry paper) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    var settings = await LibraryPreferences.readApiSettings();
    if (settings.mineruApiToken.trim().isEmpty) {
      await _openSettings();
      settings = await LibraryPreferences.readApiSettings();
      if (settings.mineruApiToken.trim().isEmpty) {
        return;
      }
    }
    if (!mounted) {
      return;
    }
    final ok = await _confirmDialog(
      context,
      title: '提取文献',
      message:
          '提取需要访问 MinerU 云端 API，会上传当前 PDF 并下载解析结果。\n\n'
          '开始前请关闭代理软件，否则可能导致上传或下载失败。\n\n'
          '确认开始吗？',
      confirmLabel: '开始提取',
    );
    if (!ok) {
      return;
    }

    unawaited(
      widget.extractionManager.start(
        workDir: snapshot.workDir,
        paperId: paper.id,
      ),
    );
  }

  Future<void> _openSettings() async {
    final current = await LibraryPreferences.readApiSettings();
    if (!mounted) {
      return;
    }
    final updated = await _showApiSettingsDialog(context, current);
    if (updated != null) {
      await LibraryPreferences.saveApiSettings(updated.apiSettings);
      await LibraryPreferences.saveReaderFontSettings(
        updated.readerFontSettings,
      );
      if (mounted) {
        await updated.applyTheme(context);
      }
    }
  }

  Future<void> _showJournalSearchDialog({String? initialQuery}) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _JournalSearchDialog(
        workDir: snapshot.workDir,
        initialQuery: initialQuery ?? '',
      ),
    );
  }

  List<LibraryFolderNode> _folderTree(List<LibraryFolder> folders) {
    final result = <LibraryFolderNode>[];
    void walk(String? parentId, int depth) {
      final children =
          folders.where((folder) => folder.parentId == parentId).toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      for (final folder in children) {
        result.add(LibraryFolderNode(folder: folder, depth: depth));
        if (depth < 2) {
          walk(folder.id, depth + 1);
        }
      }
    }

    walk(null, 0);
    return result;
  }

  List<LibraryPaperEntry> _filteredPapers(LibrarySnapshot snapshot) {
    final papers = snapshot.papers.where((paper) {
      if (_currentFolderId != null && paper.folderId != _currentFolderId) {
        return false;
      }
      return paper.matches(_search);
    }).toList();

    papers.sort((a, b) {
      final result = switch (_sortField) {
        LibrarySortField.importedAt => a.importedAt.compareTo(b.importedAt),
        LibrarySortField.title => a.displayTitle.compareTo(b.displayTitle),
        LibrarySortField.lastReadAt => (a.lastReadAt ?? '').compareTo(
          b.lastReadAt ?? '',
        ),
      };
      return _sortDescending ? -result : result;
    });

    return papers;
  }

  void _toggleSort(LibrarySortField field) {
    setState(() {
      if (_sortField == field) {
        _sortDescending = !_sortDescending;
      } else {
        _sortField = field;
        _sortDescending = true;
      }
    });
    unawaited(
      LibraryPreferences.saveLibrarySortSettings(
        LibrarySortSettings(field: _sortField, descending: _sortDescending),
      ),
    );
  }

  void _selectFolder(String? folderId) {
    setState(() {
      _currentFolderId = folderId;
      _selectedPaper = null;
    });
    widget.onFolderChanged(folderId);
    widget.onSelectionChanged(null);
  }

  void _openSelectedPaper(LibraryPaperEntry paper) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    widget.onSelectionChanged(paper.id);
    widget.onOpenPaper(snapshot.workDir, paper);
  }

  Future<void> _chooseWorkDir() async {
    final path = await _pickDirectoryWithSystemDialog(
      initialDirectory: _workDirController.text.trim(),
    );
    if (path == null || path.trim().isEmpty) {
      return;
    }
    _workDirController.text = path;
    await _loadWorkDir();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _LibraryHeader(
              loadedWorkDir: snapshot?.workDir,
              onChooseDirectory: _chooseWorkDir,
              onRefresh: snapshot == null ? null : _refresh,
              onOpenSettings: _openSettings,
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final loaded = _snapshot;
    if (loaded != null) {
      return _buildLoadedLibrary(loaded);
    }
    final future = _snapshotFuture;
    if (future == null) {
      return _LibrarySetupNotice(onChooseDirectory: _chooseWorkDir);
    }

    return FutureBuilder<LibrarySnapshot>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(width: 260, child: LinearProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: _StatusPanel(
              icon: Icons.folder_off_outlined,
              title: 'Library load failed',
              detail: snapshot.error.toString(),
            ),
          );
        }

        return _buildLoadedLibrary(snapshot.requireData);
      },
    );
  }

  Widget _buildLoadedLibrary(LibrarySnapshot data) {
    final filtered = _filteredPapers(data);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1080;
        final folderWidth = compact ? 180.0 : 210.0;
        final detailWidth = compact ? 290.0 : 330.0;
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: folderWidth,
                child: _RoundedPane(
                  child: _LibraryFolderPane(
                    folders: _folderTree(data.folders),
                    paperCount: data.papers.length,
                    currentFolderId: _currentFolderId,
                    onSelectFolder: _selectFolder,
                    onCreateRootFolder: () => _createFolder(),
                    onCreateSubFolder: (folder) =>
                        _createFolder(parentId: folder.id),
                    onDeleteFolder: _deleteFolder,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RoundedPane(
                  child: _LibraryPaperListPane(
                    papers: filtered,
                    folders: _folderTree(data.folders),
                    totalCount: data.papers.length,
                    workDir: data.workDir,
                    extractionManager: widget.extractionManager,
                    scrollController: _paperListController,
                    searchController: _searchController,
                    search: _search,
                    sortField: _sortField,
                    sortDescending: _sortDescending,
                    selectedPaperId: _selectedPaper?.id,
                    onSearchChanged: (value) => setState(() {
                      _search = value;
                    }),
                    onSort: _toggleSort,
                    onImport: _importPdfs,
                    onJournalSearch: () => _showJournalSearchDialog(),
                    onSelect: (paper) {
                      setState(() {
                        _selectedPaper = paper;
                      });
                      widget.onSelectionChanged(paper.id);
                    },
                    onRename: (paper, chineseName) =>
                        _renamePaper(data, paper, chineseName),
                    onOpen: _openSelectedPaper,
                    onDelete: _deletePaper,
                    onMove: _movePaperToFolder,
                    onExtract: _extractPaperFromLibrary,
                    onOpenFolder: _openPaperFolder,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: detailWidth,
                child: _RoundedPane(
                  child: _CachedLibraryDetailPane(
                    workDir: data.workDir,
                    folders: data.folders,
                    paper: _selectedPaper,
                    onPaperUpdated: _updatePaperInSnapshot,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoundedPane extends StatelessWidget {
  const _RoundedPane({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final readerColors = ReaderColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: readerColors.glass,
          border: Border.all(
            color: readerColors.border.withValues(alpha: 0.55),
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({
    required this.loadedWorkDir,
    required this.onChooseDirectory,
    required this.onRefresh,
    required this.onOpenSettings,
  });

  final String? loadedWorkDir;
  final VoidCallback onChooseDirectory;
  final VoidCallback? onRefresh;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final readerColors = ReaderColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: readerColors.glass,
        border: Border(bottom: BorderSide(color: readerColors.border)),
      ),
      child: SizedBox(
        height: 48,
        child: Stack(
          children: [
            const Positioned.fill(
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 980;
                  return Row(
                    children: [
                      Image.asset('assets/icon.png', width: 26, height: 26),
                      const SizedBox(width: 10),
                      Text(
                        _appDisplayName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Expanded(
                        child: DragToMoveArea(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 14),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                loadedWorkDir ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _ToolbarTextButton(
                        tooltip:
                            loadedWorkDir ??
                            '\u9009\u62e9\u6216\u66f4\u6362\u6587\u732e\u5b58\u50a8\u6587\u4ef6\u5939',
                        icon: Icons.folder_open_outlined,
                        label: loadedWorkDir == null
                            ? '\u9009\u62e9\u76ee\u5f55'
                            : '\u66f4\u6362\u76ee\u5f55',
                        compact: compact,
                        enabled: true,
                        onPressed: onChooseDirectory,
                      ),
                      _ToolbarIconButton(
                        tooltip: '\u5237\u65b0\u6587\u732e\u5e93',
                        icon: Icons.refresh,
                        enabled: onRefresh != null,
                        onPressed: onRefresh ?? () {},
                      ),
                      _ToolbarIconButton(
                        tooltip: 'API \u8bbe\u7f6e',
                        icon: Icons.settings_outlined,
                        enabled: true,
                        onPressed: onOpenSettings,
                      ),
                      const SizedBox(width: 4),
                      const _WindowControls(),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibrarySetupNotice extends StatelessWidget {
  const _LibrarySetupNotice({required this.onChooseDirectory});

  final VoidCallback onChooseDirectory;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icon.png', width: 64, height: 64),
            const SizedBox(height: 12),
            Text(
              _appDisplayName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            _StatusPanel(
              icon: Icons.folder_copy_outlined,
              title: '\u5f00\u59cb\u4f7f\u7528 Dualect',
              detail:
                  '\u8bf7\u9009\u62e9\u4e00\u4e2a\u6587\u4ef6\u5939\u7528\u4e8e\u5b58\u653e\u548c\u7ba1\u7406\u6587\u732e\u3002'
                  '\u9009\u62e9\u7a7a\u6587\u4ef6\u5939\u65f6\u4f1a\u81ea\u52a8\u521b\u5efa\u6240\u9700\u7684\u6570\u636e\u3002',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onChooseDirectory,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('\u9009\u62e9\u6587\u4ef6\u5939'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryFolderPane extends StatelessWidget {
  const _LibraryFolderPane({
    required this.folders,
    required this.paperCount,
    required this.currentFolderId,
    required this.onSelectFolder,
    required this.onCreateRootFolder,
    required this.onCreateSubFolder,
    required this.onDeleteFolder,
  });

  final List<LibraryFolderNode> folders;
  final int paperCount;
  final String? currentFolderId;
  final ValueChanged<String?> onSelectFolder;
  final VoidCallback onCreateRootFolder;
  final ValueChanged<LibraryFolder> onCreateSubFolder;
  final ValueChanged<LibraryFolder> onDeleteFolder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: Colors.transparent,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              '\u5206\u7c7b',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _FolderRow(
            label: '\u6240\u6709\u6587\u732e',
            icon: Icons.library_books_outlined,
            selected: currentFolderId == null,
            trailing: paperCount.toString(),
            onTap: () => onSelectFolder(null),
          ),
          const SizedBox(height: 6),
          for (final node in folders)
            _FolderRow(
              label: node.folder.name,
              icon: node.depth == 0
                  ? Icons.folder_outlined
                  : Icons.folder_copy_outlined,
              depth: node.depth,
              selected: node.folder.id == currentFolderId,
              onTap: () => onSelectFolder(node.folder.id),
              onCreateSubFolder: node.depth >= 2
                  ? null
                  : () => onCreateSubFolder(node.folder),
              onDeleteFolder: () => onDeleteFolder(node.folder),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onCreateRootFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('\u65b0\u5efa\u5206\u7c7b'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.depth = 0,
    this.trailing,
    this.onCreateSubFolder,
    this.onDeleteFolder,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final int depth;
  final String? trailing;
  final VoidCallback? onCreateSubFolder;
  final VoidCallback? onDeleteFolder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onSecondaryTapDown: onCreateSubFolder == null
            ? onDeleteFolder == null
                  ? null
                  : (details) => _showFolderContextMenu(
                      context,
                      details.globalPosition,
                      null,
                      onDeleteFolder!,
                    )
            : (details) => _showFolderContextMenu(
                context,
                details.globalPosition,
                onCreateSubFolder,
                onDeleteFolder,
              ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? ReaderColors.of(context).accentSoft : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(10.0 + depth * 18, 8, 8, 8),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: foreground),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showFolderContextMenu(
  BuildContext context,
  Offset position,
  VoidCallback? onCreateSubFolder,
  VoidCallback? onDeleteFolder,
) async {
  final selected = await showMenu<_FolderMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, 0),
    items: [
      if (onCreateSubFolder != null)
        const PopupMenuItem(
          value: _FolderMenuAction.createSubFolder,
          child: Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 18),
              SizedBox(width: 8),
              Text('\u65b0\u5efa\u5b50\u5206\u7c7b'),
            ],
          ),
        ),
      if (onDeleteFolder != null)
        const PopupMenuItem(
          value: _FolderMenuAction.deleteFolder,
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18),
              SizedBox(width: 8),
              Text('\u5220\u9664\u5206\u7c7b'),
            ],
          ),
        ),
    ],
  );
  if (selected == _FolderMenuAction.createSubFolder) {
    onCreateSubFolder?.call();
  } else if (selected == _FolderMenuAction.deleteFolder) {
    onDeleteFolder?.call();
  }
}

enum _FolderMenuAction { createSubFolder, deleteFolder }

class _LibraryPaperListPane extends StatelessWidget {
  const _LibraryPaperListPane({
    required this.papers,
    required this.folders,
    required this.totalCount,
    required this.workDir,
    required this.extractionManager,
    required this.scrollController,
    required this.searchController,
    required this.search,
    required this.sortField,
    required this.sortDescending,
    required this.selectedPaperId,
    required this.onSearchChanged,
    required this.onSort,
    required this.onImport,
    required this.onJournalSearch,
    required this.onSelect,
    required this.onRename,
    required this.onOpen,
    required this.onDelete,
    required this.onMove,
    required this.onExtract,
    required this.onOpenFolder,
  });

  final List<LibraryPaperEntry> papers;
  final List<LibraryFolderNode> folders;
  final int totalCount;
  final String workDir;
  final ExtractionManager extractionManager;
  final ScrollController scrollController;
  final TextEditingController searchController;
  final String search;
  final LibrarySortField sortField;
  final bool sortDescending;
  final String? selectedPaperId;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<LibrarySortField> onSort;
  final VoidCallback onImport;
  final VoidCallback onJournalSearch;
  final ValueChanged<LibraryPaperEntry> onSelect;
  final void Function(LibraryPaperEntry paper, String chineseName) onRename;
  final ValueChanged<LibraryPaperEntry> onOpen;
  final ValueChanged<LibraryPaperEntry> onDelete;
  final void Function(LibraryPaperEntry paper, String? folderId) onMove;
  final ValueChanged<LibraryPaperEntry> onExtract;
  final ValueChanged<LibraryPaperEntry> onOpenFolder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compactActions = constraints.maxWidth < 560;
                  return Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: searchController,
                          decoration: InputDecoration(
                            hintText:
                                '\u641c\u7d22\u6807\u9898\u3001\u4f5c\u8005\u3001\u671f\u520a...',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: onSearchChanged,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ToolbarTextButton(
                        tooltip: '\u5bfc\u5165',
                        icon: Icons.drive_folder_upload_outlined,
                        label: '\u5bfc\u5165',
                        compact: compactActions,
                        enabled: true,
                        onPressed: onImport,
                      ),
                      _ToolbarTextButton(
                        tooltip: '\u5206\u533a\u67e5\u8be2',
                        icon: Icons.stacked_bar_chart_outlined,
                        label: '\u5206\u533a\u67e5\u8be2',
                        compact: compactActions,
                        enabled: true,
                        onPressed: onJournalSearch,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _SortButton(
                    label: '\u5bfc\u5165',
                    active: sortField == LibrarySortField.importedAt,
                    descending: sortDescending,
                    compact: true,
                    onTap: () => onSort(LibrarySortField.importedAt),
                  ),
                  const SizedBox(width: 6),
                  _SortButton(
                    label: '\u6807\u9898',
                    active: sortField == LibrarySortField.title,
                    descending: sortDescending,
                    compact: true,
                    onTap: () => onSort(LibrarySortField.title),
                  ),
                  const SizedBox(width: 6),
                  _SortButton(
                    label: '\u9605\u8bfb',
                    active: sortField == LibrarySortField.lastReadAt,
                    descending: sortDescending,
                    compact: true,
                    onTap: () => onSort(LibrarySortField.lastReadAt),
                  ),
                  const Spacer(),
                  Text(
                    '${papers.length} / $totalCount \u7bc7\u6587\u732e',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 6),
        Expanded(
          child: papers.isEmpty
              ? const Center(
                  child: Text('\u6ca1\u6709\u5339\u914d\u7684\u6587\u732e'),
                )
              : ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  itemCount: papers.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 44, endIndent: 8),
                  itemBuilder: (context, index) {
                    final paper = papers[index];
                    return _LibraryPaperTile(
                      paper: paper,
                      folders: folders,
                      workDir: workDir,
                      extractionManager: extractionManager,
                      selected: paper.id == selectedPaperId,
                      onTap: () => onSelect(paper),
                      onRename: (chineseName) => onRename(paper, chineseName),
                      onOpen: () => onOpen(paper),
                      onDelete: () => onDelete(paper),
                      onMove: (folderId) => onMove(paper, folderId),
                      onExtract: () => onExtract(paper),
                      onOpenFolder: () => onOpenFolder(paper),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.label,
    required this.active,
    required this.descending,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final bool active;
  final bool descending;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _ToolbarButtonSurface(
      tooltip: '\u6309$label\u6392\u5e8f',
      active: active,
      onPressed: onTap,
      height: 26,
      minWidth: 0,
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            active
                ? (descending ? Icons.south : Icons.north)
                : Icons.swap_vert_outlined,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: _appFontFamily,
              fontFamilyFallback: _appFontFallbacks,
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryPaperTile extends StatefulWidget {
  const _LibraryPaperTile({
    required this.paper,
    required this.folders,
    required this.workDir,
    required this.extractionManager,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onOpen,
    required this.onDelete,
    required this.onMove,
    required this.onExtract,
    required this.onOpenFolder,
  });

  final LibraryPaperEntry paper;
  final List<LibraryFolderNode> folders;
  final String workDir;
  final ExtractionManager extractionManager;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onRename;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final ValueChanged<String?> onMove;
  final VoidCallback onExtract;
  final VoidCallback onOpenFolder;

  @override
  State<_LibraryPaperTile> createState() => _LibraryPaperTileState();
}

class _LibraryPaperTileState extends State<_LibraryPaperTile> {
  final _chineseNameController = TextEditingController();
  final _chineseNameFocusNode = FocusNode();
  var _editingChineseName = false;
  var _hovered = false;
  DateTime? _lastPrimaryTapAt;

  @override
  void didUpdateWidget(_LibraryPaperTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paper.id != widget.paper.id ||
        oldWidget.paper.chineseName != widget.paper.chineseName) {
      if (!_editingChineseName) {
        _chineseNameController.text = widget.paper.chineseName ?? '';
      }
    }
  }

  @override
  void dispose() {
    _chineseNameController.dispose();
    _chineseNameFocusNode.dispose();
    super.dispose();
  }

  void _startChineseNameEdit() {
    setState(() {
      _editingChineseName = true;
      _chineseNameController.text = widget.paper.chineseName ?? '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _chineseNameFocusNode.requestFocus();
      _chineseNameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _chineseNameController.text.length,
      );
    });
  }

  void _finishChineseNameEdit() {
    if (!_editingChineseName) {
      return;
    }
    final value = _chineseNameController.text.trim();
    setState(() {
      _editingChineseName = false;
    });
    if (value != (widget.paper.chineseName ?? '')) {
      widget.onRename(value);
    }
  }

  void _handlePrimaryTap() {
    widget.onTap();
    final now = DateTime.now();
    final previous = _lastPrimaryTapAt;
    if (previous != null &&
        now.difference(previous) <= const Duration(milliseconds: 420)) {
      _lastPrimaryTapAt = null;
      widget.onOpen();
      return;
    }
    _lastPrimaryTapAt = now;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final readerColors = ReaderColors.of(context);
    final active = widget.selected;
    final hovered = _hovered && !active;
    final fillColor = active
        ? readerColors.accentSoft
        : hovered
        ? readerColors.accentSoft.withValues(alpha: 0.52)
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() {
        _hovered = true;
      }),
      onExit: (_) => setState(() {
        _hovered = false;
      }),
      child: GestureDetector(
        onSecondaryTapDown: (details) => _showPaperContextMenu(
          context,
          details.globalPosition,
          folders: widget.folders,
          currentFolderId: widget.paper.folderId,
          onDelete: widget.onDelete,
          onMove: widget.onMove,
          onExtract: widget.onExtract,
          onOpenFolder: widget.onOpenFolder,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _handlePrimaryTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: fillColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Stack(
                children: [
                  if (active)
                    Positioned(
                      left: 0,
                      top: 8,
                      bottom: 8,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(11, 10, 8, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.picture_as_pdf_outlined,
                            color: widget.selected
                                ? colorScheme.primary
                                : colorScheme.error.withValues(alpha: 0.72),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.paper.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 5,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  AnimatedBuilder(
                                    animation: widget.extractionManager,
                                    builder: (context, _) {
                                      final paper = widget.extractionManager
                                          .mergePaper(
                                            widget.workDir,
                                            widget.paper,
                                          );
                                      return _StatusBadge(paper: paper);
                                    },
                                  ),
                                  _ChineseNameEditor(
                                    editing: _editingChineseName,
                                    controller: _chineseNameController,
                                    focusNode: _chineseNameFocusNode,
                                    chineseName: widget.paper.chineseName,
                                    onStartEdit: _startChineseNameEdit,
                                    onFinishEdit: _finishChineseNameEdit,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        AnimatedOpacity(
                          opacity: active || hovered ? 1 : 0.42,
                          duration: const Duration(milliseconds: 120),
                          child: IconButton(
                            tooltip: 'Open paper',
                            onPressed: widget.onOpen,
                            icon: const Icon(Icons.arrow_outward, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showPaperContextMenu(
  BuildContext context,
  Offset position, {
  required List<LibraryFolderNode> folders,
  required String? currentFolderId,
  required VoidCallback onDelete,
  required ValueChanged<String?> onMove,
  required VoidCallback onExtract,
  required VoidCallback onOpenFolder,
}) async {
  final selected = await showMenu<_PaperMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, 0),
    items: const [
      PopupMenuItem(
        value: _PaperMenuAction.move,
        child: Row(
          children: [
            Icon(Icons.drive_file_move_outline, size: 18),
            SizedBox(width: 8),
            Text('移动到分类'),
          ],
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        value: _PaperMenuAction.extract,
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined, size: 18),
            SizedBox(width: 8),
            Text('提取'),
          ],
        ),
      ),
      PopupMenuItem(
        value: _PaperMenuAction.openFolder,
        child: Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 18),
            SizedBox(width: 8),
            Text('打开文件目录'),
          ],
        ),
      ),
      PopupMenuItem(
        value: _PaperMenuAction.delete,
        child: Row(
          children: [
            Icon(Icons.delete_outline, size: 18),
            SizedBox(width: 8),
            Text('删除'),
          ],
        ),
      ),
    ],
  );
  switch (selected) {
    case _PaperMenuAction.move:
      if (!context.mounted) {
        return;
      }
      final folderId = await _showMovePaperMenu(
        context,
        position,
        folders: folders,
        currentFolderId: currentFolderId,
      );
      if (folderId != _movePaperMenuCancelled && folderId != currentFolderId) {
        onMove(folderId == _movePaperMenuAll ? null : folderId);
      }
    case _PaperMenuAction.extract:
      onExtract();
    case _PaperMenuAction.openFolder:
      onOpenFolder();
    case _PaperMenuAction.delete:
      onDelete();
    case null:
      return;
  }
}

const _movePaperMenuAll = '__all_papers__';
const _movePaperMenuCancelled = '__cancelled__';

Future<String> _showMovePaperMenu(
  BuildContext context,
  Offset position, {
  required List<LibraryFolderNode> folders,
  required String? currentFolderId,
}) async {
  final selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, 0),
    items: [
      const PopupMenuItem<String>(
        enabled: false,
        height: 34,
        child: Text('移动到分类'),
      ),
      const PopupMenuDivider(height: 1),
      PopupMenuItem<String>(
        value: _movePaperMenuAll,
        child: Row(
          children: [
            Icon(
              currentFolderId == null
                  ? Icons.check
                  : Icons.library_books_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('所有文献（移出分类）')),
          ],
        ),
      ),
      for (final node in folders)
        PopupMenuItem<String>(
          value: node.folder.id,
          child: Row(
            children: [
              SizedBox(width: node.depth * 16.0),
              Icon(
                node.folder.id == currentFolderId
                    ? Icons.check
                    : node.depth == 0
                    ? Icons.folder_outlined
                    : Icons.folder_copy_outlined,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  return selected ?? _movePaperMenuCancelled;
}

enum _PaperMenuAction { move, extract, openFolder, delete }

class _ChineseNameEditor extends StatelessWidget {
  const _ChineseNameEditor({
    required this.editing,
    required this.controller,
    required this.focusNode,
    required this.chineseName,
    required this.onStartEdit,
    required this.onFinishEdit,
  });

  final bool editing;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? chineseName;
  final VoidCallback onStartEdit;
  final VoidCallback onFinishEdit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (editing) {
      return SizedBox(
        width: 180,
        height: 30,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: Theme.of(context).textTheme.labelMedium,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            hintText: '\u8f93\u5165\u4e2d\u6587\u6807\u9898...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          ),
          onSubmitted: (_) => onFinishEdit(),
          onEditingComplete: onFinishEdit,
          onTapOutside: (_) => onFinishEdit(),
        ),
      );
    }

    final name = chineseName?.trim();
    final hasName = name != null && name.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onStartEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Text(
          hasName ? name : '\u6dfb\u52a0\u4e2d\u6587\u6807\u9898',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: hasName ? colorScheme.onSurfaceVariant : colorScheme.primary,
            fontStyle: hasName ? FontStyle.normal : FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

class _CachedLibraryDetailPane extends StatefulWidget {
  const _CachedLibraryDetailPane({
    required this.workDir,
    required this.folders,
    required this.paper,
    required this.onPaperUpdated,
  });

  final String workDir;
  final List<LibraryFolder> folders;
  final LibraryPaperEntry? paper;
  final ValueChanged<LibraryPaperEntry> onPaperUpdated;

  @override
  State<_CachedLibraryDetailPane> createState() =>
      _CachedLibraryDetailPaneState();
}

class _CachedLibraryDetailPaneState extends State<_CachedLibraryDetailPane> {
  final _fileSizeCache = <String, String>{};
  final _loadingPaperIds = <String>{};
  final _remarkMemoryCache = <String, String>{};
  final _remarkController = TextEditingController();
  final _doiController = TextEditingController();
  Timer? _remarkSaveTimer;
  String? _remarkPaperId;
  int _remarkLoadVersion = 0;
  var _settingRemarkText = false;
  bool _metadataLooking = false;
  String? _metadataMessage;
  LibraryPaperEntry? _displayPaper;

  @override
  void initState() {
    super.initState();
    _doiController.text = widget.paper?.doi ?? '';
    _remarkController.addListener(_onRemarkChanged);
    _displayPaper = widget.paper;
    _ensureDetailsLoaded();
  }

  @override
  void dispose() {
    _remarkSaveTimer?.cancel();
    _saveRemarkNow();
    _remarkController
      ..removeListener(_onRemarkChanged)
      ..dispose();
    _doiController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_CachedLibraryDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paper?.id != widget.paper?.id ||
        oldWidget.workDir != widget.workDir) {
      _remarkSaveTimer?.cancel();
      final oldPaperId = oldWidget.paper?.id;
      if (oldPaperId != null) {
        _saveRemarkNow(paperId: oldPaperId, workDir: oldWidget.workDir);
      }
      _doiController.text = widget.paper?.doi ?? '';
      _metadataMessage = null;
      _displayPaper = widget.paper;
      _ensureDetailsLoaded();
    } else if (oldWidget.paper?.doi != widget.paper?.doi) {
      _doiController.text = widget.paper?.doi ?? '';
      _displayPaper = widget.paper;
    }
  }

  Future<void> _ensureDetailsLoaded() async {
    final loadVersion = ++_remarkLoadVersion;
    final paper = widget.paper;
    if (paper == null) {
      _setRemarkText('', null);
      return;
    }

    if (!_loadingPaperIds.contains(paper.id) ||
        !_fileSizeCache.containsKey(paper.id)) {
      _loadingPaperIds.add(paper.id);
      final paperDir = LibraryStore.paperDir(widget.workDir, paper.id);
      final fileSize = await _readPdfSize(paperDir);

      if (!mounted ||
          loadVersion != _remarkLoadVersion ||
          widget.paper?.id != paper.id) {
        return;
      }
      setState(() {
        _fileSizeCache[paper.id] = fileSize;
        _loadingPaperIds.remove(paper.id);
      });
    }

    final paperDir = LibraryStore.paperDir(widget.workDir, paper.id);
    final remark = await _readRemark(paperDir);

    if (!mounted ||
        loadVersion != _remarkLoadVersion ||
        widget.paper?.id != paper.id) {
      return;
    }
    _setRemarkText(_remarkMemoryCache[paper.id] ?? remark, paper.id);
  }

  void _setRemarkText(String text, String? paperId) {
    _settingRemarkText = true;
    _remarkController.text = text;
    _remarkController.selection = TextSelection.collapsed(
      offset: _remarkController.text.length,
    );
    _remarkPaperId = paperId;
    _settingRemarkText = false;
  }

  void _onRemarkChanged() {
    if (_settingRemarkText || _remarkPaperId == null) {
      return;
    }
    _remarkMemoryCache[_remarkPaperId!] = _remarkController.text;
    _remarkSaveTimer?.cancel();
    _remarkSaveTimer = Timer(const Duration(milliseconds: 300), _saveRemarkNow);
  }

  Future<void> _saveRemarkNow({String? paperId, String? workDir}) async {
    final targetPaperId = paperId ?? _remarkPaperId;
    if (targetPaperId == null) {
      return;
    }
    if (_remarkPaperId != targetPaperId) {
      return;
    }
    final text = _remarkController.text;
    _remarkMemoryCache[targetPaperId] = text;
    final paperDir = LibraryStore.paperDir(
      workDir ?? widget.workDir,
      targetPaperId,
    );
    try {
      final file = File(_joinPath(paperDir, 'remark.md'));
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    } catch (_) {}
  }

  Future<void> _lookupMetadata() async {
    final paper = widget.paper;
    if (paper == null || _metadataLooking) {
      return;
    }
    setState(() {
      _metadataLooking = true;
      _metadataMessage = '\u6b63\u5728\u67e5\u627e DOI...';
    });

    try {
      var doi = ResearchMetadataService.normalizeDoi(_doiController.text);
      if (doi.isEmpty) {
        final pdfPath = _joinPath(
          LibraryStore.paperDir(widget.workDir, paper.id),
          'paper.pdf',
        );
        doi =
            await const ResearchMetadataService().extractDoiFromPdf(pdfPath) ??
            '';
      }
      if (doi.isEmpty) {
        throw const FormatException('\u672a\u5728 PDF \u4e2d\u627e\u5230 DOI');
      }
      if (mounted) {
        setState(() {
          _doiController.text = doi;
          _metadataMessage = '\u6b63\u5728\u67e5\u8be2\u5143\u6570\u636e...';
        });
      }

      final metadata = await const ResearchMetadataService().fetchMetadataByDoi(
        doi,
      );
      if (metadata == null) {
        throw const FormatException('DOI \u67e5\u8be2\u5931\u8d25');
      }

      var badges = <String>[];
      if (metadata.journal.trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _metadataMessage =
                '\u6b63\u5728\u67e5\u8be2\u671f\u520a\u5206\u533a...';
          });
        }
        try {
          final rows = await LocalResearchDatabase(
            widget.workDir,
          ).queryJournal(metadata.journal);
          badges = buildJournalBadges(rows);
        } catch (_) {}
      }

      await LibraryStore(widget.workDir).updatePaperFields(paper.id, {
        'doi': doi,
        'metaTitle': metadata.title,
        'metaAuthors': metadata.authors,
        'metaJournal': metadata.journal,
        'metaYear': metadata.year,
        'metaBadges': badges,
      });
      if (!mounted) {
        return;
      }
      final updatedPaper = paper.copyWith(
        doi: doi,
        metaTitle: metadata.title,
        metaAuthors: metadata.authors,
        metaJournal: metadata.journal,
        metaYear: metadata.year,
        metaBadges: badges,
      );
      widget.onPaperUpdated(updatedPaper);
      setState(() {
        _displayPaper = updatedPaper;
        _metadataLooking = false;
        _metadataMessage = '\u67e5\u8be2\u5b8c\u6210';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _metadataLooking = false;
        _metadataMessage = error.toString();
      });
    }
  }

  Future<void> _showJournalDetail(String journalName) async {
    final name = journalName.trim();
    if (name.isEmpty) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _JournalDetailDialog(workDir: widget.workDir, journalName: name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _displayPaper ?? widget.paper;
    if (selected == null) {
      return const Center(
        child: Text(
          '\u9009\u62e9\u4e00\u7bc7\u6587\u732e\u67e5\u770b\u8be6\u60c5',
        ),
      );
    }

    final fileSize = _fileSizeCache[selected.id] ?? '--';

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 24),
        children: [
          Text(
            '\u5907\u6ce8',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _RemarkEditor(controller: _remarkController),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _doiController,
                  decoration: InputDecoration(
                    labelText: 'DOI',
                    hintText:
                        '\u81ea\u52a8\u67e5\u627e\u6216\u624b\u52a8\u8f93\u5165',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onSubmitted: (_) => _lookupMetadata(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _metadataLooking ? null : _lookupMetadata,
                icon: const Icon(Icons.search, size: 17),
                label: Text(
                  _metadataLooking ? '\u67e5\u8be2\u4e2d' : '\u67e5\u627e',
                ),
              ),
            ],
          ),
          if (_metadataMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              _metadataMessage!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _metadataLooking
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '\u5143\u6570\u636e\u4e0e\u5206\u533a',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          _JournalPartitionSection(
            paper: selected,
            onShowJournalDetail: _showJournalDetail,
          ),
          const Divider(height: 24),
          Text(
            '\u6587\u4ef6\u4fe1\u606f',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          _DetailRow(
            label: '\u4e0a\u6b21\u9605\u8bfb',
            value: selected.lastReadAt == null
                ? '\u4ece\u672a'
                : _formatDateTime(selected.lastReadAt!),
          ),
          _DetailRow(
            label: '\u9875\u6570',
            value: selected.pageCount == null
                ? '--'
                : '${selected.pageCount} \u9875',
          ),
          _DetailRow(label: '\u6587\u4ef6\u5927\u5c0f', value: fileSize),
        ],
      ),
    );
  }

  static Future<String> _readPdfSize(String paperDir) async {
    try {
      final stat = await File(_joinPath(paperDir, 'paper.pdf')).stat();
      return _formatBytes(stat.size);
    } catch (_) {
      return '--';
    }
  }

  static Future<String> _readRemark(String paperDir) async {
    try {
      final file = File(_joinPath(paperDir, 'remark.md'));
      if (!await file.exists()) {
        return '';
      }
      return file.readAsString();
    } catch (_) {
      return '';
    }
  }
}

class _JournalPartitionSection extends StatelessWidget {
  const _JournalPartitionSection({
    required this.paper,
    required this.onShowJournalDetail,
  });

  final LibraryPaperEntry paper;
  final ValueChanged<String> onShowJournalDetail;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (paper.metaTitle?.trim().isNotEmpty == true)
          _DetailRow(
            label: '\u771f\u5b9e\u6807\u9898',
            value: paper.metaTitle!,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _DetailRow(
                label: '\u671f\u520a',
                value: paper.metaJournal ?? '--',
              ),
            ),
            if (paper.metaJournal?.trim().isNotEmpty == true)
              IconButton(
                tooltip: '\u67e5\u770b\u671f\u520a\u8be6\u60c5',
                onPressed: () => onShowJournalDetail(paper.metaJournal!),
                icon: const Icon(Icons.stacked_bar_chart_outlined, size: 18),
              ),
          ],
        ),
        _DetailRow(label: '\u5e74\u4efd', value: paper.metaYear ?? '--'),
        _DetailRow(label: '\u4f5c\u8005', value: paper.metaAuthors ?? '--'),
        const SizedBox(height: 6),
        if (paper.metaBadges.isEmpty)
          Text(
            '\u6682\u65e0\u5206\u533a\u4fe1\u606f',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final badge in paper.metaBadges) _JournalBadge(label: badge),
              Tooltip(
                message:
                    '\u5206\u533a\u4fe1\u606f\u6765\u6e90\u4e8e\u5df2\u4fdd\u5b58\u7684\u671f\u520a\u5143\u6570\u636e',
                child: Icon(
                  Icons.help_outline,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _JournalSearchDialog extends StatefulWidget {
  const _JournalSearchDialog({
    required this.workDir,
    required this.initialQuery,
  });

  final String workDir;
  final String initialQuery;

  @override
  State<_JournalSearchDialog> createState() => _JournalSearchDialogState();
}

class _JournalSearchDialogState extends State<_JournalSearchDialog> {
  late final TextEditingController _controller;
  List<String> _names = const [];
  List<JournalInfoRow> _details = const [];
  String? _selectedName;
  String? _error;
  bool _searching = false;
  bool _loadingDetails = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      return;
    }
    setState(() {
      _searching = true;
      _searched = false;
      _error = null;
      _selectedName = null;
      _details = const [];
      _names = const [];
    });
    try {
      final names = await LocalResearchDatabase(
        widget.workDir,
      ).searchJournalNames(query);
      if (!mounted) {
        return;
      }
      setState(() {
        _names = names;
        _searching = false;
        _searched = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _searching = false;
        _searched = true;
      });
    }
  }

  Future<void> _selectName(String name) async {
    setState(() {
      _selectedName = name;
      _loadingDetails = true;
      _details = const [];
      _error = null;
    });
    try {
      final details = await LocalResearchDatabase(
        widget.workDir,
      ).queryJournal(name);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
        _loadingDetails = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loadingDetails = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Column(
          children: [
            _DialogHeader(
              title: _selectedName == null
                  ? '\u671f\u520a\u5206\u533a\u67e5\u8be2'
                  : '\u671f\u520a\u8be6\u60c5',
              onClose: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText:
                            '\u8f93\u5165\u671f\u520a\u6216\u4f1a\u8bae\u540d\u79f0...',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _searching ? null : _search,
                    child: Text(
                      _searching ? '\u641c\u7d22\u4e2d' : '\u641c\u7d22',
                    ),
                  ),
                ],
              ),
            ),
            if (_searching || _loadingDetails)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
                child: _buildBody(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return _StatusPanel(
        icon: Icons.error_outline,
        title: '\u67e5\u8be2\u5931\u8d25',
        detail: _error!,
      );
    }
    if (_selectedName != null) {
      return _JournalDetailsList(rows: _details);
    }
    if (_searched && _names.isEmpty && !_searching) {
      return const Center(
        child: Text('\u672a\u627e\u5230\u5339\u914d\u7684\u671f\u520a'),
      );
    }
    if (!_searched) {
      return const Center(
        child: Text(
          '\u8f93\u5165\u671f\u520a\u6216\u4f1a\u8bae\u540d\u79f0\u540e\u70b9\u51fb\u641c\u7d22',
        ),
      );
    }
    return ListView.separated(
      itemCount: _names.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final name = _names[index];
        return ListTile(
          dense: true,
          title: Text(name),
          onTap: () => _selectName(name),
        );
      },
    );
  }
}

class _JournalDetailDialog extends StatelessWidget {
  const _JournalDetailDialog({
    required this.workDir,
    required this.journalName,
  });

  final String workDir;
  final String journalName;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Column(
          children: [
            _DialogHeader(
              title: '\u671f\u520a\u8be6\u7ec6\u4fe1\u606f - $journalName',
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: FutureBuilder<List<JournalInfoRow>>(
                future: LocalResearchDatabase(
                  workDir,
                ).queryJournal(journalName),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 220,
                        child: LinearProgressIndicator(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _StatusPanel(
                      icon: Icons.error_outline,
                      title: '\u67e5\u8be2\u5931\u8d25',
                      detail: snapshot.error.toString(),
                    );
                  }
                  final rows = snapshot.data ?? const [];
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text(
                        '\u672a\u627e\u5230\u8be5\u671f\u520a\u7684\u4fe1\u606f',
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(18),
                    child: _JournalDetailsList(rows: rows),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '\u5173\u95ed',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _JournalDetailsList extends StatelessWidget {
  const _JournalDetailsList({required this.rows});

  final List<JournalInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Center(
        child: Text('\u672a\u627e\u5230\u8be5\u671f\u520a\u7684\u4fe1\u606f'),
      );
    }
    return ListView.separated(
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Text(
            '\u5206\u533a\u6570\u636e\u6765\u6e90\u4e8e\u516c\u5f00\u6570\u636e\u5e93\uff08JCR\u3001\u4e2d\u79d1\u9662\u3001CCF\u7b49\uff09\uff0c\u4ec5\u4f9b\u53c2\u8003\u3002',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        final row = rows[index];
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withAlpha(80),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _journalTableLabel(row.table),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (final field in row.fields)
                  _DetailRow(label: field.label, value: field.value),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _journalTableLabel(String table) {
  return switch (table) {
    'JCR2024' => 'JCR 2024',
    'JCR2023' => 'JCR 2023',
    'FQBJCR2025' => '\u4e2d\u79d1\u9662\u5206\u533a\u8868 2025',
    'CCF2026' => 'CCF \u63a8\u8350\u671f\u520a 2026',
    'CCFT2025' => 'CCF \u4e2d\u6587\u671f\u520a 2025',
    'XR2026' => '\u65b0\u9510\u671f\u520a\u5206\u533a 2026',
    'XR2026Conferences' => '\u65b0\u9510\u4f1a\u8bae 2026',
    'GJQKYJMD2025' => '\u56fd\u9645\u9884\u8b66\u671f\u520a 2025',
    'GJQKYJMD2024' => '\u56fd\u9645\u9884\u8b66\u671f\u520a 2024',
    _ => table,
  };
}

class _RemarkEditor extends StatelessWidget {
  const _RemarkEditor({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final readerColors = ReaderColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: readerColors.surfaceAlt,
        border: Border.all(color: readerColors.border.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 440, minHeight: 192),
        child: TextField(
          controller: controller,
          maxLines: null,
          minLines: 5,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            hintText: '\u5728\u6b64\u4e66\u5199\u6587\u732e\u5907\u6ce8...',
            filled: true,
            fillColor: readerColors.surfaceAlt,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.all(12),
          ),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.paper});

  final LibraryPaperEntry paper;

  @override
  Widget build(BuildContext context) {
    final status = paper.extractStatus;
    final progress = paper.extractProgress?.clamp(0, 0.99);
    final normalized = switch (status) {
      'done' => ('已提取', const Color(0xFF2E7D32)),
      'pending_read' => ('提取完成', const Color(0xFF2E7D32)),
      'extracting' when progress != null => (
        '提取中 ${(progress * 100).round()}%',
        const Color(0xFF1565C0),
      ),
      'extracting' => ('提取中', const Color(0xFF1565C0)),
      _ when (paper.extractMessage ?? '').startsWith('提取失败') => (
        '提取失败',
        const Color(0xFFC62828),
      ),
      _ => ('未提取', const Color(0xFFE65100)),
    };

    final badge = _TinyBadge(label: normalized.$1, color: normalized.$2);
    if (status == 'done') {
      return badge;
    }
    final message = paper.extractMessage?.trim();
    if (message == null || message.isEmpty) {
      return badge;
    }
    return Tooltip(message: message, child: badge);
  }
}

class _JournalBadge extends StatelessWidget {
  const _JournalBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _TinyBadge(label: label, color: _badgeColor(label));
  }
}

class _TinyBadge extends StatelessWidget {
  const _TinyBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withAlpha(32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({
    super.key,
    required this.pdfPath,
    required this.paperDir,
    this.displayTitle,
    this.workDir,
    this.paperId,
    this.extractionManager,
    this.onBack,
    this.recentPapers = const [],
    this.onSwitchPaper,
  });

  final String pdfPath;
  final String paperDir;
  final String? displayTitle;
  final String? workDir;
  final String? paperId;
  final ExtractionManager? extractionManager;
  final VoidCallback? onBack;
  final List<LibraryPaperEntry> recentPapers;
  final ValueChanged<String>? onSwitchPaper;

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  late final PdfViewerController _controller;
  late final bool _pdfExists;
  final _contentPanelKey = GlobalKey<_MineruContentPanelState>();
  final _notePanelKey = GlobalKey<_MarkdownNotePanelState>();

  int? _currentPage;
  int? _pageCount;
  MineruContentItem? _activeContentItem;
  MineruPaper? _paper;
  PdfContentLinkMode _linkMode = PdfContentLinkMode.zoom;
  double _pdfPaneFraction = 0.55;
  double _notesPaneFraction = 0.32;
  bool _pdfVisible = true;
  bool _notesVisible = false;
  bool _viewerReady = false;
  bool _fitWidthOnReady = true;
  bool _pdfViewerMounted = false;
  int _pdfViewerGeneration = 0;
  int _pdfInitialReloadAttempts = 0;
  Timer? _pdfReadyWatchdog;
  bool _showExtractionDetails = false;
  bool _dictionaryVisible = false;
  Offset _dictionaryPosition = const Offset(220, 80);
  String _dictionaryQuery = '';
  List<DictionaryEntry> _dictionaryResults = const [];
  String? _dictionaryError;
  bool _dictionaryLoading = false;
  bool _pageCountPersisted = false;
  bool _pdfHasTextSelection = false;
  bool _dictionaryPanelVisible = false;
  double _bodyFontSize = 14;
  double _translationFontSize = 13;
  ReaderFontPreset _fontPreset = ReaderFontPreset.comfortable;
  double? _initialContentScrollTop;
  int? _initialContentIndex;
  final List<String> _pendingNoteAppends = [];

  @override
  void initState() {
    super.initState();
    _controller = PdfViewerController()..addListener(_onViewerChanged);
    _pdfExists = File(widget.pdfPath).existsSync();
    _loadReaderFontSettings();
    _loadReadingPosition();
  }

  @override
  void dispose() {
    unawaited(_saveReadingPosition());
    _pdfReadyWatchdog?.cancel();
    _controller.removeListener(_onViewerChanged);
    super.dispose();
  }

  Future<void> _loadReadingPosition() async {
    try {
      Map<dynamic, dynamic>? decoded;
      final workDir = widget.workDir;
      final paperId = widget.paperId;
      if (workDir != null && paperId != null) {
        final rootFile = File(_joinPath(workDir, 'scroll_positions.json'));
        if (await rootFile.exists()) {
          final rootDecoded = jsonDecode(await rootFile.readAsString());
          if (rootDecoded is Map) {
            final saved = rootDecoded[paperId];
            if (saved is Map) {
              decoded = saved;
            } else if (saved is num) {
              decoded = {'ci': saved.toInt(), 'top': 0};
            }
          }
        }
      }

      if (decoded == null) {
        final file = File(_joinPath(widget.paperDir, 'reader-position.json'));
        if (await file.exists()) {
          final paperDecoded = jsonDecode(await file.readAsString());
          if (paperDecoded is Map) {
            decoded = paperDecoded;
          }
        }
      }

      if (!mounted || decoded == null) {
        return;
      }
      final top =
          _readDouble(decoded['top']) ?? _readDouble(decoded['contentTop']);
      final index =
          _readInt(decoded['ci']) ?? _readInt(decoded['contentIndex']);
      setState(() {
        _initialContentScrollTop = top;
        _initialContentIndex = index;
      });
    } catch (_) {}
  }

  Future<void> _saveReadingPosition() async {
    try {
      final contentPosition = await _contentPanelKey.currentState
          ?.captureScrollPosition();
      if (contentPosition == null ||
          ((contentPosition.contentIndex ?? -1) < 0 &&
              contentPosition.top <= 0)) {
        return;
      }
      final data = <String, Object?>{
        'contentTop': contentPosition.top,
        'contentIndex': contentPosition.contentIndex,
        'pdfPage': _currentPage,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      };
      final file = File(_joinPath(widget.paperDir, 'reader-position.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
      final workDir = widget.workDir;
      final paperId = widget.paperId;
      if (workDir != null && paperId != null) {
        final rootFile = File(_joinPath(workDir, 'scroll_positions.json'));
        var all = <String, dynamic>{};
        if (await rootFile.exists()) {
          try {
            final decoded = jsonDecode(await rootFile.readAsString());
            if (decoded is Map) {
              all = decoded.map(
                (key, value) => MapEntry(key.toString(), value),
              );
            }
          } catch (_) {}
        }
        all[paperId] = {
          'ci': contentPosition.contentIndex ?? -1,
          'top': contentPosition.top,
        };
        await rootFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(all),
        );
      }
    } catch (_) {}
  }

  Future<void> _handleReaderBack() async {
    await _saveReadingPosition();
    if (!mounted) {
      return;
    }
    widget.onBack?.call();
  }

  Future<void> _switchRecentPaper(String paperId) async {
    await _saveReadingPosition();
    if (!mounted) {
      return;
    }
    widget.onSwitchPaper?.call(paperId);
  }

  bool get _pdfControlsEnabled =>
      _pdfVisible && _viewerReady && _controller.isReady;

  double? get _toolbarZoom =>
      _pdfControlsEnabled ? _controller.currentZoom : null;

  void _togglePdfVisible() {
    setState(() {
      _pdfVisible = !_pdfVisible;
      _viewerReady = false;
      if (_pdfVisible) {
        _fitWidthOnReady = true;
        _pdfViewerMounted = false;
        _pdfInitialReloadAttempts = 0;
        _pdfViewerGeneration += 1;
      } else {
        _pdfReadyWatchdog?.cancel();
      }
    });
  }

  void _onViewerChanged() {
    if (!mounted || !_pdfControlsEnabled) {
      return;
    }
    setState(() {});
  }

  void _handleViewerReady(
    PdfDocument document,
    PdfViewerController controller,
  ) {
    if (!mounted) {
      return;
    }
    _pdfReadyWatchdog?.cancel();
    setState(() {
      _viewerReady = true;
      _pageCount = controller.pageCount;
      _currentPage = controller.pageNumber ?? 1;
    });
    _persistPageCount(controller.pageCount);

    if (_fitWidthOnReady) {
      _fitWidthOnReady = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _fitWidth();
        }
      });
    }
  }

  void _schedulePdfViewerMount() {
    if (_pdfViewerMounted || !_pdfExists) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (!mounted || _pdfViewerMounted || !_pdfExists) {
        return;
      }
      setState(() {
        _pdfViewerMounted = true;
      });
      _startPdfReadyWatchdog();
    });
  }

  void _startPdfReadyWatchdog() {
    _pdfReadyWatchdog?.cancel();
    _pdfReadyWatchdog = Timer(const Duration(seconds: 2), () {
      if (!mounted || _viewerReady || !_pdfExists || !_pdfViewerMounted) {
        return;
      }
      if (_pdfInitialReloadAttempts >= 2) {
        return;
      }
      setState(() {
        _pdfInitialReloadAttempts += 1;
        _pdfViewerGeneration += 1;
        _viewerReady = false;
        _fitWidthOnReady = true;
      });
      _startPdfReadyWatchdog();
    });
  }

  void _persistPageCount(int pageCount) {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (_pageCountPersisted ||
        workDir == null ||
        paperId == null ||
        pageCount <= 0) {
      return;
    }
    _pageCountPersisted = true;
    unawaited(
      LibraryStore(
        workDir,
      ).updatePaperFields(paperId, {'pageCount': pageCount}),
    );
  }

  Future<void> _loadReaderFontSettings() async {
    final settings = await LibraryPreferences.readReaderFontSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _bodyFontSize = settings.bodyFontSize.clamp(10, 24).toDouble();
      _translationFontSize = settings.translationFontSize
          .clamp(10, 24)
          .toDouble();
      _fontPreset = settings.preset;
    });
  }

  void _applyReaderFontSettings(ReaderFontSettings settings) {
    if (!mounted) {
      return;
    }
    setState(() {
      _bodyFontSize = settings.bodyFontSize.clamp(10, 24).toDouble();
      _translationFontSize = settings.translationFontSize
          .clamp(10, 24)
          .toDouble();
      _fontPreset = settings.preset;
    });
  }

  void _adjustBodyFont(double delta) {
    final next = (_bodyFontSize + delta).clamp(10, 24).toDouble();
    if (next == _bodyFontSize) {
      return;
    }
    setState(() {
      _bodyFontSize = next;
    });
    _saveReaderFontSettings();
  }

  void _adjustTranslationFont(double delta) {
    final next = (_translationFontSize + delta).clamp(10, 24).toDouble();
    if (next == _translationFontSize) {
      return;
    }
    setState(() {
      _translationFontSize = next;
    });
    _saveReaderFontSettings();
  }

  void _saveReaderFontSettings() {
    unawaited(
      LibraryPreferences.saveReaderFontSettings(
        ReaderFontSettings(
          bodyFontSize: _bodyFontSize,
          translationFontSize: _translationFontSize,
          preset: _fontPreset,
        ),
      ),
    );
  }

  void _handlePageChanged(int? pageNumber) {
    if (!mounted) {
      return;
    }
    setState(() {
      _currentPage = pageNumber;
    });
  }

  void _handlePdfTextSelectionChanged(PdfTextSelection selection) {
    final hasSelection = selection.hasSelectedText;
    if (_pdfHasTextSelection == hasSelection) {
      return;
    }
    setState(() {
      _pdfHasTextSelection = hasSelection;
    });
  }

  Future<void> _handleContentBlockSelected(MineruContentItem item) async {
    if (!mounted) {
      return;
    }
    if (_linkMode == PdfContentLinkMode.none) {
      return;
    }
    setState(() {
      _activeContentItem = item;
    });

    final pageIndex = item.pageIndex;
    if (!_viewerReady ||
        !_pdfVisible ||
        !_controller.isReady ||
        pageIndex == null ||
        pageIndex < 0 ||
        pageIndex >= _controller.pageCount) {
      return;
    }

    final pageNumber = pageIndex + 1;

    final rect = item.toPdfRect(_controller.pages[pageIndex]);
    if (rect != null) {
      final documentRect = _controller.calcRectForRectInsidePage(
        pageNumber: pageNumber,
        rect: rect,
      );
      final zoom = _linkMode == PdfContentLinkMode.zoom
          ? _zoomForLinkedRect(documentRect)
          : _controller.currentZoom;
      await _controller.goTo(
        _controller.calcMatrixFor(documentRect.center, zoom: zoom),
      );
      return;
    }

    await _controller.goToPage(
      pageNumber: pageNumber,
      anchor: PdfPageAnchor.top,
    );
  }

  bool _handlePdfTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (details.type != PdfViewerGeneralTapType.tap ||
        !_pdfVisible ||
        !_viewerReady ||
        !_controller.isReady) {
      return false;
    }

    if (_pdfHasTextSelection) {
      unawaited(controller.textSelectionDelegate.clearTextSelection());
      setState(() {
        _pdfHasTextSelection = false;
      });
      return true;
    }

    if (_linkMode == PdfContentLinkMode.none) {
      return false;
    }

    final item = _findContentItemAtDocumentPosition(details.documentPosition);
    if (item == null) {
      if (_activeContentItem != null) {
        setState(() {
          _activeContentItem = null;
        });
      }
      return false;
    }

    setState(() {
      _activeContentItem = item;
    });
    _contentPanelKey.currentState?.scrollToBlock(item.contentIndex);
    return true;
  }

  MineruContentItem? _findContentItemAtDocumentPosition(Offset position) {
    final paper = _paper;
    if (paper == null || !_controller.isReady) {
      return null;
    }

    MineruContentItem? bestItem;
    var bestArea = double.infinity;
    for (final item in paper.items) {
      final pageIndex = item.pageIndex;
      if (pageIndex == null ||
          pageIndex < 0 ||
          pageIndex >= _controller.pageCount) {
        continue;
      }

      final rect = item.toPdfRect(_controller.pages[pageIndex]);
      if (rect == null) {
        continue;
      }

      final documentRect = _controller.calcRectForRectInsidePage(
        pageNumber: pageIndex + 1,
        rect: rect,
      );
      final hitRect = documentRect.inflate(3 / _controller.currentZoom);
      if (!hitRect.contains(position)) {
        continue;
      }

      final area = documentRect.width * documentRect.height;
      if (area < bestArea) {
        bestArea = area;
        bestItem = item;
      }
    }

    return bestItem;
  }

  double _zoomForLinkedRect(Rect documentRect) {
    if (documentRect.width <= 0) {
      return _controller.currentZoom;
    }

    final targetZoom = _controller.viewSize.width * 0.9 / documentRect.width;
    return targetZoom
        .clamp(_controller.minScale, _controller.maxScale)
        .toDouble();
  }

  Future<void> _zoomIn() async {
    if (!_pdfControlsEnabled) {
      return;
    }
    final next = (_controller.currentZoom * 1.12)
        .clamp(_controller.minScale, _controller.maxScale)
        .toDouble();
    await _controller.setZoom(
      _controller.centerPosition,
      next,
      duration: const Duration(milliseconds: 120),
    );
  }

  Future<void> _zoomOut() async {
    if (!_pdfControlsEnabled) {
      return;
    }
    final next = (_controller.currentZoom / 1.12)
        .clamp(_controller.minScale, _controller.maxScale)
        .toDouble();
    await _controller.setZoom(
      _controller.centerPosition,
      next,
      duration: const Duration(milliseconds: 120),
    );
  }

  Future<void> _fitWidth() async {
    if (!_pdfControlsEnabled) {
      return;
    }

    final pageNumber = _currentPage ?? _controller.pageNumber ?? 1;
    final matrix = _controller.calcMatrixFitWidthForPage(
      pageNumber: pageNumber,
    );
    await _controller.goTo(matrix);
  }

  Future<void> _resetZoom() async {
    if (!_pdfControlsEnabled) {
      return;
    }

    await _controller.setZoom(_controller.centerPosition, 1);
  }

  Future<void> _openSettings() async {
    final current = await LibraryPreferences.readApiSettings();
    if (!mounted) {
      return;
    }
    final updated = await _showApiSettingsDialog(
      context,
      current,
      initialReaderFontSettings: ReaderFontSettings(
        bodyFontSize: _bodyFontSize,
        translationFontSize: _translationFontSize,
        preset: _fontPreset,
      ),
    );
    if (updated != null) {
      await LibraryPreferences.saveApiSettings(updated.apiSettings);
      await LibraryPreferences.saveReaderFontSettings(
        updated.readerFontSettings,
      );
      if (mounted) {
        _applyReaderFontSettings(updated.readerFontSettings);
        await updated.applyTheme(context);
      }
    }
  }

  Future<void> _lookupDictionarySelection(
    String word,
    Offset position, {
    bool panel = false,
  }) async {
    final normalized = _normalizeLookupWord(word);
    if (normalized.isEmpty) {
      return;
    }
    final workDir = widget.workDir;
    if (workDir == null || workDir.trim().isEmpty) {
      _showSnack('\u672a\u8bbe\u7f6e\u5de5\u4f5c\u76ee\u5f55');
      return;
    }

    setState(() {
      _dictionaryVisible = !panel;
      _dictionaryPanelVisible = panel;
      if (!panel) {
        _dictionaryPosition = position;
      }
      _dictionaryQuery = normalized;
      _dictionaryResults = const [];
      _dictionaryError = null;
      _dictionaryLoading = true;
    });

    try {
      final results = await LocalResearchDatabase(
        workDir,
      ).lookupWord(normalized);
      if (!mounted) {
        return;
      }
      setState(() {
        _dictionaryResults = results;
        _dictionaryLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dictionaryError = error.toString();
        _dictionaryLoading = false;
      });
    }
  }

  void _openDictionaryPanel() {
    final workDir = widget.workDir;
    if (workDir == null || workDir.trim().isEmpty) {
      _showSnack('\u672a\u8bbe\u7f6e\u5de5\u4f5c\u76ee\u5f55');
      return;
    }
    setState(() {
      _dictionaryVisible = false;
      _dictionaryPanelVisible = true;
      _dictionaryPosition = Offset.zero;
      _dictionaryQuery = '';
      _dictionaryResults = const [];
      _dictionaryError = null;
      _dictionaryLoading = false;
    });
  }

  void _hideDictionaryPopup() {
    if ((!_dictionaryVisible && !_dictionaryPanelVisible) || !mounted) {
      return;
    }
    setState(() {
      _dictionaryVisible = false;
      _dictionaryPanelVisible = false;
    });
  }

  Future<void> _extractCurrentPaper() async {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (workDir == null || paperId == null) {
      return;
    }

    var settings = await LibraryPreferences.readApiSettings();
    if (settings.mineruApiToken.trim().isEmpty) {
      await _openSettings();
      settings = await LibraryPreferences.readApiSettings();
      if (settings.mineruApiToken.trim().isEmpty) {
        return;
      }
    }

    if (!mounted) {
      return;
    }
    final ok = await _confirmDialog(
      context,
      title: '\u63d0\u53d6\u6587\u732e',
      message:
          '提取需要访问 MinerU 云端 API，会上传当前 PDF 并下载解析结果。\n\n'
          '开始前请关闭代理软件，否则可能导致上传或下载失败。\n\n'
          '确认开始吗？',
      confirmLabel: '\u5f00\u59cb\u63d0\u53d6',
    );
    if (!ok) {
      return;
    }

    setState(() {
      _showExtractionDetails = true;
    });
    unawaited(
      widget.extractionManager?.start(workDir: workDir, paperId: paperId),
    );
  }

  void _cancelCurrentExtraction() {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (workDir == null || paperId == null) {
      return;
    }
    widget.extractionManager?.cancel(workDir, paperId);
  }

  double _getPageRenderingScale(
    BuildContext _,
    PdfPage page,
    PdfViewerController _,
    double estimatedScale,
  ) {
    final longestPageSide = math.max(page.width, page.height);
    final cappedScale = _pdfPreviewMaxSide / longestPageSide;

    return math.min(estimatedScale, cappedScale);
  }

  @override
  Widget build(BuildContext context) {
    final pdfFile = File(widget.pdfPath);
    final title = widget.displayTitle?.trim().isNotEmpty == true
        ? widget.displayTitle!.trim()
        : pdfFile.uri.pathSegments.last;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              _ReaderToolbar(
                pdfVisible: _pdfVisible,
                notesVisible: _notesVisible,
                onBack: widget.onBack == null ? null : _handleReaderBack,
                onTogglePdf: _togglePdfVisible,
                onToggleNotes: () => setState(() {
                  _notesVisible = !_notesVisible;
                }),
                onBatchTranslate: widget.paperId == null
                    ? null
                    : () => _contentPanelKey.currentState
                          ?.translateSelectedItems(),
                onExtract: widget.paperId == null ? null : _extractCurrentPaper,
                onOpenSettings: _openSettings,
                onDictionary: _openDictionaryPanel,
                onBodyFontDec: () => _adjustBodyFont(-1),
                onBodyFontInc: () => _adjustBodyFont(1),
                onTransFontDec: () => _adjustTranslationFont(-1),
                onTransFontInc: () => _adjustTranslationFont(1),
                linkMode: _linkMode,
                onLinkModeChanged: (mode) {
                  setState(() {
                    _linkMode = mode;
                    if (mode == PdfContentLinkMode.none) {
                      _activeContentItem = null;
                    }
                  });
                },
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final devicePixelRatio = MediaQuery.devicePixelRatioOf(
                      context,
                    );
                    final panePadding = _snapToPhysicalPixel(
                      8,
                      devicePixelRatio,
                    );
                    final dividerWidth = _snapToPhysicalPixel(
                      8,
                      devicePixelRatio,
                    );
                    final innerMaxWidth = math.max(
                      0.0,
                      constraints.maxWidth - panePadding * 2,
                    );
                    final pdfDivider = _pdfVisible ? dividerWidth : 0.0;
                    final availableWidth = math.max(
                      0.0,
                      innerMaxWidth - pdfDivider,
                    );
                    final minPaneWidth = math.min(
                      _snapToPhysicalPixel(320, devicePixelRatio),
                      _floorToPhysicalPixel(
                        availableWidth / 2,
                        devicePixelRatio,
                      ),
                    );
                    final pdfPaneWidth = _pdfVisible
                        ? _snapToPhysicalPixel(
                                availableWidth * _pdfPaneFraction,
                                devicePixelRatio,
                              )
                              .clamp(
                                minPaneWidth,
                                availableWidth - minPaneWidth,
                              )
                              .toDouble()
                        : 0.0;
                    final contentAreaWidth = _pdfVisible
                        ? availableWidth - pdfPaneWidth
                        : availableWidth;

                    return Padding(
                      padding: EdgeInsets.all(panePadding),
                      child: Row(
                        children: [
                          if (_pdfVisible) ...[
                            SizedBox(
                              width: pdfPaneWidth,
                              child: _RoundedPane(
                                child: _buildPdfColumn(title),
                              ),
                            ),
                            _PaneResizeHandle(
                              width: dividerWidth,
                              onDragUpdate: (delta) {
                                if (availableWidth <= 0) {
                                  return;
                                }
                                setState(() {
                                  _pdfPaneFraction =
                                      (_pdfPaneFraction +
                                              delta / availableWidth)
                                          .clamp(0.25, 0.75)
                                          .toDouble();
                                });
                              },
                            ),
                          ],
                          SizedBox(
                            width: contentAreaWidth,
                            child: _buildContentAndNotes(contentAreaWidth),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          if (_dictionaryVisible)
            _DictionaryLookupOverlay(
              position: _dictionaryPosition,
              query: _dictionaryQuery,
              loading: _dictionaryLoading,
              error: _dictionaryError,
              results: _dictionaryResults,
              onDismiss: _hideDictionaryPopup,
            ),
          if (_dictionaryPanelVisible)
            _DictionaryLookupPanel(
              query: _dictionaryQuery,
              loading: _dictionaryLoading,
              error: _dictionaryError,
              results: _dictionaryResults,
              onSearch: (query) =>
                  _lookupDictionarySelection(query, Offset.zero, panel: true),
              onDismiss: _hideDictionaryPopup,
            ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _appendMarkdownToNote(String markdown) {
    final trimmed = markdown.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _pendingNoteAppends.add(trimmed);
    setState(() {
      _notesVisible = true;
    });
    _schedulePendingNoteFlush();
  }

  void _schedulePendingNoteFlush() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushPendingNoteAppends();
    });
  }

  void _flushPendingNoteAppends() {
    if (!mounted || _pendingNoteAppends.isEmpty) {
      return;
    }
    final noteState = _notePanelKey.currentState;
    if (noteState == null) {
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _flushPendingNoteAppends();
        }
      });
      return;
    }
    final pending = List<String>.from(_pendingNoteAppends);
    _pendingNoteAppends.clear();
    for (final markdown in pending) {
      noteState.appendQuotedMarkdown(markdown);
    }
  }

  Future<void> _startReadingExtractedContent() async {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (workDir == null || paperId == null) {
      return;
    }
    await LibraryStore(workDir).updatePaperFields(paperId, {
      'extractStatus': 'done',
      'extractProgress': null,
      'extractMessage': null,
    });
    widget.extractionManager?.markRead(workDir, paperId);
    if (!mounted) {
      return;
    }
    setState(() {
      _showExtractionDetails = false;
    });
  }

  Widget _buildExtractionDetailPanel() {
    final manager = widget.extractionManager;
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (manager == null || workDir == null || paperId == null) {
      return _ExtractionDetailPanel(
        extracting: false,
        progress: 0,
        message: '未绑定文献库，无法显示提取进度',
        logs: const [],
        onCancel: null,
        onStartReading: null,
        onDismiss: () => setState(() {
          _showExtractionDetails = false;
        }),
      );
    }

    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final state = manager.stateFor(workDir, paperId);
        final extracting =
            manager.isRunning(workDir, paperId) || (state?.extracting ?? false);
        final completed = state?.completed ?? false;
        final message = completed
            ? '提取完成，点击下方按钮开始阅读'
            : state?.message ?? '开始提取...';
        return _ExtractionDetailPanel(
          extracting: extracting,
          progress: state?.progress ?? (extracting ? 0.05 : 0),
          message: message,
          logs: state?.logs ?? const [],
          onCancel: extracting ? _cancelCurrentExtraction : null,
          onStartReading: completed ? _startReadingExtractedContent : null,
          onDismiss: extracting
              ? null
              : () => setState(() {
                  _showExtractionDetails = false;
                }),
        );
      },
    );
  }

  Widget _buildContentAndNotes(double width) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final dividerWidth = _snapToPhysicalPixel(8, devicePixelRatio);
    final content = _showExtractionDetails
        ? _buildExtractionDetailPanel()
        : MineruContentPanel(
            key: _contentPanelKey,
            paperDir: widget.paperDir,
            paperId: widget.paperId,
            workDir: widget.workDir,
            bodyFontSize: _bodyFontSize,
            translationFontSize: _translationFontSize,
            fontPreset: _fontPreset,
            initialScrollTop: _initialContentScrollTop,
            initialContentIndex: _initialContentIndex,
            onPaperLoaded: (paper) {
              if (_paper != paper) {
                setState(() {
                  _paper = paper;
                });
              }
            },
            onBlockSelected: _handleContentBlockSelected,
            onLookupRequested: _lookupDictionarySelection,
            onDismissOverlays: _hideDictionaryPopup,
            onAppendNoteRequested: _appendMarkdownToNote,
            onReaderFontSettingsChanged: _applyReaderFontSettings,
          );

    if (!_notesVisible) {
      return _RoundedPane(child: content);
    }

    final available = math.max(0.0, width - dividerWidth);
    final minNotesWidth = math.min(
      _snapToPhysicalPixel(260, devicePixelRatio),
      _floorToPhysicalPixel(available / 2, devicePixelRatio),
    );
    final notesWidth = _snapToPhysicalPixel(
      available * _notesPaneFraction,
      devicePixelRatio,
    ).clamp(minNotesWidth, available - minNotesWidth).toDouble();
    final contentWidth = available - notesWidth;

    return Row(
      children: [
        SizedBox(
          width: contentWidth,
          child: _RoundedPane(child: content),
        ),
        _PaneResizeHandle(
          width: dividerWidth,
          onDragUpdate: (delta) {
            if (available <= 0) {
              return;
            }
            setState(() {
              _notesPaneFraction = (_notesPaneFraction - delta / available)
                  .clamp(0.22, 0.58)
                  .toDouble();
            });
          },
        ),
        SizedBox(
          width: notesWidth,
          child: _RoundedPane(
            child: MarkdownNotePanel(
              key: _notePanelKey,
              paperDir: widget.paperDir,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPdfColumn(String title) {
    final readerColors = ReaderColors.of(context);
    return Column(
      children: [
        _PdfPaneHeader(
          title: title,
          currentPage: _currentPage,
          pageCount: _pageCount,
          zoom: _toolbarZoom,
          enabled: _pdfControlsEnabled,
          onZoomOut: _zoomOut,
          onZoomIn: _zoomIn,
          onFitWidth: _fitWidth,
          onResetZoom: _resetZoom,
          recentPapers: widget.recentPapers,
          currentPaperId: widget.paperId,
          onSwitchPaper: widget.onSwitchPaper == null
              ? null
              : _switchRecentPaper,
        ),
        Expanded(child: _buildPdfViewerArea(readerColors)),
      ],
    );
  }

  Widget _buildPdfViewerArea(ReaderColors readerColors) {
    if (!_pdfExists) {
      return _MissingPdfNotice(path: widget.pdfPath);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_pdfViewerMounted &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0) {
          _schedulePdfViewerMount();
        }
        if (!_pdfViewerMounted) {
          return ColoredBox(
            color: readerColors.pdfBackground,
            child: const Center(
              child: SizedBox(width: 220, child: LinearProgressIndicator()),
            ),
          );
        }

        return _buildPdfThemeFilter(
          PdfViewer.file(
            widget.pdfPath,
            key: ValueKey('${widget.pdfPath}:$_pdfViewerGeneration'),
            controller: _controller,
            params: PdfViewerParams(
              backgroundColor: readerColors.brightness == Brightness.dark
                  ? Colors.white
                  : readerColors.pdfBackground,
              margin: 18,
              pageDropShadow: null,
              limitRenderingCache: true,
              pagePaintFilterQuality: FilterQuality.medium,
              visibleRenderScaleFactor: _pdfVisibleRenderScaleFactor,
              additionalRenderFlags: readerColors.brightness == Brightness.light
                  ? PdfPageRenderFlags.lcdText
                  : PdfPageRenderFlags.none,
              onePassRenderingSizeThreshold: _pdfPreviewMaxSide,
              getPageRenderingScale: _getPageRenderingScale,
              maxImageBytesCachedOnMemory: _maxPageImageCacheBytes,
              horizontalCacheExtent: 0.2,
              verticalCacheExtent: 0.3,
              behaviorControlParams: const PdfViewerBehaviorControlParams(
                partialImageLoadingDelay: _pdfHighQualityRenderDelay,
              ),
              textSelectionParams: PdfTextSelectionParams(
                onTextSelectionChange: _handlePdfTextSelectionChanged,
              ),
              pageAnchor: PdfPageAnchor.top,
              onViewerReady: _handleViewerReady,
              onPageChanged: _handlePageChanged,
              onGeneralTap: _handlePdfTap,
              viewerOverlayBuilder: _buildPdfViewerOverlays,
              pageOverlaysBuilder: _buildPdfPageOverlays,
              loadingBannerBuilder: _buildLoadingBanner,
              errorBannerBuilder: _buildErrorBanner,
            ),
          ),
          readerColors,
        );
      },
    );
  }

  Widget _buildPdfThemeFilter(Widget child, ReaderColors readerColors) {
    if (readerColors.brightness != Brightness.dark) {
      return child;
    }
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_pdfNightInvertMatrix),
      child: child,
    );
  }

  List<Widget> _buildPdfViewerOverlays(
    BuildContext context,
    Size size,
    PdfViewerHandleLinkTap handleLinkTap,
  ) {
    return [
      PdfViewerScrollThumb(
        controller: _controller,
        orientation: ScrollbarOrientation.right,
        margin: 4,
        thumbSize: const Size(10, 46),
        thumbBuilder: (context, thumbSize, pageNumber, controller) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: ReaderColors.of(context).accent.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Center(
              child: Text(
                pageNumber?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ).copyWith(color: Theme.of(context).colorScheme.onPrimary),
              ),
            ),
          );
        },
      ),
    ];
  }

  List<Widget> _buildPdfPageOverlays(
    BuildContext context,
    Rect pageRect,
    PdfPage page,
  ) {
    if (_linkMode == PdfContentLinkMode.none || _paper == null) {
      return const [];
    }

    final pageIndex = page.pageNumber - 1;
    final widgets = <Widget>[];
    for (final item in _paper!.items) {
      if (item.pageIndex != pageIndex) {
        continue;
      }

      final rect = item
          .toPdfRect(page)
          ?.toRectInDocument(
            page: page,
            pageRect: Rect.fromLTWH(0, 0, pageRect.width, pageRect.height),
          );
      if (rect == null || rect.isEmpty) {
        continue;
      }

      final selected = item.contentIndex == _activeContentItem?.contentIndex;
      final readerColors = ReaderColors.of(context);
      widgets.add(
        Positioned.fromRect(
          rect: rect.inflate(selected ? 2 : 1),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected
                      ? readerColors.accent
                      : readerColors.border.withAlpha(150),
                  width: selected ? 1.8 : 0.8,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      );
    }

    return widgets;
  }

  Widget _buildLoadingBanner(
    BuildContext context,
    int bytesDownloaded,
    int? totalBytes,
  ) {
    final progress = totalBytes == null || totalBytes == 0
        ? null
        : bytesDownloaded / totalBytes;

    return Center(
      child: SizedBox(
        width: 220,
        child: LinearProgressIndicator(value: progress),
      ),
    );
  }

  Widget _buildErrorBanner(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
    PdfDocumentRef documentRef,
  ) {
    return Center(
      child: _StatusPanel(
        icon: Icons.error_outline,
        title: 'PDF load failed',
        detail: error.toString(),
      ),
    );
  }
}

class MineruContentPanel extends StatefulWidget {
  const MineruContentPanel({
    super.key,
    required this.paperDir,
    this.paperId,
    this.workDir,
    this.bodyFontSize = 14,
    this.translationFontSize = 13,
    this.fontPreset = ReaderFontPreset.comfortable,
    this.initialScrollTop,
    this.initialContentIndex,
    this.onPaperLoaded,
    this.onBlockSelected,
    this.onLookupRequested,
    this.onDismissOverlays,
    this.onAppendNoteRequested,
    this.onReaderFontSettingsChanged,
  });

  final String paperDir;
  final String? paperId;
  final String? workDir;
  final double bodyFontSize;
  final double translationFontSize;
  final ReaderFontPreset fontPreset;
  final double? initialScrollTop;
  final int? initialContentIndex;
  final ValueChanged<MineruPaper>? onPaperLoaded;
  final ValueChanged<MineruContentItem>? onBlockSelected;
  final void Function(String word, Offset position)? onLookupRequested;
  final VoidCallback? onDismissOverlays;
  final ValueChanged<String>? onAppendNoteRequested;
  final ValueChanged<ReaderFontSettings>? onReaderFontSettingsChanged;

  @override
  State<MineruContentPanel> createState() => _MineruContentPanelState();
}

class ReaderContentPosition {
  const ReaderContentPosition({required this.top, required this.contentIndex});

  final double top;
  final int? contentIndex;
}

class _ExtractionStatusNotice extends StatefulWidget {
  const _ExtractionStatusNotice({
    required this.workDir,
    required this.paperId,
    required this.fallbackError,
    this.onStartReading,
  });

  final String? workDir;
  final String? paperId;
  final String fallbackError;
  final VoidCallback? onStartReading;

  @override
  State<_ExtractionStatusNotice> createState() =>
      _ExtractionStatusNoticeState();
}

class _ExtractionStatusNoticeState extends State<_ExtractionStatusNotice> {
  Future<LibraryPaperEntry?>? _paperFuture;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _paperFuture = _loadPaper();
  }

  @override
  void didUpdateWidget(_ExtractionStatusNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workDir != widget.workDir ||
        oldWidget.paperId != widget.paperId) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _refresh();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<LibraryPaperEntry?> _loadPaper() async {
    final dir = widget.workDir;
    final id = widget.paperId;
    if (dir == null || id == null) {
      return null;
    }
    final snapshot = await LibraryStore(dir).load();
    for (final paper in snapshot.papers) {
      if (paper.id == id) {
        if (paper.extractStatus == 'extracting' &&
            await MineruPaper.hasExtractedContent(
              LibraryStore.paperDir(dir, id),
            )) {
          await LibraryStore(dir).updatePaperFields(id, {
            'extractStatus': 'pending_read',
            'extractProgress': 1,
            'extractMessage': '提取完成',
          });
          return paper.copyWith(
            extractStatus: 'pending_read',
            extractProgress: 1,
            extractMessage: '提取完成',
          );
        }
        return paper;
      }
    }
    return null;
  }

  void _refresh() {
    if (!mounted) {
      return;
    }
    setState(() {
      _paperFuture = _loadPaper();
    });
  }

  void _updatePolling(String status) {
    if (status == 'extracting') {
      _pollTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refresh(),
      );
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LibraryPaperEntry?>(
      future: _paperFuture,
      builder: (context, snapshot) {
        final paper = snapshot.data;
        final status = paper?.extractStatus ?? 'none';
        final message = paper?.extractMessage?.trim();
        final progress = paper?.extractProgress?.clamp(0, 1).toDouble();
        final isLoading = snapshot.connectionState != ConnectionState.done;

        if (isLoading) {
          return const Center(
            child: SizedBox(width: 220, child: LinearProgressIndicator()),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _updatePolling(status);
          }
        });

        if (status == 'extracting') {
          return Center(
            child: SizedBox(
              width: 360,
              child: _StatusPanel(
                icon: Icons.cloud_sync_outlined,
                title: '正在提取文献',
                detail: message?.isNotEmpty == true
                    ? message!
                    : 'MinerU 正在解析当前 PDF',
                progress: progress ?? 0.05,
              ),
            ),
          );
        }

        if (status == 'pending_read') {
          return Center(
            child: SizedBox(
              width: 420,
              child: _StatusPanel(
                icon: Icons.check_circle_outline,
                title: '提取完成',
                detail: '点击下方按钮开始阅读，正文会在首次打开后加载。',
                progress: 1,
                actions: [
                  FilledButton.icon(
                    onPressed: widget.onStartReading,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('开始阅读'),
                  ),
                ],
              ),
            ),
          );
        }

        if (status == 'done') {
          return Center(
            child: _StatusPanel(
              icon: Icons.warning_amber_outlined,
              title: '提取结果未就绪',
              detail: widget.fallbackError,
            ),
          );
        }

        if (message?.startsWith('提取失败') == true) {
          return Center(
            child: _StatusPanel(
              icon: Icons.error_outline,
              title: '提取失败',
              detail: message!,
            ),
          );
        }

        return const Center(
          child: _StatusPanel(
            icon: Icons.article_outlined,
            title: '文献尚未提取',
            detail: '点击顶部“提取”按钮开始解析 PDF。',
          ),
        );
      },
    );
  }
}

class _MineruContentPanelState extends State<MineruContentPanel> {
  final _webViewKey = GlobalKey<_WebMineruDocumentViewState>();
  Future<MineruPaper>? _paperFuture;
  late Future<LibraryPaperEntry?> _entryFuture;
  MineruPaper? _paper;
  final _translatingIndexes = <int>{};
  var _forceLoadContent = false;

  @override
  void initState() {
    super.initState();
    _entryFuture = _loadCurrentPaperEntry();
    if (!_usesLibraryStatusGate) {
      _paperFuture = MineruPaper.load(widget.paperDir);
    }
  }

  @override
  void didUpdateWidget(MineruContentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paperDir != widget.paperDir ||
        oldWidget.workDir != widget.workDir ||
        oldWidget.paperId != widget.paperId) {
      _paper = null;
      _forceLoadContent = false;
      _entryFuture = _loadCurrentPaperEntry();
      _paperFuture = _usesLibraryStatusGate
          ? null
          : MineruPaper.load(widget.paperDir);
    }
  }

  bool get _usesLibraryStatusGate =>
      widget.workDir != null && widget.paperId != null;

  Future<LibraryPaperEntry?> _loadCurrentPaperEntry() async {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (workDir == null || paperId == null) {
      return null;
    }
    final snapshot = await LibraryStore(workDir).load();
    final paper = _findPaperById(snapshot.papers, paperId);
    if (paper?.extractStatus == 'extracting' &&
        await MineruPaper.hasExtractedContent(widget.paperDir)) {
      await LibraryStore(workDir).updatePaperFields(paperId, {
        'extractStatus': 'pending_read',
        'extractProgress': 1,
        'extractMessage': '提取完成',
      });
      return paper!.copyWith(
        extractStatus: 'pending_read',
        extractProgress: 1,
        extractMessage: '提取完成',
      );
    }
    return paper;
  }

  Future<void> startReading() async {
    final workDir = widget.workDir;
    final paperId = widget.paperId;
    if (workDir != null && paperId != null) {
      await LibraryStore(workDir).updatePaperFields(paperId, {
        'extractStatus': 'done',
        'extractProgress': null,
        'extractMessage': null,
      });
    }
    setState(() {
      _forceLoadContent = true;
      _paper = null;
      _entryFuture = _loadCurrentPaperEntry();
      _paperFuture = MineruPaper.load(widget.paperDir);
    });
  }

  void scrollToPage(int? pageNumber) {
    final paper = _paper;
    if (pageNumber == null || paper == null) {
      return;
    }
    final pageIndex = pageNumber - 1;
    MineruContentItem? item;
    for (final candidate in paper.items) {
      if (candidate.pageIndex == pageIndex) {
        item = candidate;
        break;
      }
    }
    if (item == null) {
      return;
    }
    scrollToBlock(item.contentIndex);
  }

  void scrollToBlock(int contentIndex) {
    _webViewKey.currentState?.scrollToBlock(contentIndex);
  }

  Future<ReaderContentPosition?> captureScrollPosition() {
    return _webViewKey.currentState?.captureScrollPosition() ??
        Future.value(null);
  }

  Future<void> reload() async {
    setState(() {
      _paper = null;
      _entryFuture = _loadCurrentPaperEntry();
      _paperFuture = _forceLoadContent || !_usesLibraryStatusGate
          ? MineruPaper.load(widget.paperDir)
          : null;
    });
    try {
      final future = _paperFuture;
      if (future != null) {
        await future;
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_usesLibraryStatusGate && !_forceLoadContent) {
      return FutureBuilder<LibraryPaperEntry?>(
        future: _entryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(width: 220, child: LinearProgressIndicator()),
            );
          }
          final status = snapshot.data?.extractStatus ?? 'none';
          if (status != 'done') {
            return _ExtractionStatusNotice(
              workDir: widget.workDir,
              paperId: widget.paperId,
              fallbackError: '',
              onStartReading: startReading,
            );
          }
          _paperFuture ??= MineruPaper.load(widget.paperDir);
          return _buildPaperFuture(context);
        },
      );
    }
    _paperFuture ??= MineruPaper.load(widget.paperDir);
    return _buildPaperFuture(context);
  }

  Widget _buildPaperFuture(BuildContext context) {
    return FutureBuilder<MineruPaper>(
      future: _paperFuture,
      builder: (context, snapshot) {
        return _buildBody(context, snapshot);
      },
    );
  }

  Widget _buildBody(BuildContext context, AsyncSnapshot<MineruPaper> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(
        child: SizedBox(width: 220, child: LinearProgressIndicator()),
      );
    }

    if (snapshot.hasError) {
      return _ExtractionStatusNotice(
        workDir: widget.workDir,
        paperId: widget.paperId,
        fallbackError: snapshot.error.toString(),
      );
    }

    final paper = snapshot.requireData;
    if (_paper != paper) {
      _paper = paper;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onPaperLoaded?.call(paper);
        }
      });
    }
    if (paper.items.isEmpty) {
      return _ExtractionStatusNotice(
        workDir: widget.workDir,
        paperId: widget.paperId,
        fallbackError: paper.contentListPath,
      );
    }

    return ColoredBox(
      color: ReaderColors.of(context).surfaceAlt,
      child: WebMineruDocumentView(
        key: _webViewKey,
        paper: paper,
        bodyFontSize: widget.bodyFontSize,
        translationFontSize: widget.translationFontSize,
        fontPreset: widget.fontPreset,
        initialScrollTop: widget.initialScrollTop,
        initialContentIndex: widget.initialContentIndex,
        onBlockSelected: widget.onBlockSelected,
        onTranslateRequested: _translateItem,
        onDeleteTranslationRequested: _deleteTranslation,
        onLookupRequested: widget.onLookupRequested,
        onDismissOverlays: widget.onDismissOverlays,
        onAppendNoteRequested: widget.onAppendNoteRequested,
      ),
    );
  }

  Future<AppApiSettings?> _ensureDeepSeekSettings() async {
    var settings = await LibraryPreferences.readApiSettings();
    if (settings.deepSeekApiKey.trim().isNotEmpty) {
      return settings;
    }
    if (!mounted) {
      return null;
    }

    final updated = await _showApiSettingsDialog(
      context,
      settings,
      initialReaderFontSettings: ReaderFontSettings(
        bodyFontSize: widget.bodyFontSize,
        translationFontSize: widget.translationFontSize,
        preset: widget.fontPreset,
      ),
    );
    if (updated == null) {
      return null;
    }
    await LibraryPreferences.saveApiSettings(updated.apiSettings);
    await LibraryPreferences.saveReaderFontSettings(updated.readerFontSettings);
    if (mounted) {
      widget.onReaderFontSettingsChanged?.call(updated.readerFontSettings);
      await updated.applyTheme(context);
    }
    settings = updated.apiSettings;
    return settings.deepSeekApiKey.trim().isEmpty ? null : settings;
  }

  Future<void> _translateItem(MineruContentItem item) async {
    final paper = _paper;
    final markdown = item.translationMarkdown;
    if (paper == null || markdown == null || markdown.trim().isEmpty) {
      return;
    }
    if (_translatingIndexes.contains(item.contentIndex)) {
      return;
    }

    final settings = await _ensureDeepSeekSettings();
    if (settings == null || !mounted) {
      return;
    }

    setState(() {
      _translatingIndexes.add(item.contentIndex);
    });
    await _webViewKey.currentState?.upsertTranslationMarkdown(
      item.contentIndex,
      '*\u7ffb\u8bd1\u4e2d...*',
      streaming: true,
    );

    var latest = '';
    try {
      await const DeepSeekTranslationService().translateStream(
        markdown: markdown,
        settings: settings,
        onChunk: (text) {
          latest = text;
          _webViewKey.currentState?.upsertTranslationMarkdown(
            item.contentIndex,
            text,
            streaming: true,
          );
        },
      );

      if (latest.trim().isEmpty) {
        throw const FormatException(
          '\u6a21\u578b\u672a\u8fd4\u56de\u8bd1\u6587',
        );
      }

      await MineruPaper.saveTranslation(
        paper.paperDir,
        item.contentIndex,
        latest,
      );
      paper.translations[item.contentIndex.toString()] = latest;
      await _webViewKey.currentState?.upsertTranslationMarkdown(
        item.contentIndex,
        latest,
        streaming: false,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      final message = '*\u7ffb\u8bd1\u5931\u8d25: $error*';
      await _webViewKey.currentState?.upsertTranslationMarkdown(
        item.contentIndex,
        message,
        streaming: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _translatingIndexes.remove(item.contentIndex);
        });
      } else {
        _translatingIndexes.remove(item.contentIndex);
      }
    }
  }

  Future<void> translateSelectedItems() async {
    final paper = _paper;
    if (paper == null) {
      return;
    }

    final selectedIndexes =
        await _webViewKey.currentState?.selectedContentIndexes() ?? const [];
    if (selectedIndexes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '\u8bf7\u5148\u9009\u4e2d\u8981\u7ffb\u8bd1\u7684\u6bb5\u843d',
            ),
          ),
        );
      }
      return;
    }

    final itemsByIndex = {
      for (final item in paper.items) item.contentIndex: item,
    };
    final batch = <MineruContentItem>[];
    for (final index in selectedIndexes) {
      final item = itemsByIndex[index];
      if (item?.translationMarkdown?.trim().isNotEmpty == true &&
          !_translatingIndexes.contains(index)) {
        batch.add(item!);
      }
      if (batch.length >= 10) {
        break;
      }
    }

    if (batch.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '\u9009\u4e2d\u5185\u5bb9\u4e0d\u652f\u6301\u7ffb\u8bd1',
            ),
          ),
        );
      }
      return;
    }

    final settings = await _ensureDeepSeekSettings();
    if (settings == null || !mounted) {
      return;
    }

    setState(() {
      _translatingIndexes.addAll(batch.map((item) => item.contentIndex));
    });
    for (final item in batch) {
      await _webViewKey.currentState?.upsertTranslationMarkdown(
        item.contentIndex,
        '*\u7ffb\u8bd1\u4e2d...*',
        streaming: true,
      );
    }

    try {
      final markdowns = [for (final item in batch) item.translationMarkdown!];
      final results = await const DeepSeekTranslationService()
          .batchTranslateStream(
            markdowns: markdowns,
            settings: settings,
            onProgress: (partial) {
              for (var i = 0; i < batch.length; i++) {
                final text = partial[i];
                if (text == null || text.trim().isEmpty) {
                  continue;
                }
                _webViewKey.currentState?.upsertTranslationMarkdown(
                  batch[i].contentIndex,
                  text,
                  streaming: true,
                );
              }
            },
          );

      for (var i = 0; i < batch.length; i++) {
        final item = batch[i];
        final text = results[i];
        await MineruPaper.saveTranslation(
          paper.paperDir,
          item.contentIndex,
          text,
        );
        paper.translations[item.contentIndex.toString()] = text;
        await _webViewKey.currentState?.upsertTranslationMarkdown(
          item.contentIndex,
          text,
          streaming: false,
        );
      }
      await _webViewKey.currentState?.clearSelection();
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      for (final item in batch) {
        await _webViewKey.currentState?.upsertTranslationMarkdown(
          item.contentIndex,
          '*\u7ffb\u8bd1\u5931\u8d25: $error*',
          streaming: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _translatingIndexes.removeAll(batch.map((item) => item.contentIndex));
        });
      } else {
        _translatingIndexes.removeAll(batch.map((item) => item.contentIndex));
      }
    }
  }

  Future<void> _deleteTranslation(MineruContentItem item) async {
    final paper = _paper;
    if (paper == null) {
      return;
    }

    await MineruPaper.removeTranslation(paper.paperDir, item.contentIndex);
    paper.translations.remove(item.contentIndex.toString());
    await _webViewKey.currentState?.removeTranslation(item.contentIndex);
    if (mounted) {
      setState(() {});
    }
  }
}

class WebMineruDocumentView extends StatefulWidget {
  const WebMineruDocumentView({
    super.key,
    required this.paper,
    required this.bodyFontSize,
    required this.translationFontSize,
    required this.fontPreset,
    this.initialScrollTop,
    this.initialContentIndex,
    this.onBlockSelected,
    this.onTranslateRequested,
    this.onDeleteTranslationRequested,
    this.onLookupRequested,
    this.onDismissOverlays,
    this.onAppendNoteRequested,
  });

  final MineruPaper paper;
  final double bodyFontSize;
  final double translationFontSize;
  final ReaderFontPreset fontPreset;
  final double? initialScrollTop;
  final int? initialContentIndex;
  final ValueChanged<MineruContentItem>? onBlockSelected;
  final ValueChanged<MineruContentItem>? onTranslateRequested;
  final ValueChanged<MineruContentItem>? onDeleteTranslationRequested;
  final void Function(String word, Offset position)? onLookupRequested;
  final VoidCallback? onDismissOverlays;
  final ValueChanged<String>? onAppendNoteRequested;

  @override
  State<WebMineruDocumentView> createState() => _WebMineruDocumentViewState();
}

class _WebMineruDocumentViewState extends State<WebMineruDocumentView> {
  InAppWebViewController? _controller;
  bool _loading = true;
  _LocalDocumentAssetServer? _assetServer;
  Object? _error;
  bool _initialScrollRestored = false;

  Map<int, MineruContentItem> get _itemsByContentIndex => {
    for (final item in widget.paper.items) item.contentIndex: item,
  };

  @override
  void initState() {
    super.initState();
    _startAssetServer();
  }

  @override
  void didUpdateWidget(WebMineruDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paper != widget.paper) {
      _initialScrollRestored = false;
      _startAssetServer();
    } else if (oldWidget.bodyFontSize != widget.bodyFontSize ||
        oldWidget.translationFontSize != widget.translationFontSize ||
        oldWidget.fontPreset != widget.fontPreset) {
      _applyReaderTypography();
    }
    if (oldWidget.initialScrollTop != widget.initialScrollTop ||
        oldWidget.initialContentIndex != widget.initialContentIndex) {
      _initialScrollRestored = false;
      if (!_loading) {
        unawaited(_restoreInitialScrollPosition());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) {
      unawaited(_applyReaderTheme());
    }
  }

  Future<void> _startAssetServer() async {
    final oldServer = _assetServer;
    _assetServer = null;
    await oldServer?.close();

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final server = await _LocalDocumentAssetServer.start(widget.paper);
      if (!mounted) {
        await server.close();
        return;
      }

      setState(() {
        _assetServer = server;
      });

      final url = WebUri(server.documentUrl);
      await _controller?.loadUrl(urlRequest: URLRequest(url: url));
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    }
  }

  Future<void> scrollToBlock(int contentIndex) async {
    await _controller?.evaluateJavascript(
      source: 'window.scrollToBlock && window.scrollToBlock($contentIndex);',
    );
  }

  Future<void> upsertTranslationMarkdown(
    int contentIndex,
    String markdown, {
    required bool streaming,
  }) async {
    final html = _renderTranslationMarkdownHtml(markdown);
    await _controller?.evaluateJavascript(
      source:
          'window.upsertTranslation && window.upsertTranslation($contentIndex, ${jsonEncode(html)}, ${jsonEncode(markdown)}, ${streaming ? 'true' : 'false'});',
    );
  }

  Future<void> removeTranslation(int contentIndex) async {
    await _controller?.evaluateJavascript(
      source:
          'window.removeTranslation && window.removeTranslation($contentIndex);',
    );
  }

  Future<List<int>> selectedContentIndexes() async {
    final result = await _controller?.evaluateJavascript(
      source:
          'window.getSelectedBlocks ? JSON.stringify(window.getSelectedBlocks()) : "[]"',
    );
    final text = result?.toString() ?? '[]';
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      return const [];
    }
    return decoded.map(_readInt).whereType<int>().toList(growable: false);
  }

  Future<void> clearSelection() async {
    await _controller?.evaluateJavascript(
      source: 'window.clearSelectedBlocks && window.clearSelectedBlocks();',
    );
  }

  Future<void> _applyReaderTypography() async {
    final preset = widget.fontPreset;
    await _controller?.evaluateJavascript(
      source:
          'window.setReaderTypography && window.setReaderTypography('
          '${widget.bodyFontSize}, ${widget.translationFontSize}, '
          '${jsonEncode(preset.bodyCssFamily)}, '
          '${jsonEncode(preset.headingCssFamily)});',
    );
  }

  Future<void> _applyReaderTheme() async {
    if (!mounted) {
      return;
    }
    final readerColors = ReaderColors.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final theme = {
      'colorScheme': readerColors.brightness == Brightness.dark
          ? 'dark'
          : 'light',
      'docBg': _cssColor(readerColors.surfaceAlt),
      'blockBg': _cssColor(readerColors.surface),
      'text': _cssColor(colorScheme.onSurface),
      'muted': _cssColor(colorScheme.onSurfaceVariant),
      'border': _cssColor(readerColors.border),
      'accent': _cssColor(readerColors.accent),
      'accentSoft': _cssColor(readerColors.accentSoft),
      'multiAccent': _cssColor(colorScheme.secondary),
      'editorFill': _cssColor(readerColors.editorFill),
      'codeFill': _cssColor(readerColors.codeFill),
      'tableHeader': _cssColor(readerColors.tableHeader),
      'dangerSoft': _cssColor(colorScheme.errorContainer),
      'highlight': readerColors.brightness == Brightness.dark
          ? '#66591f'
          : '#fff1a8',
      'overlayBg': readerColors.brightness == Brightness.dark
          ? 'rgba(0,0,0,.94)'
          : 'rgba(14,16,15,.94)',
      'overlayButtonBg': _cssColor(readerColors.surfaceAlt),
      'overlayButtonText': _cssColor(colorScheme.onSurface),
      'scrollbarThumb': readerColors.brightness == Brightness.dark
          ? 'rgba(121,184,177,.38)'
          : 'rgba(47,111,115,.32)',
      'scrollbarThumbHover': readerColors.brightness == Brightness.dark
          ? 'rgba(121,184,177,.58)'
          : 'rgba(47,111,115,.52)',
      'shadow': readerColors.brightness == Brightness.dark
          ? 'rgba(0,0,0,.38)'
          : 'rgba(17,24,20,.16)',
    };
    await _controller?.evaluateJavascript(
      source:
          'window.setReaderTheme && window.setReaderTheme(${jsonEncode(theme)});',
    );
  }

  Future<ReaderContentPosition?> captureScrollPosition() async {
    final result = await _controller?.evaluateJavascript(
      source:
          'window.getReaderScrollPosition ? JSON.stringify(window.getReaderScrollPosition()) : null',
    );
    if (result == null) {
      return null;
    }
    try {
      final decoded = _decodeJavascriptJson(result);
      if (decoded is! Map) {
        return null;
      }
      return ReaderContentPosition(
        top: _readDouble(decoded['top']) ?? 0,
        contentIndex: _readInt(decoded['index']),
      );
    } catch (_) {
      return null;
    }
  }

  Object? _decodeJavascriptJson(Object result) {
    Object? decoded = result;
    for (var i = 0; i < 2; i++) {
      if (decoded is! String) {
        return decoded;
      }
      decoded = jsonDecode(decoded);
    }
    return decoded;
  }

  Future<void> _restoreInitialScrollPosition() async {
    final top = widget.initialScrollTop;
    final index = widget.initialContentIndex;
    if (_initialScrollRestored || (top == null && index == null)) {
      return;
    }
    const delays = [
      Duration.zero,
      Duration(milliseconds: 120),
      Duration(milliseconds: 360),
    ];
    for (final delay in delays) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (!mounted || _controller == null) {
        return;
      }
      await _controller?.evaluateJavascript(
        source:
            'window.restoreReaderScrollPosition && window.restoreReaderScrollPosition(${index ?? 'null'}, ${top ?? 0});',
      );
    }
    _initialScrollRestored = true;
  }

  @override
  void dispose() {
    _assetServer?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final environmentError = _appWebViewEnvironmentError;
    if (Platform.isWindows &&
        _appWebViewEnvironment == null &&
        environmentError != null) {
      return Center(
        child: _StatusPanel(
          icon: Icons.web_asset_off_outlined,
          title:
              'Markdown \u9605\u8bfb\u7ec4\u4ef6\u521d\u59cb\u5316\u5931\u8d25',
          detail: environmentError.toString(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: _StatusPanel(
          icon: Icons.web_asset_off_outlined,
          title: 'Web document server failed',
          detail: _error.toString(),
        ),
      );
    }

    final server = _assetServer;
    if (server == null) {
      return const Center(
        child: SizedBox(width: 220, child: LinearProgressIndicator()),
      );
    }

    return Stack(
      children: [
        InAppWebView(
          key: ValueKey(server.documentUrl),
          webViewEnvironment: _appWebViewEnvironment,
          initialUrlRequest: URLRequest(url: WebUri(server.documentUrl)),
          initialSettings: InAppWebViewSettings(
            transparentBackground: false,
            javaScriptEnabled: true,
            supportZoom: false,
            disableContextMenu: false,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            controller.addJavaScriptHandler(
              handlerName: 'blockClick',
              callback: (args) {
                if (args.isEmpty) {
                  return null;
                }
                final index = _readInt(args.first);
                final item = index == null ? null : _itemsByContentIndex[index];
                if (item != null) {
                  widget.onBlockSelected?.call(item);
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'translateBlock',
              callback: (args) {
                final item = _itemFromJsArgs(args);
                if (item != null) {
                  widget.onTranslateRequested?.call(item);
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'deleteTranslation',
              callback: (args) {
                final item = _itemFromJsArgs(args);
                if (item != null) {
                  widget.onDeleteTranslationRequested?.call(item);
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'copyMarkdown',
              callback: (args) async {
                final markdown = args.isEmpty
                    ? ''
                    : args.first?.toString() ?? '';
                if (markdown.trim().isNotEmpty) {
                  await Clipboard.setData(ClipboardData(text: markdown));
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'appendNote',
              callback: (args) {
                final markdown = args.isEmpty
                    ? ''
                    : args.first?.toString() ?? '';
                if (markdown.trim().isNotEmpty) {
                  widget.onAppendNoteRequested?.call(markdown);
                }
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'saveMarks',
              callback: (args) async {
                final jsonText = args.isEmpty
                    ? '[]'
                    : args.first?.toString() ?? '[]';
                await _saveMarksJson(jsonText);
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'lookupSelection',
              callback: (args) {
                if (args.isEmpty) {
                  return null;
                }
                final word = args[0]?.toString() ?? '';
                final x = args.length > 1
                    ? _readDouble(args[1]) ?? 220.0
                    : 220.0;
                final y = args.length > 2 ? _readDouble(args[2]) ?? 80.0 : 80.0;
                final renderObject = context.findRenderObject();
                final origin = renderObject is RenderBox
                    ? renderObject.localToGlobal(Offset.zero)
                    : Offset.zero;
                widget.onLookupRequested?.call(word, origin + Offset(x, y));
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'dismissOverlays',
              callback: (_) {
                widget.onDismissOverlays?.call();
                return null;
              },
            );
          },
          onLoadStop: (_, _) {
            _applyReaderTypography();
            _applyReaderTheme();
            Future.delayed(
              const Duration(milliseconds: 80),
              _restoreInitialScrollPosition,
            );
            if (mounted) {
              setState(() {
                _loading = false;
              });
            }
          },
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
      ],
    );
  }

  MineruContentItem? _itemFromJsArgs(List<dynamic> args) {
    if (args.isEmpty) {
      return null;
    }
    final index = _readInt(args.first);
    return index == null ? null : _itemsByContentIndex[index];
  }

  Future<void> _saveMarksJson(String jsonText) async {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! List) {
        return;
      }
      final file = File(_joinPath(widget.paper.paperDir, 'marks.json'));
      await file.writeAsString(jsonEncode(decoded));
    } catch (_) {}
  }
}

class VirtualMineruContentList extends StatefulWidget {
  const VirtualMineruContentList({
    super.key,
    required this.items,
    required this.imageRoot,
    required this.translations,
  });

  final List<MineruContentItem> items;
  final String imageRoot;
  final Map<String, String> translations;

  @override
  State<VirtualMineruContentList> createState() =>
      _VirtualMineruContentListState();
}

class _VirtualMineruContentListState extends State<VirtualMineruContentList> {
  static const _horizontalPadding = 18.0;
  static const _topPadding = 14.0;
  static const _bottomPadding = 28.0;
  static const _overscan = 900.0;

  late final ScrollController _scrollController;
  late List<double> _heights;
  late List<double> _offsets;
  late double _contentHeight;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _resetHeightModel();
  }

  @override
  void didUpdateWidget(VirtualMineruContentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items ||
        oldWidget.translations != widget.translations ||
        oldWidget.imageRoot != widget.imageRoot) {
      _resetHeightModel();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _resetHeightModel() {
    _heights = [
      for (final item in widget.items)
        _estimateItemHeight(
          item,
          widget.translations[item.contentIndex.toString()],
        ),
    ];
    _recomputeOffsets();
  }

  void _recomputeOffsets() {
    _offsets = List<double>.filled(widget.items.length + 1, 0);
    var offset = 0.0;
    for (var i = 0; i < widget.items.length; i++) {
      _offsets[i] = offset;
      offset += _heights[i];
    }
    _offsets[widget.items.length] = offset;
    _contentHeight = _topPadding + offset + _bottomPadding;
  }

  void _handleItemMeasured(int index, double height) {
    if (index < 0 || index >= _heights.length) {
      return;
    }

    final oldHeight = _heights[index];
    if ((oldHeight - height).abs() < 1) {
      return;
    }

    final currentOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final itemIsAboveViewport = _topPadding + _offsets[index] < currentOffset;

    setState(() {
      _heights[index] = height;
      _recomputeOffsets();
    });

    if (itemIsAboveViewport && _scrollController.hasClients) {
      final delta = height - oldHeight;
      final targetOffset = (_scrollController.offset + delta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if ((targetOffset - _scrollController.offset).abs() >= 1) {
        _scrollController.jumpTo(targetOffset);
      }
    }
  }

  int _findIndexForOffset(double scrollOffset) {
    if (widget.items.isEmpty) {
      return 0;
    }

    final contentOffset = (scrollOffset - _topPadding).clamp(
      0.0,
      _offsets.last,
    );
    var low = 0;
    var high = widget.items.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_offsets[mid + 1] < contentOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low.clamp(0, widget.items.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scrollController,
            child: AnimatedBuilder(
              animation: _scrollController,
              builder: (context, _) {
                final scrollOffset = _scrollController.hasClients
                    ? _scrollController.offset
                    : 0.0;
                final viewportHeight = constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 900.0;
                final startIndex = _findIndexForOffset(
                  scrollOffset - _overscan,
                );
                final endIndex = _findIndexForOffset(
                  scrollOffset + viewportHeight + _overscan,
                );

                return SizedBox(
                  height: math.max(_contentHeight, viewportHeight),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var index = startIndex; index <= endIndex; index++)
                        Positioned(
                          key: ValueKey(
                            'virtual-item-${widget.items[index].contentIndex}',
                          ),
                          top: _topPadding + _offsets[index],
                          left: _horizontalPadding,
                          right: _horizontalPadding,
                          child: _MeasuredVirtualItem(
                            index: index,
                            onMeasured: _handleItemMeasured,
                            child: MineruContentCard(
                              item: widget.items[index],
                              imageRoot: widget.imageRoot,
                              translation:
                                  widget.translations[widget
                                      .items[index]
                                      .contentIndex
                                      .toString()],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _MeasuredVirtualItem extends StatefulWidget {
  const _MeasuredVirtualItem({
    required this.index,
    required this.onMeasured,
    required this.child,
  });

  final int index;
  final void Function(int index, double height) onMeasured;
  final Widget child;

  @override
  State<_MeasuredVirtualItem> createState() => _MeasuredVirtualItemState();
}

class _MeasuredVirtualItemState extends State<_MeasuredVirtualItem> {
  double? _lastHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportSize());
  }

  @override
  void didUpdateWidget(_MeasuredVirtualItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportSize());
  }

  void _reportSize() {
    if (!mounted) {
      return;
    }

    final size = context.size;
    if (size == null) {
      return;
    }

    final height = size.height;
    if (_lastHeight != null && (_lastHeight! - height).abs() < 1) {
      return;
    }

    _lastHeight = height;
    widget.onMeasured(widget.index, height);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class _LocalDocumentAssetServer {
  _LocalDocumentAssetServer._(this._server, this.paper) {
    _server.listen(_handleRequest);
  }

  final HttpServer _server;
  final MineruPaper paper;

  String get origin => 'http://${_server.address.host}:${_server.port}';
  String get documentUrl => '$origin/document';

  static Future<_LocalDocumentAssetServer> start(MineruPaper paper) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _LocalDocumentAssetServer._(server, paper);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      _sendStatus(request, HttpStatus.methodNotAllowed);
      return;
    }

    final path = request.uri.path;
    try {
      if (path == '/document') {
        _sendText(
          request,
          _buildMineruHtml(paper, origin),
          contentType: ContentType.html,
        );
        return;
      }

      if (path.startsWith('/images/')) {
        final relativePath = path.substring('/images/'.length);
        final file = _resolveSafeFile(
          _joinPath(_joinPath(paper.paperDir, 'mineru-output'), 'images'),
          relativePath,
        );
        await _sendFile(request, file);
        return;
      }

      if (path.startsWith('/katex/')) {
        final relativePath = path.substring('/katex/'.length);
        await _sendAsset(request, '$_katexAssetBase/$relativePath');
        return;
      }

      _sendStatus(request, HttpStatus.notFound);
    } catch (_) {
      _sendStatus(request, HttpStatus.notFound);
    }
  }

  File _resolveSafeFile(String root, String relativePath) {
    final decoded = Uri.decodeComponent(relativePath).replaceAll('\\', '/');
    final parts = decoded
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.any((part) => part == '..' || part.contains(':'))) {
      throw ArgumentError('Unsafe path');
    }

    var current = root;
    for (final part in parts) {
      current = _joinPath(current, part);
    }
    return File(current);
  }

  Future<void> _sendAsset(HttpRequest request, String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      request.response.headers.contentType = _contentTypeForPath(assetPath);
      request.response.headers.set(
        HttpHeaders.cacheControlHeader,
        'public, max-age=3600',
      );
      request.response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      _sendStatus(request, HttpStatus.notFound);
      return;
    }
    await request.response.close();
  }

  Future<void> _sendFile(HttpRequest request, File file) async {
    if (!file.existsSync()) {
      _sendStatus(request, HttpStatus.notFound);
      return;
    }

    request.response.headers.contentType = _contentTypeForPath(file.path);
    request.response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=3600',
    );
    if (request.method != 'HEAD') {
      await request.response.addStream(file.openRead());
    }
    await request.response.close();
  }

  void _sendText(
    HttpRequest request,
    String text, {
    required ContentType contentType,
  }) {
    final bytes = utf8.encode(text);
    request.response.headers.contentType = contentType;
    request.response.headers.contentLength = bytes.length;
    if (request.method != 'HEAD') {
      request.response.add(bytes);
    }
    request.response.close();
  }

  void _sendStatus(HttpRequest request, int statusCode) {
    request.response.statusCode = statusCode;
    request.response.close();
  }
}

ContentType _contentTypeForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'html' => ContentType.html,
    'css' => ContentType('text', 'css', charset: 'utf-8'),
    'js' => ContentType('application', 'javascript', charset: 'utf-8'),
    'png' => ContentType('image', 'png'),
    'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
    'gif' => ContentType('image', 'gif'),
    'webp' => ContentType('image', 'webp'),
    'svg' => ContentType('image', 'svg+xml', charset: 'utf-8'),
    'woff2' => ContentType('font', 'woff2'),
    'woff' => ContentType('font', 'woff'),
    'ttf' => ContentType('font', 'ttf'),
    _ => ContentType.binary,
  };
}

String _cssColor(Color color) {
  final value = color.toARGB32();
  return '#${(value & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';
}

String _buildMineruHtml(MineruPaper paper, String assetOrigin) {
  final body = StringBuffer();
  final marksJson = _readMarksJson(paper.paperDir);

  var i = 0;
  while (i < paper.items.length) {
    final item = paper.items[i];
    if (_shouldGroupContentItem(item)) {
      final group = <MineruContentItem>[item];
      var j = i + 1;
      while (j < paper.items.length && paper.items[j].type == item.type) {
        group.add(paper.items[j]);
        j++;
      }
      _writeGroupedItemsHtml(body, group, paper, assetOrigin);
      i = j;
      continue;
    }

    final translation = paper.translations[item.contentIndex.toString()];
    final markdown = item.translationMarkdown ?? item.primaryText;
    final translationMarkdown = translation ?? '';
    body.writeln(
      '<section class="block ${_htmlAttr(item.displayType)}" data-index="${item.contentIndex}" data-markdown="${_htmlAttr(markdown)}" data-translation-markdown="${_htmlAttr(translationMarkdown)}" data-translatable="${item.translationMarkdown == null ? 'false' : 'true'}" data-has-translation="${translation == null || translation.trim().isEmpty ? 'false' : 'true'}">',
    );
    body.writeln(
      '<button type="button" class="select-dot" title="Select for batch translation" aria-label="Select block"></button>',
    );
    body.writeln(
      '<div class="meta">#${item.contentIndex} | ${_htmlEscape(item.displayType)}${item.pageIndex == null ? '' : ' | p.${item.pageIndex! + 1}'}</div>',
    );
    body.writeln('<div class="content-body">');
    body.writeln(_renderItemHtml(item, paper.paperDir, assetOrigin));
    body.writeln('</div>');
    if (translation != null && translation.trim().isNotEmpty) {
      body.writeln(
        '<div class="translation">${_renderTranslationMarkdownHtml(translation)}</div>',
      );
    }
    body.writeln('</section>');
    i++;
  }

  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self' data: blob:; img-src 'self' data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline';">
  <link rel="stylesheet" href="/katex/katex.min.css">
  <style>
    :root {
      color-scheme: light;
      --body-size: 14px;
      --trans-size: 13px;
      --reader-body-font: "Segoe UI", "Microsoft YaHei UI", "Noto Sans SC", Arial, sans-serif;
      --reader-heading-font: "Segoe UI", "Microsoft YaHei UI", "Noto Sans SC", Arial, sans-serif;
      --doc-bg: #f7f8f5;
      --block-bg: #fff;
      --doc-text: #202422;
      --muted: #5c6761;
      --border: #d9ddd6;
      --accent: #2f6f73;
      --accent-soft: #eaf1ef;
      --multi-accent: #4a90d9;
      --editor-fill: #fafaf7;
      --code-fill: #eceee8;
      --table-header: #e8edeb;
      --danger-soft: #f8ecea;
      --highlight: #fff1a8;
      --overlay-bg: rgba(14, 16, 15, .94);
      --overlay-button-bg: #eef2ed;
      --overlay-button-text: #111;
      --scrollbar-thumb: rgba(47,111,115,.32);
      --scrollbar-thumb-hover: rgba(47,111,115,.52);
      --panel-shadow: rgba(17, 24, 20, .16);
      font-family: var(--reader-body-font);
      font-size: 15px;
      line-height: 1.55;
      color: var(--doc-text);
      background: var(--doc-bg);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 10px 12px 28px;
      background: var(--doc-bg);
      overflow-y: scroll;
      overflow-anchor: none;
      scroll-behavior: auto;
    }
    ::-webkit-scrollbar {
      width: 5px;
      height: 5px;
    }
    ::-webkit-scrollbar-track {
      background: transparent;
    }
    ::-webkit-scrollbar-thumb {
      background: var(--scrollbar-thumb);
      border-radius: 3px;
    }
    ::-webkit-scrollbar-thumb:hover {
      background: var(--scrollbar-thumb-hover);
    }
    .block {
      position: relative;
      margin: 0 0 4px;
      padding: 10px 12px 12px 30px;
      border: 1px solid transparent;
      border-radius: 6px;
      background: transparent;
      contain: content;
      cursor: default;
      transition: background .12s ease, border-color .12s ease, box-shadow .12s ease;
    }
    .block:hover {
      border-color: var(--border);
      background: var(--block-bg);
    }
    .block.selected {
      border-color: var(--accent);
      background: var(--block-bg);
      box-shadow: inset 3px 0 0 var(--accent);
    }
    .block.multi-selected {
      border-color: var(--multi-accent);
      background: var(--block-bg);
      box-shadow: inset 3px 0 0 var(--multi-accent);
    }
    .select-dot {
      position: absolute;
      left: 10px;
      top: 13px;
      width: 11px;
      height: 11px;
      border: 1px solid var(--muted);
      border-radius: 50%;
      background: var(--block-bg);
      cursor: pointer;
      padding: 0;
      opacity: .58;
      transition: opacity .12s ease, border-color .12s ease;
    }
    .block:hover .select-dot,
    .block.selected .select-dot,
    .block.multi-selected .select-dot { opacity: 1; }
    .select-dot:hover { border-color: var(--accent); opacity: 1; }
    .block.multi-selected .select-dot {
      border-color: var(--multi-accent);
      background: var(--multi-accent);
      box-shadow: inset 0 0 0 3px var(--block-bg);
    }
    .meta {
      margin-bottom: 5px;
      color: var(--muted);
      font-size: 11px;
      user-select: none;
    }
    h1, h2, h3, p { margin: 0; }
    h1, h2, h3 { font-family: var(--reader-heading-font); }
    h1 { font-size: 21px; line-height: 1.25; }
    h2 { font-size: 18px; line-height: 1.3; }
    p {
      overflow-wrap: anywhere;
      font-size: var(--body-size);
    }
    ul { margin: 0; padding-left: 22px; }
    li {
      margin: 0 0 6px;
      font-size: var(--body-size);
    }
    .reference-list {
      margin: 0;
      padding-left: 22px;
    }
    .reference-list li {
      margin-bottom: 8px;
      line-height: 1.45;
    }
    .translation {
      margin-top: 12px;
      padding: 8px 10px 8px 12px;
      border-left: 3px solid var(--border);
      border-radius: 0 6px 6px 0;
      background: transparent;
      font-size: var(--trans-size);
    }
    .translation.streaming {
      border-left-color: var(--accent);
    }
    .translation p { margin: 0 0 8px; }
    .translation p,
    .translation li {
      font-size: var(--trans-size);
    }
    .translation p:last-child { margin-bottom: 0; }
    .translation ul, .translation ol { margin: 0; padding-left: 22px; }
    .translation table { margin-top: 4px; }
    .doc-menu {
      position: fixed;
      z-index: 120;
      min-width: 132px;
      display: none;
      padding: 5px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--block-bg);
      box-shadow: 0 8px 28px var(--panel-shadow);
    }
    .doc-menu.open { display: block; }
    .doc-menu button {
      display: block;
      width: 100%;
      border: 0;
      border-radius: 4px;
      padding: 7px 10px;
      background: transparent;
      color: var(--doc-text);
      font: inherit;
      font-size: 13px;
      text-align: left;
      cursor: pointer;
    }
    .doc-menu button:hover { background: var(--accent-soft); }
    .doc-menu button.danger:hover { background: var(--danger-soft); }
    .doc-menu button[hidden] { display: none; }
    .hl-marker { background: var(--highlight); border-radius: 2px; }
    u[data-mark-type="underline"] {
      text-decoration-thickness: 1px;
      text-decoration-color: var(--accent);
      text-underline-offset: 3px;
      text-decoration-skip-ink: none;
    }
    .katex {
      font-family: KaTeX_Main, "Times New Roman", serif;
      text-rendering: auto;
      -webkit-font-smoothing: antialiased;
      font-synthesis: none;
    }
    .katex-html { text-shadow: none; }
    .katex .katex-mathml {
      position: absolute !important;
      clip: rect(1px, 1px, 1px, 1px) !important;
      padding: 0 !important;
      border: 0 !important;
      height: 1px !important;
      width: 1px !important;
      overflow: hidden !important;
    }
    .formula-block {
      padding: 8px 0;
      overflow-x: auto;
      font-size: var(--body-size);
    }
    .thumb-wrap {
      width: 100%;
      height: ${_thumbnailHeight}px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 6px;
      background: var(--code-fill);
      overflow: hidden;
      cursor: zoom-in;
      user-select: none;
    }
    .thumb-wrap img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      display: block;
    }
    .caption {
      margin-top: 8px;
      color: var(--muted);
      font-size: 13px;
    }
    .table-wrap {
      max-height: 420px;
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 6px;
    }
    table {
      border-collapse: collapse;
      min-width: 100%;
      font-size: 13px;
      line-height: 1.3;
    }
    td, th {
      border: 1px solid var(--border);
      padding: 6px 8px;
      vertical-align: middle;
    }
    tr:first-child td, th {
      background: var(--table-header);
      font-weight: 700;
    }
    pre {
      margin: 0;
      padding: 10px;
      border-radius: 6px;
      background: var(--code-fill);
      overflow: auto;
      font-family: Consolas, "Cascadia Mono", monospace;
      font-size: 13px;
      line-height: 1.45;
    }
    #imageOverlay {
      position: fixed;
      inset: 0;
      z-index: 99;
      display: none;
      align-items: center;
      justify-content: center;
      background: var(--overlay-bg);
    }
    #imageOverlay.open { display: flex; }
    #imageOverlay img {
      max-width: 96vw;
      max-height: 94vh;
      object-fit: contain;
    }
    #imageOverlay button {
      position: fixed;
      top: 14px;
      right: 16px;
      border: 0;
      border-radius: 18px;
      padding: 8px 12px;
      background: var(--overlay-button-bg);
      color: var(--overlay-button-text);
      cursor: pointer;
    }
  </style>
</head>
<body>
  $body
  <div id="imageOverlay" onclick="closeImageOverlay()">
    <button type="button" onclick="closeImageOverlay(); event.stopPropagation();">Close</button>
    <img id="imageOverlayImg" alt="">
  </div>
  <div id="docMenu" class="doc-menu" onclick="event.stopPropagation();">
    <button id="lookupMenuButton" type="button">查词典</button>
    <button id="copyMenuButton" type="button">复制本段</button>
    <button id="noteMenuButton" type="button">写入笔记</button>
    <button id="underlineMenuButton" type="button">下划线</button>
    <button id="highlightMenuButton" type="button">高亮</button>
    <button id="deleteMarkMenuButton" class="danger" type="button">删除标注</button>
    <button id="translateMenuButton" type="button">翻译成中文</button>
    <button id="deleteTranslationMenuButton" class="danger" type="button">删除翻译</button>
  </div>
  <script src="/katex/katex.min.js"></script>
  <script src="/katex/contrib/auto-render.min.js"></script>
  <script>
    let menuBlockIndex = null;
    let menuClientX = 220;
    let menuClientY = 80;
    let menuLookupText = '';
    let menuSource = 'content';
    let rightClickedMark = null;
    let marks = $marksJson;
    const selectedBlocks = new Set();
    const mathOptions = {
      throwOnError: false,
      delimiters: [
        {left: "\$\$", right: "\$\$", display: true},
        {left: "\\\\[", right: "\\\\]", display: true},
        {left: "\$", right: "\$", display: false},
        {left: "\\\\(", right: "\\\\)", display: false}
      ]
    };
    function renderMath(container) {
      if (typeof renderMathInElement === 'function') {
        if (container.dataset && container.dataset.mathRendered === 'true') return;
        renderMathInElement(container, mathOptions);
        if (container.dataset) container.dataset.mathRendered = 'true';
      }
    }
    let mathObserver = null;
    const mathRenderQueue = [];
    let mathWorkScheduled = false;
    let documentScrollActiveUntil = 0;
    function scheduleMathWork() {
      if (mathWorkScheduled || !mathRenderQueue.length) return;
      mathWorkScheduled = true;
      const run = function(deadline) {
        mathWorkScheduled = false;
        if (performance.now() < documentScrollActiveUntil) {
          setTimeout(scheduleMathWork, 80);
          return;
        }
        let rendered = 0;
        while (mathRenderQueue.length && rendered < 2) {
          if (rendered > 0 && deadline && deadline.timeRemaining() < 4) break;
          const container = mathRenderQueue.shift();
          if (container && container.isConnected) {
            container.dataset.mathQueued = 'false';
            renderMath(container);
            rendered += 1;
          }
        }
        scheduleMathWork();
      };
      if (typeof requestIdleCallback === 'function') {
        requestIdleCallback(run, { timeout: 500 });
      } else {
        setTimeout(function() {
          run({ timeRemaining: function() { return 8; } });
        }, 32);
      }
    }
    function enqueueMathRendering(container) {
      if (!container || container.dataset.mathRendered === 'true' ||
          container.dataset.mathQueued === 'true') return;
      container.dataset.mathQueued = 'true';
      mathRenderQueue.push(container);
      scheduleMathWork();
    }
    function queueMathRendering(container) {
      if (!container) return;
      if (!mathObserver) {
        enqueueMathRendering(container);
        return;
      }
      mathObserver.observe(container);
    }
    function startLazyMathRendering() {
      const blocks = document.querySelectorAll('.block');
      if (typeof IntersectionObserver !== 'function') {
        blocks.forEach(renderMath);
        return;
      }
      const preloadDistance = Math.max(800, Math.round(window.innerHeight * 2.5));
      mathObserver = new IntersectionObserver(function(entries) {
        entries.forEach(function(entry) {
          if (!entry.isIntersecting) return;
          mathObserver.unobserve(entry.target);
          enqueueMathRendering(entry.target);
        });
      }, {
        root: null,
        rootMargin: preloadDistance + 'px 0px',
        threshold: 0
      });
      blocks.forEach(queueMathRendering);
    }
    window.setReaderTypography = function(bodySize, transSize, bodyFont, headingFont) {
      const root = document.documentElement;
      root.style.setProperty('--body-size', Number(bodySize || 14) + 'px');
      root.style.setProperty('--trans-size', Number(transSize || 13) + 'px');
      if (bodyFont) root.style.setProperty('--reader-body-font', bodyFont);
      if (headingFont) root.style.setProperty('--reader-heading-font', headingFont);
    };
    window.setReaderTheme = function(theme) {
      if (!theme) return;
      const root = document.documentElement;
      root.style.colorScheme = theme.colorScheme || 'light';
      const map = {
        docBg: '--doc-bg',
        blockBg: '--block-bg',
        text: '--doc-text',
        muted: '--muted',
        border: '--border',
        accent: '--accent',
        accentSoft: '--accent-soft',
        multiAccent: '--multi-accent',
        editorFill: '--editor-fill',
        codeFill: '--code-fill',
        tableHeader: '--table-header',
        dangerSoft: '--danger-soft',
        highlight: '--highlight',
        overlayBg: '--overlay-bg',
        overlayButtonBg: '--overlay-button-bg',
        overlayButtonText: '--overlay-button-text',
        scrollbarThumb: '--scrollbar-thumb',
        scrollbarThumbHover: '--scrollbar-thumb-hover',
        shadow: '--panel-shadow'
      };
      for (const key in map) {
        if (theme[key]) root.style.setProperty(map[key], theme[key]);
      }
    };
    function openImageOverlay(src) {
      const overlay = document.getElementById('imageOverlay');
      const img = document.getElementById('imageOverlayImg');
      img.src = src;
      overlay.classList.add('open');
    }
    function closeImageOverlay() {
      const overlay = document.getElementById('imageOverlay');
      const img = document.getElementById('imageOverlayImg');
      overlay.classList.remove('open');
      img.src = '';
    }
    function selectBlock(index) {
      const block = document.querySelector('.block[data-index="' + index + '"]');
      if (!block) return null;
      const selected = document.querySelector('.block.selected');
      if (selected && selected !== block) selected.classList.remove('selected');
      block.classList.add('selected');
      return block;
    }
    function hideDocMenu() {
      const menu = document.getElementById('docMenu');
      menu.classList.remove('open');
      menuBlockIndex = null;
    }
    function selectedLookupText() {
      const text = window.getSelection ? window.getSelection().toString().trim() : '';
      if (!text) return '';
      const match = text.match(/[A-Za-z][A-Za-z\\-']*/);
      return match ? match[0] : '';
    }
    function selectedPlainText() {
      return window.getSelection ? window.getSelection().toString().trim() : '';
    }
    function blockMarkdown(block, source) {
      if (!block) return '';
      return (source === 'trans'
        ? (block.dataset.translationMarkdown || '')
        : (block.dataset.markdown || '')).trim();
    }
    function noteMarkdown(block, source) {
      const selected = selectedPlainText();
      if (selected) return selected;
      return blockMarkdown(block, source);
    }
    function textNodesIn(container) {
      const nodes = [];
      const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) nodes.push(node);
      return nodes;
    }
    function rangeOffsets(container, range) {
      const nodes = textNodesIn(container);
      let offset = 0;
      let start = -1;
      let end = -1;
      for (const node of nodes) {
        const length = node.textContent.length;
        if (node === range.startContainer) start = offset + range.startOffset;
        if (node === range.endContainer) {
          end = offset + range.endOffset;
          break;
        }
        offset += length;
      }
      return start >= 0 && end >= 0 && end > start ? { start, end } : null;
    }
    function rangeForOffsets(container, start, end) {
      const nodes = textNodesIn(container);
      let offset = 0;
      let startNode = null;
      let endNode = null;
      let startOffset = 0;
      let endOffset = 0;
      for (const node of nodes) {
        const length = node.textContent.length;
        if (!startNode && offset + length >= start) {
          startNode = node;
          startOffset = Math.max(0, start - offset);
        }
        if (!endNode && offset + length >= end) {
          endNode = node;
          endOffset = Math.max(0, end - offset);
          break;
        }
        offset += length;
      }
      if (!startNode || !endNode) return null;
      const range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      return range;
    }
    function wrapRange(range, mark) {
      const el = mark.type === 'underline' ? document.createElement('u') : document.createElement('span');
      if (mark.type === 'highlight') el.className = 'hl-marker';
      el.dataset.markType = mark.type;
      el.dataset.markId = mark.id;
      try {
        range.surroundContents(el);
      } catch (_) {
        const fragment = range.extractContents();
        el.appendChild(fragment);
        range.insertNode(el);
      }
    }
    function saveMarks() {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('saveMarks', JSON.stringify(marks));
      }
    }
    function applyMark(type) {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !selection.rangeCount || menuBlockIndex === null) return;
      const block = document.querySelector('.block[data-index="' + menuBlockIndex + '"]');
      const body = block ? block.querySelector('.content-body') : null;
      if (!body) return;
      const range = selection.getRangeAt(0);
      if (!body.contains(range.commonAncestorContainer)) return;
      const offsets = rangeOffsets(body, range);
      if (!offsets) return;
      const mark = {
        id: Date.now().toString(36) + Math.random().toString(36).slice(2),
        type,
        ci: menuBlockIndex,
        source: 'content',
        startOffset: offsets.start,
        endOffset: offsets.end
      };
      wrapRange(range, mark);
      marks.push(mark);
      selection.removeAllRanges();
      saveMarks();
    }
    function restoreMarks() {
      for (const mark of marks) {
        const block = document.querySelector('.block[data-index="' + mark.ci + '"]');
        const body = block ? block.querySelector('.content-body') : null;
        if (!body) continue;
        const range = rangeForOffsets(body, Number(mark.startOffset), Number(mark.endOffset));
        if (range && range.toString()) wrapRange(range, mark);
      }
    }
    function deleteRightClickedMark() {
      if (!rightClickedMark) return;
      const id = rightClickedMark.dataset.markId;
      const parent = rightClickedMark.parentNode;
      while (rightClickedMark.firstChild) parent.insertBefore(rightClickedMark.firstChild, rightClickedMark);
      parent.removeChild(rightClickedMark);
      marks = marks.filter((mark) => mark.id !== id);
      rightClickedMark = null;
      saveMarks();
    }
    function setBlockMultiSelected(index, selected) {
      const block = document.querySelector('.block[data-index="' + index + '"]');
      if (!block) return;
      block.classList.toggle('multi-selected', selected);
    }
    function toggleBlockSelection(index) {
      if (selectedBlocks.has(index)) {
        selectedBlocks.delete(index);
        setBlockMultiSelected(index, false);
      } else {
        selectedBlocks.add(index);
        setBlockMultiSelected(index, true);
      }
    }
    window.getSelectedBlocks = function() {
      return Array.from(selectedBlocks).sort((a, b) => a - b);
    };
    window.clearSelectedBlocks = function() {
      for (const index of selectedBlocks) setBlockMultiSelected(index, false);
      selectedBlocks.clear();
    };
    window.scrollToBlock = function(index) {
      const block = selectBlock(index);
      if (!block) return;
      block.scrollIntoView({ block: 'center', inline: 'nearest' });
    };
    window.getReaderScrollPosition = function() {
      const doc = document.scrollingElement || document.documentElement || document.body;
      const top = window.scrollY || doc.scrollTop || document.documentElement.scrollTop || document.body.scrollTop || 0;
      let index = null;
      const blocks = document.querySelectorAll('.block[data-index]');
      const viewportTop = 0;
      for (const block of blocks) {
        const rect = block.getBoundingClientRect();
        if (rect.bottom >= viewportTop) {
          index = Number(block.dataset.index);
          break;
        }
      }
      return { top, index };
    };
    window.restoreReaderScrollPosition = function(index, top) {
      const doc = document.scrollingElement || document.documentElement || document.body;
      const restoreTop = Number(top || 0);
      if (index !== null && index !== undefined) {
        const block = document.querySelector('.block[data-index="' + index + '"]');
        if (block) block.scrollIntoView({ block: 'start', inline: 'nearest' });
      }
      requestAnimationFrame(function() {
        if (restoreTop > 0) {
          window.scrollTo(0, restoreTop);
          doc.scrollTop = restoreTop;
        }
        requestAnimationFrame(function() {
          if (restoreTop > 0) {
            window.scrollTo(0, restoreTop);
            doc.scrollTop = restoreTop;
          }
        });
      });
    };
    window.restoreReaderScrollPositionExact = function(top) {
      const doc = document.scrollingElement || document.documentElement || document.body;
      const restoreTop = Number(top || 0);
      if (restoreTop <= 0) return;
      requestAnimationFrame(function() {
        window.scrollTo(0, restoreTop);
        doc.scrollTop = restoreTop;
        requestAnimationFrame(function() {
          window.scrollTo(0, restoreTop);
          doc.scrollTop = restoreTop;
        });
      });
    };
    window.upsertTranslation = function(index, html, markdown, streaming) {
      const block = document.querySelector('.block[data-index="' + index + '"]');
      if (!block) return;
      let translation = block.querySelector('.translation');
      if (!translation) {
        translation = document.createElement('div');
        translation.className = 'translation';
        block.appendChild(translation);
      }
      translation.innerHTML = html;
      if (translation.dataset) delete translation.dataset.mathRendered;
      translation.classList.toggle('streaming', !!streaming);
      block.dataset.hasTranslation = 'true';
      block.dataset.translationMarkdown = markdown || '';
      queueMathRendering(translation);
    };
    window.removeTranslation = function(index) {
      const block = document.querySelector('.block[data-index="' + index + '"]');
      if (!block) return;
      const translation = block.querySelector('.translation');
      if (translation) translation.remove();
      block.dataset.hasTranslation = 'false';
      block.dataset.translationMarkdown = '';
    };
    document.addEventListener('click', function(event) {
      hideDocMenu();
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('dismissOverlays');
      }
      const dot = event.target.closest('.select-dot');
      if (dot) {
        const blockForDot = dot.closest('.block');
        if (!blockForDot) return;
        event.stopPropagation();
        toggleBlockSelection(Number(blockForDot.dataset.index));
        return;
      }
      const block = event.target.closest('.block');
      if (!block || block.contains(document.getElementById('imageOverlay'))) return;
      const index = Number(block.dataset.index);
      selectBlock(index);
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('blockClick', index);
      }
    });
    document.addEventListener('contextmenu', function(event) {
      const block = event.target.closest('.block');
      if (!block) return;
      event.preventDefault();
      const index = Number(block.dataset.index);
      selectBlock(index);
      menuBlockIndex = index;
      const menu = document.getElementById('docMenu');
      const translateButton = document.getElementById('translateMenuButton');
      const lookupButton = document.getElementById('lookupMenuButton');
      const copyButton = document.getElementById('copyMenuButton');
      const noteButton = document.getElementById('noteMenuButton');
      const underlineButton = document.getElementById('underlineMenuButton');
      const highlightButton = document.getElementById('highlightMenuButton');
      const deleteMarkButton = document.getElementById('deleteMarkMenuButton');
      const deleteButton = document.getElementById('deleteTranslationMenuButton');
      const lookupText = selectedLookupText();
      const selectedText = selectedPlainText();
      rightClickedMark = event.target.closest('[data-mark-id]');
      menuSource = event.target.closest('.translation') ? 'trans' : 'content';
      menuLookupText = lookupText;
      translateButton.hidden = menuSource !== 'content' || block.dataset.translatable !== 'true';
      lookupButton.hidden = !lookupText;
      copyButton.hidden = !blockMarkdown(block, menuSource);
      noteButton.hidden = !noteMarkdown(block, menuSource);
      underlineButton.hidden = !selectedText;
      highlightButton.hidden = !selectedText;
      deleteMarkButton.hidden = !rightClickedMark;
      deleteButton.hidden = menuSource !== 'trans' || block.dataset.hasTranslation !== 'true';
      if (translateButton.hidden && lookupButton.hidden && copyButton.hidden && noteButton.hidden && underlineButton.hidden && highlightButton.hidden && deleteMarkButton.hidden && deleteButton.hidden) return;
      const x = Math.min(event.clientX, window.innerWidth - 150);
      const y = Math.min(event.clientY, window.innerHeight - 86);
      menuClientX = x;
      menuClientY = y;
      menu.style.left = x + 'px';
      menu.style.top = y + 'px';
      menu.classList.add('open');
    });
    document.getElementById('translateMenuButton').addEventListener('click', function() {
      if (menuBlockIndex !== null && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('translateBlock', menuBlockIndex);
      }
      hideDocMenu();
    });
    document.getElementById('lookupMenuButton').addEventListener('click', function() {
      const text = menuLookupText || selectedLookupText();
      if (text && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('lookupSelection', text, menuClientX, menuClientY);
      }
      hideDocMenu();
    });
    document.getElementById('copyMenuButton').addEventListener('click', function() {
      const block = document.querySelector('.block[data-index="' + menuBlockIndex + '"]');
      const markdown = blockMarkdown(block, menuSource);
      if (markdown && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('copyMarkdown', markdown);
      }
      hideDocMenu();
    });
    document.getElementById('noteMenuButton').addEventListener('click', function() {
      const block = document.querySelector('.block[data-index="' + menuBlockIndex + '"]');
      const markdown = noteMarkdown(block, menuSource);
      if (markdown && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('appendNote', markdown);
      }
      hideDocMenu();
    });
    document.getElementById('underlineMenuButton').addEventListener('click', function() {
      applyMark('underline');
      hideDocMenu();
    });
    document.getElementById('highlightMenuButton').addEventListener('click', function() {
      applyMark('highlight');
      hideDocMenu();
    });
    document.getElementById('deleteMarkMenuButton').addEventListener('click', function() {
      deleteRightClickedMark();
      hideDocMenu();
    });
    document.getElementById('deleteTranslationMenuButton').addEventListener('click', function() {
      if (menuBlockIndex !== null && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('deleteTranslation', menuBlockIndex);
      }
      hideDocMenu();
    });
    document.addEventListener('keydown', function(event) {
      if (event.key === 'Escape') {
        closeImageOverlay();
        hideDocMenu();
      }
    });
    let pendingScrollX = 0;
    let pendingScrollY = 0;
    let scrollFrame = 0;
    let precisionGestureUntil = 0;
    function flushDocumentScroll() {
      scrollFrame = 0;
      const x = pendingScrollX;
      const y = pendingScrollY;
      pendingScrollX = 0;
      pendingScrollY = 0;
      window.scrollBy(x, y);
    }
    function queueDocumentScroll(x, y, speed) {
      documentScrollActiveUntil = performance.now() + 160;
      pendingScrollX += x * speed;
      pendingScrollY += y * speed;
      if (!scrollFrame) {
        scrollFrame = requestAnimationFrame(flushDocumentScroll);
      }
    }
    window.dualectPanScroll = function(x, y) {
      queueDocumentScroll(-(Number(x) || 0), -(Number(y) || 0), 1.35);
    };
    document.addEventListener('wheel', function(event) {
      if (event.ctrlKey || event.metaKey) return;

      const modeFactor = event.deltaMode === WheelEvent.DOM_DELTA_LINE
        ? 16
        : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
          ? window.innerHeight
          : 1;
      const legacyDelta = Math.abs(event.wheelDeltaY || event.wheelDelta || 0);
      const wheelRemainder = legacyDelta % 120;
      const looksLikeMouseWheel = Math.abs(event.deltaX) < 0.01 &&
        legacyDelta >= 119.5 &&
        (wheelRemainder < 0.5 || 120 - wheelRemainder < 0.5);
      const now = performance.now();
      if (!looksLikeMouseWheel) {
        precisionGestureUntil = now + 180;
      }
      const isPrecisionGesture = now < precisionGestureUntil;
      const speed = isPrecisionGesture ? 3.0 : 0.46;

      event.preventDefault();
      queueDocumentScroll(
        event.deltaX * modeFactor,
        event.deltaY * modeFactor,
        speed
      );
    }, { passive: false });
    startLazyMathRendering();
    restoreMarks();
  </script>
</body>
</html>
''';
}

bool _shouldGroupContentItem(MineruContentItem item) {
  return item.type == 'list' || item.type == 'reference';
}

void _writeGroupedItemsHtml(
  StringBuffer body,
  List<MineruContentItem> group,
  MineruPaper paper,
  String assetOrigin,
) {
  final first = group.first;
  final type = first.type == 'reference' ? 'references' : 'list';
  final markdowns = [
    for (final item in group)
      if ((item.translationMarkdown ?? item.primaryText).trim().isNotEmpty)
        item.translationMarkdown ?? item.primaryText,
  ];
  final markdown = markdowns.join('\n');
  final hasTranslation = group.any((item) {
    final translation = paper.translations[item.contentIndex.toString()];
    return translation != null && translation.trim().isNotEmpty;
  });
  final translationMarkdown = [
    for (final item in group)
      if ((paper.translations[item.contentIndex.toString()] ?? '')
          .trim()
          .isNotEmpty)
        paper.translations[item.contentIndex.toString()]!.trim(),
  ].join('\n');

  body.writeln(
    '<section class="block $type" data-index="${first.contentIndex}" data-markdown="${_htmlAttr(markdown)}" data-translation-markdown="${_htmlAttr(translationMarkdown)}" data-translatable="${markdown.trim().isEmpty ? 'false' : 'true'}" data-has-translation="${hasTranslation ? 'true' : 'false'}">',
  );
  body.writeln(
    '<button type="button" class="select-dot" title="Select for batch translation" aria-label="Select block"></button>',
  );
  body.writeln(
    '<div class="meta">#${first.contentIndex}-${group.last.contentIndex} | ${_htmlEscape(type)}${first.pageIndex == null ? '' : ' | p.${first.pageIndex! + 1}'}</div>',
  );
  body.writeln('<div class="content-body">');
  if (first.type == 'reference') {
    body.writeln('<ol class="reference-list">');
    for (final item in group) {
      body.writeln('<li>${_htmlEscape(item.primaryText)}</li>');
    }
    body.writeln('</ol>');
  } else {
    for (final item in group) {
      body.writeln(_renderItemHtml(item, paper.paperDir, assetOrigin));
    }
  }
  body.writeln('</div>');
  if (translationMarkdown.trim().isNotEmpty) {
    body.writeln(
      '<div class="translation">${_renderTranslationMarkdownHtml(translationMarkdown)}</div>',
    );
  }
  body.writeln('</section>');
}

String _readMarksJson(String paperDir) {
  try {
    final file = File(_joinPath(paperDir, 'marks.json'));
    if (!file.existsSync()) {
      return '[]';
    }
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is List ? jsonEncode(decoded) : '[]';
  } catch (_) {
    return '[]';
  }
}

String _renderItemHtml(
  MineruContentItem item,
  String paperDir,
  String assetOrigin,
) {
  switch (item.type) {
    case 'text':
    case 'reference':
      final text = _htmlEscape(item.primaryText);
      if (item.textLevel == 1) {
        return '<h1>$text</h1>';
      }
      if (item.textLevel == 2) {
        return '<h2>$text</h2>';
      }
      return '<p>$text</p>';
    case 'list':
      final items = item.listItems
          .map((entry) => '<li>${_htmlEscape(entry)}</li>')
          .join();
      return '<ul>$items</ul>';
    case 'equation':
      return '<div class="formula-block">${_htmlEscape(item.equationMarkdown)}</div>';
    case 'image':
    case 'chart':
      return _renderImageHtml(item, paperDir, assetOrigin);
    case 'table':
      final caption = item.tableCaption.isEmpty
          ? ''
          : '<div class="caption">${_htmlEscape(item.tableCaption.join(' '))}</div>';
      final table = item.tableBody.trim().isNotEmpty
          ? '<div class="table-wrap">${item.tableBody}</div>'
          : _renderImageHtml(item, paperDir, assetOrigin);
      return '$caption$table';
    case 'code':
      final imagePath = item.absoluteImagePath(paperDir);
      if (imagePath != null && File(imagePath).existsSync()) {
        return _renderImageHtml(item, paperDir, assetOrigin);
      }
      final caption = item.codeCaption.isEmpty
          ? ''
          : '<div class="caption">${_htmlEscape(item.codeCaption.join(' '))}</div>';
      return '$caption<pre>${_htmlEscape(item.codeBody)}</pre>';
    default:
      return '<p>${_htmlEscape(item.primaryText)}</p>';
  }
}

String _renderImageHtml(
  MineruContentItem item,
  String paperDir,
  String assetOrigin,
) {
  final imagePath = item.absoluteImagePath(paperDir);
  final captions = [...item.imageCaption, ...item.chartCaption];
  final caption = captions.isEmpty
      ? ''
      : '<div class="caption">${_htmlEscape(captions.join(' '))}</div>';
  if (imagePath == null || !File(imagePath).existsSync()) {
    return '<div class="thumb-wrap">${_htmlEscape(item.imagePath ?? 'missing image')}</div>$caption';
  }

  final fileName = imagePath.split(RegExp(r'[\\/]')).last;
  final uri = '$assetOrigin/images/${Uri.encodeComponent(fileName)}';
  final escapedUri = _htmlAttr(uri);
  return '''
<div class="thumb-wrap" ondblclick="openImageOverlay('$escapedUri')" oncontextmenu="openImageOverlay('$escapedUri'); return false;">
  <img src="$escapedUri" loading="lazy" alt="">
</div>
$caption
''';
}

String _renderTranslationMarkdownHtml(String value) {
  final protected = _protectLatexForMarkdown(value.trim());
  final html = md.markdownToHtml(
    protected.text,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  return html.replaceAllMapped(RegExp('\u0000MATH(\\d+)\u0000'), (match) {
    final index = int.tryParse(match.group(1) ?? '');
    if (index == null || index < 0 || index >= protected.formulas.length) {
      return '';
    }
    return _htmlEscape(protected.formulas[index]);
  });
}

_ProtectedLatex _protectLatexForMarkdown(String value) {
  final formulas = <String>[];
  var text = value.replaceAllMapped(
    RegExp(r'\$\$([\s\S]*?)\$\$', multiLine: true),
    (match) {
      formulas.add(match.group(0) ?? '');
      return '\u0000MATH${formulas.length - 1}\u0000';
    },
  );
  text = text.replaceAllMapped(RegExp(r'\$([^\n]+?)\$'), (match) {
    formulas.add(match.group(0) ?? '');
    return '\u0000MATH${formulas.length - 1}\u0000';
  });
  return _ProtectedLatex(text: text, formulas: formulas);
}

class _ProtectedLatex {
  const _ProtectedLatex({required this.text, required this.formulas});

  final String text;
  final List<String> formulas;
}

String _htmlEscape(String value) {
  return const HtmlEscape(HtmlEscapeMode.element).convert(value);
}

String _htmlAttr(String value) {
  return const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
}

double _estimateItemHeight(MineruContentItem item, String? translation) {
  const cardChrome = 54.0;
  final translationHeight = translation == null || translation.trim().isEmpty
      ? 0.0
      : 26.0 + _estimateTextHeight(translation, charsPerLine: 48);

  final contentHeight = switch (item.type) {
    'text' =>
      item.textLevel == 1
          ? 58.0
          : item.textLevel == 2
          ? 50.0
          : _estimateTextHeight(item.primaryText, charsPerLine: 72),
    'list' =>
      12.0 +
          item.listItems.fold<double>(
            0,
            (sum, value) =>
                sum + _estimateTextHeight(value, charsPerLine: 64) + 4,
          ),
    'equation' => item.primaryText.length > 90 ? 104.0 : 72.0,
    'image' || 'chart' =>
      _thumbnailHeight +
          (item.imageCaption.isNotEmpty || item.chartCaption.isNotEmpty
              ? 34.0
              : 0.0),
    'table' =>
      42.0 +
          math.min(item.tableRows.length, 32) * 34.0 +
          (item.tableCaption.isNotEmpty ? 34.0 : 0.0),
    'code' =>
      28.0 +
          math.max(1, item.codeBody.split('\n').length) * 22.0 +
          (item.codeCaption.isNotEmpty ? 34.0 : 0.0),
    _ => _estimateTextHeight(item.primaryText, charsPerLine: 72),
  };

  return math.max(72.0, cardChrome + contentHeight + translationHeight);
}

double _estimateTextHeight(String text, {required int charsPerLine}) {
  final paragraphs = text.trim().isEmpty ? const [''] : text.trim().split('\n');
  var lines = 0;
  for (final paragraph in paragraphs) {
    lines += math.max(1, (paragraph.length / charsPerLine).ceil());
  }
  return 8.0 + lines * 22.0;
}

class MineruContentCard extends StatelessWidget {
  const MineruContentCard({
    super.key,
    required this.item,
    required this.imageRoot,
    required this.translation,
  });

  final MineruContentItem item;
  final String imageRoot;
  final String? translation;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '#${item.contentIndex}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.pageIndex == null
                        ? item.displayType
                        : '${item.displayType} | p.${item.pageIndex! + 1}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildContent(context),
              if (translation != null && translation!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: ReaderColors.of(context).accentSoft,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: _TextOrMarkdownBlock(markdown: translation!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (item.type) {
      case 'text':
      case 'reference':
        return _buildText(context);
      case 'list':
        return _TextOrMarkdownBlock(markdown: item.listMarkdown);
      case 'equation':
        return _MarkdownBlock(markdown: item.equationMarkdown);
      case 'image':
      case 'chart':
        return _ImageContent(item: item, imageRoot: imageRoot);
      case 'table':
        return _TableContent(item: item, imageRoot: imageRoot);
      case 'code':
        return _ImageContent(item: item, imageRoot: imageRoot);
      default:
        return _TextOrMarkdownBlock(markdown: item.primaryText);
    }
  }

  Widget _buildText(BuildContext context) {
    final text = item.primaryText;
    final level = item.textLevel;
    if (level == 1 || level == 2) {
      return SelectableText(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: level == 1 ? 20 : 17,
        ),
      );
    }

    return _TextOrMarkdownBlock(markdown: text);
  }
}

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.item, required this.imageRoot});

  final MineruContentItem item;
  final String imageRoot;

  @override
  Widget build(BuildContext context) {
    final imagePath = item.absoluteImagePath(imageRoot);
    final captions = [...item.imageCaption, ...item.chartCaption];
    final imageFile = imagePath == null ? null : File(imagePath);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (imageFile != null && imageFile.existsSync())
          _ImageContextMenu(
            imagePath: imagePath!,
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: ColoredBox(
                  color: ReaderColors.of(context).codeFill,
                  child: SizedBox(
                    height: _thumbnailHeight,
                    width: double.infinity,
                    child: Image.file(
                      imageFile,
                      fit: BoxFit.contain,
                      cacheWidth: _thumbnailCacheWidth,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: _thumbnailHeight,
            child: _MissingInlineAsset(path: item.imagePath ?? 'missing image'),
          ),
        if (captions.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(
            captions.join(' '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ImageContextMenu extends StatelessWidget {
  const _ImageContextMenu({required this.imagePath, required this.child});

  final String imagePath;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) {
        _showImageMenu(context, details.globalPosition, imagePath);
      },
      onDoubleTap: () => _showImagePreview(context, imagePath),
      child: Tooltip(message: 'Right-click to view full image', child: child),
    );
  }
}

Future<void> _showImageMenu(
  BuildContext context,
  Offset position,
  String imagePath,
) async {
  final selected = await showMenu<_ImageMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: const [
      PopupMenuItem(
        value: _ImageMenuAction.view,
        child: Text('View full image'),
      ),
    ],
  );

  if (!context.mounted || selected == null) {
    return;
  }

  switch (selected) {
    case _ImageMenuAction.view:
      _showImagePreview(context, imagePath);
  }
}

enum _ImageMenuAction { view }

void _showImagePreview(BuildContext context, String imagePath) {
  showDialog<void>(
    context: context,
    builder: (context) {
      return Dialog.fullscreen(
        backgroundColor: ReaderColors.of(context).pdfBackground,
        child: _FullImagePreview(imagePath: imagePath),
      );
    },
  );
}

class _FullImagePreview extends StatelessWidget {
  const _FullImagePreview({required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Center(
              child: file.existsSync()
                  ? Image.file(file, fit: BoxFit.contain)
                  : Text(
                      imagePath,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          top: 14,
          right: 14,
          child: IconButton.filled(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }
}

class _TableContent extends StatelessWidget {
  const _TableContent({required this.item, required this.imageRoot});

  final MineruContentItem item;
  final String imageRoot;

  @override
  Widget build(BuildContext context) {
    final rows = item.tableRows;
    final imagePath = item.absoluteImagePath(imageRoot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.tableCaption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              item.tableCaption.join(' '),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        if (rows.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _MarkdownTable(rows: rows),
          )
        else if (imagePath != null && File(imagePath).existsSync())
          Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            cacheWidth: 1100,
            filterQuality: FilterQuality.medium,
          )
        else
          _TextOrMarkdownBlock(markdown: _stripHtml(item.tableBody)),
      ],
    );
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final columnCount = rows.fold<int>(
      0,
      (maxCount, row) => math.max(maxCount, row.length),
    );
    final columnWidths = <int, TableColumnWidth>{
      for (var i = 0; i < columnCount; i++)
        i: FixedColumnWidth(i == 0 ? 150 : 330),
    };

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: columnWidths,
      border: TableBorder.all(color: colorScheme.outlineVariant),
      children: [
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
          TableRow(
            decoration: BoxDecoration(
              color: rowIndex == 0
                  ? ReaderColors.of(context).tableHeader
                  : null,
            ),
            children: [
              for (
                var columnIndex = 0;
                columnIndex < columnCount;
                columnIndex++
              )
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontWeight: rowIndex == 0
                          ? FontWeight.w700
                          : FontWeight.w400,
                      fontSize: 13,
                      height: 1.25,
                    ),
                    child: _TextOrMarkdownBlock(
                      markdown: columnIndex < rows[rowIndex].length
                          ? rows[rowIndex][columnIndex]
                          : '',
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _MissingInlineAsset extends StatelessWidget {
  const _MissingInlineAsset({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(Icons.broken_image_outlined, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(path, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

class _MarkdownBlock extends StatelessWidget {
  const _MarkdownBlock({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      selectable: false,
      data: markdown,
      builders: _markdownBuilders(context),
      extensionSet: _markdownExtensionSet,
      styleSheet: _markdownStyleSheet(context),
    );
  }
}

bool _needsMarkdownRendering(String value) {
  final text = value.trim();
  if (text.isEmpty) {
    return false;
  }

  return text.contains(r'$') ||
      text.contains(r'\(') ||
      text.contains(r'\[') ||
      text.startsWith('- ') ||
      text.startsWith('* ') ||
      RegExp(r'^\d+\.\s').hasMatch(text) ||
      text.startsWith('#') ||
      text.startsWith('>') ||
      text.startsWith('```') ||
      text.contains('\n|') ||
      text.startsWith('|');
}

class _TextOrMarkdownBlock extends StatelessWidget {
  const _TextOrMarkdownBlock({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    if (_needsMarkdownRendering(markdown)) {
      return _MarkdownBlock(markdown: markdown);
    }

    return SelectableText(
      markdown,
      style: DefaultTextStyle.of(context).style.copyWith(height: 1.45),
    );
  }
}

class _PaneResizeHandle extends StatelessWidget {
  const _PaneResizeHandle({required this.width, required this.onDragUpdate});

  final double width;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
        child: Tooltip(
          message: 'Resize panes',
          child: SizedBox(
            width: width,
            child: Center(
              child: Container(
                width: 2,
                height: double.infinity,
                color: colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExtractionDetailPanel extends StatelessWidget {
  const _ExtractionDetailPanel({
    required this.extracting,
    required this.progress,
    required this.message,
    required this.logs,
    required this.onCancel,
    required this.onStartReading,
    required this.onDismiss,
  });

  final bool extracting;
  final double progress;
  final String message;
  final List<String> logs;
  final VoidCallback? onCancel;
  final VoidCallback? onStartReading;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: ReaderColors.of(context).surfaceAlt,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          extracting
                              ? Icons.cloud_sync_outlined
                              : Icons.info_outline,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '\u6587\u732e\u63d0\u53d6',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (onDismiss != null)
                          IconButton(
                            tooltip: '\u5173\u95ed',
                            onPressed: onDismiss,
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(message, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: extracting
                          ? progress.clamp(0, 1).toDouble()
                          : null,
                      minHeight: 5,
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 180,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withAlpha(
                            90,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Scrollbar(
                          thumbVisibility: true,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(10),
                            itemCount: logs.length,
                            itemBuilder: (context, index) {
                              return Text(
                                logs[index],
                                style: Theme.of(context).textTheme.bodySmall,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (onCancel != null)
                          OutlinedButton.icon(
                            onPressed: onCancel,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('\u7ec8\u6b62'),
                          ),
                        if (onStartReading != null) ...[
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: onStartReading,
                            icon: const Icon(Icons.play_arrow_outlined),
                            label: const Text('开始阅读'),
                          ),
                        ],
                        if (onDismiss != null) ...[
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: onDismiss,
                            child: const Text('\u5173\u95ed'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DictionaryLookupPanel extends StatefulWidget {
  const _DictionaryLookupPanel({
    required this.query,
    required this.loading,
    required this.error,
    required this.results,
    required this.onSearch,
    required this.onDismiss,
  });

  final String query;
  final bool loading;
  final String? error;
  final List<DictionaryEntry> results;
  final ValueChanged<String> onSearch;
  final VoidCallback onDismiss;

  @override
  State<_DictionaryLookupPanel> createState() => _DictionaryLookupPanelState();
}

class _DictionaryLookupPanelState extends State<_DictionaryLookupPanel> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(_DictionaryLookupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query &&
        widget.query != _controller.text.trim()) {
      _controller.text = widget.query;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      return;
    }
    widget.onSearch(query);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onDismiss,
        child: Stack(
          children: [
            Positioned(
              right: 18,
              bottom: 18,
              width: 360,
              child: GestureDetector(
                onTap: () {},
                child: _DictionaryCard(
                  title: '\u8bcd\u5178',
                  query: widget.query,
                  loading: widget.loading,
                  error: widget.error,
                  results: widget.results,
                  onDismiss: widget.onDismiss,
                  header: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 34,
                          child: TextField(
                            controller: _controller,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => _submit(),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '\u8f93\u5165\u5355\u8bcd',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _ToolbarIconButton(
                        tooltip: '\u67e5\u8be2',
                        icon: Icons.search,
                        enabled: !widget.loading,
                        onPressed: _submit,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DictionaryLookupOverlay extends StatelessWidget {
  const _DictionaryLookupOverlay({
    required this.position,
    required this.query,
    required this.loading,
    required this.error,
    required this.results,
    required this.onDismiss,
  });

  final Offset position;
  final String query;
  final bool loading;
  final String? error;
  final List<DictionaryEntry> results;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onDismiss,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const width = 330.0;
            const height = 300.0;
            final left = position.dx
                .clamp(8.0, math.max(8.0, constraints.maxWidth - width - 8))
                .toDouble();
            final top = position.dy
                .clamp(52.0, math.max(52.0, constraints.maxHeight - height - 8))
                .toDouble();
            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: width,
                  child: GestureDetector(
                    onTap: () {},
                    child: _DictionaryCard(
                      title: query,
                      query: query,
                      loading: loading,
                      error: error,
                      results: results,
                      onDismiss: onDismiss,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DictionaryCard extends StatelessWidget {
  const _DictionaryCard({
    required this.title,
    required this.query,
    required this.loading,
    required this.error,
    required this.results,
    required this.onDismiss,
    this.header,
  });

  final String title;
  final String query;
  final bool loading;
  final String? error;
  final List<DictionaryEntry> results;
  final VoidCallback onDismiss;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final readerColors = ReaderColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: readerColors.shadow,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _ToolbarIconButton(
                    tooltip: '\u5173\u95ed',
                    icon: Icons.close,
                    enabled: true,
                    onPressed: onDismiss,
                  ),
                ],
              ),
              if (header != null) ...[const SizedBox(height: 8), header!],
              const SizedBox(height: 8),
              if (loading)
                const LinearProgressIndicator(minHeight: 2)
              else if (error != null)
                Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                )
              else if (query.trim().isEmpty)
                Text(
                  '\u8f93\u5165\u5355\u8bcd\u540e\u67e5\u8be2',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (results.isEmpty)
                Text(
                  '\u672a\u627e\u5230\u5339\u914d\u7ed3\u679c',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 12),
                    itemBuilder: (context, index) =>
                        _DictionaryEntryView(entry: results[index]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DictionaryEntryView extends StatelessWidget {
  const _DictionaryEntryView({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.word,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (entry.translation.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            entry.translation.replaceAll(r'\n', '\n'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        if (entry.definition.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            entry.definition.replaceAll(r'\n', '\n'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _ReaderToolbar extends StatelessWidget {
  const _ReaderToolbar({
    required this.pdfVisible,
    required this.notesVisible,
    this.onBack,
    required this.onTogglePdf,
    required this.onToggleNotes,
    required this.onBatchTranslate,
    required this.onExtract,
    required this.onOpenSettings,
    required this.onDictionary,
    required this.onBodyFontDec,
    required this.onBodyFontInc,
    required this.onTransFontDec,
    required this.onTransFontInc,
    required this.linkMode,
    required this.onLinkModeChanged,
  });

  final bool pdfVisible;
  final bool notesVisible;
  final VoidCallback? onBack;
  final VoidCallback onTogglePdf;
  final VoidCallback onToggleNotes;
  final VoidCallback? onBatchTranslate;
  final VoidCallback? onExtract;
  final VoidCallback onOpenSettings;
  final VoidCallback onDictionary;
  final VoidCallback onBodyFontDec;
  final VoidCallback onBodyFontInc;
  final VoidCallback onTransFontDec;
  final VoidCallback onTransFontInc;
  final PdfContentLinkMode linkMode;
  final ValueChanged<PdfContentLinkMode> onLinkModeChanged;

  @override
  Widget build(BuildContext context) {
    final readerColors = ReaderColors.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: readerColors.glass,
        border: Border(bottom: BorderSide(color: readerColors.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 44,
          child: Stack(
            children: [
              const Positioned.fill(
                child: DragToMoveArea(child: SizedBox.expand()),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const compactThreshold = 760.0;
                    const rightControlsWidth = 30.0 + 4.0 + 126.0;
                    final backWidth = onBack == null ? 0.0 : 30.0;
                    final availableForTools = math.max(
                      0.0,
                      constraints.maxWidth - backWidth - rightControlsWidth,
                    );
                    final compact = availableForTools < compactThreshold;
                    final tools = _ReaderToolbarTools(
                      compact: compact,
                      pdfVisible: pdfVisible,
                      onTogglePdf: onTogglePdf,
                      onBatchTranslate: onBatchTranslate,
                      onExtract: onExtract,
                      onOpenSettings: onOpenSettings,
                      onDictionary: onDictionary,
                      onBodyFontDec: onBodyFontDec,
                      onBodyFontInc: onBodyFontInc,
                      onTransFontDec: onTransFontDec,
                      onTransFontInc: onTransFontInc,
                      linkMode: linkMode,
                      onLinkModeChanged: onLinkModeChanged,
                    );

                    return Row(
                      children: [
                        if (onBack != null)
                          _ToolbarIconButton(
                            tooltip: '返回文献库',
                            icon: Icons.arrow_back,
                            enabled: true,
                            onPressed: onBack!,
                          ),
                        if (availableForTools > 0)
                          SizedBox(
                            width: availableForTools,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: tools,
                            ),
                          ),
                        const Spacer(),
                        _ToolbarToggleButton(
                          tooltip: notesVisible ? '隐藏笔记' : '显示笔记',
                          icon: Icons.notes_outlined,
                          active: notesVisible,
                          onPressed: onToggleNotes,
                        ),
                        const SizedBox(width: 4),
                        const _WindowControls(),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderToolbarTools extends StatelessWidget {
  const _ReaderToolbarTools({
    required this.compact,
    required this.pdfVisible,
    required this.onTogglePdf,
    required this.onBatchTranslate,
    required this.onExtract,
    required this.onOpenSettings,
    required this.onDictionary,
    required this.onBodyFontDec,
    required this.onBodyFontInc,
    required this.onTransFontDec,
    required this.onTransFontInc,
    required this.linkMode,
    required this.onLinkModeChanged,
  });

  final bool compact;
  final bool pdfVisible;
  final VoidCallback onTogglePdf;
  final VoidCallback? onBatchTranslate;
  final VoidCallback? onExtract;
  final VoidCallback onOpenSettings;
  final VoidCallback onDictionary;
  final VoidCallback onBodyFontDec;
  final VoidCallback onBodyFontInc;
  final VoidCallback onTransFontDec;
  final VoidCallback onTransFontInc;
  final PdfContentLinkMode linkMode;
  final ValueChanged<PdfContentLinkMode> onLinkModeChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolbarToggleButton(
            tooltip: pdfVisible ? '隐藏 PDF' : '显示 PDF',
            icon: Icons.picture_as_pdf_outlined,
            active: pdfVisible,
            onPressed: onTogglePdf,
          ),
          const _ToolbarSeparator(),
          _ToolbarLinkModeControl(
            value: linkMode,
            onChanged: onLinkModeChanged,
            compact: compact,
          ),
          const _ToolbarSeparator(),
          _ToolbarTextButton(
            tooltip: '提取文献内容',
            icon: Icons.cloud_upload_outlined,
            label: '提取',
            compact: compact,
            enabled: onExtract != null,
            onPressed: onExtract ?? () {},
          ),
          _ToolbarTextButton(
            tooltip: '批量翻译选中段落',
            icon: Icons.translate_outlined,
            label: '批量翻译',
            compact: compact,
            enabled: onBatchTranslate != null,
            onPressed: onBatchTranslate ?? () {},
          ),
          const _ToolbarSeparator(),
          if (!compact) const _ToolbarSmallLabel(text: '正文'),
          _ToolbarMiniButton(label: 'A-', onPressed: onBodyFontDec),
          _ToolbarMiniButton(label: 'A+', onPressed: onBodyFontInc),
          const _ToolbarSeparator(),
          if (!compact) const _ToolbarSmallLabel(text: '译文'),
          _ToolbarMiniButton(label: 'A-', onPressed: onTransFontDec),
          _ToolbarMiniButton(label: 'A+', onPressed: onTransFontInc),
          const _ToolbarSeparator(),
          _ToolbarIconButton(
            tooltip: 'API 设置',
            icon: Icons.settings_outlined,
            enabled: true,
            onPressed: onOpenSettings,
          ),
          _ToolbarTextButton(
            tooltip: '词典',
            icon: Icons.menu_book_outlined,
            label: '词典',
            compact: compact,
            enabled: true,
            onPressed: onDictionary,
          ),
        ],
      ),
    );
  }
}

class _PdfPaneHeader extends StatelessWidget {
  const _PdfPaneHeader({
    required this.title,
    required this.currentPage,
    required this.pageCount,
    required this.zoom,
    required this.enabled,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFitWidth,
    required this.onResetZoom,
    required this.recentPapers,
    required this.currentPaperId,
    required this.onSwitchPaper,
  });

  final String title;
  final int? currentPage;
  final int? pageCount;
  final double? zoom;
  final bool enabled;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFitWidth;
  final VoidCallback onResetZoom;
  final List<LibraryPaperEntry> recentPapers;
  final String? currentPaperId;
  final ValueChanged<String>? onSwitchPaper;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final readerColors = ReaderColors.of(context);
    final pageLabel = currentPage == null || pageCount == null
        ? '-- / --'
        : '$currentPage / $pageCount';
    final zoomLabel = zoom == null ? '--%' : '${(zoom! * 100).round()}%';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: readerColors.surface,
        border: Border(bottom: BorderSide(color: readerColors.border)),
      ),
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(
                Icons.picture_as_pdf_outlined,
                size: 17,
                color: colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(child: _ToolbarTitle(fileName: title)),
              const _ToolbarSeparator(),
              _ToolbarMetric(label: pageLabel),
              _ToolbarIconButton(
                tooltip: '\u7f29\u5c0f',
                icon: Icons.remove,
                enabled: enabled,
                onPressed: onZoomOut,
              ),
              _ToolbarMetric(label: zoomLabel),
              _ToolbarIconButton(
                tooltip: '\u653e\u5927',
                icon: Icons.add,
                enabled: enabled,
                onPressed: onZoomIn,
              ),
              _ToolbarIconButton(
                tooltip: '\u9002\u5e94\u5bbd\u5ea6',
                icon: Icons.fit_screen_outlined,
                enabled: enabled,
                onPressed: onFitWidth,
              ),
              _ToolbarIconButton(
                tooltip: '\u91cd\u7f6e\u7f29\u653e',
                icon: Icons.center_focus_strong_outlined,
                enabled: enabled,
                onPressed: onResetZoom,
              ),
              if (onSwitchPaper != null) ...[
                const _ToolbarSeparator(),
                _RecentPapersMenu(
                  papers: recentPapers,
                  currentPaperId: currentPaperId,
                  onSwitchPaper: onSwitchPaper!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarTitle extends StatelessWidget {
  const _ToolbarTitle({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Text(
      fileName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
  }
}

class _ToolbarSeparator extends StatelessWidget {
  const _ToolbarSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _RecentPapersMenu extends StatelessWidget {
  const _RecentPapersMenu({
    required this.papers,
    required this.currentPaperId,
    required this.onSwitchPaper,
  });

  final List<LibraryPaperEntry> papers;
  final String? currentPaperId;
  final ValueChanged<String> onSwitchPaper;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '\u6700\u8fd1\u9605\u8bfb',
      padding: EdgeInsets.zero,
      onSelected: (id) {
        if (id != currentPaperId) {
          onSwitchPaper(id);
        }
      },
      itemBuilder: (context) {
        if (papers.isEmpty) {
          return [
            const PopupMenuItem<String>(
              enabled: false,
              value: '',
              child: Text('\u6682\u65e0\u9605\u8bfb\u8bb0\u5f55'),
            ),
          ];
        }
        return [
          for (final paper in papers)
            PopupMenuItem<String>(
              value: paper.id,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      paper.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (paper.id == currentPaperId) ...[
                    const SizedBox(width: 8),
                    Text(
                      '\u5f53\u524d',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ];
      },
      child: _ToolbarButtonSurface(
        tooltip: '\u6700\u8fd1\u9605\u8bfb',
        onPressed: null,
        enabled: true,
        minWidth: 30,
        height: 28,
        child: const Icon(Icons.history_outlined, size: 17),
      ),
    );
  }
}

class _ToolbarSmallLabel extends StatelessWidget {
  const _ToolbarSmallLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ToolbarMiniButton extends StatelessWidget {
  const _ToolbarMiniButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: _ToolbarButtonSurface(
        tooltip: label,
        onPressed: onPressed,
        minWidth: 30,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _ToolbarToggleButton extends StatelessWidget {
  const _ToolbarToggleButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ToolbarButtonSurface(
      tooltip: tooltip,
      active: active,
      enabled: true,
      onPressed: onPressed,
      minWidth: 30,
      height: 28,
      child: Icon(icon, size: 17),
    );
  }
}

class _ToolbarTextButton extends StatelessWidget {
  const _ToolbarTextButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.compact = false,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: _ToolbarButtonSurface(
          tooltip: tooltip,
          enabled: enabled,
          onPressed: enabled ? onPressed : null,
          minWidth: compact ? 30 : 0,
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15),
              if (!compact) ...[
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarMetric extends StatelessWidget {
  const _ToolbarMetric({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ToolbarButtonSurface(
      tooltip: tooltip,
      enabled: enabled,
      onPressed: enabled ? onPressed : null,
      minWidth: 30,
      height: 28,
      child: Icon(icon, size: 17),
    );
  }
}

class _ToolbarLinkModeControl extends StatelessWidget {
  const _ToolbarLinkModeControl({
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final PdfContentLinkMode value;
  final ValueChanged<PdfContentLinkMode> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarLinkModeSegment(
              label: compact ? null : '无关联',
              tooltip: '无关联',
              icon: Icons.link_off_outlined,
              selected: value == PdfContentLinkMode.none,
              onPressed: () => onChanged(PdfContentLinkMode.none),
            ),
            _ToolbarLinkModeSegment(
              label: compact ? null : '普通关联',
              tooltip: '普通关联',
              icon: Icons.vertical_align_center_outlined,
              selected: value == PdfContentLinkMode.page,
              onPressed: () => onChanged(PdfContentLinkMode.page),
            ),
            _ToolbarLinkModeSegment(
              label: compact ? null : '缩放关联',
              tooltip: '缩放关联',
              icon: Icons.zoom_in_map_outlined,
              selected: value == PdfContentLinkMode.zoom,
              onPressed: () => onChanged(PdfContentLinkMode.zoom),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarLinkModeSegment extends StatelessWidget {
  const _ToolbarLinkModeSegment({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String? label;
  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ToolbarButtonSurface(
      tooltip: tooltip,
      active: selected,
      onPressed: onPressed,
      height: 28,
      minWidth: label == null ? 30 : 62,
      radius: 0,
      showBorder: false,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 8),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: label == null
            ? Icon(icon, size: 15)
            : Text(
                label!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
      ),
    );
  }
}

class _ToolbarButtonSurface extends StatefulWidget {
  const _ToolbarButtonSurface({
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.enabled = true,
    this.active = false,
    this.danger = false,
    this.minWidth = 30,
    this.height = 28,
    this.radius = 5,
    this.padding = EdgeInsets.zero,
    this.showBorder = true,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool enabled;
  final bool active;
  final bool danger;
  final double minWidth;
  final double height;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool showBorder;

  @override
  State<_ToolbarButtonSurface> createState() => _ToolbarButtonSurfaceState();
}

class _ToolbarButtonSurfaceState extends State<_ToolbarButtonSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled && widget.onPressed != null;
    final foreground = !enabled
        ? colorScheme.onSurface.withValues(alpha: 0.32)
        : widget.danger
        ? colorScheme.error
        : widget.active
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    final background = !enabled
        ? Colors.transparent
        : widget.danger && _hovered
        ? colorScheme.errorContainer
        : widget.active
        ? colorScheme.primary.withValues(alpha: _hovered ? 0.18 : 0.12)
        : _hovered
        ? ReaderColors.of(context).accentSoft
        : Colors.transparent;
    final borderColor = widget.showBorder
        ? (_hovered || widget.active
              ? colorScheme.outline.withValues(alpha: 0.45)
              : colorScheme.outlineVariant.withValues(alpha: 0.55))
        : Colors.transparent;

    Widget button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() {
        _hovered = true;
      }),
      onExit: (_) => setState(() {
        _hovered = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          height: widget.height,
          constraints: BoxConstraints(minWidth: widget.minWidth),
          padding: widget.padding,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: borderColor),
          ),
          child: IconTheme(
            data: IconThemeData(color: foreground, size: 17),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: foreground,
                fontFamily: _appFontFamily,
                letterSpacing: 0,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

class _WindowControls extends StatelessWidget {
  const _WindowControls();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowControlButton(
          tooltip: '最小化',
          icon: Icons.remove,
          onPressed: () => windowManager.minimize(),
        ),
        _WindowControlButton(
          tooltip: '最大化/还原',
          icon: Icons.crop_square,
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _WindowControlButton(
          tooltip: '关闭',
          icon: Icons.close,
          danger: true,
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }
}

class _WindowControlButton extends StatelessWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return _ToolbarButtonSurface(
      tooltip: tooltip,
      danger: danger,
      onPressed: onPressed,
      height: 32,
      minWidth: 42,
      radius: 0,
      showBorder: false,
      child: Icon(icon, size: 16),
    );
  }
}

class MarkdownNotePanel extends StatefulWidget {
  const MarkdownNotePanel({super.key, this.paperDir});

  final String? paperDir;

  @override
  State<MarkdownNotePanel> createState() => _MarkdownNotePanelState();
}

class _MarkdownNotePanelState extends State<MarkdownNotePanel> {
  late final TextEditingController _controller;

  bool _previewMode = false;
  String _renderedMarkdown = _sampleMarkdownNote;
  Timer? _saveTimer;
  bool _loading = false;
  final List<String> _pendingQuotedAppends = [];
  String? get _notesPath =>
      widget.paperDir == null ? null : _joinPath(widget.paperDir!, 'notes.md');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _sampleMarkdownNote);
    _controller.addListener(_scheduleSave);
    _loadNotes();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveNotes();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    final path = _notesPath;
    if (path == null) {
      return;
    }
    setState(() {
      _loading = true;
    });
    try {
      final file = File(path);
      final text = await file.exists() ? await file.readAsString() : '';
      if (!mounted) {
        return;
      }
      _controller.text = text;
      setState(() {
        _renderedMarkdown = text;
        _loading = false;
      });
      _flushPendingQuotedAppends();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
        _flushPendingQuotedAppends();
      }
    }
  }

  void _scheduleSave() {
    final path = _notesPath;
    if (path == null || _loading) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _saveNotes);
  }

  Future<void> _saveNotes() async {
    final path = _notesPath;
    if (path == null) {
      return;
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(_controller.text);
    } catch (_) {}
  }

  Future<void> _renderMarkdown() async {
    _saveTimer?.cancel();
    await _saveNotes();
    setState(() {
      _renderedMarkdown = _controller.text;
      _previewMode = true;
    });
  }

  void _editMarkdown() {
    setState(() {
      _previewMode = false;
    });
  }

  void _resetSample() {
    setState(() {
      _controller.text = _sampleMarkdownNote;
      _renderedMarkdown = _sampleMarkdownNote;
      _previewMode = false;
    });
  }

  void appendQuotedMarkdown(String markdown) {
    if (_loading) {
      _pendingQuotedAppends.add(markdown);
      return;
    }
    _appendQuotedMarkdownNow(markdown);
  }

  void _flushPendingQuotedAppends() {
    if (_pendingQuotedAppends.isEmpty) {
      return;
    }
    final pending = List<String>.from(_pendingQuotedAppends);
    _pendingQuotedAppends.clear();
    for (final markdown in pending) {
      _appendQuotedMarkdownNow(markdown);
    }
  }

  void _appendQuotedMarkdownNow(String markdown) {
    final trimmed = markdown.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final quote = trimmed
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim().isEmpty ? '>' : '> $line')
        .join('\n');
    final text = _controller.text;
    final separator = text.trim().isEmpty
        ? ''
        : text.endsWith('\n\n')
        ? ''
        : text.endsWith('\n')
        ? '\n'
        : '\n\n';
    final next = '$text$separator$quote\n';
    setState(() {
      _controller.text = next;
      _controller.selection = TextSelection.collapsed(offset: next.length);
      _renderedMarkdown = next;
      _previewMode = false;
    });
    _scheduleSave();
  }

  Future<void> _openNoteLocation() async {
    final path = _notesPath;
    if (path == null) {
      return;
    }
    _saveTimer?.cancel();
    await _saveNotes();
    await _revealInExplorer(path);
  }

  Future<void> _pasteClipboardImage() async {
    final paperDir = widget.paperDir;
    if (paperDir == null) {
      _showNoteMessage('\u8bf7\u5148\u6253\u5f00\u4e00\u7bc7\u6587\u732e');
      return;
    }

    final imageDir = Directory(_joinPath(paperDir, 'images')).absolute.path;
    final imagePath = await _saveClipboardImageToDirectory(imageDir);
    if (imagePath == null) {
      _showNoteMessage(
        '\u526a\u8d34\u677f\u4e2d\u6ca1\u6709\u53ef\u7528\u56fe\u7247',
      );
      return;
    }

    final fileName = imagePath.split(RegExp(r'[\\/]')).last;
    final markdown = '![image](images/$fileName)';
    final selection = _controller.selection;
    final text = _controller.text;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final normalizedStart = math.min(start, end).clamp(0, text.length).toInt();
    final normalizedEnd = math.max(start, end).clamp(0, text.length).toInt();
    final prefix =
        normalizedStart > 0 &&
            !RegExp(r'\s').hasMatch(text[normalizedStart - 1])
        ? '\n'
        : '';
    final suffix =
        normalizedEnd < text.length &&
            !RegExp(r'\s').hasMatch(text[normalizedEnd])
        ? '\n'
        : '';
    final inserted = '$prefix$markdown$suffix';
    _controller.value = TextEditingValue(
      text:
          '${text.substring(0, normalizedStart)}$inserted${text.substring(normalizedEnd)}',
      selection: TextSelection.collapsed(
        offset: normalizedStart + inserted.length,
      ),
    );
    _scheduleSave();
    _showNoteMessage('\u5df2\u63d2\u5165\u526a\u8d34\u677f\u56fe\u7247');
  }

  void _showNoteMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final readerColors = ReaderColors.of(context);

    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: readerColors.surface,
            border: Border(bottom: BorderSide(color: readerColors.border)),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 40,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 360;
                    return Row(
                      children: [
                        const Icon(Icons.notes_outlined, size: 18),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _previewMode ? '\u9884\u89c8' : '\u7f16\u8f91',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (widget.paperDir == null)
                          _ToolbarTextButton(
                            tooltip: 'Sample',
                            icon: Icons.restore_outlined,
                            label: 'Sample',
                            compact: compact,
                            enabled: true,
                            onPressed: _resetSample,
                          ),
                        if (!_previewMode && widget.paperDir != null)
                          _ToolbarTextButton(
                            tooltip: '\u7c98\u8d34\u56fe\u7247',
                            icon: Icons.image_outlined,
                            label: '\u7c98\u8d34\u56fe\u7247',
                            compact: compact,
                            enabled: true,
                            onPressed: _pasteClipboardImage,
                          ),
                        _ToolbarTextButton(
                          tooltip: '\u6253\u5f00\u4f4d\u7f6e',
                          icon: Icons.folder_open_outlined,
                          label: '\u6253\u5f00\u4f4d\u7f6e',
                          compact: compact,
                          enabled: true,
                          onPressed: _openNoteLocation,
                        ),
                        _ToolbarTextButton(
                          tooltip: _previewMode
                              ? '\u7f16\u8f91'
                              : '\u9884\u89c8',
                          icon: _previewMode
                              ? Icons.edit_outlined
                              : Icons.visibility_outlined,
                          label: _previewMode ? '\u7f16\u8f91' : '\u9884\u89c8',
                          compact: compact,
                          enabled: true,
                          onPressed: _previewMode
                              ? _editMarkdown
                              : _renderMarkdown,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: _previewMode
                ? _MarkdownPreview(
                    key: const ValueKey('markdown-preview'),
                    markdown: _renderedMarkdown,
                    paperDir: widget.paperDir,
                  )
                : _MarkdownEditor(
                    key: const ValueKey('markdown-editor'),
                    controller: _controller,
                    onPasteImage: widget.paperDir == null
                        ? null
                        : _pasteClipboardImage,
                  ),
          ),
        ),
      ],
    );
  }
}

class _MarkdownEditor extends StatelessWidget {
  const _MarkdownEditor({
    super.key,
    required this.controller,
    this.onPasteImage,
  });

  final TextEditingController controller;
  final VoidCallback? onPasteImage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final readerColors = ReaderColors.of(context);

    return ColoredBox(
      color: readerColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: controller,
          expands: true,
          maxLines: null,
          minLines: null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          contextMenuBuilder: (context, editableTextState) {
            final buttonItems = <ContextMenuButtonItem>[
              ...editableTextState.contextMenuButtonItems,
              if (onPasteImage != null)
                ContextMenuButtonItem(
                  label: '\u7c98\u8d34\u56fe\u7247',
                  onPressed: () {
                    ContextMenuController.removeAny();
                    onPasteImage!();
                  },
                ),
            ];
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableTextState.contextMenuAnchors,
              buttonItems: buttonItems,
            );
          },
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 14,
            height: 1.45,
            color: colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: readerColors.editorFill,
            hintText: r'在此书写 Markdown 笔记，支持 $...$、$$...$$、表格和图片。',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
      ),
    );
  }
}

class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({super.key, required this.markdown, this.paperDir});

  final String markdown;
  final String? paperDir;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ReaderColors.of(context).surfaceAlt,
      child: Markdown(
        selectable: true,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        data: markdown,
        imageBuilder: (uri, title, alt) =>
            _buildNoteMarkdownImage(context, uri, title, alt, paperDir),
        builders: _markdownBuilders(context),
        extensionSet: _markdownExtensionSet,
        styleSheet: _markdownStyleSheet(context),
      ),
    );
  }
}

Widget _buildNoteMarkdownImage(
  BuildContext context,
  Uri uri,
  String? title,
  String? alt,
  String? paperDir,
) {
  final source = uri.toString();
  if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return Image.network(source, fit: BoxFit.contain);
  }

  final normalized = source.replaceAll('\\', '/');
  final file = _resolveNoteImageFile(paperDir, normalized);
  if (file != null && file.existsSync()) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(file, fit: BoxFit.contain),
      ),
    );
  }

  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: ReaderColors.of(context).codeFill,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: ReaderColors.of(context).border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(alt?.isNotEmpty == true ? alt! : source)),
      ],
    ),
  );
}

File? _resolveNoteImageFile(String? paperDir, String source) {
  if (paperDir == null || source.trim().isEmpty) {
    return null;
  }
  final decoded = Uri.decodeFull(source).replaceAll('\\', '/');
  if (decoded.startsWith('/') || decoded.contains('..')) {
    return null;
  }
  if (decoded.startsWith('images/')) {
    return File(
      _joinPath(paperDir, decoded.replaceAll('/', Platform.pathSeparator)),
    );
  }
  return File(
    _joinPath(paperDir, decoded.replaceAll('/', Platform.pathSeparator)),
  );
}

Future<String?> _saveClipboardImageToDirectory(String imageDir) async {
  if (!Platform.isWindows) {
    return null;
  }
  const script = r'''
& {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $ImageDir = [System.Environment]::GetEnvironmentVariable("PDF_MARKDOWN_READER_IMAGE_DIR", "Process")
  if ([string]::IsNullOrWhiteSpace($ImageDir)) {
    exit 3
  }

  function New-OutputPath([string]$Ext) {
    [System.IO.Directory]::CreateDirectory($ImageDir) | Out-Null
    $name = "pasted_{0}.{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $Ext
    return [System.IO.Path]::Combine($ImageDir, $name)
  }

  function Save-BitmapSource([System.Windows.Media.Imaging.BitmapSource]$Source) {
    $path = New-OutputPath "png"
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
    try {
      $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
      $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Source))
      $encoder.Save($stream)
    } finally {
      $stream.Dispose()
    }
    Write-Output $path
    exit 0
  }

  $data = [System.Windows.Clipboard]::GetDataObject()
  if ($data -ne $null) {
    if ($data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
      $files = [string[]]$data.GetData([System.Windows.DataFormats]::FileDrop)
      foreach ($file in $files) {
        if ([System.IO.File]::Exists($file)) {
          $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
          if (@(".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp") -contains $ext) {
            [System.IO.Directory]::CreateDirectory($ImageDir) | Out-Null
            $dest = [System.IO.Path]::Combine(
              $ImageDir,
              ("pasted_{0}{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $ext)
            )
            [System.IO.File]::Copy($file, $dest, $true)
            Write-Output $dest
            exit 0
          }
        }
      }
    }

    foreach ($format in @("PNG", "image/png", "JFIF", "FileContents")) {
      if ($data.GetDataPresent($format)) {
        $raw = $data.GetData($format)
        if ($raw -is [System.IO.Stream]) {
          $ext = if ($format -eq "JFIF") { "jpg" } else { "png" }
          $path = New-OutputPath $ext
          $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
          try { $raw.CopyTo($stream) } finally { $stream.Dispose() }
          Write-Output $path
          exit 0
        }
        if ($raw -is [byte[]]) {
          $ext = if ($format -eq "JFIF") { "jpg" } else { "png" }
          $path = New-OutputPath $ext
          [System.IO.File]::WriteAllBytes($path, $raw)
          Write-Output $path
          exit 0
        }
      }
    }
  }

  try {
    if ([System.Windows.Clipboard]::ContainsImage()) {
      Save-BitmapSource ([System.Windows.Clipboard]::GetImage())
    }
  } catch {}

  if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    $image = [System.Windows.Forms.Clipboard]::GetImage()
    $path = New-OutputPath "png"
    $image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
    Write-Output $path
    exit 0
  }

  exit 2
}
''';
  try {
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-STA', '-Command', script],
      environment: {'PDF_MARKDOWN_READER_IMAGE_DIR': imageDir},
    );
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout.toString().trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null;
  }
}

Future<void> _revealInExplorer(String path) async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    final file = File(path);
    if (await file.exists()) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await Process.run('explorer.exe', [File(path).parent.path]);
    }
  } catch (_) {}
}

Map<String, MarkdownElementBuilder> _markdownBuilders(BuildContext context) {
  return {
    'latex': LatexElementBuilder(
      textStyle: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: DefaultTextStyle.of(context).style.fontSize ?? 14,
      ),
      textScaleFactor: 1.08,
    ),
  };
}

md.ExtensionSet get _markdownExtensionSet {
  return md.ExtensionSet(
    [LatexBlockSyntax(), ...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
    [
      _SafeLatexInlineSyntax(),
      ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
    ],
  );
}

MarkdownStyleSheet _markdownStyleSheet(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;
  final readerColors = ReaderColors.of(context);
  final baseStyle = MarkdownStyleSheet.fromTheme(Theme.of(context));

  return baseStyle.copyWith(
    h1: baseStyle.h1?.copyWith(fontSize: 24),
    h2: baseStyle.h2?.copyWith(fontSize: 19),
    p: baseStyle.p?.copyWith(height: 1.45),
    code: baseStyle.code?.copyWith(
      fontFamily: 'Consolas',
      backgroundColor: readerColors.codeFill,
    ),
    codeblockDecoration: BoxDecoration(
      color: readerColors.codeFill,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquoteDecoration: BoxDecoration(
      color: readerColors.accentSoft,
      border: Border(left: BorderSide(color: colorScheme.primary, width: 4)),
    ),
    tableBorder: TableBorder.all(color: colorScheme.outlineVariant),
    tableHead: baseStyle.tableHead?.copyWith(fontWeight: FontWeight.w700),
    tableHeadCellsDecoration: BoxDecoration(color: readerColors.tableHeader),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tableScrollbarThumbVisibility: true,
  );
}

class _SafeLatexInlineSyntax extends md.InlineSyntax {
  _SafeLatexInlineSyntax()
    : super(r'(?:\$\$[^\n]+?\$\$|\$[^\n]+?\$|\\\([^\n]+?\\\)|\\\[[^\n]+?\\\])');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match.group(0);
    if (raw == null || raw.length < 3) {
      return false;
    }

    final delimiter = _LatexDelimiter.forRaw(raw);
    if (delimiter == null) {
      return false;
    }

    final equation = raw
        .substring(delimiter.left.length, raw.length - delimiter.right.length)
        .trim();
    if (equation.isEmpty) {
      return false;
    }

    final element = md.Element.text('latex', equation);
    element.attributes['MathStyle'] = delimiter.display ? 'display' : 'text';
    parser.addNode(element);

    return true;
  }
}

class _LatexDelimiter {
  const _LatexDelimiter({
    required this.left,
    required this.right,
    required this.display,
  });

  final String left;
  final String right;
  final bool display;

  static const _all = [
    _LatexDelimiter(left: r'$$', right: r'$$', display: true),
    _LatexDelimiter(left: r'$', right: r'$', display: false),
    _LatexDelimiter(left: r'\(', right: r'\)', display: false),
    _LatexDelimiter(left: r'\[', right: r'\]', display: true),
  ];

  static _LatexDelimiter? forRaw(String raw) {
    for (final delimiter in _all) {
      if (raw.startsWith(delimiter.left) && raw.endsWith(delimiter.right)) {
        return delimiter;
      }
    }
    return null;
  }
}

class _MissingPdfNotice extends StatelessWidget {
  const _MissingPdfNotice({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _StatusPanel(
        icon: Icons.insert_drive_file_outlined,
        title: 'PDF file not found',
        detail: path,
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.detail,
    this.progress,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String detail;
  final double? progress;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (progress != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress!.clamp(0, 1)),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MineruPaper {
  const MineruPaper({
    required this.paperDir,
    required this.contentListPath,
    required this.items,
    required this.translations,
    required this.pageCount,
  });

  final String paperDir;
  final String contentListPath;
  final List<MineruContentItem> items;
  final Map<String, String> translations;
  final int pageCount;

  static Future<bool> hasExtractedContent(String paperDir) async {
    final mineruDir = _joinPath(paperDir, 'mineru-output');
    final contentListFile = await _findMineruOutputFile(
      mineruDir,
      preferredNames: const [
        'content_list_v2.json',
        'content list v2.json',
        'content_list.json',
        'content list.json',
      ],
      matcher: _isMineruContentListName,
    );
    if (!await contentListFile.exists()) {
      return false;
    }
    try {
      final decoded = jsonDecode(await contentListFile.readAsString());
      return decoded is List && decoded.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<MineruPaper> load(String paperDir) async {
    final mineruDir = _joinPath(paperDir, 'mineru-output');
    final contentListFile = await _findMineruOutputFile(
      mineruDir,
      preferredNames: const [
        'content_list_v2.json',
        'content list v2.json',
        'content_list.json',
        'content list.json',
      ],
      matcher: _isMineruContentListName,
    );
    final layoutFile = await _findMineruOutputFile(
      mineruDir,
      preferredNames: const ['layout.json'],
      matcher: _isMineruLayoutName,
    );
    final contentListPath = contentListFile.path;

    final contentJson = await contentListFile.readAsString();
    final rawItems = jsonDecode(contentJson) as List<dynamic>;
    final isPageGroupedFormat = rawItems.isNotEmpty && rawItems.first is List;
    final items = <MineruContentItem>[];
    var contentIndex = 0;
    var rawIndex = 0;

    void appendRawItem(Object? rawItem, {int? fallbackPageIndex}) {
      if (rawItem is List) {
        for (final child in rawItem) {
          appendRawItem(child, fallbackPageIndex: fallbackPageIndex);
        }
        return;
      }
      if (rawItem is! Map) {
        return;
      }

      final json = rawItem.map((key, value) => MapEntry(key.toString(), value));
      final item = MineruContentItem.fromJson(
        json,
        rawIndex: rawIndex++,
        contentIndex: contentIndex,
        fallbackPageIndex: fallbackPageIndex,
      );
      if (!_legacyProjectRendersMineruItem(
        item,
        paperDir: paperDir,
        rawType: json['type']?.toString() ?? 'unknown',
        isPageGroupedFormat: isPageGroupedFormat,
      )) {
        return;
      }

      contentIndex++;
      if (item.isRenderable) {
        items.add(item);
      }
    }

    for (var pageIndex = 0; pageIndex < rawItems.length; pageIndex++) {
      final rawItem = rawItems[pageIndex];
      appendRawItem(
        rawItem,
        fallbackPageIndex: rawItem is List ? pageIndex : null,
      );
    }

    final translations = await loadTranslations(paperDir);

    var pageCount = 0;
    if (await layoutFile.exists()) {
      final layoutJson =
          jsonDecode(await layoutFile.readAsString()) as Map<String, dynamic>;
      final pages = layoutJson['pdf_info'];
      if (pages is List) {
        pageCount = pages.length;
      }
    }
    if (pageCount == 0 && rawItems.every((item) => item is List)) {
      pageCount = rawItems.length;
    }

    return MineruPaper(
      paperDir: paperDir,
      contentListPath: contentListPath,
      items: items,
      translations: translations,
      pageCount: pageCount,
    );
  }

  static Future<Map<String, String>> loadTranslations(String paperDir) async {
    final translationsPath = _joinPath(paperDir, 'translations.json');
    final translations = <String, String>{};
    final translationsFile = File(translationsPath);
    if (!await translationsFile.exists()) {
      return translations;
    }

    final decoded = jsonDecode(await translationsFile.readAsString());
    if (decoded is! Map) {
      return translations;
    }
    for (final entry in decoded.entries) {
      translations[entry.key.toString()] = entry.value?.toString() ?? '';
    }
    return translations;
  }

  static Future<void> saveTranslation(
    String paperDir,
    int contentIndex,
    String text,
  ) async {
    final translations = await loadTranslations(paperDir);
    translations[contentIndex.toString()] = text;
    await _writeTranslations(paperDir, translations);
  }

  static Future<void> removeTranslation(
    String paperDir,
    int contentIndex,
  ) async {
    final translations = await loadTranslations(paperDir);
    translations.remove(contentIndex.toString());
    await _writeTranslations(paperDir, translations);
  }

  static Future<void> _writeTranslations(
    String paperDir,
    Map<String, String> translations,
  ) async {
    final file = File(_joinPath(paperDir, 'translations.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(translations),
    );
  }
}

bool _legacyProjectRendersMineruItem(
  MineruContentItem item, {
  required String paperDir,
  required String rawType,
  required bool isPageGroupedFormat,
}) {
  if (isPageGroupedFormat) {
    if (const {
      'page_number',
      'page_header',
      'page_footnote',
      'page_footer',
    }.contains(rawType)) {
      return false;
    }
    if (const {
      'title',
      'paragraph',
      'equation_interline',
      'table',
      'list',
      'code',
    }.contains(rawType)) {
      return true;
    }
  } else {
    if (const {'page_number', 'header', 'footer'}.contains(rawType)) {
      return false;
    }
    if (const {'text', 'equation', 'list', 'table', 'code'}.contains(rawType)) {
      return true;
    }
  }

  if (rawType == 'image' || rawType == 'chart') {
    final imagePath = item.absoluteImagePath(paperDir);
    return (imagePath != null && File(imagePath).existsSync()) ||
        item.imageCaption.isNotEmpty ||
        item.chartCaption.isNotEmpty;
  }
  return false;
}

class MineruContentItem {
  const MineruContentItem({
    required this.rawIndex,
    required this.contentIndex,
    required this.type,
    required this.text,
    required this.content,
    required this.pageIndex,
    required this.bbox,
    required this.textLevel,
    required this.imagePath,
    required this.listItems,
    required this.tableBody,
    required this.tableCaption,
    required this.imageCaption,
    required this.chartCaption,
    required this.codeCaption,
    required this.codeBody,
  });

  final int rawIndex;
  final int contentIndex;
  final String type;
  final String text;
  final String content;
  final int? pageIndex;
  final List<double> bbox;
  final int? textLevel;
  final String? imagePath;
  final List<String> listItems;
  final String tableBody;
  final List<String> tableCaption;
  final List<String> imageCaption;
  final List<String> chartCaption;
  final List<String> codeCaption;
  final String codeBody;

  bool get isRenderable {
    if (type == 'header' ||
        type == 'footer' ||
        type == 'page_header' ||
        type == 'page_footer' ||
        type == 'page_footnote' ||
        type == 'page_number') {
      return false;
    }
    switch (type) {
      case 'text':
      case 'reference':
        return text.trim().isNotEmpty;
      case 'list':
        return listItems.isNotEmpty;
      case 'equation':
        return text.trim().isNotEmpty || content.trim().isNotEmpty;
      case 'image':
      case 'chart':
        return imagePath?.trim().isNotEmpty == true ||
            imageCaption.isNotEmpty ||
            chartCaption.isNotEmpty;
      case 'table':
        return tableBody.trim().isNotEmpty || tableCaption.isNotEmpty;
      case 'code':
        return imagePath?.trim().isNotEmpty == true ||
            codeBody.trim().isNotEmpty ||
            codeCaption.isNotEmpty;
      default:
        return false;
    }
  }

  String get displayType {
    if (type == 'text' && textLevel != null) {
      return 'title';
    }
    if (type == 'text') {
      return 'paragraph';
    }
    return type;
  }

  String get primaryText {
    if (text.trim().isNotEmpty) {
      return text.trim();
    }
    if (content.trim().isNotEmpty) {
      return content.trim();
    }
    return type;
  }

  String get listMarkdown {
    return listItems.map((item) => '- $item').join('\n');
  }

  String get equationMarkdown {
    final value = primaryText;
    if (value.startsWith(r'$$') || value.startsWith(r'\[')) {
      return value;
    }
    return '\$\$\n$value\n\$\$';
  }

  String? get translationMarkdown {
    switch (type) {
      case 'text':
      case 'reference':
        final text = primaryText;
        if (text.isEmpty) {
          return null;
        }
        if (type == 'reference') {
          return text;
        }
        if (textLevel != null && textLevel! >= 1 && textLevel! <= 6) {
          return '${List.filled(textLevel!, '#').join()} $text';
        }
        return text;
      case 'list':
        return listItems.isEmpty ? null : listMarkdown;
      case 'equation':
        return equationMarkdown;
      case 'code':
        if (codeBody.trim().isEmpty) {
          return null;
        }
        return '```\n$codeBody\n```';
      default:
        return null;
    }
  }

  PdfRect? toPdfRect(PdfPage page) {
    if (bbox.length != 4) {
      return null;
    }

    final left = bbox[0] / 1000 * page.width;
    final topFromPageTop = bbox[1] / 1000 * page.height;
    final right = bbox[2] / 1000 * page.width;
    final bottomFromPageTop = bbox[3] / 1000 * page.height;

    if (right <= left || bottomFromPageTop <= topFromPageTop) {
      return null;
    }

    return PdfRect(
      left,
      page.height - topFromPageTop,
      right,
      page.height - bottomFromPageTop,
    );
  }

  List<List<String>> get tableRows => _parseHtmlTable(tableBody);

  String? absoluteImagePath(String paperDir) {
    final relativePath = imagePath;
    if (relativePath == null || relativePath.trim().isEmpty) {
      return null;
    }
    return _joinPath(_joinPath(paperDir, 'mineru-output'), relativePath);
  }

  static MineruContentItem fromJson(
    Map<String, dynamic> json, {
    required int rawIndex,
    required int contentIndex,
    int? fallbackPageIndex,
  }) {
    final rawType = json['type']?.toString() ?? 'unknown';
    final contentMap = _readStringKeyMap(json['content']);
    final normalizedType = _normalizeMineruContentType(rawType);
    final text = _readMineruItemText(rawType, json, contentMap);
    final content = _readMineruItemContent(rawType, json, contentMap, text);

    return MineruContentItem(
      rawIndex: rawIndex,
      contentIndex: contentIndex,
      type: normalizedType,
      text: text,
      content: content,
      pageIndex: _readInt(json['page_idx']) ?? fallbackPageIndex,
      bbox: _readDoubleList(json['bbox']),
      textLevel: _readInt(json['text_level']) ?? _readInt(contentMap?['level']),
      imagePath: _readMineruImagePath(json, contentMap),
      listItems: _readMineruListItems(
        json['list_items'] ?? contentMap?['list_items'],
      ),
      tableBody:
          json['table_body']?.toString() ??
          contentMap?['html']?.toString() ??
          '',
      tableCaption: _combineMineruTextLists([
        json['table_caption'],
        contentMap?['table_caption'],
        json['table_footnote'],
        contentMap?['table_footnote'],
      ]),
      imageCaption: _combineMineruTextLists([
        json['image_caption'],
        contentMap?['image_caption'],
        json['image_footnote'],
        contentMap?['image_footnote'],
      ]),
      chartCaption: _combineMineruTextLists([
        json['chart_caption'],
        contentMap?['chart_caption'],
        json['chart_footnote'],
        contentMap?['chart_footnote'],
      ]),
      codeCaption: _combineMineruTextLists([
        json['code_caption'],
        contentMap?['code_caption'],
        json['algorithm_caption'],
        contentMap?['algorithm_caption'],
      ]),
      codeBody:
          json['code_body']?.toString() ??
          _readMineruRichText(contentMap?['algorithm_content']),
    );
  }
}

int? _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? _readDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

String? _readOptionalString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}

List<String> _readStringList(Object? value) {
  if (value is List) {
    return value.map((item) => item?.toString() ?? '').toList(growable: false);
  }
  return const [];
}

Map<String, dynamic>? _readStringKeyMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _normalizeMineruContentType(String rawType) {
  return switch (rawType) {
    'paragraph' || 'title' => 'text',
    'equation_interline' || 'equation_inline' => 'equation',
    'algorithm' => 'code',
    'ref_text' => 'reference',
    _ => rawType,
  };
}

String _readMineruItemText(
  String rawType,
  Map<String, dynamic> json,
  Map<String, dynamic>? contentMap,
) {
  final directText = _readOptionalString(json['text']);
  if (directText != null) {
    return directText;
  }

  return switch (rawType) {
    'paragraph' => _readMineruRichText(contentMap?['paragraph_content']),
    'title' => _readMineruRichText(contentMap?['title_content']),
    'equation_interline' => _readMineruRichText(
      contentMap?['math_content'] ?? json['content'],
    ),
    'algorithm' => _readMineruRichText(contentMap?['algorithm_content']),
    'page_header' => _readMineruRichText(contentMap?['page_header_content']),
    'page_footer' => _readMineruRichText(contentMap?['page_footer_content']),
    'page_footnote' => _readMineruRichText(
      contentMap?['page_footnote_content'],
    ),
    'ref_text' => _readMineruRichText(contentMap?['ref_text_content']),
    'page_number' => _readMineruRichText(contentMap?['page_number_content']),
    _ => _readMineruRichText(json['content']),
  };
}

String _readMineruItemContent(
  String rawType,
  Map<String, dynamic> json,
  Map<String, dynamic>? contentMap,
  String text,
) {
  final rawContent = json['content'];
  if (rawContent is String) {
    return rawContent;
  }
  if (rawType == 'paragraph' ||
      rawType == 'title' ||
      rawType == 'ref_text' ||
      rawType == 'equation_interline' ||
      rawType == 'algorithm') {
    return text;
  }
  return _readMineruRichText(contentMap?['content']);
}

String? _readMineruImagePath(
  Map<String, dynamic> json,
  Map<String, dynamic>? contentMap,
) {
  final directPath = _readOptionalString(
    json['img_path'] ?? json['image_path'],
  );
  if (directPath != null) {
    return directPath;
  }

  final directSource = _readStringKeyMap(json['image_source']);
  final nestedSource = _readStringKeyMap(contentMap?['image_source']);
  return _readOptionalString(
    directSource?['path'] ??
        nestedSource?['path'] ??
        contentMap?['img_path'] ??
        contentMap?['image_path'],
  );
}

List<String> _readMineruListItems(Object? value) {
  if (value is! List) {
    return _readMineruTextList(value);
  }

  final items = <String>[];
  for (final rawItem in value) {
    final map = _readStringKeyMap(rawItem);
    final text = map == null
        ? _readMineruRichText(rawItem)
        : _readMineruRichText(
            map['item_content'] ?? map['content'] ?? map['text'],
          );
    if (text.trim().isNotEmpty) {
      items.add(text.trim());
    }
  }
  return items;
}

List<String> _combineMineruTextLists(Iterable<Object?> values) {
  final combined = <String>[];
  final seen = <String>{};
  for (final value in values) {
    for (final text in _readMineruTextList(value)) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      combined.add(trimmed);
    }
  }
  return combined;
}

List<String> _readMineruTextList(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is List) {
    return value
        .map(_readMineruRichText)
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
  }

  final text = _readMineruRichText(value).trim();
  return text.isEmpty ? const [] : [text];
}

String _readMineruRichText(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  if (value is List) {
    return _joinMineruTextFragments(value.map(_readMineruRichText));
  }

  final map = _readStringKeyMap(value);
  if (map == null) {
    return value.toString();
  }

  final type = map['type']?.toString() ?? map['item_type']?.toString();
  if (type == 'equation_inline') {
    final math = _readMineruRichText(map['content']).trim();
    return math.isEmpty ? '' : '\$$math\$';
  }
  if (type == 'equation_interline' ||
      type == 'equation_display' ||
      type == 'math') {
    final math = _readMineruRichText(
      map['math_content'] ?? map['content'],
    ).trim();
    return math.isEmpty ? '' : '\$\$\n$math\n\$\$';
  }

  for (final key in const [
    'text',
    'content',
    'item_content',
    'paragraph_content',
    'title_content',
    'algorithm_content',
    'page_header_content',
    'page_footer_content',
    'page_footnote_content',
    'page_number_content',
    'math_content',
  ]) {
    if (map.containsKey(key)) {
      final text = _readMineruRichText(map[key]);
      if (text.trim().isNotEmpty) {
        return text;
      }
    }
  }

  return '';
}

String _joinMineruTextFragments(Iterable<String> fragments) {
  final buffer = StringBuffer();
  for (final rawFragment in fragments) {
    final fragment = rawFragment.trim();
    if (fragment.isEmpty) {
      continue;
    }
    if (buffer.isNotEmpty &&
        _shouldInsertSpaceBetween(buffer.toString(), fragment)) {
      buffer.write(' ');
    }
    buffer.write(fragment);
  }
  return buffer.toString();
}

bool _shouldInsertSpaceBetween(String left, String right) {
  if (left.isEmpty || right.isEmpty) {
    return false;
  }
  final leftUnit = left.codeUnitAt(left.length - 1);
  final rightUnit = right.codeUnitAt(0);
  if (leftUnit <= 32 || rightUnit <= 32) {
    return false;
  }

  final rightChar = String.fromCharCode(rightUnit);
  final leftChar = String.fromCharCode(leftUnit);
  if (',.;:!?)]}%'.contains(rightChar)) {
    return false;
  }
  if ('([{'.contains(leftChar)) {
    return false;
  }
  return true;
}

String _formatDateShort(String iso) {
  final date = DateTime.tryParse(iso);
  if (date == null) {
    return '--';
  }
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _formatDateTime(String iso) {
  final date = DateTime.tryParse(iso);
  if (date == null) {
    return '--';
  }
  return '${_formatDateShort(iso)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}

String _generateLibraryId() {
  final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final random = math.Random().nextInt(0xFFFFFF).toRadixString(36);
  return '$now-$random';
}

String _fileNameWithoutExtension(String path) {
  final normalized = path.replaceAll('\\', '/');
  final fileName = normalized.split('/').last;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) {
    return fileName;
  }
  return fileName.substring(0, dot);
}

LibraryPaperEntry? _findPaperById(
  List<LibraryPaperEntry> papers,
  String paperId,
) {
  for (final paper in papers) {
    if (paper.id == paperId) {
      return paper;
    }
  }
  return null;
}

int _folderDepth(List<LibraryFolder> folders, String folderId) {
  var depth = 0;
  var current = _findFolderById(folders, folderId);
  while (current?.parentId != null) {
    depth += 1;
    current = _findFolderById(folders, current!.parentId!);
    if (depth > 10) {
      break;
    }
  }
  return depth;
}

LibraryFolder? _findFolderById(List<LibraryFolder> folders, String folderId) {
  for (final folder in folders) {
    if (folder.id == folderId) {
      return folder;
    }
  }
  return null;
}

File _safeRelativeFile(String root, String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  final parts = normalized
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.any((part) => part == '..' || part.contains(':'))) {
    throw ArgumentError('Unsafe path: $relativePath');
  }
  var current = root;
  for (final part in parts) {
    current = _joinPath(current, part);
  }
  return File(current);
}

Future<File> _findMineruOutputFile(
  String mineruDir, {
  required List<String> preferredNames,
  required bool Function(String fileName) matcher,
}) async {
  for (final name in preferredNames) {
    final file = File(_joinPath(mineruDir, name));
    if (await file.exists()) {
      return file;
    }
  }

  final dir = Directory(mineruDir);
  final matchedFiles = <File>[];
  if (await dir.exists()) {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        if (matcher(name)) {
          matchedFiles.add(entity);
        }
      }
    }
  }
  if (matchedFiles.isNotEmpty) {
    matchedFiles.sort((a, b) {
      final aName = a.path.replaceAll('\\', '/').split('/').last;
      final bName = b.path.replaceAll('\\', '/').split('/').last;
      final aScore = _mineruFilePriority(aName);
      final bScore = _mineruFilePriority(bName);
      if (aScore != bScore) {
        return bScore.compareTo(aScore);
      }
      return aName.compareTo(bName);
    });
    return matchedFiles.first;
  }

  return File(_joinPath(mineruDir, preferredNames.first));
}

bool _isMineruContentListName(String fileName) {
  final normalized = _normalizeMineruFileName(fileName);
  return normalized.endsWith('contentlistjson') ||
      normalized.endsWith('contentlistv2json');
}

bool _isMineruLayoutName(String fileName) {
  return _normalizeMineruFileName(fileName) == 'layoutjson';
}

String _normalizeMineruFileName(String fileName) {
  return fileName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

int _mineruFilePriority(String fileName) {
  final normalized = _normalizeMineruFileName(fileName);
  if (normalized.endsWith('contentlistv2json')) {
    return 30;
  }
  if (normalized.endsWith('contentlistjson')) {
    return 20;
  }
  if (normalized == 'layoutjson') {
    return 10;
  }
  return 0;
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String hintText,
}) async {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(title: title, hintText: hintText),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({required this.title, required this.hintText});

  final String title;
  final String hintText;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _controller = TextEditingController();
  var _submitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    if (_submitted) {
      return;
    }
    _submitted = true;
    Navigator.of(context).pop(value ?? _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hintText),
        textInputAction: TextInputAction.done,
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('\u53d6\u6d88'),
        ),
        FilledButton(onPressed: _submit, child: const Text('\u786e\u5b9a')),
      ],
    );
  }
}

Future<bool> _confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '\u786e\u5b9a',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('\u53d6\u6d88'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

Future<AppSettingsDialogResult?> _showApiSettingsDialog(
  BuildContext context,
  AppApiSettings initialSettings, {
  ReaderFontSettings? initialReaderFontSettings,
}) async {
  final themeScope = AppThemeScope.maybeOf(context);
  final readerFontSettings =
      initialReaderFontSettings ??
      await LibraryPreferences.readReaderFontSettings();
  if (!context.mounted) {
    return null;
  }
  return showDialog<AppSettingsDialogResult>(
    context: context,
    builder: (dialogContext) => _ApiSettingsDialog(
      initialSettings: initialSettings,
      initialTheme: themeScope?.theme ?? AppColorTheme.sage,
      initialReaderFontSettings: readerFontSettings,
    ),
  );
}

class AppSettingsDialogResult {
  const AppSettingsDialogResult({
    required this.apiSettings,
    required this.theme,
    required this.readerFontSettings,
  });

  final AppApiSettings apiSettings;
  final AppColorTheme theme;
  final ReaderFontSettings readerFontSettings;

  Future<void> applyTheme(BuildContext context) async {
    final themeScope = AppThemeScope.maybeOf(context);
    if (themeScope != null) {
      await themeScope.onThemeChanged(theme);
    } else {
      await LibraryPreferences.saveAppTheme(theme);
    }
  }
}

class _ApiSettingsDialog extends StatefulWidget {
  const _ApiSettingsDialog({
    required this.initialSettings,
    required this.initialTheme,
    required this.initialReaderFontSettings,
  });

  final AppApiSettings initialSettings;
  final AppColorTheme initialTheme;
  final ReaderFontSettings initialReaderFontSettings;

  @override
  State<_ApiSettingsDialog> createState() => _ApiSettingsDialogState();
}

class _ApiSettingsDialogState extends State<_ApiSettingsDialog> {
  late final TextEditingController _deepSeekKeyController;
  late final TextEditingController _mineruTokenController;
  late bool _deepSeekThinking;
  late AppColorTheme _theme;
  late ReaderFontPreset _readerFontPreset;
  Timer? _deepSeekModelDebounce;
  List<String> _deepSeekModels = const [];
  String? _selectedDeepSeekModel;
  String? _deepSeekModelError;
  bool _loadingDeepSeekModels = false;
  int _deepSeekModelRequest = 0;

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    _deepSeekKeyController = TextEditingController(
      text: settings.deepSeekApiKey,
    );
    _selectedDeepSeekModel = settings.deepSeekModel.trim().isEmpty
        ? null
        : settings.deepSeekModel.trim();
    if (_selectedDeepSeekModel != null) {
      _deepSeekModels = [_selectedDeepSeekModel!];
    }
    _mineruTokenController = TextEditingController(
      text: settings.mineruApiToken,
    );
    _deepSeekThinking = settings.deepSeekEnableThinking;
    _theme = widget.initialTheme;
    _readerFontPreset = widget.initialReaderFontSettings.preset;
    if (_deepSeekKeyController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadDeepSeekModels();
        }
      });
    }
  }

  @override
  void dispose() {
    _deepSeekModelDebounce?.cancel();
    _deepSeekModelRequest++;
    _deepSeekKeyController.dispose();
    _mineruTokenController.dispose();
    super.dispose();
  }

  void _onDeepSeekKeyChanged(String value) {
    _deepSeekModelDebounce?.cancel();
    _deepSeekModelRequest++;
    final key = value.trim();
    setState(() {
      _loadingDeepSeekModels = false;
      _deepSeekModelError = null;
      _deepSeekModels = const [];
      _selectedDeepSeekModel = null;
    });
    if (key.isEmpty) {
      return;
    }
    _deepSeekModelDebounce = Timer(
      const Duration(milliseconds: 700),
      _loadDeepSeekModels,
    );
  }

  Future<void> _loadDeepSeekModels() async {
    _deepSeekModelDebounce?.cancel();
    final key = _deepSeekKeyController.text.trim();
    if (key.isEmpty) {
      setState(() {
        _loadingDeepSeekModels = false;
        _deepSeekModelError = null;
        _deepSeekModels = const [];
        _selectedDeepSeekModel = null;
      });
      return;
    }

    final requestId = ++_deepSeekModelRequest;
    final previousModel = _selectedDeepSeekModel;
    setState(() {
      _loadingDeepSeekModels = true;
      _deepSeekModelError = null;
    });
    try {
      final models = await const DeepSeekModelService().fetchModels(
        apiKey: key,
      );
      if (!mounted || requestId != _deepSeekModelRequest) {
        return;
      }
      setState(() {
        _deepSeekModels = models;
        _selectedDeepSeekModel = _pickDeepSeekModel(models, previousModel);
        _loadingDeepSeekModels = false;
      });
    } on DeepSeekModelException catch (error) {
      if (!mounted || requestId != _deepSeekModelRequest) {
        return;
      }
      setState(() {
        _deepSeekModelError = error.message;
        _loadingDeepSeekModels = false;
      });
    }
  }

  String _pickDeepSeekModel(List<String> models, String? previousModel) {
    if (previousModel != null && models.contains(previousModel)) {
      return previousModel;
    }
    for (final preferred in const [
      'deepseek-flash',
      'deepseek-v4-flash',
      'deepseek-chat',
    ]) {
      if (models.contains(preferred)) {
        return preferred;
      }
    }
    return models.first;
  }

  void _save() {
    final deepSeekKey = _deepSeekKeyController.text.trim();
    if (deepSeekKey.isNotEmpty && _selectedDeepSeekModel == null) {
      setState(() {
        _deepSeekModelError = '请先成功获取并选择模型';
      });
      _loadDeepSeekModels();
      return;
    }
    Navigator.of(context).pop(
      AppSettingsDialogResult(
        theme: _theme,
        readerFontSettings: ReaderFontSettings(
          bodyFontSize: widget.initialReaderFontSettings.bodyFontSize,
          translationFontSize:
              widget.initialReaderFontSettings.translationFontSize,
          preset: _readerFontPreset,
        ),
        apiSettings: AppApiSettings(
          deepSeekApiKey: deepSeekKey,
          deepSeekModel: _selectedDeepSeekModel ?? _defaultDeepSeekModel,
          deepSeekEnableThinking: _deepSeekThinking,
          mineruApiToken: _mineruTokenController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('外观', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              DropdownButtonFormField<AppColorTheme>(
                initialValue: _theme,
                decoration: const InputDecoration(labelText: '配色主题'),
                items: [
                  for (final theme in AppColorTheme.values)
                    DropdownMenuItem(value: theme, child: Text(theme.label)),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _theme = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ReaderFontPreset>(
                initialValue: _readerFontPreset,
                decoration: const InputDecoration(labelText: '阅读字体'),
                items: [
                  for (final preset in ReaderFontPreset.values)
                    DropdownMenuItem(value: preset, child: Text(preset.label)),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _readerFontPreset = value;
                  });
                },
              ),
              const Divider(height: 28),
              Text(
                'DeepSeek \u7ffb\u8bd1\u8bbe\u7f6e',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _deepSeekKeyController,
                obscureText: true,
                onChanged: _onDeepSeekKeyChanged,
                onSubmitted: (_) => _loadDeepSeekModels(),
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey(
                  '${_selectedDeepSeekModel ?? ''}:${_deepSeekModels.join(',')}',
                ),
                initialValue: _deepSeekModels.contains(_selectedDeepSeekModel)
                    ? _selectedDeepSeekModel
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '模型',
                  errorText: _deepSeekModelError,
                  helperText: _deepSeekKeyController.text.trim().isEmpty
                      ? '输入 API Key 后自动获取官方可用模型'
                      : _loadingDeepSeekModels
                      ? '正在从 DeepSeek 获取模型...'
                      : _deepSeekModels.isNotEmpty
                      ? '已获取 ${_deepSeekModels.length} 个官方模型'
                      : '等待获取模型',
                  suffixIcon: _loadingDeepSeekModels
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: '重新获取模型',
                          onPressed: _deepSeekKeyController.text.trim().isEmpty
                              ? null
                              : _loadDeepSeekModels,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                ),
                items: [
                  for (final model in _deepSeekModels)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: _loadingDeepSeekModels
                    ? null
                    : (value) {
                        setState(() {
                          _selectedDeepSeekModel = value;
                        });
                      },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('\u542f\u7528\u601d\u8003'),
                value: _deepSeekThinking,
                onChanged: (value) => setState(() {
                  _deepSeekThinking = value;
                }),
              ),
              const Divider(height: 28),
              Text(
                'MinerU PDF \u63d0\u53d6\u8bbe\u7f6e',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _mineruTokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Token',
                  hintText: '\u5728 mineru.net \u7533\u8bf7\u7684 Token',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('\u53d6\u6d88'),
        ),
        FilledButton(onPressed: _save, child: const Text('\u4fdd\u5b58')),
      ],
    );
  }
}

const _windowsDialogSetupScript = r'''
Add-Type -AssemblyName System.Windows.Forms
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$nativeCode = @"
using System.Runtime.InteropServices;
public static class NativeDpiAwareness {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
}
"@
try {
  Add-Type -TypeDefinition $nativeCode -ErrorAction SilentlyContinue | Out-Null
  [NativeDpiAwareness]::SetProcessDPIAware() | Out-Null
} catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()
''';

Future<String?> _pickDirectoryWithSystemDialog({
  String? initialDirectory,
}) async {
  if (!Platform.isWindows) {
    return null;
  }
  final encodedInitial = base64Encode(
    utf8.encode(initialDirectory?.trim() ?? ''),
  );
  final script =
      _windowsDialogSetupScript +
      r'''
$initialPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('__INITIAL_DIRECTORY__'))
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = 'Select library work directory'
$dialog.ShowNewFolderButton = $true
try { $dialog.UseDescriptionForTitle = $true } catch {}
try { $dialog.AutoUpgradeEnabled = $true } catch {}
if ($initialPath -and [System.IO.Directory]::Exists($initialPath)) {
  $dialog.SelectedPath = $initialPath
}
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $dialog.SelectedPath
}
'''
          .replaceAll('__INITIAL_DIRECTORY__', encodedInitial);
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout.toString().trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null;
  }
}

Future<List<String>> _pickPdfFilesWithSystemDialog({
  String? initialDirectory,
}) async {
  if (!Platform.isWindows) {
    return const [];
  }
  try {
    final paths = await _windowsLibraryChannel.invokeListMethod<String>(
      'pickPdfFiles',
      {'initialDirectory': initialDirectory?.trim() ?? ''},
    );
    if (paths != null) {
      return paths
          .map((path) => path.trim())
          .where((path) => path.isNotEmpty)
          .toList(growable: false);
    }
  } on MissingPluginException {
    // Older builds do not expose the native dialog channel.
  } on PlatformException {
    // Fall back to the PowerShell dialog below.
  }
  final encodedInitial = base64Encode(
    utf8.encode(initialDirectory?.trim() ?? ''),
  );
  final script =
      _windowsDialogSetupScript +
      r'''
$initialPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('__INITIAL_DIRECTORY__'))
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Import PDF files'
$dialog.Filter = 'PDF files (*.pdf)|*.pdf'
$dialog.Multiselect = $true
try { $dialog.AutoUpgradeEnabled = $true } catch {}
if ($initialPath -and [System.IO.Directory]::Exists($initialPath)) {
  $dialog.InitialDirectory = $initialPath
}
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  foreach ($name in $dialog.FileNames) {
    Write-Output $name
  }
}
'''
          .replaceAll('__INITIAL_DIRECTORY__', encodedInitial);
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    if (result.exitCode != 0) {
      return const [];
    }
    return result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

Color _badgeColor(String badge) {
  final value = badge.toUpperCase();
  if (value.contains('Q1') ||
      value.contains('1\u533a') ||
      value.contains('A\u7c7b') ||
      value.contains('TOP')) {
    return const Color(0xFF2E7D32);
  }
  if (value.contains('Q2') ||
      value.contains('2\u533a') ||
      value.contains('B\u7c7b')) {
    return const Color(0xFF1565C0);
  }
  if (value.contains('Q3') ||
      value.contains('3\u533a') ||
      value.contains('C\u7c7b')) {
    return const Color(0xFFF57C00);
  }
  if (value.contains('Q4') ||
      value.contains('4\u533a') ||
      value.contains('\u9884\u8b66')) {
    return const Color(0xFFC62828);
  }
  return const Color(0xFF607D8B);
}

List<double> _readDoubleList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .map((item) {
        if (item is num) {
          return item.toDouble();
        }
        if (item is String) {
          return double.tryParse(item);
        }
        return null;
      })
      .whereType<double>()
      .toList(growable: false);
}

List<List<String>> _parseHtmlTable(String html) {
  if (html.trim().isEmpty) {
    return const [];
  }

  final rows = <List<String>>[];
  final rowMatches = RegExp(
    r'<tr[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);

  for (final rowMatch in rowMatches) {
    final rowHtml = rowMatch.group(1) ?? '';
    final cells =
        RegExp(
          r'<t[dh][^>]*>(.*?)</t[dh]>',
          caseSensitive: false,
          dotAll: true,
        ).allMatches(rowHtml).map((cellMatch) {
          return _stripHtml(cellMatch.group(1) ?? '').trim();
        }).toList();

    if (cells.isNotEmpty) {
      rows.add(cells);
    }
  }

  return rows;
}

String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .trim();
}

String _joinPath(String first, String second) {
  if (first.endsWith(r'\') || first.endsWith('/')) {
    return '$first$second';
  }
  return '$first${Platform.pathSeparator}$second';
}
