/// Определение страны выбранной ноды для флага в статус-баре.
///
/// Страна берётся из флаг-эмодзи в названии прокси («🇩🇪 Berlin 1») —
/// так подписывают ноды практически все провайдеры. Если эмодзи нет,
/// пробуем угадать страну по названию (RU/EN слова и города).
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

/// Словарь названий стран и крупных узловых городов (RU/EN).
///
/// Ключи в нижнем регистре; сопоставление — по целым словам и биграммам
/// из названия ноды, чтобы короткие коды («us», «uk») не ловились внутри
/// случайных слов.
const Map<String, String> _countryNameMap = {
  // Россия / СНГ
  'россия': 'RU',
  'russia': 'RU',
  'москва': 'RU',
  'moscow': 'RU',
  'украина': 'UA',
  'ukraine': 'UA',
  'казахстан': 'KZ',
  'kazakhstan': 'KZ',
  'беларусь': 'BY',
  'belarus': 'BY',
  // Европа
  'германия': 'DE',
  'germany': 'DE',
  'нидерланды': 'NL',
  'netherlands': 'NL',
  'амстердам': 'NL',
  'amsterdam': 'NL',
  'франция': 'FR',
  'france': 'FR',
  'париж': 'FR',
  'paris': 'FR',
  'британия': 'GB',
  'англи': 'GB',
  'британи': 'GB',
  'london': 'GB',
  'лондон': 'GB',
  'финляндия': 'FI',
  'finland': 'FI',
  'хельсинки': 'FI',
  'helsinki': 'FI',
  'швеция': 'SE',
  'sweden': 'SE',
  'стокгольм': 'SE',
  'норвегия': 'NO',
  'norway': 'NO',
  'дания': 'DK',
  'denmark': 'DK',
  'польша': 'PL',
  'poland': 'PL',
  'варшава': 'PL',
  'warsaw': 'PL',
  'чехия': 'CZ',
  'czech': 'CZ',
  'прага': 'CZ',
  'португалия': 'PT',
  'portugal': 'PT',
  'испания': 'ES',
  'spain': 'ES',
  'мадрид': 'ES',
  'италия': 'IT',
  'italy': 'IT',
  'милан': 'IT',
  'швейцария': 'CH',
  'switzerland': 'CH',
  'цирих': 'CH',
  'austri': 'AT',
  'австри': 'AT',
  'вена': 'AT',
  'vienna': 'AT',
  'румыния': 'RO',
  'romania': 'RO',
  'молдова': 'MD',
  'moldova': 'MD',
  'грузия': 'GE',
  'georgia': 'GE',
  'армения': 'AM',
  'armenia': 'AM',
  'сербия': 'RS',
  'serbia': 'RS',
  'болгария': 'BG',
  'bulgaria': 'BG',
  'греция': 'GR',
  'greece': 'GR',
  'венгрия': 'HU',
  'hungary': 'HU',
  'ирландия': 'IE',
  'ireland': 'IE',
  'luxembourg': 'LU',
  'люксембург': 'LU',
  'эстония': 'EE',
  'estonia': 'EE',
  'латвия': 'LV',
  'latvia': 'LV',
  'литва': 'LT',
  'lithuania': 'LT',
  'исландия': 'IS',
  'iceland': 'IS',
  // Азия / Ближний Восток
  'турция': 'TR',
  'turkey': 'TR',
  'стамбул': 'TR',
  'istanbul': 'TR',
  'эмират': 'AE',
  'emirates': 'AE',
  'дубай': 'AE',
  'dubai': 'AE',
  'israel': 'IL',
  'израиль': 'IL',
  'япония': 'JP',
  'japan': 'JP',
  'токио': 'JP',
  'tokyo': 'JP',
  'гонконг': 'HK',
  'hongkong': 'HK',
  'hong kong': 'HK',
  'тайвань': 'TW',
  'taiwan': 'TW',
  'сингапур': 'SG',
  'singapore': 'SG',
  'корея': 'KR',
  'korea': 'KR',
  'сеул': 'KR',
  'seoul': 'KR',
  'китай': 'CN',
  'china': 'CN',
  'индия': 'IN',
  'india': 'IN',
  'вьетнам': 'VN',
  'vietnam': 'VN',
  'таиланд': 'TH',
  'thailand': 'TH',
  'малайзия': 'MY',
  'malaysia': 'MY',
  'индонезия': 'ID',
  'indonesia': 'ID',
  'филиппины': 'PH',
  'philippines': 'PH',
  'узбекистан': 'UZ',
  'uzbekistan': 'UZ',
  // Америка / Океания / Африка
  'сша': 'US',
  'usa': 'US',
  'u.s.': 'US',
  'америка': 'US',
  'america': 'US',
  'нью-йорк': 'US',
  'new york': 'US',
  'los angeles': 'US',
  'канада': 'CA',
  'canada': 'CA',
  'бразилия': 'BR',
  'brazil': 'BR',
  'мексика': 'MX',
  'mexico': 'MX',
  'аргентина': 'AR',
  'argentina': 'AR',
  'чили': 'CL',
  'chile': 'CL',
  'австралия': 'AU',
  'australia': 'AU',
  'новая зеландия': 'NZ',
  'new zealand': 'NZ',
  'юар': 'ZA',
  'south africa': 'ZA',
  'египет': 'EG',
  'egypt': 'EG',
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

/// Ищет страну по словам названия (включая биграммы для «hong kong»).
String? _detectByName(String name) {
  final rawTokens = name.split(RegExp(r'\s+'));
  final tokens = rawTokens.map(_normalizeToken).where((t) => t.isNotEmpty).toList();
  for (final token in tokens) {
    final code = _countryNameMap[token];
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
  return null;
}

/// Определяет страну ноды по её названию: сначала флаг-эмодзи, затем
/// слова (страны/города). Возвращает ISO alpha-2 код или null.
String? detectNodeCountryCode(String? nodeName) {
  if (nodeName == null || nodeName.isEmpty) {
    return null;
  }
  return _detectByEmoji(nodeName) ?? _detectByName(nodeName);
}
