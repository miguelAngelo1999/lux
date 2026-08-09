import 'package:flutter/material.dart';
import 'package:lux/util/t_text.dart';

/// Reusable settings rows.
///
/// Extracted so section files describe *what* a setting is rather than repeating
/// how a switch or a dropdown is laid out. Each row carries a keywords list used
/// by the settings search, so a row is findable by terms that do not appear in
/// its visible label.
class SettingRow {
  final String title;
  final List<String> keywords;
  final Widget Function(BuildContext) build;

  const SettingRow({
    required this.title,
    required this.build,
    this.keywords = const [],
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (title.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

Widget sectionHeader(BuildContext context, String title) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: TText(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );

Widget switchTile({
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  return SwitchListTile(
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle: TText(subtitle, style: const TextStyle(fontSize: 11)),
    value: value,
    dense: true,
    onChanged: onChanged,
  );
}

Widget dropdownTile<T>({
  required String title,
  required T value,
  required List<T> options,
  required String Function(T) label,
  required ValueChanged<T>? onChanged,
  String? subtitle,
}) {
  // A value outside options would throw, which can happen when a config carries
  // a value this build no longer offers.
  final safeValue = options.contains(value) ? value : options.first;
  return ListTile(
    dense: true,
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle:
        subtitle == null ? null : TText(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: DropdownButton<T>(
      value: safeValue,
      underline: const SizedBox(),
      items: options
          .map((o) => DropdownMenuItem(
                value: o,
                child: TText(label(o), style: const TextStyle(fontSize: 12)),
              ))
          .toList(),
      onChanged: onChanged == null
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    ),
  );
}

Widget numberTile({
  required String title,
  required int value,
  required ValueChanged<int>? onChanged,
  String? subtitle,
}) {
  return ListTile(
    dense: true,
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle:
        subtitle == null ? null : TText(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: SizedBox(
      width: 86,
      child: TextFormField(
        // A key tied to the value makes the field pick up an external change
        // instead of keeping the value it was first built with.
        key: ValueKey('num-$title-$value'),
        initialValue: value.toString(),
        keyboardType: TextInputType.number,
        textAlign: TextAlign.end,
        enabled: onChanged != null,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: OutlineInputBorder(),
        ),
        onFieldSubmitted: (v) {
          final n = int.tryParse(v.trim());
          if (n != null && onChanged != null) onChanged(n);
        },
      ),
    ),
  );
}

Widget textFieldTile({
  required String title,
  required String value,
  required String hint,
  required ValueChanged<String>? onChanged,
  String? subtitle,
  bool obscure = false,
}) {
  return ListTile(
    dense: true,
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: TText(subtitle, style: const TextStyle(fontSize: 11)),
          ),
        TextFormField(
          key: ValueKey('txt-$title-$value'),
          initialValue: value,
          obscureText: obscure,
          enabled: onChanged != null,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            border: const OutlineInputBorder(),
          ),
          onFieldSubmitted: onChanged,
        ),
      ],
    ),
  );
}

/// A row that performs an action, with optional busy state.
Widget actionTile({
  required BuildContext context,
  required String title,
  required String subtitle,
  required String buttonLabel,
  required VoidCallback? onPressed,
  bool busy = false,
  IconData? icon,
}) {
  return ListTile(
    dense: true,
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle: TText(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 14),
            label: TText(buttonLabel, style: const TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 30),
            ),
          ),
  );
}

/// A read-only value with a copy button, for identifiers and paths.
Widget copyableTile({
  required BuildContext context,
  required String title,
  required String value,
  required String subtitle,
  required VoidCallback onCopy,
  bool copied = false,
}) {
  return ListTile(
    dense: true,
    title: TText(title, style: const TextStyle(fontSize: 13)),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TText(subtitle, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: const TextStyle(fontSize: 11, fontFamily: 'Menlo'),
        ),
      ],
    ),
    trailing: IconButton(
      icon: Icon(copied ? Icons.check : Icons.copy, size: 15),
      tooltip: copied ? 'Copied' : 'Copy',
      onPressed: onCopy,
    ),
  );
}
