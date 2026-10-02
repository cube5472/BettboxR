// Отчёт подмены подписок — файл, устойчивый к «слепоте» экспорта логов.
//
// Основной журнал приложения держит последние 256 записей
// (maxLength в common/constant.dart), и потоки debug-лога ядра
// вытесняют строки [APP] SubSpoof/SubPreload из выгрузки за секунды:
// в присланном логе подмена выглядит как «только ядро», причины
// отказов панели не видны. Этот отчёт пишется в ОТДЕЛЬНЫЙ ФАЙЛ и
// досыпается в конец экспортируемого журнала (AppController.exportLogs)
// — что реально ушло на панель (UA, X-Hwid, device-заголовки) и что
// вернулось (статус, тип тела, маркеры x-hwid-*), видно всегда.
import 'dart:io';

import 'package:bett_box/common/common.dart';

class SpoofReport {
  SpoofReport._();

  static const fileName = 'spoof_report.log';

  /// Сколько последних строк хранить в файле: отчёт нужен для разбора
  /// одной-двух последних проверок панели, длинная история не нужна.
  static const maxLines = 400;

  static File? _cachedFile;

  static Future<File> _getFile() async {
    final cached = _cachedFile;
    if (cached != null) {
      return cached;
    }
    final path = '${await appPath.homeDirPath}/$fileName';
    final file = File(path);
    _cachedFile = file;
    return file;
  }

  /// Добавляет запись с меткой времени. Ошибки записи глушатся:
  /// отчёт не должен ломать загрузку подписки.
  static Future<void> write(String text) async {
    try {
      final file = await _getFile();
      final stamp = DateTime.now().toIso8601String().substring(11, 23);
      await file.writeAsString(
        '[$stamp] $text\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {}
  }

  /// Читает отчёт для экспорта журнала; null — файла ещё нет.
  /// Хвост ограничивается [maxLines], самые свежие строки в конце.
  static Future<String?> readForExport() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) {
        return null;
      }
      final content = await file.readAsString();
      if (content.isEmpty) {
        return null;
      }
      final lines = content.split('\n');
      final tail = lines.length <= maxLines
          ? lines
          : lines.sublist(lines.length - maxLines);
      return tail.join('\n').trim();
    } catch (_) {
      return null;
    }
  }
}
