import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/config/general.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:intl/intl.dart' show DateFormat;

/// Экран «Стелс-проверка»: приложение смотрит на себя глазами детектора VPN —
/// локальные порты, tun-интерфейс, TRANSPORT_VPN, DNS, IPv6 и выходной IP.
class StealthCheckView extends ConsumerStatefulWidget {
  const StealthCheckView({super.key});

  @override
  ConsumerState<StealthCheckView> createState() => _StealthCheckViewState();
}

class _StealthCheckViewState extends ConsumerState<StealthCheckView> {
  static const _ok = 'ok';
  static const _warn = 'warn';
  static const _bad = 'bad';
  static const _fail = 'fail';
  static const _running = 'running';

  bool _isRunning = false;
  bool _hasRun = false;
  DateTime? _lastRun;

  String? _vPorts;
  String? _vTun;
  String? _vVpnNet;
  String? _vDns;
  String? _vIpv6;
  String? _vExit;

  String _portsBad = '';
  String _tunNames = '';
  String _dnsIp = '';
  String _exitInfo = '';
  bool _ipv6NoV6 = false;
  bool _hasGlobalIpv6 = false;
  List<String> _physicalDns = const [];

  Future<void> _handleEnableVpn() async {
    try {
      await globalState.appController.updateStatus(true);
    } catch (e) {
      commonPrint.log('stealth check: enable vpn failed: $e');
    }
  }

  void _openGeneralSettings() {
    showExtend(
      context,
      builder: (_, type) => AdaptiveSheetScaffold(
        type: type,
        title: appLocalizations.general,
        body: generateListView(generalItems),
      ),
    );
  }

