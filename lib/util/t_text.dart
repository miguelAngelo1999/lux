import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../model/app.dart';

/// Translations loaded once at startup from assets/translations.json.
///
/// Keys are the English source strings, so a widget can be translated by
/// swapping Text for TText without introducing a separate key vocabulary. A
/// missing translation falls back to the English text rather than showing a key,
/// which means a partially translated UI degrades gracefully.
class TranslationCache {
  static Map<String, Map<String, String>> _cache = {};
  static bool _loaded = false;

  static bool get isLoaded => _loaded;

  /// Language codes present in the bundle, excluding English.
  static List<String> get availableLanguages => _cache.keys.toList()..sort();

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final data = await rootBundle.loadString('assets/translations.json');
      final json = jsonDecode(data) as Map<String, dynamic>;
      final translations = json['translations'] as Map<String, dynamic>? ?? {};
      _cache = translations.map(
        (lang, strings) => MapEntry(
          lang,
          (strings as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, v.toString())),
        ),
      );
      _loaded = true;
    } catch (e) {
      // A missing or malformed bundle must not break the UI; every lookup then
      // returns the English source.
      debugPrint('TranslationCache: could not load translations: $e');
      _loaded = true;
    }
  }

  static String translate(String text, String languageCode) {
    if (languageCode.isEmpty ||
        languageCode == 'en' ||
        languageCode == 'system') {
      return text;
    }
    return _cache[languageCode]?[text] ?? text;
  }

  /// Fraction of known strings translated for [languageCode], for reporting
  /// coverage in Settings.
  static double coverage(String languageCode) {
    final strings = _cache[languageCode];
    if (strings == null || strings.isEmpty) return 0;
    final total = _cache.values.fold<int>(0, (m, e) => e.length > m ? e.length : m);
    if (total == 0) return 0;
    return strings.length / total;
  }
}

/// Drop-in replacement for [Text] that translates using the language selected in
/// Settings.
///
/// Rebuilds only when the locale changes, via context.select on that one field.
class TText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final StrutStyle? strutStyle;

  const TText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.strutStyle,
  });

  @override
  Widget build(BuildContext context) {
    final lang =
        context.select<AppStateModel, String>((m) => m.locale.languageCode);
    return Text(
      TranslationCache.translate(data, lang),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      strutStyle: strutStyle,
    );
  }
}

/// Translate a bare string where a widget cannot be used, such as a tooltip
/// message or a TextField hint.
///
/// Does not subscribe to locale changes, so a caller that must update live
/// should read the locale itself and rebuild.
String tl(BuildContext context, String text) {
  try {
    final lang =
        Provider.of<AppStateModel>(context, listen: false).locale.languageCode;
    return TranslationCache.translate(text, lang);
  } catch (_) {
    return text;
  }
}
