// Встроенный скрипт клиента: s-ru (правила маршрутизации + фильтр RU-нод).
// Источник — download/s-ru-combined.js; при изменении скрипта обновить константу.
// Raw-строка (r'''): JS не обрабатывается Dart-экранированием.

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
