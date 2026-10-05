// Встроенные скрипты клиента.
//  - s-ru: правила маршрутизации + фильтр RU-нод (источник — download/s-ru-combined.js)
//  - Bag-rules-paranoid: DNS-карантин (источник — download/Bag-rules-paranoid.yaml)
//  - РФ-БС: схема белых списков (правила + 50 провайдеров + DNS-фолбэки,
//    источник — scripts/rf_bs_script.js, генерируется из BettboxR-1609-fixed-v2.yaml)
// При изменении скрипта обновить соответствующую константу.
// Raw-строки (r'''): JS не обрабатывается Dart-экранированием.

const String kBuiltinSRuScriptLabel = 's-ru';

const String builtinSRuScript = r'''// Compatible_With_Bettbox
//
// BettboxR — скрипт «s-ru»: правила маршрутизации + фильтр RU-нод в одном.
//
// Зачем нужен:
//  1) «Правила маршрутизации (s-ru)» — подставляет полный набор правил:
//     реклама и шпионские домены в блок, RU-сервисы напрямую, Discord /
//     YouTube / игры / AI и заблокированное — через VPN. Правила ставятся
//     только если в профиле есть все нужные rule-providers и группы,
//     иначе профиль остаётся на своих правилах (конфиг не ломается).
//  2) «Убирать RU-ноды из авто-групп» — выкидывает RU-ноды из url-test /
//     fallback / load-balance, чтобы автовыбор не гонял трафик через РФ.
//     В обычных (select) группах RU-ноды остаются — можно выбрать вручную.
//
// Чекбоксы: Профили → Скрипты → «⋮» на карточке скрипта → «Настройка».
// Сам скрипт включается тумблером на его карточке (и действует на профили,
// у которых включён «скрипт-оверрайд»).

// ---- Чекбоксы (настройка скрипта в приложении) ----
var ruleOptionsEnable = {
  "Правила маршрутизации (s-ru)": true,
  "Убирать RU-ноды из авто-групп": true
};

// ---- Фильтр RU-нод ----
// Маска RU-нод (можно дополнить: /🇷🇺|Russia|\bRU\b/i)
var RU_MASK = /🇷🇺|Russia/i;

// Типы групп, из которых убираем RU-ноды
var AUTO_TYPES = ["url-test", "fallback", "load-balance"];

// ---- Набор правил s-ru ----
var S_RU_RULES = [
  'DOMAIN,api.ipify.org,🛡️ VPN',
  'RULE-SET,private-ips,DIRECT,no-resolve',
  'IP-CIDR,::/0,REJECT-DROP,no-resolve',
  'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP',
  'RULE-SET,private-domains,DIRECT',
  'RULE-SET,category-ads,REJECT-DROP',
  'RULE-SET,win-spy,REJECT-DROP',
  'RULE-SET,torrent-domains,DIRECT',
  'RULE-SET,google-play,PROXY',
  'RULE-SET,twitch-ads,PROXY',
  'RULE-SET,youtube,📺 Youtube',
  'RULE-SET,telegram,PROXY',
  'RULE-SET,github,PROXY',
  'RULE-SET,epicgames,🎮 Игры',
  'RULE-SET,origin,🎮 Игры',
  'RULE-SET,riot,🎮 Игры',
  'RULE-SET,escapefromtarkov,🎮 Игры',
  'RULE-SET,steam,🎮 Игры',
  'RULE-SET,faceit,🎮 Игры',
  'RULE-SET,twitch,DIRECT',
  'RULE-SET,microsoft,DIRECT',
  'RULE-SET,apple,DIRECT',
  'RULE-SET,pinterest,DIRECT',
  'RULE-SET,category-ru,DIRECT',
  'RULE-SET,whitelist,DIRECT',
  'RULE-SET,torrent-clients,DIRECT',
  'PROCESS-NAME-REGEX,discord,💬 Discord.exe',
  'PROCESS-NAME-REGEX,vesktop,💬 Discord.exe',
  'RULE-SET,games,🎮 Игры',
  'RULE-SET,ru-apps,DIRECT',
  'RULE-SET,direct-ips,DIRECT',
  'RULE-SET,telegram-ips,PROXY',
  'RULE-SET,telegram-domains,PROXY',
  'RULE-SET,discord_domains,PROXY',
  'RULE-SET,discord_voiceips,PROXY',
  'RULE-SET,discord_vc,PROXY',
  'PROCESS-NAME,Discord.exe,PROXY',
  'RULE-SET,ai,PROXY',
  'RULE-SET,google-deepmind,PROXY',
  'DOMAIN-SUFFIX,twitter.com,PROXY',
  'DOMAIN-SUFFIX,x.com,PROXY',
  'DOMAIN-SUFFIX,instagram.com,PROXY',
  'RULE-SET,facebook-ips,PROXY',
  'DOMAIN-SUFFIX,facebook.com,PROXY',
  'RULE-SET,whatsapp-domains,PROXY',
  'RULE-SET,cloudflare-ips,PROXY',
  'RULE-SET,cloudflare-domains,PROXY',
  'IP-CIDR,23.0.0.0/12,PROXY',
  'IP-CIDR,104.64.0.0/10,PROXY',
  'IP-CIDR,52.0.0.0/8,PROXY',
  'IP-CIDR,54.0.0.0/8,PROXY',
  'IP-CIDR,23.235.32.0/20,PROXY',
  'IP-CIDR,43.249.72.0/22,PROXY',
  'RULE-SET,oisd_big,PROXY',
  'RULE-SET,refilter_domains,PROXY',
  'RULE-SET,ru-inline-banned,PROXY',
  'RULE-SET,inline-blocked-ips,PROXY',
  'MATCH,PROXY'
];

// Группы, на которые ссылаются правила (DIRECT и REJECT-DROP встроены в ядро).
var S_RU_REQUIRED_GROUPS = ["🛡️ VPN", "PROXY", "📺 Youtube", "🎮 Игры", "💬 Discord.exe"];

function _groupNames(config) {
  var names = {};
  var groups = config["proxy-groups"];
  if (Array.isArray(groups)) {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i] && typeof groups[i].name === "string") {
        names[groups[i].name] = true;
      }
    }
  }
  var proxies = config.proxies;
  if (Array.isArray(proxies)) {
    for (var j = 0; j < proxies.length; j++) {
      if (proxies[j] && typeof proxies[j].name === "string") {
        names[proxies[j].name] = true;
      }
    }
  }
  return names;
}

function _providerNames(config) {
  var names = {};
  var providers = config["rule-providers"];
  if (providers && typeof providers === "object") {
    for (var key in providers) {
      names[key] = true;
    }
  }
  return names;
}

function _usedRuleSets(rules) {
  var used = {};
  for (var i = 0; i < rules.length; i++) {
    var parts = String(rules[i]).split(",");
    if (parts[0] === "RULE-SET" && parts[1]) {
      used[parts[1]] = true;
    }
  }
  return used;
}

// Ставит правила только при полном наборе провайдеров и групп — иначе профиль
// остаётся на своих правилах, а не падает при старте ядра.
function _applyRules(config) {
  var providers = _providerNames(config);
  var used = _usedRuleSets(S_RU_RULES);
  for (var name in used) {
    if (!providers[name]) {
      console.warn("s-ru: в профиле нет rule-provider '" + name + "', правила не применены");
      return false;
    }
  }
  var names = _groupNames(config);
  for (var i = 0; i < S_RU_REQUIRED_GROUPS.length; i++) {
    if (!names[S_RU_REQUIRED_GROUPS[i]]) {
      console.warn("s-ru: в профиле нет группы '" + S_RU_REQUIRED_GROUPS[i] + "', правила не применены");
      return false;
    }
  }
  config.rules = S_RU_RULES.slice();
  return true;
}

function _filterRuNodes(config) {
  var groups = config["proxy-groups"];
  if (!Array.isArray(groups)) return;

  for (var i = 0; i < groups.length; i++) {
    var group = groups[i];
    if (!group || AUTO_TYPES.indexOf(group.type) === -1) continue;

    // 1) обычный список прокси внутри группы
    if (Array.isArray(group.proxies)) {
      var filtered = group.proxies.filter(function (name) {
        return !RU_MASK.test(String(name));
      });
      // не даём группе опустеть — пустая группа ломает конфиг
      if (filtered.length > 0) {
        group.proxies = filtered;
      }
    }

    // 2) группы на провайдерах / include-all — фильтруем через exclude-filter
    var usesProviders =
      group["include-all"] === true || (Array.isArray(group.use) && group.use.length > 0);
    if (usesProviders) {
      var old = typeof group["exclude-filter"] === "string" ? group["exclude-filter"] : "";
      var add = "🇷🇺|Russia";
      if (old.indexOf(add) === -1) {
        group["exclude-filter"] = old ? old + "|" + add : add;
      }
    }
  }
}

function main(config) {
  if (!config) return config;

  var opts = typeof ruleOptionsEnable === "object" && ruleOptionsEnable ? ruleOptionsEnable : {};

  if (opts["Правила маршрутизации (s-ru)"] !== false) {
    _applyRules(config);
  }
  if (opts["Убирать RU-ноды из авто-групп"] !== false) {
    _filterRuNodes(config);
  }
  return config;
}
''';

