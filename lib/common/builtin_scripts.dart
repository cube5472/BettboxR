// Встроенные скрипты клиента.
//  - s-ru: правила маршрутизации + фильтр RU-нод (источник — download/s-ru-combined.js)
//  - Bag-rules-paranoid: DNS-карантин (источник — download/Bag-rules-paranoid.yaml)
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
