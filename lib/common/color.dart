import 'dart:math';

import 'package:flutter/material.dart';

extension ColorExtension on Color {
  Color get opacity80 {
    return withAlpha(204);
  }

  Color get opacity60 {
    return withAlpha(153);
  }

  Color get opacity50 {
    return withAlpha(128);
  }

  Color get opacity38 {
    return withAlpha(97);
  }

  Color get opacity30 {
    return withAlpha(77);
  }

  Color get opacity12 {
    return withAlpha(31);
  }

  Color get opacity15 {
    return withAlpha(38);
  }

  Color get opacity10 {
    return withAlpha(15);
  }

  Color get opacity3 {
    return withAlpha(76);
  }

  Color get opacity0 {
    return withAlpha(0);
  }

  int get value32bit {
    return _floatToInt8(a) << 24 |
        _floatToInt8(r) << 16 |
        _floatToInt8(g) << 8 |
        _floatToInt8(b) << 0;
  }

  int get alpha8bit => (0xff000000 & value32bit) >> 24;

  int get red8bit => (0x00ff0000 & value32bit) >> 16;

  int get green8bit => (0x0000ff00 & value32bit) >> 8;

  int get blue8bit => (0x000000ff & value32bit) >> 0;

  int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lighten([double amount = 10]) {
    if (amount <= 0) return this;
    if (amount > 100) return Colors.white;
    final HSLColor hsl = this == const Color(0xFF000000)
        ? HSLColor.fromColor(this).withSaturation(0)
        : HSLColor.fromColor(this);
    return hsl
        .withLightness(min(1, max(0, hsl.lightness + amount / 100)))
        .toColor();
  }

  String get hex {
    final value = toARGB32();
    final red = (value >> 16) & 0xFF;
    final green = (value >> 8) & 0xFF;
    final blue = value & 0xFF;
    return '#${red.toRadixString(16).padLeft(2, '0')}'
            '${green.toRadixString(16).padLeft(2, '0')}'
            '${blue.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  Color darken([final int amount = 10]) {
    if (amount <= 0) return this;
    if (amount > 100) return Colors.black;
    final HSLColor hsl = HSLColor.fromColor(this);
    return hsl
        .withLightness(min(1, max(0, hsl.lightness - amount / 100)))
        .toColor();
  }

  Color blendDarken(BuildContext context, {double factor = 0.1}) {
    final brightness = Theme.of(context).brightness;
    return Color.lerp(
      this,
      brightness == Brightness.dark ? Colors.white : Colors.black,
      factor,
    )!;
  }

  Color blendLighten(BuildContext context, {double factor = 0.1}) {
    final brightness = Theme.of(context).brightness;
    return Color.lerp(
      this,
      brightness == Brightness.dark ? Colors.black : Colors.white,
      factor,
    )!;
  }
}

extension ColorSchemeExtension on ColorScheme {
  ColorScheme toPureBlack(bool isPrueBlack) => isPrueBlack
      ? copyWith(
          surface: Colors.black,
          surfaceContainer: surfaceContainer.darken(5),
        )
      : this;
}

/// Цвет-метка «угольной» темы: тёмно-коричневый свотч в настройках темы
/// (см. defaultPrimaryColors в common/constant.dart).
const kCoalPrimaryColor = 0xFF5D4037;

/// «Угольно-чёрная» тема с коричневой обводкой: включается выбором
/// коричневого свотча (kCoalPrimaryColor) как основного цвета в тёмном
/// режиме. Поверхности становятся угольно-чёрными с тёплым подтоном,
/// обводки (outline/outlineVariant) — коричневыми.
extension CoalColorSchemeExtension on ColorScheme {
  ColorScheme toCoal(int? primaryColor) {
    if (primaryColor != kCoalPrimaryColor) return this;
    return copyWith(
      surface: const Color(0xFF080706),
      surfaceDim: const Color(0xFF050403),
      surfaceBright: const Color(0xFF1B1712),
      surfaceContainerLowest: const Color(0xFF050403),
      surfaceContainerLow: const Color(0xFF0B0907),
      surfaceContainer: const Color(0xFF0E0B09),
      surfaceContainerHigh: const Color(0xFF13100C),
      surfaceContainerHighest: const Color(0xFF181410),
      onSurface: const Color(0xFFE8DDD6),
      onSurfaceVariant: const Color(0xFFBCAAA4),
      outline: const Color(0xFF8D6E63),
      outlineVariant: const Color(0xFF4E342E),
    );
  }
}