const String kBuiltinBagRulesParanoidLabel = 'Bag-rules-paranoid';

const String builtinBagRulesParanoidScript = r'''// Compatible_With_Bettbox
//
// BettboxR — скрипт «Bag-rules-paranoid»: DNS-карантин (fail-closed).
//
// Что делает:
//  1) «DNS-карантин (Quad9 через VPN)» — разрешает ровно один резолвер:
//     Quad9 (домены + IPv4 + IPv6), и только через туннель. Всё остальное
//     запрещено: классический DNS (порт 53, UDP+TCP), DoT/DoQ (порт 853 —
//     всем, кроме Quad9), DoH публичных сервисов по доменам, публичные
//     резолверы по IP (Google, Cloudflare, AdGuard, OpenDNS, Yandex,
//     Mullvad, ControlD, NextDNS — v4+v6; ловит raw-IP DoH в обход имён).
//     Проверка внешнего IP (api.ipify.org) принудительно через туннель.
//     Правила ставятся В НАЧАЛО списка правил профиля — собственные
//     правила маршрутизации профиля продолжают работать как раньше.
//  2) «Блокировать QUIC (UDP 443)» — запрещает HTTP/3: весь HTTPS идёт
//     по TCP и одинаково проходит через туннель и правила. Бонус: на
//     UDP/443 сидят WARP/MASQUE-туннели — они тоже закрываются.
//
// Защита: правила применяются только если в профиле есть группа PROXY и
// список правил — иначе конфиг не трогается. Повторное применение
// безопасно: перед вставкой убирается предыдущий набор правил скрипта.
// При выключении чекбокса правила скрипта удаляются из конфига.
//
// Чекбоксы: Профили → Скрипты → «⋮» на карточке скрипта → «Настройка».

// ---- Чекбоксы (настройка скрипта в приложении) ----
var ruleOptionsEnable = {
  "DNS-карантин (Quad9 через VPN)": true,
  "Блокировать QUIC (UDP 443)": true
};

// ---- Quad9: единственный разрешённый резолвер ----
var QUAD9_DOMAINS = [
  "dns.quad9.net",
  "dns9.quad9.net",
  "dns10.quad9.net",
  "dns11.quad9.net"
];

// IPv4: 9/10/11 = secure / unfiltered / unfiltered+ECS
var QUAD9_IPS_V4 = [
  "9.9.9.9/32",
  "9.9.9.10/32",
  "9.9.9.11/32",
  "149.112.112.9/32",
  "149.112.112.10/32",
  "149.112.112.11/32"
];

// IPv6
var QUAD9_IPS_V6 = [
  "2620:fe::fe/128",
  "2620:fe::9/128",
  "2620:fe::10/128",
  "2620:fe::fe:10/128",
  "2620:fe::11/128",
  "2620:fe::fe:11/128"
];

// ---- Запрет классического DNS (порт 53, UDP+TCP, к любому адресу) ----
var BLOCK_PLAIN_DNS = [
  "AND,((NETWORK,udp),(DST-PORT,53)),REJECT",
  "AND,((NETWORK,tcp),(DST-PORT,53)),REJECT"
];

// ---- Полный запрет DoT/DoQ (порт 853), кроме Quad9 выше ----
var BLOCK_DOT = "DST-PORT,853,REJECT";

// ---- DoH публичных сервисов (порт 443 — ловим по доменам) ----
var BLOCK_DOH_DOMAINS = [
  "use-application-dns.net",
  "cloudflare-dns.com",
  "mozilla.cloudflare-dns.com",
  "dns.google",
  "dns.adguard-dns.com",
  "family.adguard-dns.com",
  "unfiltered.adguard-dns.com",
  "dns.nextdns.io",
  "dns.controld.com",
  "doh.opendns.com",
  "dns.mullvad.net",
  "doh.mullvad.net",
  "dns.yandex.net",
  "common.dot.dns.yandex.net",
  "doh.cleanbrowsing.org",
  "dns.alidns.com",
  "doh.dns.sb",
  "dns.sb",
  "doh.pub",
  "dot.pub",
  "doh.360.cn"
];

// ---- Публичные резолверы по IP (raw-IP DoH/DoQ) ----
var BLOCK_RESOLVER_IPS = [
  // Google
  "8.8.8.8/32",
  "8.8.4.4/32",
  "2001:4860:4860::8888/128",
  "2001:4860:4860::8844/128",
  // Cloudflare
  "1.1.1.1/32",
  "1.0.0.1/32",
  "2606:4700:4700::1111/128",
  "2606:4700:4700::1001/128",
  // AdGuard
  "94.140.14.14/32",
  "94.140.15.15/32",
  "2a10:50c0::ad1:ff/128",
  "2a10:50c0::ad2:ff/128",
  // OpenDNS / FamilyShield
  "208.67.222.222/32",
  "208.67.220.220/32",
  "208.67.222.123/32",
  "208.67.220.123/32",
  // Yandex
  "77.88.8.8/32",
  "77.88.8.1/32",
  "2a02:6b8::feed:0ff/128",
  "2a02:6b8:0:1::feed:0ff/128",
  // Mullvad
  "194.242.2.2/32",
  "193.19.108.2/32",
  // ControlD
  "76.76.2.0/24",
  "76.223.122.150/32",
  // NextDNS
  "45.90.28.0/24",
  "45.90.30.0/24"
];

// ---- QUIC / HTTP3 (UDP 443) ----
var BLOCK_QUIC = "AND,((NETWORK,udp),(DST-PORT,443)),REJECT";

// Собирает набор правил карантинa. quicBlock — включать ли запрет QUIC.
function _bagRuleList(quicBlock) {
  var rules = [];
  // Проверка внешнего IP — всегда через туннель. Ставим самым первым:
  // правило срабатывает раньше любых блокировок (в т.ч. раньше запрета QUIC).
  rules.push("DOMAIN,api.ipify.org,PROXY");
  var i;
  for (i = 0; i < QUAD9_DOMAINS.length; i++) {
    rules.push("DOMAIN," + QUAD9_DOMAINS[i] + ",PROXY");
  }
  for (i = 0; i < QUAD9_IPS_V4.length; i++) {
    rules.push("IP-CIDR," + QUAD9_IPS_V4[i] + ",PROXY,no-resolve");
  }
  for (i = 0; i < QUAD9_IPS_V6.length; i++) {
    rules.push("IP-CIDR," + QUAD9_IPS_V6[i] + ",PROXY,no-resolve");
  }
  for (i = 0; i < BLOCK_PLAIN_DNS.length; i++) {
    rules.push(BLOCK_PLAIN_DNS[i]);
  }
  rules.push(BLOCK_DOT);
  for (i = 0; i < BLOCK_DOH_DOMAINS.length; i++) {
    rules.push("DOMAIN," + BLOCK_DOH_DOMAINS[i] + ",REJECT");
  }
  for (i = 0; i < BLOCK_RESOLVER_IPS.length; i++) {
    rules.push("IP-CIDR," + BLOCK_RESOLVER_IPS[i] + ",REJECT,no-resolve");
  }
  if (quicBlock) {
    rules.push(BLOCK_QUIC);
  }
  return rules;
}

// Полный набор (с QUIC-правилом) — по нему находим/удаляем свои правила.
var BAG_ALL_RULES = _bagRuleList(true);

function _isOurs(rule) {
  return BAG_ALL_RULES.indexOf(String(rule)) !== -1;
}

function _hasGroup(config, name) {
  var groups = config["proxy-groups"];
  if (!Array.isArray(groups)) return false;
  for (var i = 0; i < groups.length; i++) {
    if (groups[i] && groups[i].name === name) return true;
  }
  return false;
}

// Ставит правила только при наличии группы PROXY и списка правил —
// иначе профиль остаётся на своих правилах, а не падает при старте ядра.
function _apply(config, quicBlock) {
  if (!_hasGroup(config, "PROXY")) {
    console.warn("Bag-rules-paranoid: в профиле нет группы 'PROXY', правила не применены");
    return false;
  }
  if (!Array.isArray(config.rules)) {
    console.warn("Bag-rules-paranoid: в профиле нет списка правил, правила не применены");
    return false;
  }
  config.rules = _bagRuleList(quicBlock).concat(
    config.rules.filter(function (rule) {
      return !_isOurs(rule);
    })
  );
  return true;
}

function _remove(config) {
  if (!Array.isArray(config.rules)) return;
  config.rules = config.rules.filter(function (rule) {
    return !_isOurs(rule);
  });
}

function main(config) {
  if (!config) return config;

  var opts = typeof ruleOptionsEnable === "object" && ruleOptionsEnable ? ruleOptionsEnable : {};

  if (opts["DNS-карантин (Quad9 через VPN)"] !== false) {
    _apply(config, opts["Блокировать QUIC (UDP 443)"] !== false);
  } else {
    _remove(config);
  }
  return config;
}
''';

