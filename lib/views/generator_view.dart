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

// ---------------- Пресеты DNS (порт «Шаг 1: DNS» веб-генератора) ----------------
// Значения пресетов 1:1 из https://github.com/cube5472/RKN-gen-mihomo
// (index.html, select.dns-preset). Отличие: Яндекс-варианты вынесены первыми
// и помечены как РФ-доступные — зарубежные DoH/DoT (AdGuard, Google,
// Cloudflare) в РФ регулярно режутся на 853/443 порту.

const String _kDnsPresetDefault = 'default';
const String _kDnsPresetCustom = 'custom';

const String _kFieldDefaultNs = 'defaultNameserver';
const String _kFieldNameserver = 'nameserver';
const String _kFieldProxyNs = 'proxyServerNameserver';

class _DnsPreset {
  final String key;
  final String label;
  final String value;
  const _DnsPreset(this.key, this.label, this.value);
}

const List<_DnsPreset> _kDnsPresets = [
  _DnsPreset(
    'rf-dot',
    '🇷🇺 Яндекс (DoT) — работает в РФ',
    'tls://77.88.8.8#skip-cert-verify=true, tls://77.88.8.1#skip-cert-verify=true',
  ),
  _DnsPreset('rf-plain', '🇷🇺 Яндекс (обычные) — работает в РФ', '77.88.8.8, 77.88.8.1'),
  _DnsPreset(
    'doh-cf',
    '🔒 Cloudflare (DoH)',
    'https://cloudflare-dns.com/dns-query#skip-cert-verify=true',
  ),
  _DnsPreset('doh-google', '🔒 Google (DoH)', 'https://dns.google/dns-query#skip-cert-verify=true'),
  _DnsPreset(
    'doh-adguard',
    '🔒 AdGuard (DoH)',
    'https://dns.adguard.com/dns-query#skip-cert-verify=true',
  ),
  _DnsPreset('doh-quad9', '🔒 Quad9 (DoH)', 'https://dns.quad9.net/dns-query#skip-cert-verify=true'),
  _DnsPreset(
    'doh-opendns',
    '🔒 OpenDNS (DoH)',
    'https://doh.opendns.com/dns-query#skip-cert-verify=true',
  ),
  _DnsPreset(
    'dot-cf',
    '🔒 Cloudflare (DoT)',
    'tls://1.1.1.1#skip-cert-verify=true, tls://1.0.0.1#skip-cert-verify=true',
  ),
  _DnsPreset(
    'dot-google',
    '🔒 Google (DoT)',
    'tls://8.8.8.8#skip-cert-verify=true, tls://8.8.4.4#skip-cert-verify=true',
  ),
  _DnsPreset(
    'dot-adguard',
    '🔒 AdGuard (DoT)',
    'tls://94.140.14.14#skip-cert-verify=true, tls://94.140.15.15#skip-cert-verify=true',
  ),
  _DnsPreset(
    'dot-quad9',
    '🔒 Quad9 (DoT)',
    'tls://9.9.9.9#skip-cert-verify=true, tls://149.112.112.112#skip-cert-verify=true',
  ),
  _DnsPreset(
    'dot-opendns',
    '🔒 OpenDNS (DoT)',
    'tls://208.67.222.222#skip-cert-verify=true, tls://208.67.220.220#skip-cert-verify=true',
  ),
  _DnsPreset('plain-cf', '🌐 Cloudflare (обычные)', '1.1.1.1, 1.0.0.1'),
  _DnsPreset('plain-google', '🌐 Google (обычные)', '8.8.8.8, 8.8.4.4'),
  _DnsPreset('plain-adguard', '🌐 AdGuard (обычные)', '94.140.14.14, 94.140.15.15'),
  _DnsPreset('plain-quad9', '🌐 Quad9 (обычные)', '9.9.9.9, 149.112.112.112'),
  _DnsPreset('plain-opendns', '🌐 OpenDNS (обычные)', '208.67.222.222, 208.67.220.220'),
];

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
  // DNS (раздел «7. DNS»): пустое поле = дефолт веб-генератора
  // (kDefaultDnsValues в buildConfig).
  final _defaultNsController = TextEditingController();
  final _nameserverController = TextEditingController();
  final _proxyNsController = TextEditingController();
  final Map<String, String> _dnsSelection = {
    _kFieldDefaultNs: _kDnsPresetDefault,
    _kFieldNameserver: _kDnsPresetDefault,
    _kFieldProxyNs: _kDnsPresetDefault,
  };

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
  final _providerIntervalController = TextEditingController(text: '86400');

  List<Map<String, dynamic>> _proxies = [];
  // Кэш разобранных подписок (URL -> прокси): правки локального текста и
  // неудачные обновления не должны «стирать» уже скачанные ноды.
  final Map<String, List<Map<String, dynamic>>> _fetchedProxies = {};
  final List<List<String>> _chains = [];
  bool _parsing = false;
  List<String> _problems = const [];
  List<String> _pendingUrls = const [];
  String _lastParsedText = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _servicePresets = {for (final key in kServiceRules.keys) key: false};
    _servicePresets['telegram'] = true;
    _servicePresets['discord'] = true;
    _servicePresets['youtube'] = true;
    _cdnPresets = {for (final key in kCdnRules.keys) key: false};
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
    _defaultNsController.dispose();
    _nameserverController.dispose();
    _proxyNsController.dispose();
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
    // ВАЖНО: строки локального текста сохраняются КАК ЕСТЬ (с отступами) —
    // отступы критичны для YAML. Отделяем только чистые URL-строки.
    final rawLines = _linksController.text.split(RegExp(r'\r?\n'));
    final urls = <String>[];
    final localLines = <String>[];
    for (final line in rawLines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('http://') || t.startsWith('https://')) {
        // http(s)://user:pass@host:port — это ссылка на HTTP/SOCKS5-прокси
        // (userinfo в URL), а не подписка.
        if (RegExp(r'^https?://[^/@]+@').hasMatch(t)) {
          localLines.add(line);
        } else {
          urls.add(t);
        }
      } else {
        localLines.add(line);
      }
    }
    _lastParsedText = _linksController.text;
    // Подписки, удалённые из текста, вычищаем из кэша; одинаковые URL
    // не скачиваем дважды.
    _fetchedProxies.removeWhere((url, _) => !urls.contains(url));
    final uniqueUrls = urls.toSet().toList();
    setState(() {
      _parsing = true;
      _problems = const [];
      // Жёлтая подсказка — только про ещё не скачанные подписки.
      _pendingUrls = fetchUrls
          ? const []
          : uniqueUrls.where((u) => !_fetchedProxies.containsKey(u)).toList();
    });
    final collected = <Map<String, dynamic>>[];
    final problems = <String>[];
    try {
      if (localLines.isNotEmpty) {
        final localText = localLines.join('\n');
        // Clash-YAML (в т.ч. вставленные конфиги и импорт файлов):
        // распознаём по ключу proxies: и вынимаем список прокси.
        if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(localText)) {
          try {
            collected.addAll(parseYamlSubscription(localText));
          } on Object catch (e) {
            // Убираем технический префикс "Exception: ", оставляем суть.
            final msg = e.toString().replaceFirst(
              RegExp(r'^Exception:\s*'),
              '',
            );
            problems.add('YAML: $msg');
          }
        }
        // Ссылки и WG/AWG-INI (строки YAML не ссылки — молча пропустятся).
        try {
          collected.addAll(parseManualInput(localText));
        } on Object catch (e) {
          problems.add('Ошибка разбора: $e');
        }
        if (collected.isEmpty && problems.isEmpty) {
          final sample = localLines.first;
          problems.add(
            'Локальные строки не распознаны. Поддержка: ссылки vless:// '
            'ss:// ssr:// trojan:// hy2:// tuic:// anytls:// vmess:// '
            'hysteria:// warp:// masque:// awg:// wg:// socks5:// '
            'http(s)://user:pass@host:port, конфиги WG/AWG '
            '([Interface]…[Peer]), clash-YAML с ключом proxies:. '
            'Пример строки: '
            '${sample.length > 40 ? '${sample.substring(0, 40)}…' : sample}',
          );
        }
      }
      if (fetchUrls) {
        for (final url in uniqueUrls) {
          try {
            final body = await _fetchText(url);
            final parsed = parseSubscriptionBody(body);
            if (parsed.isEmpty) {
              problems.add('Подписка ${_hostOf(url)}: прокси не найдены');
              continue;
            }
            _fetchedProxies[url] = parsed;
            collected.addAll(parsed);
          } on Object catch (e) {
            // Сеть или парсинг упали — отдаём ранее скачанные прокси,
            // чтобы неудачное обновление не «стирало» подписку.
            final cached = _fetchedProxies[url];
            if (cached != null && cached.isNotEmpty) {
              collected.addAll(cached);
              problems.add(
                'Подписка ${_hostOf(url)}: $e — показаны ранее '
                'загруженные прокси',
              );
            } else {
              problems.add('Подписка ${_hostOf(url)}: $e');
            }
          }
        }
      } else {
        // Правка текста без перезагрузки: подписки берём из кэша, чтобы
        // локальные добавления (конфиг AWG/WARP, ссылки) не затирали их.
        for (final url in uniqueUrls) {
          final cached = _fetchedProxies[url];
          if (cached != null) collected.addAll(cached);
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

  // ---------------- Удаление разобранных нод ----------------

  // Удаляем ноду из разобранных: имя вычищаем из цепочек (цепочка с менее
  // чем 2 узлами удаляется), чтобы не осталось битых ссылок dialer-proxy.
  void _deleteProxy(int index) {
    final name = '${_proxies[index]['name']}';
    setState(() {
      _proxies.removeAt(index);
      _chains.removeWhere((chain) {
        chain.remove(name);
        return chain.length < 2;
      });
    });
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
          defaultNameserver: _defaultNsController.text,
          nameserver: _nameserverController.text,
          proxyServerNameserver: _proxyNsController.text,
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
      final profile = await Profile.normal(
        label: label,
      ).saveFileWithString(yaml);
      await globalState.appController.addProfile(profile);
      if (!mounted) return;
      await globalState.showMessage(
        title: 'Генератор BettboxR',
        message: TextSpan(
          text:
              'Профиль «$label» создан и добавлен. '
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

  // ---------------- DNS ----------------

  // Синхронизация «пресет ↔ текст» как в веб-генераторе: текст совпадает
  // со значением пресета → этот пресет; пусто → «По умолчанию»;
  // иначе → «Свой вариант».
  String _dnsKeyForText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return _kDnsPresetDefault;
    for (final preset in _kDnsPresets) {
      if (preset.value == trimmed) return preset.key;
    }
    return _kDnsPresetCustom;
  }

  TextEditingController _dnsControllerFor(String field) {
    switch (field) {
      case _kFieldDefaultNs:
        return _defaultNsController;
      case _kFieldNameserver:
        return _nameserverController;
      default:
        return _proxyNsController;
    }
  }

  void _selectDnsPreset(String field, String? key) {
    if (key == null) return;
    setState(() {
      _dnsSelection[field] = key;
      if (key == _kDnsPresetDefault) {
        // «По умолчанию» = пустое поле: buildConfig возьмёт kDefaultDnsValues.
        _dnsControllerFor(field).text = '';
      } else if (key != _kDnsPresetCustom) {
        // «Свой вариант» — текст не трогаем.
        for (final preset in _kDnsPresets) {
          if (preset.key == key) {
            _dnsControllerFor(field).text = preset.value;
            break;
          }
        }
      }
    });
  }

  void _onDnsTextChanged(String field, String text) {
    final key = _dnsKeyForText(text);
    if (_dnsSelection[field] != key) {
      setState(() {
        _dnsSelection[field] = key;
      });
    }
  }

  // ---------------- UI ----------------

  Widget _section(String title, List<Widget> children) {
    final outline = Theme.of(context).colorScheme.outline;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: outline.withValues(alpha: 0.6)),
      ),
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

  Widget _dnsField({
    required String field,
    required String title,
    required String subtitle,
    required String hint,
  }) {
    final hintColor = Theme.of(context).hintColor;
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: _kDnsPresetDefault,
        child: Text('— По умолчанию (пусто) —', overflow: TextOverflow.ellipsis),
      ),
      for (final preset in _kDnsPresets)
        DropdownMenuItem(
          value: preset.key,
          child: Text(preset.label, overflow: TextOverflow.ellipsis),
        ),
      const DropdownMenuItem(
        value: _kDnsPresetCustom,
        child: Text('✏️ Свой вариант', overflow: TextOverflow.ellipsis),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontSize: 12, color: hintColor)),
        const SizedBox(height: 8),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Пресет',
            border: OutlineInputBorder(),
          ),
          child: DropdownButton<String>(
            value: _dnsSelection[field] ?? _kDnsPresetDefault,
            isExpanded: true,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: items,
            onChanged: (key) => _selectDnsPreset(field, key),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _dnsControllerFor(field),
          onChanged: (text) => _onDnsTextChanged(field, text),
          minLines: 1,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: 'Серверы (через запятую)',
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
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
                  'По одной в строке: vless://… trojan://… ss://… ssr://… '
                  'hy2://… tuic://… anytls://… vmess://… hysteria://…\n'
                  'warp://… masque://… awg://… wg://… socks5://… '
                  'http(s)://user:pass@host:port…\n'
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
                'Не скачано подписок: ${_pendingUrls.length} — '
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
                  // Показываем все ноды без ограничения: у каждой чипа
                  // крестик — ноду можно удалить до создания профиля.
                  for (var i = 0; i < _proxies.length; i++)
                    InputChip(
                      label: Text('${_proxies[i]['name']}'),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => _deleteProxy(i),
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
        _section('7. DNS', [
          Text(
            'Глобальные DNS конфига — как «Шаг 1: DNS» в веб-генераторе. '
            'Пустое поле = значения веб-генератора по умолчанию. В РФ '
            'зарубежные DoH/DoT (AdGuard, Google, Cloudflare) часто '
            'блокируются — для работы без VPN выбирайте Яндекс-пресеты. '
            'Подстраховка: приложение и так добавляет tls://77.88.8.8 '
            'в готовый конфиг (фикс v2), но основной nameserver лучше '
            'сразу выбрать доступным.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          _dnsField(
            field: _kFieldDefaultNs,
            title: 'Default Nameserver — начальный DNS',
            subtitle:
                'Резолвит доменные имена основного DNS при старте. '
                'Пусто — Cloudflare + AdGuard + Google (IP-адреса).',
            hint:
                'tls://1.1.1.1#skip-cert-verify=true, '
                'https://94.140.14.14/dns-query#skip-cert-verify=true, '
                'https://8.8.8.8/dns-query#skip-cert-verify=true',
          ),
          const SizedBox(height: 16),
          _dnsField(
            field: _kFieldNameserver,
            title: 'Nameserver — основные DNS',
            subtitle:
                'Основные DNS-серверы конфига. Пусто — AdGuard DoT '
                '(в РФ часто заблокирован).',
            hint:
                'tls://77.88.8.8#skip-cert-verify=true, '
                'tls://77.88.8.1#skip-cert-verify=true',
          ),
          const SizedBox(height: 16),
          _dnsField(
            field: _kFieldProxyNs,
            title: 'Proxy-server Nameserver — DNS для прокси',
            subtitle:
                'Резолв доменов самих прокси-нод; если он мёртв, VPN не '
                'поднимается вовсе. Пусто — Cloudflare + AdGuard + Google.',
            hint:
                'tls://1.1.1.1#skip-cert-verify=true, '
                'https://94.140.14.14/dns-query#skip-cert-verify=true, '
                'https://8.8.8.8/dns-query#skip-cert-verify=true',
          ),
        ]),
        _section('8. Настройки', [
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
