// Экран «Генератор BettboxR» — нативный порт веб-генератора «РКН ОФФЛАЙН».
// Вставка ссылок/подписок/AWG-конфигов → правила и пресеты → создание профиля.
import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/generator/generator_core.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GeneratorView extends ConsumerStatefulWidget {
  const GeneratorView({super.key});

  @override
  ConsumerState<GeneratorView> createState() => _GeneratorViewState();
}

class _GeneratorViewState extends ConsumerState<GeneratorView> {
  final _linksController = TextEditingController();
  final _customRulesController = TextEditingController();
  final _providerUrlController = TextEditingController();
  final _urlTestController = TextEditingController(
    text: 'https://www.gstatic.com/generate_204',
  );
  final _mtuController = TextEditingController();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  // Провайдеры правил
  final Map<String, bool> _providerSets = {
    'roscomvpn': true,
    'davoyan': false,
    'legiz': false,
  };
  static const Map<String, String> _providerLabels = {
    'roscomvpn': 'RoscomVPN (основной набор)',
    'davoyan': 'Davoyan (легкий, быстрые обновления)',
    'legiz': 'Legiz (минимальный)',
  };

  // Пресеты сервисов и CDN
  late Map<String, bool> _servicePresets;
  late Map<String, bool> _cdnPresets;
  bool _ruUnblock = true;
  bool _providerMode = false;
  final _providerIntervalController = TextEditingController(
    text: '86400',
  );

  List<Map<String, dynamic>> _proxies = [];
  final List<List<String>> _chains = [];
  bool _parsing = false;
  List<String> _problems = const [];
  List<String> _pendingUrls = const [];
  String _lastParsedText = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _servicePresets = {
      for (final key in kServiceRules.keys) key: false,
    };
    _servicePresets['telegram'] = true;
    _servicePresets['discord'] = true;
    _servicePresets['youtube'] = true;
    _cdnPresets = {
      for (final key in kCdnRules.keys) key: false,
    };
    _linksController.addListener(_onLinksChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _linksController.removeListener(_onLinksChanged);
    _linksController.dispose();
    _customRulesController.dispose();
    _providerUrlController.dispose();
    _urlTestController.dispose();
    _mtuController.dispose();
    _providerIntervalController.dispose();
    _dio.close();
    super.dispose();
  }

  // ---------------- Разбор источников ----------------

