/// Определение страны выбранной ноды для флага в статус-баре.
///
/// Порядок определения:
/// 1. Флаг-эмодзи в названии прокси («🇩🇪 Berlin 1») — так подписывают
///    ноды практически все провайдеры.
/// 2. Слова стран и крупных узловых городов (RU/EN + популярная латынь).
/// 3. Двухбуквенные ISO-коды как отдельные токены: «DE», «us1», «SG-02»,
///    «GB#3». Токены режутся по пробелам и пунктуации, поэтому «DE-1»,
///    «DE_1», «DE•1» и «DE#1» распознаются одинаково.
///
/// Если ни один способ не сработал, вызывающий код берёт страну из
/// последней IP-проверки (AppController.syncNodeFlagNotification →
/// detectionState) — это фолбэк для нод с «безликими» именами (личные
/// VPS и т.п.).
///
/// Результат — ISO 3166-1 alpha-2 код в верхнем регистре (например DE),
/// либо null, если страну определить не удалось. Код уходит в нативный
/// слой (NodeFlagNotification), который рисует флаг в уведомлении рядом
/// с иконкой приложения в статус-баре.
library;

final RegExp _flagEmojiRegExp = RegExp(
  r'[\u{1F1E6}-\u{1F1FF}]{2}',
  unicode: true,
);

/// Разделители внутри названий нод: пробелы, дефисы разных видов,
/// подчёркивания, буллеты, слэши, решётки, скобки и прочая пунктуация.
/// Благодаря этому «DE-1», «DE_1», «DE•1» и «DE#1» дают один токен «DE».
final RegExp _tokenSplitRegExp = RegExp(
  r'[\s\-‐‑‒–—―_·•.,/\\|#(){}\[\]<>+=*~^%$@!?;:]+',
);

final RegExp _digitsRegExp = RegExp(r'\d+');

/// Флаг-эмодзи → ISO-код: региональные индикаторы — это буквы A-Z,
/// смещённые на 0x1F1E6 от 'A' (0x41).
String? _countryCodeFromFlagEmoji(String emoji) {
  final runes = emoji.runes.toList();
  if (runes.length != 2) {
    return null;
  }
  final first = runes[0] - 0x1F1E6 + 65;
  final second = runes[1] - 0x1F1E6 + 65;
  if (first < 65 || first > 90 || second < 65 || second > 90) {
    return null;
  }
  return String.fromCharCodes([first, second]);
}