  Future<void> _run() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _vPorts = _running;
      _vTun = _running;
      _vVpnNet = _running;
      _vDns = _running;
      _vIpv6 = _running;
      _vExit = _running;
    });
    await _checkPorts();
    await _checkSystem();
    await _checkDns();
    _checkIpv6();
    await _checkExit();
    if (!mounted) return;
    setState(() {
      _isRunning = false;
      _hasRun = true;
      _lastRun = DateTime.now();
    });
  }

  /// Детекторы первым делом стучатся на типичные порты прокси на localhost.
  Future<void> _checkPorts() async {
    final cfg = ref.read(patchClashConfigProvider);
    final ports = <int>{7890, 7891, 7892, 7893, 1080, 8080, 8888, 9090, 9091};
    if (cfg.mixedPort > 0) {
      ports.add(cfg.mixedPort);
    }
    final active = <int>[];
    for (final port in ports) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 700),
        );
        socket.destroy();
        active.add(port);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _vPorts = active.isEmpty ? _ok : _bad;
      _portsBad = active.join(', ');
    });
  }

  /// tun-интерфейс, TRANSPORT_VPN и DNS физической сети — через Kotlin-движок.
  Future<void> _checkSystem() async {
    Map<String, dynamic>? data;
    try {
      data = await vpn?.stealthCheck();
    } catch (_) {}
    final tunList = data?['tunInterfaces'];
    final tunNames = tunList is List
        ? tunList
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .join(', ')
        : '';
    final isVpnNetwork = data?['isVpnNetwork'] == true;
    final hasGlobalIpv6 = data?['hasGlobalIpv6'] == true;
    final dnsList = data?['physicalDns'];
    final physicalDns = dnsList is List
        ? dnsList
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
        : <String>[];
    _physicalDns = physicalDns;
    _hasGlobalIpv6 = hasGlobalIpv6;
    if (!mounted) return;
    setState(() {
      _tunNames = tunNames;
      _vTun = data == null ? _fail : _warn;
      _vVpnNet = isVpnNetwork ? _warn : _ok;
    });
  }

  /// Резолвер-эхо через туннель: если виден DNS физической сети — утечка.
  Future<void> _checkDns() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client.getUrl(
        Uri.parse(
          'https://cloudflare-dns.com/dns-query?name=whoami.cloudflare&type=TXT',
        ),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      final map = json.decode(body) as Map<String, dynamic>;
      final answers = map['Answer'] as List?;
      final resolverIps = <String>[];
      if (answers != null) {
        final reg = RegExp(r'ip=([0-9a-fA-F:.]+)');
        for (final answer in answers) {
          final dataStr = answer is Map
              ? answer['data']?.toString() ?? ''
              : '';
          for (final match in reg.allMatches(dataStr)) {
            final ip = match.group(1);
            if (ip != null && !resolverIps.contains(ip)) {
              resolverIps.add(ip);
            }
          }
        }
      }
      if (!mounted) return;
      if (resolverIps.isEmpty) {
        setState(() {
          _vDns = _fail;
          _dnsIp = '';
        });
        return;
      }
      final leaked = _physicalDns.any(resolverIps.contains);
      setState(() {
        _vDns = leaked ? _bad : _ok;
        _dnsIp = resolverIps.take(2).join(', ');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _vDns = _fail;
        _dnsIp = '';
      });
    }
  }

  /// IPv6: если в физической сети есть глобальный v6, а туннель его не
  /// покрывает — часть трафика может уходить мимо VPN.
  void _checkIpv6() {
    final cfg = ref.read(patchClashConfigProvider);
    if (!mounted) return;
    setState(() {
      if (!_hasGlobalIpv6) {
        _ipv6NoV6 = true;
        _vIpv6 = _ok;
      } else if (cfg.ipv6) {
        _ipv6NoV6 = false;
        _vIpv6 = _ok;
      } else {
        _ipv6NoV6 = false;
        _vIpv6 = _bad;
      }
    });
  }

  /// Что видит внешний мир: IP, страна и ASN узла выхода.
  Future<void> _checkExit() async {
    var ok = false;
    var info = '';
    Future<String> fetchText(String url) async {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      return body;
    }

    try {
      final body = await fetchText('https://ipinfo.io/json');
      final map = json.decode(body) as Map<String, dynamic>;
      final ip = map['ip']?.toString() ?? '';
      final country = map['country']?.toString() ?? '';
      final city = map['city']?.toString() ?? '';
      final org = map['org']?.toString() ?? '';
      if (ip.isNotEmpty) {
        ok = true;
        final geo = [city, country].where((item) => item.isNotEmpty).join(', ');
        final parts = <String>[ip];
        if (geo.isNotEmpty) {
          parts.add(geo);
        }
        if (org.isNotEmpty) {
          parts.add(org);
        }
        info = parts.join(' · ');
      }
    } catch (_) {
      try {
        final ip = (await fetchText('https://api.ipify.org')).trim();
        if (ip.isNotEmpty) {
          ok = true;
          info = ip;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _vExit = ok ? _ok : _fail;
      _exitInfo = info;
    });
  }

  String _portsSubtitle() {
    switch (_vPorts) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return appLocalizations.stealthPortsOk;
      case _bad:
        return appLocalizations.stealthPortsBad(_portsBad);
    }
    return '';
  }

  String _tunSubtitle() {
    switch (_vTun) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _warn:
        return _tunNames.isNotEmpty
            ? '${appLocalizations.stealthTunWarn} · $_tunNames'
            : appLocalizations.stealthTunWarn;
    }
    return '';
  }

  String _vpnNetSubtitle() {
    switch (_vVpnNet) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _warn:
        return appLocalizations.stealthVpnNetWarn;
    }
    return '';
  }

  String _dnsSubtitle() {
    switch (_vDns) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _dnsIp.isNotEmpty
            ? '${appLocalizations.stealthDnsOk} · $_dnsIp'
            : appLocalizations.stealthDnsOk;
      case _bad:
        return appLocalizations.stealthDnsLeak;
      case _fail:
        return appLocalizations.stealthDnsFail;
    }
    return '';
  }

  String _ipv6Subtitle() {
    switch (_vIpv6) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _ipv6NoV6
            ? appLocalizations.stealthIpv6OkNoV6
            : appLocalizations.stealthIpv6OkCovered;
      case _bad:
        return appLocalizations.stealthIpv6Bad;
    }
    return '';
  }

  String _exitSubtitle() {
    switch (_vExit) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _exitInfo.isNotEmpty
            ? '${appLocalizations.stealthExitOk} · $_exitInfo'
            : appLocalizations.stealthExitOk;
      case _fail:
        return appLocalizations.stealthExitFail;
    }
    return '';
  }

  String _marker(String? verdict) {
    switch (verdict) {
      case _ok:
        return '[OK]';
      case _warn:
        return '[!]';
      case _bad:
        return '[X]';
      default:
        return '[?]';
    }
  }

  String _buildReport() {
    final buffer = StringBuffer('BettboxR · ${appLocalizations.stealthCheck}');
    if (_lastRun != null) {
      buffer.write(
        '\n${appLocalizations.stealthCheckedAt(DateFormat('HH:mm').format(_lastRun!))}',
      );
    }
    void addRow(String title, String subtitle, String? verdict) {
      buffer.write('\n${_marker(verdict)} $title');
      if (subtitle.isNotEmpty) {
        buffer.write(' — $subtitle');
      }
    }

    addRow(appLocalizations.stealthPortsTitle, _portsSubtitle(), _vPorts);
    addRow(appLocalizations.stealthTunTitle, _tunSubtitle(), _vTun);
    addRow(appLocalizations.stealthVpnNetTitle, _vpnNetSubtitle(), _vVpnNet);
    addRow(appLocalizations.stealthDnsTitle, _dnsSubtitle(), _vDns);
    addRow('IPv6', _ipv6Subtitle(), _vIpv6);
    addRow(appLocalizations.stealthExitTitle, _exitSubtitle(), _vExit);
    return buffer.toString();
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
    if (!mounted) return;
    globalState.showNotifier(appLocalizations.copySuccess);
  }

  Widget _divider(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      color: context.colorScheme.outlineVariant.withValues(
        alpha: context.colorScheme.brightness == Brightness.light ? 0.6 : 0.45,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String? verdict,
    String subtitle = '',
    VoidCallback? onFix,
  }) {
    Widget trailing;
    switch (verdict) {
      case _running:
        trailing = SizedBox(
          width: 18,
          height: 18,
          child: SpinKitThreeBounce(
            color: context.colorScheme.primary,
            size: 12,
          ),
        );
        break;
      case _ok:
        trailing = Icon(
          Icons.check_circle,
          size: 20,
          color: const Color(0xFF4CAF50),
        );
        break;
      case _warn:
        trailing = Icon(
          Icons.warning_amber_rounded,
          size: 20,
          color: const Color(0xFFFFA000),
        );
        break;
      case _bad:
        trailing = Icon(Icons.cancel, size: 20, color: context.colorScheme.error);
        break;
      case _fail:
        trailing = Icon(
          Icons.help_outline,
          size: 20,
          color: context.colorScheme.outline,
        );
        break;
      default:
        trailing = Icon(
          Icons.radio_button_unchecked,
          size: 20,
          color: context.colorScheme.outline,
        );
    }
    if (onFix != null && verdict == _bad) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onFix, child: Text(appLocalizations.stealthFix)),
          const SizedBox(width: 4),
          trailing,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: context.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.outline,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  Widget _buildNeedVpn(BuildContext context) {
    return CommonCard(
      type: CommonCardType.filled,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 40,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              appLocalizations.stealthCheckNeedVpn,
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _handleEnableVpn,
              icon: const Icon(Icons.power_settings_new),
              label: Text(appLocalizations.stealthCheckEnableVpn),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    int closed,
    int total,
  ) {
    final stateText = !_hasRun && !_isRunning
        ? appLocalizations.stealthCheckRun
        : _isRunning
        ? appLocalizations.stealthCheckChecking
        : appLocalizations.stealthCheckScore('$closed', '$total');
    return CommonCard(
      type: CommonCardType.filled,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 20,
                  color: context.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(stateText, style: context.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _hasRun && total > 0 ? closed / total : null,
                minHeight: 6,
              ),
            ),
            if (_lastRun != null) ...[
              const SizedBox(height: 8),
              Text(
                appLocalizations.stealthCheckedAt(
                  DateFormat('HH:mm').format(_lastRun!),
                ),
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isRunning ? null : _run,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    _hasRun
                        ? appLocalizations.stealthCheckRerun
                        : appLocalizations.stealthCheckRun,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _hasRun && !_isRunning ? _copyReport : null,
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(appLocalizations.stealthCheckCopyReport),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CommonCard(
        type: CommonCardType.filled,
        child: Column(
          children: [
            _buildRow(
              context,
              icon: Icons.lan_outlined,
              title: appLocalizations.stealthPortsTitle,
              verdict: _vPorts,
              subtitle: _portsSubtitle(),
              onFix: _vPorts == _bad ? _openGeneralSettings : null,
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.swap_vert,
              title: appLocalizations.stealthTunTitle,
              verdict: _vTun,
              subtitle: _tunSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.vpn_lock_outlined,
              title: appLocalizations.stealthVpnNetTitle,
              verdict: _vVpnNet,
              subtitle: _vpnNetSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.dns_outlined,
              title: appLocalizations.stealthDnsTitle,
              verdict: _vDns,
              subtitle: _dnsSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.travel_explore,
              title: 'IPv6',
              verdict: _vIpv6,
              subtitle: _ipv6Subtitle(),
              onFix: _vIpv6 == _bad ? _openGeneralSettings : null,
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.public,
              title: appLocalizations.stealthExitTitle,
              verdict: _vExit,
              subtitle: _exitSubtitle(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        ref.watch(runTimeProvider) != null &&
        !ref.watch(isSmartStoppedProvider);
    if (connected && !_hasRun && !_isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasRun && !_isRunning) {
          _run();
        }
      });
    }
    final verdicts = [_vPorts, _vTun, _vVpnNet, _vDns, _vIpv6, _vExit];
    final closed = verdicts.where((v) => v == _ok).length;
    final failed = verdicts.where((v) => v == _fail).length;
    final total = verdicts.length - failed;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32, top: 4),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: connected
              ? _buildHeader(context, closed, total)
              : _buildNeedVpn(context),
        ),
        const SizedBox(height: 8),
        if (connected) _buildResults(context),
      ],
    );
  }
}
