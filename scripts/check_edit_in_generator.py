#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 18: проверка 'Изменить в генераторе' (rebuild через UI генератора).
1) Баланс скобок (Dart-aware): view/profiles — абсолют; core — дельта к базе
   (известный артефакт стриппера на _yamlScalar в БАЗЕ).
2) Символы: новые на месте, старые молча-пересборочные — перенесены/убраны.
3) Эмуляции: extractProxiesYamlBlock на генераторном YAML, повторный захват
   salvage-логикой, patchYamlConfig сохраняет маркер и блок, round-trip
   customRules params->текст->parse, гидрация DNS-ключей.
"""
import json
import re
import subprocess
import sys

REPO = '/home/z/my-project/BettboxR'
FILES = [
    'lib/generator/generator_core.dart',
    'lib/views/generator_view.dart',
    'lib/views/profiles/profiles.dart',
]
fails = []


def check(cond, msg):
    print(('OK  ' if cond else 'FAIL') + ' | ' + msg)
    if not cond:
        fails.append(msg)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def git_show(path):
    return subprocess.run(
        ['git', '-C', REPO, 'show', 'HEAD:' + path],
        capture_output=True, text=True, check=True,
    ).stdout


# ---------- Dart-aware stripper ----------
def strip_dart(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '/' and nxt == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and nxt == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
        elif c in ('"', "'"):
            triple = src[i:i + 3] == c * 3
            q = c * 3 if triple else c
            i += len(q)
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src.startswith(q, i):
                    i += len(q)
                    break
                i += 1
        elif c == '$' and nxt == '{':
            # строковая интерполяция вне строк сюда не попадает (мы в коде)
            out.append(c); i += 1
        else:
            out.append(c); i += 1
    return ''.join(out)


def counts(src):
    s = strip_dart(src)
    return {ch: s.count(ch) for ch in '{}()[]'}


def balanced(cnt):
    return (cnt['{'] == cnt['}'] and cnt['('] == cnt[')']
            and cnt['['] == cnt[']'])


# 1. Баланс
for f in FILES:
    src = read(REPO + '/' + f)
    cnt = counts(src)
    if f.endswith('generator_core.dart'):
        base_cnt = counts(git_show(f))
        d = {k: cnt[k] - base_cnt[k] for k in cnt}
        ok = (d['{'] == d['}'] and d['('] == d[')'] and d['['] == d[']']
              and all(v >= 0 for v in (d['{'], d['}'], d['('], d[')'])))
        check(ok, 'core: дельта скобок к базе (артефакт _yamlScalar) %s' % d)
    else:
        check(balanced(cnt), '%s: абсолютный баланс %s' % (f.split('/')[-1], cnt))

core = read(REPO + '/lib/generator/generator_core.dart')
view = read(REPO + '/lib/views/generator_view.dart')
prof = read(REPO + '/lib/views/profiles/profiles.dart')
core_base = git_show('lib/generator/generator_core.dart')
view_base = git_show('lib/views/generator_view.dart')
prof_base = git_show('lib/views/profiles/profiles.dart')

# 2. Символы
check('String extractProxiesYamlBlock(String yaml)' in core,
      'core: extractProxiesYamlBlock добавлена')
check(core_base.count('extractProxiesYamlBlock') == 0,
      'core: в базе функции нет')
check("import 'dart:io';" in view and "import 'dart:io';" not in prof,
      'dart:io переехал: view есть, profiles убран')
check('final Profile? rebuildProfile;' in view and
      'final String? rebuildYaml;' in view,
      'view: поля rebuildProfile/rebuildYaml')
check('const GeneratorView({super.key, this.rebuildProfile, this.rebuildYaml});'
      in view, 'view: конструктор с опц. параметрами')
check('if (_isRebuild) _hydrateForRebuild();' in view,
      'view: гидрация вызывается в initState')
check('Future<void> _rebuildProfile()' in view,
      'view: _rebuildProfile добавлена')
check('onPressed: _isRebuild ? _rebuildProfile : _createProfile' in view,
      'view: кнопка переключает обработчик')
check("'Пересобрать профиль'" in view and "'Создать профиль в BettboxR'" in view,
      'view: обе подписи кнопки')
check('Редактирование профиля ' in view, 'view: баннер режима пересборки')
check('if (Navigator.of(context).canPop()) {' in view,
      'view: экран закрывается после пересборки (с canPop-страховкой)')
check('setProfileAndAutoApply' in view and
      'setProfileAndAutoApply' not in prof,
      'hot-apply переехал в view')
check('await appPath.getProfilePath(profile.id)}.bak' in view and
      'writeAsString' not in prof,
      'бэкап .bak теперь в view (в profiles — только упоминание в комментарии)')
check('saveFileWithString' in view, 'view: сохранение через валидацию ядра')
check('extractGeneratorParams' in prof and 'extractGeneratorParams' in view,
      'extractGeneratorParams используется в обоих')
check('embedGeneratorMarker(buildConfig(params), params)' not in prof and
      'buildConfig' not in prof,
      'profiles: прямой пересборочный код убран')
check("label: 'Изменить в генераторе'" in prof and
      'Пересобрать генератором' not in prof,
      'profiles: новый пункт меню')
check('Icons.edit_note' in prof and 'Icons.auto_fix_high' not in prof,
      'profiles: иконка edit_note')
check("import 'package:bett_box/views/generator_view.dart';" in prof,
      'profiles: импорт GeneratorView')
check('rebuildProfile: profile,' in prof and 'rebuildYaml: oldContent,' in prof,
      'profiles: профиль и YAML передаются в генератор')
check('showExtend(' in prof and 'AdaptiveSheetScaffold(' in prof,
      'profiles: навигация через showExtend')
# гидрация использует те же ключи, что понимает _applyTemplateData
tpl_keys = ["'urlTest'", "'defaultNameserver'", "'nameserver'",
            "'proxyServerNameserver'", "'mtu'", "'providerMode'",
            "'providerUrl'", "'providerInterval'", "'ruUnblock'",
            "'ruleCategories'", "'servicePresets'", "'cdnPresets'",
            "'customRules'"]
hydr = view.split('void _hydrateForRebuild()')[1].split('if (params.providerMode)')[0]
check(all(k in hydr for k in tpl_keys), 'view: гидрация передаёт все 13 ключей')
check('_lastParsedText = proxiesBlock;' in view.split('void _hydrateForRebuild')[1].split('// ---------------- Разбор')[0],
      'view: _lastParsedText ставится ДО смены текста (нет лишнего автопарса)')

# ---------- 3. Функциональные эмуляции ----------
K_MARK = '# bettboxr-generator v1'
K_PREF = '# bettboxr-params: '


def yaml_scalar(s):
    def needs(q):
        if q == '' or re.search(r'''[:{}\[\],&*#?|\-<>=!%@
`"';]''', q) or q != q.strip() or any(x in q for x in ('\n', '\t')):
            return True
        if re.match(r'^[-]?\d', q) or q.lower() in (
                'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'):
            return True
        return False
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"') if needs(s) else s


def make_proxy(name, server, port, extra=None):
    p = {'name': name, 'type': 'vless', 'server': server, 'port': port,
         'uuid': 'b8e3f7a2-1111-2222-3333-444455556666', 'udp': True,
         'tls': True, 'servername': 'example.com',
         'client-fingerprint': 'chrome',
         'ws-opts': {'path': '/wspath', 'headers': {'Host': 'example.com'}}}
    if extra:
        p.update(extra)
    return p


def yaml_dump_item(p, indent=2):
    pad = ' ' * indent
    lines = []
    first = True
    for k, v in p.items():
        lead = pad + '- ' if first else pad + '  '
        first = False
        if isinstance(v, dict):
            lines.append(lead + k + ':')
            for k2, v2 in v.items():
                if isinstance(v2, dict):
                    lines.append(pad + '    ' + k2 + ':')
                    for k3, v3 in v2.items():
                        lines.append(pad + '      ' + k3 + ': ' + yaml_scalar(v3))
                else:
                    lines.append(pad + '    ' + k2 + ': ' + yaml_scalar(v2))
        else:
            lines.append(lead + k + ': ' + (str(v).lower() if isinstance(v, bool) else str(v)))
    return '\n'.join(lines)


def build_gen_yaml(proxies, params_json):
    head = K_MARK + '\n' + K_PREF + json.dumps(params_json, ensure_ascii=False) + '\n'
    body = 'mixed-port: 7890\nmode: rule\nlog-level: info\nproxies:\n'
    body += '\n'.join(yaml_dump_item(p) for p in proxies) + '\n'
    body += 'proxy-groups:\n  - name: PROXY\n    type: select\n' \
            '    proxies:\n      - AUTO\n' \
            'proxy-providers:\n  up: {}\nrules:\n  - MATCH,PROXY\n'
    return head + body


def extract_block(yaml_text):
    lines = yaml_text.split('\n')
    key = re.compile(r'^proxies\s*:\s*(#.*)?$')
    item = re.compile(r'^(\s*)- ')
    start = next((i for i, l in enumerate(lines) if key.match(l)), -1)
    if start < 0:
        return ''
    block = ['proxies:']
    for l in lines[start + 1:]:
        if l.strip() == '' or l.startswith(' ') or l.startswith('\t') or item.match(l):
            block.append(l)
        else:
            break
    while block and block[-1].strip() == '':
        block.pop()
    return '' if len(block) <= 1 else '\n'.join(block)


def salvage_items(text):
    lines = text.split('\n')
    key = re.compile(r'^proxies\s*:\s*(#.*)?$')
    item = re.compile(r'^(\s*)- ')
    names = []
    for i, l in enumerate(lines):
        if not key.match(l):
            continue
        j = i + 1
        blk = []
        while j < len(lines):
            t = lines[j]
            if t.strip() == '' or t.startswith(' ') or t.startswith('\t') or item.match(t):
                blk.append(t); j += 1
            else:
                break
        starts = [k for k, b in enumerate(blk) if item.match(b)]
        if starts:
            ind = len(item.match(blk[starts[0]]).group(1))
            cuts = [k for k in starts if len(item.match(blk[k]).group(1)) == ind]
            for a, b in zip(cuts, cuts[1:] + [len(blk)]):
                chunk = '\n'.join(blk[a:b])
                m = re.search(r'name:\s*("?)([^"\n]+?)\1\s*$', chunk.split('\n')[0])
                if m:
                    names.append(m.group(2))
    return names


def patch_yaml_emul(content):
    # табы -> 2 пробела (вне комментариев-маркеров) + кавычки short-id
    out = []
    for line in content.split('\n'):
        if line.startswith((K_MARK, K_PREF)):
            out.append(line)
            continue
        line = line.replace('\t', '  ')
        line = re.sub(r'(\bshort-id\s*:\s*)([0-9a-fA-F]+)',
                      lambda m: m.group(1) + '"%s"' % m.group(2), line)
        out.append(line)
    return '\n'.join(out)


def extract_params(content):
    for line in content.split('\n'):
        s = line.strip()
        if not s:
            continue
        if not s.startswith('#'):
            return None
        if s.startswith(K_PREF):
            return json.loads(s[len(K_PREF):])
    return None


params = {
    'urlTest': 'https://www.gstatic.com/generate_204',
    'defaultNameserver': '', 'nameserver': '', 'proxyServerNameserver': '',
    'mtu': '', 'providerMode': False, 'providerUrl': '',
    'providerInterval': 86400,
    'proxies': [{'name': 'node-%02d' % i, 'type': 'vless',
                 'server': 'srv%d.example.com' % i, 'port': 443}
                for i in range(1, 8)],
    'chains': [['node-01', 'node-02']],
    'ruleCategories': ['base', 'telegram', 'googleai'],
    'servicePresets': ['telegram', 'discord', 'youtube'],
    'cdnPresets': ['cloudflare'],
    'ruUnblock': True,
    'customRules': [
        {'type': 'DOMAIN-SUFFIX', 'value': 'example.org', 'action': 'PROXY'},
        {'type': 'DOMAIN-KEYWORD', 'value': 'ads', 'action': 'REJECT,DROP'},
    ],
}

yaml_full = build_gen_yaml(params['proxies'], params)

# 3a. Извлечение блока
blk = extract_block(yaml_full)
check(blk.startswith('proxies:\n  - name: node-01'),
      'эмуляция: блок начинается с proxies: + первый элемент')
check('proxy-groups' not in blk and 'proxy-providers' not in blk
      and 'rules:' not in blk,
      'эмуляция: блок не захватывает следующие секции')
names = salvage_items(blk)
check(names == [p['name'] for p in params['proxies']],
      'эмуляция: salvage повторно разбирает все %d нод по порядку' % len(names))

# 3b. patchYamlConfig сохраняет и маркер, и блок
patched = patch_yaml_emul(yaml_full)
check(extract_params(patched) == params,
      'эмуляция: маркер/params переживают patchYamlConfig')
check(salvage_items(extract_block(patched)) == names,
      'эмуляция: блок прокси переживает patchYamlConfig')

# 3c. Конфиг без прокси (provider-режим): блок пуст -> поле «Источники» пусто
prov_params = dict(params, providerMode=True, proxies=[], chains=[])
prov_yaml = build_gen_yaml([], prov_params)
prov_yaml = prov_yaml.replace('proxies:\nproxy-groups:', 'proxy-groups:')
check(extract_block(prov_yaml) == '',
      'эмуляция: provider-конфиг без proxies: -> пустой блок')

# 3d. Конфиг без маркера: extract_params -> None (пункт меню покажет сообщение)
check(extract_params('mixed-port: 7890\nproxies:\n  - name: x\n') is None,
      'эмуляция: конфиг без маркера -> params=None')

# 3e. customRules: params -> текст -> parse (round-trip, action с запятой)
lines = [','.join([r['type'], r['value'], r['action']])
         for r in params['customRules']]
reparsed = []
for line in lines:
    parts = line.split(',')
    if len(parts) < 3:
        continue
    reparsed.append({'type': parts[0].strip(), 'value': parts[1].strip(),
                     'action': ','.join(parts[2:]).strip()})
check(reparsed == params['customRules'],
      'эмуляция: customRules params->текст->parse без потерь (вкл. запятые в action)')

# 3f. DNS-ключи гидрации: пресетные тексты маппятся обратно в ключ пресета
dns_presets = {
    'rf-dot': 'tls://77.88.8.8#skip-cert-verify=true, tls://77.88.8.1#skip-cert-verify=true',
    'doh-cf': 'https://cloudflare-dns.com/dns-query#skip-cert-verify=true',
}
def dns_key(text):
    t = text.strip()
    if not t:
        return 'default'
    for k, v in dns_presets.items():
        if v == t:
            return k
    return 'custom'
check(dns_key(dns_presets['rf-dot']) == 'rf-dot'
      and dns_key('') == 'default'
      and dns_key('tls://9.9.9.9') == 'custom',
      'эмуляция: _dnsKeyForText — пресет/пусто/свой вариант')

print()
if fails:
    print('FAILED: %d' % len(fails))
    sys.exit(1)
print('ALL CHECKS PASSED')