/// Словарь названий стран и крупных узловых городов (RU/EN + латынь).
///
/// Ключи в нижнем регистре; сопоставление — по целым словам и биграммам
/// из названия ноды, чтобы короткие коды («us», «uk») не ловились внутри
/// случайных слов.
const Map<String, String> _countryNameMap = {
  // Россия / СНГ
  'россия': 'RU',
  'russia': 'RU',
  'rusia': 'RU',
  'москва': 'RU',
  'moscow': 'RU',
  'питер': 'RU',
  'спб': 'RU',
  'украина': 'UA',
  'ukraine': 'UA',
  'киев': 'UA',
  'kiev': 'UA',
  'kyiv': 'UA',
  'харьков': 'UA',
  'kharkiv': 'UA',
  'одесса': 'UA',
  'odesa': 'UA',
  'казахстан': 'KZ',
  'kazakhstan': 'KZ',
  'алматы': 'KZ',
  'almaty': 'KZ',
  'астана': 'KZ',
  'astana': 'KZ',
  'беларусь': 'BY',
  'belarus': 'BY',
  'минск': 'BY',
  'minsk': 'BY',
  'узбекистан': 'UZ',
  'uzbekistan': 'UZ',
  'ташкент': 'UZ',
  'tashkent': 'UZ',
  'грузия': 'GE',
  'georgia': 'GE',
  'тбилиси': 'GE',
  'tbilisi': 'GE',
  'батуми': 'GE',
  'batumi': 'GE',
  'армения': 'AM',
  'armenia': 'AM',
  'ереван': 'AM',
  'yerevan': 'AM',
  'азербайджан': 'AZ',
  'azerbaijan': 'AZ',
  'баку': 'AZ',
  'baku': 'AZ',
  'молдова': 'MD',
  'moldova': 'MD',
  'кишинев': 'MD',
  'кишинёв': 'MD',
  'chisinau': 'MD',
  // Европа
  'германия': 'DE',
  'germany': 'DE',
  'alemania': 'DE',
  'берлин': 'DE',
  'berlin': 'DE',
  'мюнхен': 'DE',
  'munich': 'DE',
  'франкфурт': 'DE',
  'frankfurt': 'DE',
  'гамбург': 'DE',
  'hamburg': 'DE',
  'дюссельдорф': 'DE',
  'dusseldorf': 'DE',
  'нидерланды': 'NL',
  'netherlands': 'NL',
  'голландия': 'NL',
  'holland': 'NL',
  'амстердам': 'NL',
  'amsterdam': 'NL',
  'роттердам': 'NL',
  'rotterdam': 'NL',
  'франция': 'FR',
  'france': 'FR',
  'francia': 'FR',
  'париж': 'FR',
  'paris': 'FR',
  'лион': 'FR',
  'lyon': 'FR',
  'марсель': 'FR',
  'marseille': 'FR',
  'страсбург': 'FR',
  'strasbourg': 'FR',
  'британия': 'GB',
  'англи': 'GB',
  'англия': 'GB',
  'england': 'GB',
  'шотландия': 'GB',
  'scotland': 'GB',
  'британи': 'GB',
  'london': 'GB',
  'лондон': 'GB',
  'манчестер': 'GB',
  'manchester': 'GB',
  'эдинбург': 'GB',
  'edinburgh': 'GB',
  'финляндия': 'FI',
  'finland': 'FI',
  'хельсинки': 'FI',
  'helsinki': 'FI',
  'швеция': 'SE',
  'sweden': 'SE',
  'стокгольм': 'SE',
  'stockholm': 'SE',
  'норвегия': 'NO',
  'norway': 'NO',
  'осло': 'NO',
  'oslo': 'NO',
  'дания': 'DK',
  'denmark': 'DK',
  'копенгаген': 'DK',
  'copenhagen': 'DK',
  'исландия': 'IS',
  'iceland': 'IS',
  'рейкьявик': 'IS',
  'reykjavik': 'IS',
  'польша': 'PL',
  'poland': 'PL',
  'варшава': 'PL',
  'warsaw': 'PL',
  'краков': 'PL',
  'krakow': 'PL',
  'чехия': 'CZ',
  'czech': 'CZ',
  'прага': 'CZ',
  'prague': 'CZ',
  'словакия': 'SK',
  'slovakia': 'SK',
  'братислава': 'SK',
  'bratislava': 'SK',
  'венгрия': 'HU',
  'hungary': 'HU',
  'будапешт': 'HU',
  'budapest': 'HU',
  'румыния': 'RO',
  'romania': 'RO',
  'бухарест': 'RO',
  'bucharest': 'RO',
  'сербия': 'RS',
  'serbia': 'RS',
  'белград': 'RS',
  'belgrade': 'RS',
  'болгария': 'BG',
  'bulgaria': 'BG',
  'софия': 'BG',
  'sofia': 'BG',
  'греция': 'GR',
  'greece': 'GR',
  'афины': 'GR',
  'athens': 'GR',
  'хорватия': 'HR',
  'croatia': 'HR',
  'загреб': 'HR',
  'zagreb': 'HR',
  'словения': 'SI',
  'slovenia': 'SI',
  'любляна': 'SI',
  'ljubljana': 'SI',
  'босния': 'BA',
  'bosnia': 'BA',
  'португалия': 'PT',
  'portugal': 'PT',
  'лиссабон': 'PT',
  'lisbon': 'PT',
  'испания': 'ES',
  'spain': 'ES',
  'мадрид': 'ES',
  'madrid': 'ES',
  'барселона': 'ES',
  'barcelona': 'ES',
  'италия': 'IT',
  'italy': 'IT',
  'милан': 'IT',
  'milan': 'IT',
  'рим': 'IT',
  'rome': 'IT',
  'швейцария': 'CH',
  'switzerland': 'CH',
  'цирих': 'CH',
  'zurich': 'CH',
  'женева': 'CH',
  'geneva': 'CH',
  'бельгия': 'BE',
  'belgium': 'BE',
  'брюссель': 'BE',
  'brussels': 'BE',
  'антверпен': 'BE',
  'antwerp': 'BE',
  'ирландия': 'IE',
  'ireland': 'IE',
  'дублин': 'IE',
  'dublin': 'IE',
  'люксембург': 'LU',
  'luxembourg': 'LU',
  'эстония': 'EE',
  'estonia': 'EE',
  'таллин': 'EE',
  'tallinn': 'EE',
  'латвия': 'LV',
  'latvia': 'LV',
  'рига': 'LV',
  'riga': 'LV',
  'литва': 'LT',
  'lithuania': 'LT',
  'вильнюс': 'LT',
  'vilnius': 'LT',
  // Азия / Ближний Восток
  'турция': 'TR',
  'turkey': 'TR',
  'стамбул': 'TR',
  'istanbul': 'TR',
  'анкара': 'TR',
  'ankara': 'TR',
  'анталия': 'TR',
  'antalya': 'TR',
  'измир': 'TR',
  'izmir': 'TR',
  'эмират': 'AE',
  'emirates': 'AE',
  'дубай': 'AE',
  'dubai': 'AE',
  'israel': 'IL',
  'израиль': 'IL',
  'авив': 'IL',
  'aviv': 'IL',
  'иерусалим': 'IL',
  'jerusalem': 'IL',
  'саудовская': 'SA',
  'saudi': 'SA',
  'рияд': 'SA',
  'riyadh': 'SA',
  'катар': 'QA',
  'qatar': 'QA',
  'доха': 'QA',
  'doha': 'QA',
  'япония': 'JP',
  'japan': 'JP',
  'japon': 'JP',
  'токио': 'JP',
  'tokyo': 'JP',
  'осака': 'JP',
  'osaka': 'JP',
  'гонконг': 'HK',
  'hongkong': 'HK',
  'hong kong': 'HK',
  'макао': 'MO',
  'macau': 'MO',
  'тайвань': 'TW',
  'taiwan': 'TW',
  'тайбей': 'TW',
  'taipei': 'TW',
  'сингапур': 'SG',
  'singapore': 'SG',
  'корея': 'KR',
  'korea': 'KR',
  'сеул': 'KR',
  'seoul': 'KR',
  'пусан': 'KR',
  'busan': 'KR',
  'китай': 'CN',
  'china': 'CN',
  'пекин': 'CN',
  'beijing': 'CN',
  'шанхай': 'CN',
  'shanghai': 'CN',
  'шэньчжэнь': 'CN',
  'shenzhen': 'CN',
  'индия': 'IN',
  'india': 'IN',
  'мумбаи': 'IN',
  'mumbai': 'IN',
  'дели': 'IN',
  'delhi': 'IN',
  'вьетнам': 'VN',
  'vietnam': 'VN',
  'ханой': 'VN',
  'hanoi': 'VN',
  'сайгон': 'VN',
  'saigon': 'VN',
  'хошимин': 'VN',
  'таиланд': 'TH',
  'thailand': 'TH',
  'бангкок': 'TH',
  'bangkok': 'TH',
  'паттайя': 'TH',
  'pattaya': 'TH',
  'малайзия': 'MY',
  'malaysia': 'MY',
  'куала': 'MY',
  'kuala': 'MY',
  'лумпур': 'MY',
  'lumpur': 'MY',
  'индонезия': 'ID',
  'indonesia': 'ID',
  'джакарта': 'ID',
  'jakarta': 'ID',
  'филиппины': 'PH',
  'philippines': 'PH',
  'манила': 'PH',
  'manila': 'PH',
  'монголия': 'MN',
  'mongolia': 'MN',
  'уланбатор': 'MN',
  'ulaanbaatar': 'MN',
  // Америка / Океания / Африка
  'сша': 'US',
  'usa': 'US',
  'америка': 'US',
  'america': 'US',
  'нью-йорк': 'US',
  'нью': 'US',
  'йорк': 'US',
  'new york': 'US',
  'анджелес': 'US',
  'angeles': 'US',
  'вашингтон': 'US',
  'washington': 'US',
  'чикаго': 'US',
  'chicago': 'US',
  'майами': 'US',
  'miami': 'US',
  'сиэтл': 'US',
  'seattle': 'US',
  'бостон': 'US',
  'boston': 'US',
  'хьюстон': 'US',
  'houston': 'US',
  'даллас': 'US',
  'dallas': 'US',
  'атланта': 'US',
  'atlanta': 'US',
  'денвер': 'US',
  'denver': 'US',
  'канада': 'CA',
  'canada': 'CA',
  'торонто': 'CA',
  'toronto': 'CA',
  'ванкувер': 'CA',
  'vancouver': 'CA',
  'монреаль': 'CA',
  'montreal': 'CA',
  'бразилия': 'BR',
  'brazil': 'BR',
  'brasil': 'BR',
  'паулу': 'BR',
  'paulo': 'BR',
  'рио': 'BR',
  'rio': 'BR',
  'мексика': 'MX',
  'mexico': 'MX',
  'аргентина': 'AR',
  'argentina': 'AR',
  'байрес': 'AR',
  'aires': 'AR',
  'чили': 'CL',
  'chile': 'CL',
  'сантьяго': 'CL',
  'santiago': 'CL',
  'перу': 'PE',
  'peru': 'PE',
  'лима': 'PE',
  'lima': 'PE',
  'колумбия': 'CO',
  'colombia': 'CO',
  'богота': 'CO',
  'bogota': 'CO',
  'австралия': 'AU',
  'australia': 'AU',
  'сидней': 'AU',
  'sydney': 'AU',
  'мельбурн': 'AU',
  'melbourne': 'AU',
  'брисбен': 'AU',
  'brisbane': 'AU',
  'новая зеландия': 'NZ',
  'new zealand': 'NZ',
  'окленд': 'NZ',
  'auckland': 'NZ',
  'юар': 'ZA',
  'south africa': 'ZA',
  'йоханнесбург': 'ZA',
  'johannesburg': 'ZA',
  'кейптаун': 'ZA',
  'египет': 'EG',
  'egypt': 'EG',
  'каир': 'EG',
  'cairo': 'EG',
};