const String kBuiltinRFBSScriptLabel = 'РФ-БС';

const String builtinRFBSScript = r'''// Compatible_With_Bettbox
//
// BettboxR — скрипт «РФ-БС» (РФ — Белые Списки): готовая схема маршрутизации
// для режима белых списков, накладывается на любой профиль. Прокси скрипт не
// трогает и не добавляет — работают ноды и группы самого профиля.
//
// Что делает:
//  1) «Схема белых списков (правила и провайдеры)» — ставит ПОЛНЫЙ набор
//     правил схемы ПЕРЕД правилами профиля: приватные адреса, весь IPv6 и
//     (по чекбоксу) QUIC в блок; RU-сервисы и белый список РКН — напрямую;
//     заблокированное (Telegram/YouTube/Discord/AI/Cloudflare/соцсети и пр.)
//     — через PROXY. 50 нужных rule-providers скрипт добавляет в профиль
//     сам (roscomvpn-geosite и др.); провайдер профиля с тем же именем
//     заменяется — схема самодостаточна. На первый старт ядра нужна
//     доступность источников списков (cdn.jsdelivr.net/github), дальше они
//     лежат в кэше. Цели-группы схемы (📺 Youtube, 🎮 Игры, 💬 Discord.exe)
//     работают, только если такие группы есть в профиле, иначе трафик уходит
//     в PROXY. При выключении чекбокса правила схемы удаляются (провайдеры
//     остаются — их нельзя отличить от профильных).
//  2) «Заменять финал на MATCH,PROXY» — убирает MATCH-правила профиля и
//     ставит MATCH,PROXY в конец (всё не из списка — через VPN). Выключено —
//     финал остаётся за профилем. Добавленный финал неотличим от профильного:
//     после выключения чекбокса остаётся в конфиге.
//  3) «Блокировать QUIC (UDP 443)» — управляет QUIC-правилом схемы.
//  4) «DNS-фолбэки (Яндекс 77.88.8.8)» — добавляет Яндекс-резолверы
//     (77.88.8.8/77.88.8.1) в default-nameserver, nameserver и
//     proxy-server-nameserver. В режиме белых списков иностранные резолверы
//     режутся первыми — без доступного без VPN апстрима резолв умирает
//     (внутренний DNS ядра не проходит через правила, скриптом его не
//     закрыть). Только если в профиле dns.enable: true — иначе DNS
//     настраивает приложение. Дубликаты не добавляются, при выключении
//     чекбокса уже добавленные не удаляются.
//
// Защита: схема применяется только если в профиле есть группа PROXY и это
// не ломает конфиг. Повторное применение безопасно: свои правила снимаются
// перед вставкой.
//
// Чекбоксы: Профили → Скрипты → «⋮» на карточке скрипта → «Настройка».

// ---- Чекбоксы (настройка скрипта в приложении) ----
var ruleOptionsEnable = {
  "Схема белых списков (правила и провайдеры)": true,
  "Заменять финал на MATCH,PROXY": true,
  "Блокировать QUIC (UDP 443)": true,
  "DNS-фолбэки (Яндекс 77.88.8.8)": true
};

// ---- Правила схемы (без финала MATCH; цели-группы резолвятся по профилю) ----
var RF_BS_RULES = [
  "RULE-SET,private-ips,DIRECT,no-resolve",
  "IP-CIDR,::/0,REJECT-DROP,no-resolve",
  "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP",
  "RULE-SET,private-domains,DIRECT",
  "RULE-SET,category-ads,REJECT-DROP",
  "RULE-SET,win-spy,REJECT-DROP",
  "RULE-SET,torrent-domains,DIRECT",
  "RULE-SET,google-play,PROXY",
  "RULE-SET,twitch-ads,PROXY",
  "RULE-SET,youtube,📺 Youtube",
  "RULE-SET,telegram,PROXY",
  "RULE-SET,github,PROXY",
  "RULE-SET,epicgames,🎮 Игры",
  "RULE-SET,origin,🎮 Игры",
  "RULE-SET,riot,🎮 Игры",
  "RULE-SET,escapefromtarkov,🎮 Игры",
  "RULE-SET,steam,🎮 Игры",
  "RULE-SET,faceit,🎮 Игры",
  "RULE-SET,twitch,DIRECT",
  "RULE-SET,microsoft,DIRECT",
  "RULE-SET,apple,DIRECT",
  "RULE-SET,pinterest,DIRECT",
  "RULE-SET,category-ru,DIRECT",
  "RULE-SET,ru-outside,DIRECT",
  "RULE-SET,ru-inside,DIRECT",
  "RULE-SET,ru-inline,DIRECT",
  "RULE-SET,geosite-ru,DIRECT",
  "RULE-SET,yandex,DIRECT",
  "RULE-SET,mailru,DIRECT",
  "RULE-SET,drweb,DIRECT",
  "RULE-SET,geoip-ru,DIRECT,no-resolve",
  "RULE-SET,geoip-by,DIRECT,no-resolve",
  "RULE-SET,whitelist,DIRECT",
  "RULE-SET,torrent-clients,DIRECT",
  "PROCESS-NAME-REGEX,discord,💬 Discord.exe",
  "PROCESS-NAME-REGEX,vesktop,💬 Discord.exe",
  "RULE-SET,games,🎮 Игры",
  "RULE-SET,ru-apps,DIRECT",
  "RULE-SET,direct-ips,DIRECT",
  "RULE-SET,telegram-ips,PROXY",
  "RULE-SET,telegram-domains,PROXY",
  "RULE-SET,discord_domains,PROXY",
  "RULE-SET,discord_voiceips,PROXY",
  "RULE-SET,discord_vc,PROXY",
  "PROCESS-NAME,Discord.exe,PROXY",
  "RULE-SET,ai,PROXY",
  "RULE-SET,google-deepmind,PROXY",
  "DOMAIN-SUFFIX,twitter.com,PROXY",
  "DOMAIN-SUFFIX,x.com,PROXY",
  "DOMAIN-SUFFIX,instagram.com,PROXY",
  "RULE-SET,facebook-ips,PROXY",
  "DOMAIN-SUFFIX,facebook.com,PROXY",
  "RULE-SET,whatsapp-domains,PROXY",
  "DOMAIN-KEYWORD,bittorrent,DIRECT",
  "DST-PORT,5223,PROXY",
  "DOMAIN-SUFFIX,push.apple.com,PROXY",
  "DOMAIN-SUFFIX,mtalk.google.com,PROXY",
  "DOMAIN-SUFFIX,identity.apple.com,PROXY",
  "DOMAIN-SUFFIX,deviceenrollment.apple.com,PROXY",
  "RULE-SET,cloudflare-ips,PROXY",
  "RULE-SET,cloudflare-domains,PROXY",
  "IP-CIDR,23.0.0.0/12,PROXY",
  "IP-CIDR,104.64.0.0/10,PROXY",
  "IP-CIDR,52.0.0.0/8,PROXY",
  "IP-CIDR,54.0.0.0/8,PROXY",
  "IP-CIDR,23.235.32.0/20,PROXY",
  "IP-CIDR,43.249.72.0/22,PROXY",
  "RULE-SET,oisd_big,PROXY",
  "RULE-SET,refilter_domains,PROXY",
  "RULE-SET,ru-inline-banned,PROXY",
  "RULE-SET,inline-blocked-ips,PROXY",
];

// QUIC-правило — единственное с чекбоксом (вынесено, чтобы легко фильтровать)
var RF_BS_QUIC_RULE = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP";

// ---- Провайдеры схемы (добавляются в профиль при применении) ----
var RF_BS_PROVIDERS = {
  "private-domains": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/private.mrs", "p": "./ruleset/geosite-private.mrs", "i": 2592000, "f": "mrs"},
  "category-ru": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/category-ru.mrs", "p": "./ruleset/category-ru.mrs", "i": 86400, "f": "mrs"},
  "whitelist": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/whitelist.mrs", "p": "./ruleset/whitelist.mrs", "i": 86400, "f": "mrs"},
  "microsoft": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/microsoft.mrs", "p": "./ruleset/microsoft.mrs", "i": 86400, "f": "mrs"},
  "apple": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/apple.mrs", "p": "./ruleset/apple.mrs", "i": 86400, "f": "mrs"},
  "google-play": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/google-play.mrs", "p": "./ruleset/google-play.mrs", "i": 86400, "f": "mrs"},
  "epicgames": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/epicgames.mrs", "p": "./ruleset/epicgames.mrs", "i": 86400, "f": "mrs"},
  "origin": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/origin.mrs", "p": "./ruleset/origin.mrs", "i": 86400, "f": "mrs"},
  "riot": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/riot.mrs", "p": "./ruleset/riot.mrs", "i": 86400, "f": "mrs"},
  "escapefromtarkov": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/escapefromtarkov.mrs", "p": "./ruleset/escapefromtarkov.mrs", "i": 86400, "f": "mrs"},
  "steam": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/steam.mrs", "p": "./ruleset/steam.mrs", "i": 86400, "f": "mrs"},
  "twitch": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/twitch.mrs", "p": "./ruleset/twitch.mrs", "i": 86400, "f": "mrs"},
  "pinterest": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/pinterest.mrs", "p": "./ruleset/pinterest.mrs", "i": 86400, "f": "mrs"},
  "faceit": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/faceit.mrs", "p": "./ruleset/faceit.mrs", "i": 86400, "f": "mrs"},
  "private-ips": {"b": "ipcidr", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/mihomo/private.mrs", "p": "./ruleset/geoip-private.mrs", "i": 2592000, "f": "mrs"},
  "direct-ips": {"b": "ipcidr", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/mihomo/direct.mrs", "p": "./ruleset/direct-ips.mrs", "i": 86400, "f": "mrs"},
  "github": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/github.mrs", "p": "./ruleset/github.mrs", "i": 86400, "f": "mrs"},
  "twitch-ads": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/twitch-ads.mrs", "p": "./ruleset/twitch-ads.mrs", "i": 86400, "f": "mrs"},
  "youtube": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/youtube.mrs", "p": "./rule-sets/youtube.mrs", "i": 86400, "f": "mrs"},
  "telegram": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/telegram.mrs", "p": "./ruleset/telegram.mrs", "i": 86400, "f": "mrs"},
  "win-spy": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/win-spy.mrs", "p": "./ruleset/win-spy.mrs", "i": 86400, "f": "mrs"},
  "torrent-domains": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/torrent.mrs", "p": "./ruleset/torrent-domains.mrs", "i": 86400, "f": "mrs"},
  "category-ads": {"b": "domain", "u": "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/category-ads.mrs", "p": "./ruleset/category-ads.mrs", "i": 86400, "f": "mrs"},
  "torrent-clients": {"b": "classical", "u": "https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/torrent-clients.yaml", "p": "./rule-sets/torrent-clients.yaml", "i": 86400, "f": "yaml"},
  "games": {"b": "classical", "u": "https://raw.githubusercontent.com/roscomvpn/custom-category/release/mihomo/games.yaml", "p": "./ruleset/games.yaml", "i": 86400, "f": "yaml"},
  "ru-apps": {"b": "classical", "u": "https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/ru-app-list.yaml", "p": "./rule-sets/ru-apps.yaml", "i": 86400, "f": "yaml"},
  "oisd_big": {"b": "domain", "u": "https://github.com/legiz-ru/mihomo-rule-sets/raw/main/oisd/big.mrs", "p": "./oisd/big.mrs", "i": 86400, "f": "mrs"},
  "telegram-domains": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/telegram.mrs", "p": "./rule-sets/telegram-domains.mrs", "i": 86400, "f": "mrs"},
  "telegram-ips": {"b": "ipcidr", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs", "p": "./rule-sets/telegram-ips.mrs", "i": 86400, "f": "mrs"},
  "discord_domains": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/discord.mrs", "p": "./rule-sets/discord_domains.mrs", "i": 86400, "f": "mrs"},
  "discord_vc": {"b": "classical", "payload": ["AND,((IP-CIDR,138.128.136.0/21),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,162.158.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,172.64.0.0/13),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,34.0.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,34.2.0.0/15),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,35.192.0.0/12),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,35.208.0.0/12),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,5.200.14.128/25),(NETWORK,udp),(DST-PORT,50000-50100))", "AND,((IP-CIDR,66.22.192.0/18),(NETWORK,udp),(DST-PORT,50000-50100))"]},
  "discord_voiceips": {"b": "ipcidr", "u": "https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/discord-voice-ip-list.mrs", "p": "./rule-sets/discord_voiceips.mrs", "i": 86400, "f": "mrs"},
  "cloudflare-ips": {"b": "ipcidr", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geoip/cloudflare.mrs", "p": "./rule-sets/cloudflare-ips.mrs", "i": 86400, "f": "mrs"},
  "cloudflare-domains": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/cloudflare.mrs", "p": "./rule-sets/cloudflare-domains.mrs", "i": 86400, "f": "mrs"},
  "ru-inside": {"b": "classical", "u": "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-clashx.lst", "p": "./rule-sets/ru-inside.lst", "i": 86400, "f": "text"},
  "refilter_domains": {"b": "domain", "u": "https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/domain-rule.mrs", "p": "./re-filter/domain-rule.mrs", "i": 86400, "f": "mrs"},
  "ru-inline-banned": {"b": "classical", "payload": ["DOMAIN-SUFFIX,habr.com", "DOMAIN-SUFFIX,seasonvar.ru", "DOMAIN-SUFFIX,lib.social", "DOMAIN-SUFFIX,kemono.su", "DOMAIN-SUFFIX,jut.su", "DOMAIN-SUFFIX,kara.su", "DOMAIN-SUFFIX,theins.ru", "DOMAIN-SUFFIX,tvrain.ru", "DOMAIN-SUFFIX,echo.msk.ru", "DOMAIN-SUFFIX,the-village.ru", "DOMAIN-SUFFIX,snob.ru", "DOMAIN-SUFFIX,novayagazeta.ru", "DOMAIN-SUFFIX,moscowtimes.ru", "DOMAIN-SUFFIX,natribu.org", "DOMAIN-KEYWORD,animego", "DOMAIN-KEYWORD,yummyanime", "DOMAIN-KEYWORD,yummy-anime", "DOMAIN-KEYWORD,animeportal", "DOMAIN-KEYWORD,anime-portal", "DOMAIN-KEYWORD,animedub", "DOMAIN-KEYWORD,anidub", "DOMAIN-KEYWORD,animelib", "DOMAIN-KEYWORD,ikianime", "DOMAIN-KEYWORD,anilibria"]},
  "inline-blocked-ips": {"b": "classical", "payload": ["IP-CIDR,172.232.25.131/32"]},
  "ai": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-ai-!cn.mrs", "p": "./rule-sets/ai.mrs", "i": 86400, "f": "mrs"},
  "google-deepmind": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/google-gemini.mrs", "p": "./rule-sets/gooogle-deepmind.mrs", "i": 86400, "f": "mrs"},
  "ru-inline": {"b": "classical", "payload": ["DOMAIN-SUFFIX,2ip.ru", "DOMAIN-SUFFIX,yastatic.net", "DOMAIN-SUFFIX,yandex.net", "DOMAIN-SUFFIX,yandex.kz", "DOMAIN-SUFFIX,yandex.com", "DOMAIN-SUFFIX,yadi.sk", "DOMAIN-SUFFIX,mycdn.me", "DOMAIN-SUFFIX,jivosite.com", "DOMAIN-SUFFIX,vk.com", "DOMAIN-SUFFIX,avira.com", "DOMAIN-SUFFIX,.ru", "DOMAIN-SUFFIX,.su", "DOMAIN-SUFFIX,.by", "DOMAIN-SUFFIX,.ru.com", "DOMAIN-SUFFIX,.ru.net", "DOMAIN-SUFFIX,kudago.com", "DOMAIN-SUFFIX,kinescope.io", "DOMAIN-SUFFIX,redheadsound.studio", "DOMAIN-SUFFIX,plplayer.online", "DOMAIN-SUFFIX,lomont.site", "DOMAIN-SUFFIX,remanga.org", "DOMAIN-SUFFIX,shopstory.live", "DOMAIN-KEYWORD,avito", "DOMAIN-KEYWORD,miradres", "DOMAIN-KEYWORD,premier", "DOMAIN-KEYWORD,shutterstock", "DOMAIN-KEYWORD,2gis", "DOMAIN-KEYWORD,diginetita", "DOMAIN-KEYWORD,kinescopecdn", "DOMAIN-KEYWORD,researchgate", "DOMAIN-KEYWORD,springer", "DOMAIN-KEYWORD,nextcloud", "DOMAIN-KEYWORD,kaspersky", "DOMAIN-KEYWORD,stepik", "DOMAIN-KEYWORD,likee", "DOMAIN-KEYWORD,snapchat", "DOMAIN-KEYWORD,yappy", "DOMAIN-KEYWORD,pikabu", "DOMAIN-KEYWORD,okko", "DOMAIN-KEYWORD,wink", "DOMAIN-KEYWORD,kion", "DOMAIN-KEYWORD,roblox", "DOMAIN-KEYWORD,ozon", "DOMAIN-KEYWORD,wildberries", "DOMAIN-KEYWORD,aliexpress"]},
  "ru-outside": {"b": "classical", "u": "https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Russia/outside-clashx.lst", "p": "./rule-sets/ru-outside.lst", "i": 86400, "f": "text"},
  "yandex": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/yandex.yaml", "p": "./rule-sets/yandex.yaml", "i": 86400, "f": "yaml"},
  "mailru": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/mailru.mrs", "p": "./rule-sets/mailru.mrs", "i": 86400, "f": "mrs"},
  "drweb": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/drweb.mrs", "p": "./rule-sets/drweb.mrs", "i": 86400, "f": "mrs"},
  "geosite-ru": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/category-ru.mrs", "p": "./rule-sets/geosite-ru.mrs", "i": 86400, "f": "mrs"},
  "geoip-ru": {"b": "ipcidr", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/ru.mrs", "p": "./rule-sets/geoip-ru.mrs", "i": 86400, "f": "mrs"},
  "geoip-by": {"b": "ipcidr", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/by.mrs", "p": "./rule-sets/geoip-by.mrs", "i": 86400, "f": "mrs"},
  "facebook-ips": {"b": "ipcidr", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/facebook.mrs", "p": "./rule-sets/facebook-ips.mrs", "i": 86400, "f": "mrs"},
  "whatsapp-domains": {"b": "domain", "u": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/whatsapp.mrs", "p": "./rule-sets/whatsapp-domains.mrs", "i": 86400, "f": "mrs"},
};

// ---- DNS-фолбэки: Яндекс доступен в белых списках без VPN ----
var RF_BS_DNS_PLAIN = ["77.88.8.8", "77.88.8.1"];
var RF_BS_DNS_DOT = [
  "tls://77.88.8.8#skip-cert-verify=true",
  "tls://77.88.8.1#skip-cert-verify=true"
];

// Цели, не требующие группы/прокси в профиле
var RF_BS_BUILTIN_TARGETS = {
  DIRECT: true, REJECT: true, "REJECT-DROP": true, PASS: true,
  PROXY: true, GLOBAL: true, COMPATIBLE: true
};

// ---- Хелперы ----

function _groupNames(config) {
  var names = {};
  var groups = config["proxy-groups"];
  if (Array.isArray(groups)) {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i] && typeof groups[i].name === "string") {
        names[groups[i].name] = true;
      }
    }
  }
  var proxies = config.proxies;
  if (Array.isArray(proxies)) {
    for (var j = 0; j < proxies.length; j++) {
      if (proxies[j] && typeof proxies[j].name === "string") {
        names[proxies[j].name] = true;
      }
    }
  }
  return names;
}

function _hasProxyGroup(config) {
  var groups = config["proxy-groups"];
  if (!Array.isArray(groups)) return false;
  for (var i = 0; i < groups.length; i++) {
    if (groups[i] && groups[i].name === "PROXY") return true;
  }
  return false;
}

// Заменяет цель правила на PROXY, если в профиле нет такой группы/прокси.
// Цель — последний сегмент (или предпоследний при хвосте no-resolve).
function _resolveRule(rule, names) {
  var parts = String(rule).split(",");
  var t = parts.length - 1;
  if (parts[t] === "no-resolve" && parts.length >= 3) t -= 1;
  var target = parts[t];
  if (!RF_BS_BUILTIN_TARGETS[target] && !names[target]) {
    parts[t] = "PROXY";
  }
  return parts.join(",");
}

// Все варианты строк правил скрипта (сырые и с заменёнными целями) —
// для снятия перед повторной вставкой.
var RF_BS_OUR_STRINGS = (function () {
  var map = {};
  for (var i = 0; i < RF_BS_RULES.length; i++) {
    map[RF_BS_RULES[i]] = true;
    map[_resolveRule(RF_BS_RULES[i], {})] = true;
  }
  return map;
})();

function _isOurs(rule) {
  return RF_BS_OUR_STRINGS[String(rule)] === true;
}

function _applyProviders(config) {
  var providers = config["rule-providers"];
  if (!providers || typeof providers !== "object" || Array.isArray(providers)) {
    providers = {};
  }
  for (var name in RF_BS_PROVIDERS) {
    if (providers[name]) {
      console.warn("РФ-БС: заменяю rule-provider профиля '" + name + "'");
    }
    var p = RF_BS_PROVIDERS[name];
    var def;
    if (p.payload) {
      def = { type: "inline", behavior: p.b, payload: p.payload.slice() };
    } else {
      def = {
        type: "http",
        behavior: p.b,
        url: p.u,
        path: p.p,
        interval: p.i
      };
      if (p.f) def.format = p.f;
    }
    providers[name] = def;
  }
  config["rule-providers"] = providers;
}

function _applyRules(config, names, opts) {
  var quicBlock = opts["Блокировать QUIC (UDP 443)"] !== false;
  var finalMatch = opts["Заменять финал на MATCH,PROXY"] !== false;

  var ours = [];
  for (var i = 0; i < RF_BS_RULES.length; i++) {
    var raw = RF_BS_RULES[i];
    if (!quicBlock && raw === RF_BS_QUIC_RULE) continue;
    ours.push(_resolveRule(raw, names));
  }

  var rest = [];
  var rules = Array.isArray(config.rules) ? config.rules : [];
  for (var j = 0; j < rules.length; j++) {
    var rule = rules[j];
    if (_isOurs(rule)) continue;
    if (finalMatch && String(rule).split(",")[0] === "MATCH") continue;
    rest.push(rule);
  }

  config.rules = ours.concat(rest);
  if (finalMatch) {
    config.rules.push("MATCH,PROXY");
  }
}

function _removeOurs(config) {
  if (!Array.isArray(config.rules)) return;
  config.rules = config.rules.filter(function (rule) {
    return !_isOurs(rule);
  });
}

function _applyDns(config) {
  var dns = config.dns;
  if (!dns || typeof dns !== "object" || dns.enable !== true) return;
  var plan = [
    ["default-nameserver", RF_BS_DNS_PLAIN],
    ["nameserver", RF_BS_DNS_DOT],
    ["proxy-server-nameserver", RF_BS_DNS_DOT]
  ];
  for (var i = 0; i < plan.length; i++) {
    var key = plan[i][0];
    var fallback = plan[i][1];
    var list = dns[key];
    if (list == null) {
      dns[key] = fallback.slice();
      continue;
    }
    if (!Array.isArray(list)) continue;
    for (var k = 0; k < fallback.length; k++) {
      var item = fallback[k];
      var exists = false;
      for (var m = 0; m < list.length; m++) {
        if (String(list[m]) === item) { exists = true; break; }
      }
      if (!exists) list.push(item);
    }
  }
}

// ---- Точка входа ----

function main(config) {
  if (!config) return config;

  var opts = typeof ruleOptionsEnable === "object" && ruleOptionsEnable ? ruleOptionsEnable : {};

  if (opts["Схема белых списков (правила и провайдеры)"] !== false) {
    if (_hasProxyGroup(config)) {
      _applyProviders(config);
      _applyRules(config, _groupNames(config), opts);
    } else {
      console.warn("РФ-БС: в профиле нет группы 'PROXY', схема не применена");
    }
  } else {
    _removeOurs(config);
  }

  if (opts["DNS-фолбэки (Яндекс 77.88.8.8)"] !== false) {
    _applyDns(config);
  }

  return config;
}
''';