  void _onLinksChanged() {
    if (_linksController.text == _lastParsedText) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), () {
      if (mounted && _linksController.text != _lastParsedText) {
        _parseSources(fetchUrls: false);
      }
    });
  }

  String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } on Object {
      return url;
    }
  }

  Future<String> _fetchText(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: true,
        validateStatus: (code) => code != null && code >= 200 && code < 400,
        headers: {'User-Agent': 'clash.meta/1.19.0'},
      ),
    );
    final body = response.data ?? '';
    if (body.trim().isEmpty) {
      throw Exception('сервер вернул пустой ответ');
    }
    return body;
  }

  Future<void> _parseSources({bool fetchUrls = true}) async {
    if (_parsing) return;
    final lines = _linksController.text
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final urls = <String>[];
    final localLines = <String>[];
    for (final line in lines) {
      if (line.startsWith('http://') || line.startsWith('https://')) {
        urls.add(line);
      } else {
        localLines.add(line);
      }
    }
    _lastParsedText = _linksController.text;
    setState(() {
      _parsing = true;
      _problems = const [];
      _pendingUrls = fetchUrls ? const [] : urls;
    });
    final collected = <Map<String, dynamic>>[];
    final problems = <String>[];
    try {
      if (localLines.isNotEmpty) {
        try {
          collected.addAll(parseManualInput(localLines.join('\n')));
        } on Object catch (e) {
          problems.add('Ошибка разбора: $e');
        }
        if (collected.isEmpty && problems.isEmpty) {
          final sample = localLines.first;
          problems.add(
            'Локальные строки не распознаны. Пример: '
            '${sample.length > 48 ? '${sample.substring(0, 48)}…' : sample}',
          );
        }
      }
      if (fetchUrls) {
        for (final url in urls) {
          try {
            final body = await _fetchText(url);
            collected.addAll(parseSubscriptionBody(body));
          } on Object catch (e) {
            problems.add('Подписка ${_hostOf(url)}: $e');
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _parsing = false;
          _proxies = uniqueProxies(collected);
          _problems = problems;
        });
      }
    }
  }

  Future<void> _importFile() async {
    try {
      final files = await picker.pickerFiles(
        allowedExtensions: ['conf', 'yaml', 'yml', 'txt'],
      );
      if (files == null || files.isEmpty) return;
      final buffer = StringBuffer(_linksController.text);
      for (final file in files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(utf8.decode(bytes, allowMalformed: true));
      }
      setState(() {
        _linksController.text = buffer.toString();
      });
      await _parseSources();
    } on Object catch (e) {
      _showError('Ошибка импорта: $e');
    }
  }

  // ---------------- Цепочки ----------------

  Future<void> _addChain() async {
    if (_proxies.isEmpty) return;
    final selected = <String>[];
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Новая цепочка (dialer-proxy)'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Отметьте прокси в порядке следования цепочки: '
                        'первый — вход, последний — выход.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    for (final proxy in _proxies)
                      CheckboxListTile(
                        dense: true,
                        title: Text('${proxy['name']}'),
                        subtitle: Text(
                          '${proxy['type']} · ${proxy['server'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: selected.contains(proxy['name']),
                        onChanged: (checked) {
                          setDialogState(() {
                            final name = proxy['name'] as String;
                            if (checked == true) {
                              selected.add(name);
                            } else {
                              selected.remove(name);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == true && selected.length >= 2 && mounted) {
      setState(() {
        _chains.add(selected);
      });
    } else if (result == true && mounted) {
      _showError('Для цепочки нужно минимум 2 прокси.');
    }
  }

  // ---------------- Создание профиля ----------------

  List<Map<String, String>> _parseCustomRules() {
    final rules = <Map<String, String>>[];
    for (var line in _customRulesController.text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;
      rules.add({
        'type': parts[0].trim(),
        'value': parts[1].trim(),
        'action': parts.sublist(2).join(',').trim(),
      });
    }
    return rules;
  }

  Future<void> _createProfile() async {
    if (_providerMode && _providerUrlController.text.trim().isEmpty) {
      _showError('Укажите URL подписки в разделе 7 (режим provider).');
      return;
    }
    if (!_providerMode && _proxies.isEmpty) {
      _showError(
        'Нет прокси: вставьте ссылки или URL подписки в раздел 1 '
        'и нажмите «Разобрать».',
      );
      return;
    }
    final loading = ref.read(loadingProvider.notifier);
    loading.value = true;
    try {
      final yaml = buildConfig(
        GeneratorParams(
          urlTest: _urlTestController.text,
          defaultNameserver: kDefaultDnsValues['defaultNameserver'] as String,
          nameserver: kDefaultDnsValues['nameserver'] as String,
          proxyServerNameserver:
              kDefaultDnsValues['proxyServerNameserver'] as String,
          mtu: _mtuController.text.trim(),
          providerMode: _providerMode,
          providerUrl: _providerUrlController.text,
          providerInterval:
              int.tryParse(_providerIntervalController.text) ?? 86400,
          proxies: _proxies,
          chains: _chains,
          providerSets: _providerSets.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
          servicePresets: _servicePresets.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
          cdnPresets: _cdnPresets.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
          ruUnblock: _ruUnblock,
          customRules: _parseCustomRules(),
        ),
      );
      final now = DateTime.now();
      final label =
          'BettboxR-${now.day.toString().padLeft(2, '0')}.'
          '${now.month.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
      final profile = await Profile.normal(label: label)
          .saveFileWithString(yaml);
      await globalState.appController.addProfile(profile);
      if (!mounted) return;
      await globalState.showMessage(
        title: 'Генератор BettboxR',
        message: TextSpan(
          text: 'Профиль «$label» создан и добавлен. '
              'Проверьте список профилей — конфиг прошёл валидацию ядра.',
        ),
        cancelable: false,
      );
    } on Object catch (e) {
      if (!mounted) return;
      await globalState.showMessage(
        title: 'Генератор BettboxR',
        message: TextSpan(text: '$e'),
        cancelable: false,
      );
    } finally {
      loading.value = false;
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------- UI ----------------

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32, top: 4),
      children: [
        _section('1. Источники прокси', [
          TextField(
            controller: _linksController,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              hintText:
                  'По одной в строке: vless://… trojan://… ss://… hy2://… '
                  'tuic://… anytls://… vmess://… hysteria://… masque://…\n'
                  'URL подписки (https://…) — будет скачана автоматически\n'
                  'или конфиг WireGuard / AmneziaWG ([Interface]…[Peer])',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _importFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Импорт файла'),
              ),
              FilledButton.tonalIcon(
                onPressed: _parsing ? null : _parseSources,
                icon: const Icon(Icons.bolt),
                label: const Text('Разобрать'),
              ),
            ],
          ),
          if (_parsing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Обработка источников…'),
                ],
              ),
            )
          else ...[
            const SizedBox(height: 8),
            Text(
              _proxies.isEmpty
                  ? 'Прокси не добавлены'
                  : 'Разобрано прокси: ${_proxies.length} (дубли удалены)',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary),
            ),
            if (_pendingUrls.isNotEmpty)
              Text(
                'Подписок в списке: ${_pendingUrls.length} — '
                'нажмите «Разобрать», чтобы скачать',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.tertiary,
                  fontSize: 13,
                ),
              ),
            for (final problem in _problems)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  problem,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
          if (_proxies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final proxy in _proxies.take(24))
                    Chip(
                      label: Text('${proxy['name']}'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (_proxies.length > 24)
                    Chip(
                      label: Text('+${_proxies.length - 24} ещё'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
        ]),
        _section('2. Цепочки (dialer-proxy)', [
          if (_chains.isEmpty)
            const Text(
              'Цепочки не заданы. Каждая цепочка создаёт каскад прокси: '
              'трафик проходит через узлы по порядку.',
              style: TextStyle(fontSize: 13),
            ),
          for (var i = 0; i < _chains.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: Text(_chains[i].join('  →  ')),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() {
                    _chains.removeAt(i);
                  });
                },
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _proxies.isEmpty ? null : _addChain,
            icon: const Icon(Icons.add),
            label: const Text('Добавить цепочку'),
          ),
        ]),
        _section('3. Провайдеры правил', [
          for (final entry in _providerSets.entries)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_providerLabels[entry.key] ?? entry.key),
              value: entry.value,
              onChanged: (checked) {
                setState(() {
                  _providerSets[entry.key] = checked ?? false;
                });
              },
            ),
        ]),
        _section('4. Пресеты сервисов', [
          for (final entry in _servicePresets.entries)
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(kPresetLabels[entry.key] ?? entry.key),
              value: entry.value,
              onChanged: (checked) {
                setState(() {
                  _servicePresets[entry.key] = checked;
                });
              },
            ),
        ]),
        _section('5. CDN-провайдеры', [
          for (final entry in _cdnPresets.entries)
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(kCdnLabels[entry.key] ?? entry.key),
              value: entry.value,
              onChanged: (checked) {
                setState(() {
                  _cdnPresets[entry.key] = checked;
                });
              },
            ),
        ]),
        _section('6. Разблокировка RU', [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Разблокировка заблокированных RU-ресурсов'),
            subtitle: const Text(
              'oisd_big, re-filter, ru-inline-banned, inline-blocked-ips',
            ),
            value: _ruUnblock,
            onChanged: (checked) {
              setState(() {
                _ruUnblock = checked;
              });
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _customRulesController,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText:
                  'Свои правила, по одному в строке: TYPE,value,action\n'
                  'Например: DOMAIN-SUFFIX,example.org,PROXY',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
        _section('7. Настройки', [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Встроить в конфиг')),
              ButtonSegment(value: true, label: Text('Подписка (provider)')),
            ],
            selected: {_providerMode},
            onSelectionChanged: (selection) {
              setState(() {
                _providerMode = selection.first;
              });
            },
          ),
          const SizedBox(height: 8),
          Text(
            _providerMode
                ? 'Прокси берутся с URL подписки: ядро само скачает и будет '
                    'обновлять их. Раздел 1 в этом режиме не используется.'
                : 'Прокси, разобранные в разделе 1, записываются в конфиг '
                    'напрямую (без автообновления).',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          if (_providerMode) ...[
            TextField(
              controller: _providerUrlController,
              decoration: const InputDecoration(
                labelText: 'URL подписки (YAML с proxies)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _providerIntervalController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Интервал обновления, сек (по умолчанию 86400)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          TextField(
            controller: _urlTestController,
            decoration: const InputDecoration(
              labelText: 'URL для проверки доступности',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mtuController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'MTU для TUN (пусто — по умолчанию ядра)',
              border: OutlineInputBorder(),
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _createProfile,
            icon: const Icon(Icons.rocket_launch),
            label: const Text(
              'Создать профиль в BettboxR',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}