/// Двухбуквенные ISO-коды, как их пишут в названиях нод провайдеры
/// («DE-1», «US 2», «sg premium»). Сопоставление — по целому токену
/// после резки пунктуации и приведения к нижнему регистру.
///
/// Осознанно НЕ включены слова английского языка, маскирующиеся под
/// коды: «in», «is», «it», «no», «at», «my», «be» — они ловили бы
/// случайные слова названий. Такие страны определяются по словам выше
/// или по фолбэку IP-проверки.
const Map<String, String> _countryCodeMap = {
  'ru': 'RU',
  'ua': 'UA',
  'by': 'BY',
  'kz': 'KZ',
  'uz': 'UZ',
  'md': 'MD',
  'ge': 'GE',
  'am': 'AM',
  'az': 'AZ',
  'de': 'DE',
  'nl': 'NL',
  'fr': 'FR',
  'gb': 'GB',
  'uk': 'GB',
  'ie': 'IE',
  'fi': 'FI',
  'se': 'SE',
  'dk': 'DK',
  'pl': 'PL',
  'cz': 'CZ',
  'sk': 'SK',
  'hu': 'HU',
  'ro': 'RO',
  'bg': 'BG',
  'gr': 'GR',
  'rs': 'RS',
  'hr': 'HR',
  'si': 'SI',
  'ba': 'BA',
  'ch': 'CH',
  'es': 'ES',
  'pt': 'PT',
  'lu': 'LU',
  'ee': 'EE',
  'lv': 'LV',
  'lt': 'LT',
  'tr': 'TR',
  'il': 'IL',
  'ae': 'AE',
  'sa': 'SA',
  'qa': 'QA',
  'jp': 'JP',
  'kr': 'KR',
  'cn': 'CN',
  'hk': 'HK',
  'mo': 'MO',
  'tw': 'TW',
  'sg': 'SG',
  'mn': 'MN',
  'vn': 'VN',
  'th': 'TH',
  'id': 'ID',
  'ph': 'PH',
  'us': 'US',
  'ca': 'CA',
  'mx': 'MX',
  'br': 'BR',
  'ar': 'AR',
  'cl': 'CL',
  'co': 'CO',
  'pe': 'PE',
  'au': 'AU',
  'nz': 'NZ',
  'za': 'ZA',
  'eg': 'EG',
};

