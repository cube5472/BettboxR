import 'package:bett_box/common/common.dart';
import 'package:bett_box/services/dns_stats.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';

/// Экран пассивной DNS-статистики (уровень 1): кто реально отвечает на
/// запросы ядра, сколько кэш-попаданий, ошибок и задержек. Данные копятся
/// сервисом DnsStatsService из debug-лога ядра, пока включён тумблер сбора.
class DnsStatsView extends StatefulWidget {
  const DnsStatsView({super.key});

  @override
  State<DnsStatsView> createState() => _DnsStatsViewState();
}

class _DnsStatsViewState extends State<DnsStatsView> {
  @override
  void initState() {
    super.initState();
    dnsStats.addListener(_onStatsChanged);
    if (!dnsStats.isLoaded) {
      dnsStats.load();
    }
  }

  @override
  void dispose() {
    dnsStats.removeListener(_onStatsChanged);
    super.dispose();
  }

  void _onStatsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleToggle(bool value) async {
    await dnsStats.setEnabled(value);
  }

  Future<void> _handleReset() async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: CommonDialog(
        title: 'Сбросить статистику?',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Сбросить'),
          ),
        ],
        child: const Text(
          'Будут удалены все собранные данные за 7 дней. Сбор продолжит работать, если он включён.',
        ),
      ),
    );
    if (confirmed == true) {
      await dnsStats.reset();
    }
  }

  List<MapEntry<String, DnsServerStats>> _sortedServers(DnsDayStats day) {
    final entries = day.servers.entries.toList();
    entries.sort((a, b) => b.value.queries.compareTo(a.value.queries));
    return entries;
  }

  List<MapEntry<String, int>> _sortedDomains(DnsDayStats day) {
    final entries = day.domains.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries.take(15).toList();
  }

  String _serverLine(DnsServerStats stats) {
    final parts = <String>[
      'запросов: ${stats.queries}',
      'ответов: ${stats.answers}',
      if (stats.timeouts > 0) 'нет ответа: ${stats.timeouts}',
      if (stats.latencySamples > 0) '≈${stats.avgLatencyMs} мс',
    ];
    return parts.join(' · ');
  }

  String _qtypesLine(DnsDayStats day) {
    final entries = day.qtypes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((entry) => '${entry.key} — ${entry.value}').join(' · ');
  }

  String _eventLine(DnsEvent event) {
    final parts = <String>[_formatTime(event.at)];
    if (event.server != null && event.server!.isNotEmpty) {
      parts.add(event.server!);
    }
    if (event.latencyMs != null) {
      parts.add('${event.latencyMs} мс');
    }
    return parts.join(' · ');
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'answer':
        return 'ответ';
      case 'cache':
        return 'кэш';
      case 'error':
        return 'ошибка';
      case 'timeout':
        return 'нет ответа';
      default:
        return 'запрос';
    }
  }

  Color _kindColor(String kind, ColorScheme colorScheme) {
    switch (kind) {
      case 'cache':
        return colorScheme.onSurfaceVariant;
      case 'error':
        return colorScheme.error;
      case 'timeout':
        return colorScheme.tertiary;
      case 'answer':
        return colorScheme.primary;
      default:
        return colorScheme.onSurface;
    }
  }

  String _formatTime(int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Widget _statCell(String value, String label, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.textTheme.bodyMedium?.copyWith(
          color: context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> items) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListHeader(
            title: title,
            padding: const EdgeInsets.only(left: 8, bottom: 8),
          ),
          CommonCard(
            type: CommonCardType.filled,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  items[i],
                  if (i != items.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: context.colorScheme.outlineVariant.withValues(
                        alpha:
                            context.colorScheme.brightness == Brightness.light
                            ? 0.6
                            : 0.45,
                      ),
                      indent: 16,
                      endIndent: 16,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = dnsStats.today;
    final colorScheme = context.colorScheme;
    final errorsTotal = day.errors + day.timeouts;
    final avgLatency = day.latencySamples > 0 ? '${day.avgLatencyMs} мс' : '—';
    final servers = _sortedServers(day);
    final domains = _sortedDomains(day);
    final events = dnsStats.events.reversed.toList();

    return CommonScaffold(
      title: 'DNS-статистика',
      actions: [
        IconButton(
          tooltip: 'Сбросить',
          onPressed: _handleReset,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 20, top: 8),
        children: [
          _section('Сбор данных', [
            ListItem.switchItem(
              title: const Text('Собирать DNS-статистику'),
              subtitle: const Text(
                'Пока включено, ядро временно работает с уровнем логов debug. Данные хранятся только на устройстве.',
              ),
              delegate: SwitchDelegate<bool>(
                value: dnsStats.enabled,
                onChanged: _handleToggle,
              ),
            ),
          ]),
          if (!dnsStats.enabled)
            _hint(
              'Сбор выключен. Включите тумблер, откройте несколько сайтов и вернитесь на этот экран.',
            )
          else if (day.handled == 0 && day.errors == 0 && day.timeouts == 0)
            _hint(
              'Данных пока нет. Счётчики заполняются в фоне, пока VPN работает и приложение открыто.',
            )
          else ...[
            _section('За сегодня', [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    _statCell(
                      '${day.handled}',
                      'запросов',
                      colorScheme.onSurface,
                    ),
                    _statCell(
                      '${day.cacheHits}',
                      'из кэша',
                      colorScheme.onSurfaceVariant,
                    ),
                    _statCell(
                      '$errorsTotal',
                      'ошибок',
                      errorsTotal > 0
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                    _statCell(avgLatency, 'ср. задержка', colorScheme.primary),
                  ],
                ),
              ),
            ]),
            if (day.qtypes.isNotEmpty)
              _section('Типы записей', [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _qtypesLine(day),
                    style: context.textTheme.bodyMedium,
                  ),
                ),
              ]),
            if (servers.isNotEmpty)
              _section('Серверы', [
                for (final entry in servers)
                  ListItem(
                    title: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _serverLine(entry.value),
                        style: context.textTheme.bodySmall,
                      ),
                    ),
                  ),
              ]),
            if (domains.isNotEmpty)
              _section('Топ-домены', [
                for (final entry in domains)
                  ListItem(
                    title: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text('${entry.value}'),
                  ),
              ]),
            if (events.isNotEmpty)
              _section('Последние события', [
                for (final event in events.take(20))
                  ListItem(
                    title: Text(
                      '${_kindLabel(event.kind)} — ${event.domain}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _kindColor(event.kind, colorScheme),
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _eventLine(event),
                        style: context.textTheme.bodySmall,
                      ),
                    ),
                  ),
              ]),
          ],
          _section('О статистике', [
            const ListItem(
              title: Text(
                'Счётчики отражают реальные запросы ядра к DNS-серверам. Ответы из fakeip-пула внешних запросов не создают и в статистику не попадают. Пока приложение свёрнуто и выгружено системой, сбор приостанавливается. Хранятся данные последних 7 дней.',
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
