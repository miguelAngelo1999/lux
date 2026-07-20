import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../model/app.dart';

/// Loaded once at startup from assets/translations.json.
/// Maps: languageCode → { english_string → translated_string }
class TranslationCache {
  static Map<String, Map<String, String>> _cache = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final data = await rootBundle.loadString('assets/translations.json');
      final json = jsonDecode(data) as Map<String, dynamic>;
      final translations = json['translations'] as Map<String, dynamic>;
      _cache = translations.map((lang, strings) => MapEntry(
            lang,
            (strings as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v.toString())),
          ));
      _loaded = true;
    } catch (e) {
      debugPrint('TranslationCache: failed to load: $e');
    }
  }

  static String translate(String text, String languageCode) {
    if (languageCode == 'en' || languageCode == 'system') return text;
    return _cache[languageCode]?[text] ?? text;
  }
}

/// Drop-in replacement for Text() that auto-translates based on the
/// currently selected language in Settings → General → Language.
///
/// Usage: TText('Settings') instead of Text('Settings')
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
    final lang = context
        .select<AppStateModel, String>((m) => m.locale.languageCode);
    final translated = TranslationCache.translate(data, lang);
    return Text(
      translated,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      strutStyle: strutStyle,
    );
  }
}

/// Translate a raw string using the current locale from context.
/// Use when you can't use TText (e.g. tooltip strings, hint text).
String tl(BuildContext context, String text) {
  try {
    final lang =
        Provider.of<AppStateModel>(context, listen: false).locale.languageCode;
    return TranslationCache.translate(text, lang);
  } catch (_) {
    return text;
  }
}