/// Достаёт ISO-код страны из флаг-эмодзи в названии ноды.
String? _detectByEmoji(String name) {
  final match = _flagEmojiRegExp.firstMatch(name);
  if (match == null) {
    return null;
  }
  return _countryCodeFromFlagEmoji(match.group(0)!);
}

/// Нормализует токен названия: нижний регистр, без пунктуации по краям.
String _normalizeToken(String token) {
  return token
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '');
}

/// Ищет страну по токенам названия.
///
/// Проходы по порядку приоритета:
/// 1. Слова стран/городов («Германия», «Frankfurt») — самый надёжный
///    источник, поэтому проверяется первым по всем токенам.
/// 2. Двухбуквенные ISO-коды токенов («DE», «US», «sg»).
/// 3. Биграммы слов («hong kong», «new york»).
/// 4. Токены, срезанные до букв: «DE1» → «de», «германия2» → «германия».
String? _detectByName(String name) {
  final rawTokens = name.split(_tokenSplitRegExp);
  final tokens = rawTokens
      .map(_normalizeToken)
      .where((t) => t.isNotEmpty)
      .toList();
  for (final token in tokens) {
    final code = _countryNameMap[token];
    if (code != null) {
      return code;
    }
  }
  for (final token in tokens) {
    final code = _countryCodeMap[token];
    if (code != null) {
      return code;
    }
  }
  for (var i = 0; i < tokens.length - 1; i++) {
    final bigram = '${tokens[i]} ${tokens[i + 1]}';
    final code = _countryNameMap[bigram];
    if (code != null) {
      return code;
    }
  }
  for (final token in tokens) {
    final lettersOnly = token.replaceAll(_digitsRegExp, '');
    if (lettersOnly == token || lettersOnly.isEmpty) {
      continue;
    }
    final code = _countryNameMap[lettersOnly] ?? _countryCodeMap[lettersOnly];
    if (code != null) {
      return code;
    }
  }
  return null;
}

/// Определяет страну ноды по её названию: сначала флаг-эмодзи, затем
/// слова (страны/города) и двухбуквенные ISO-коды токенов. Возвращает
/// ISO alpha-2 код или null.
String? detectNodeCountryCode(String? nodeName) {
  if (nodeName == null || nodeName.isEmpty) {
    return null;
  }
  return _detectByEmoji(nodeName) ?? _detectByName(nodeName);
}
