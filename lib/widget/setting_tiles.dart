import 'package:flutter/material.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/lux_icons.dart';

/// Reusable settings rows styled in Lux's Porcelain Light / Obsidian Dark
/// hairline card system.
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

Widget sectionHeader(BuildContext context, String title, {LuxGlyph? glyph}) {
  final tokens = LuxTokens.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 14, 4, 7),
    child: Row(
      children: [
        if (glyph != null) ...[
          LuxIcon(glyph, size: 13, color: tokens.textMuted),
          const SizedBox(width: 6),
        ],
        TText(
          title,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
            color: tokens.textSecondary,
          ),
        ),
      ],
    ),
  );
}

/// macOS System Settings style grouped hairline card wrapping a list of rows
/// separated by crisp 0.75px hairline dividers.
Widget settingCard(BuildContext context, List<Widget> children) {
  final tokens = LuxTokens.of(context);
  return Material(
    color: tokens.cardBg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
      side: BorderSide(color: tokens.hairline, width: 0.75),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            Container(
              height: 0.75,
              margin: const EdgeInsets.only(left: 14),
              color: tokens.hairline,
            ),
          children[i],
        ],
      ],
    ),
  );
}

Widget switchTile({
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  return Builder(builder: (context) {
    final tokens = LuxTokens.of(context);
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      title: TText(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: tokens.textPrimary,
        ),
      ),
      subtitle: TText(
        subtitle,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          color: tokens.textMuted,
        ),
      ),
      value: value,
      dense: true,
      onChanged: onChanged,
    );
  });
}

/// Inline segmented control row (e.g., Light | Dark | System or System | Mixed | TUN).
Widget segmentedTile<T>({
  required BuildContext context,
  required String title,
  required T value,
  required List<T> options,
  required String Function(T) label,
  required ValueChanged<T>? onChanged,
  String? subtitle,
}) {
  final tokens = LuxTokens.of(context);
  final safeValue = options.contains(value) ? value : options.first;

  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final stackVertically = constraints.maxWidth < 430;
        final control = Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: tokens.subtlePillBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.hairline, width: 0.75),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final opt in options)
                _SegmentedOption<T>(
                  label: label(opt),
                  selected: opt == safeValue,
                  enabled: onChanged != null,
                  onTap: () => onChanged?.call(opt),
                ),
            ],
          ),
        );

        final textCol = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TText(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                color: tokens.textPrimary,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              TText(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: tokens.textMuted,
                ),
              ),
            ],
          ],
        );

        if (stackVertically) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              textCol,
              const SizedBox(height: 8),
              control,
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: textCol),
            const SizedBox(width: 12),
            control,
          ],
        );
      },
    ),
  );
}

class _SegmentedOption<T> extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SegmentedOption({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: selected ? tokens.cardBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? tokens.hairlineStrong : Colors.transparent,
              width: 0.75,
            ),
          ),
          child: TText(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              color: selected ? tokens.textPrimary : tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

Widget dropdownTile<T>({
  required String title,
  required T value,
  required List<T> options,
  required String Function(T) label,
  required ValueChanged<T>? onChanged,
  String? subtitle,
}) {
  final safeValue = options.contains(value) ? value : options.first;
  return Builder(builder: (context) {
    final tokens = LuxTokens.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      title: TText(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: tokens.textPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : TText(
              subtitle,
              style: TextStyle(fontSize: 11, color: tokens.textMuted),
            ),
      trailing: Container(
        height: 29,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: tokens.subtlePillBg,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: tokens.hairline, width: 0.75),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: safeValue,
            isDense: true,
            icon: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: LuxIcon(LuxGlyph.chevronDown,
                  size: 12, color: tokens.textMuted),
            ),
            items: options
                .map((o) => DropdownMenuItem(
                      value: o,
                      child: TText(
                        label(o),
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.textPrimary,
                        ),
                      ),
                    ))
                .toList(),
            onChanged: onChanged == null
                ? null
                : (v) {
                    if (v != null) onChanged(v);
                  },
          ),
        ),
      ),
    );
  });
}

Widget numberTile({
  required String title,
  required int value,
  required ValueChanged<int>? onChanged,
  String? subtitle,
}) {
  return Builder(builder: (context) {
    final tokens = LuxTokens.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      title: TText(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: tokens.textPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : TText(
              subtitle,
              style: TextStyle(fontSize: 11, color: tokens.textMuted),
            ),
      trailing: SizedBox(
        width: 86,
        height: 30,
        child: TextFormField(
          key: ValueKey('num-$title-$value'),
          initialValue: value.toString(),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.end,
          enabled: onChanged != null,
          style: luxMonoStyle(fontSize: 12, color: tokens.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: tokens.subtlePillBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: tokens.hairline, width: 0.75),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: tokens.cobalt, width: 1.0),
            ),
          ),
          onFieldSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && onChanged != null) onChanged(n);
          },
        ),
      ),
    );
  });
}

Widget textFieldTile({
  required String title,
  required String value,
  required String hint,
  required ValueChanged<String>? onChanged,
  String? subtitle,
  bool obscure = false,
}) {
  return Builder(builder: (context) {
    final tokens = LuxTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TText(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: tokens.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            TText(
              subtitle,
              style: TextStyle(fontSize: 11, color: tokens.textMuted),
            ),
          ],
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: TextFormField(
              key: ValueKey('txt-$title-$value'),
              initialValue: value,
              obscureText: obscure,
              enabled: onChanged != null,
              style: luxMonoStyle(fontSize: 11.5, color: tokens.textPrimary),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: 11.5, color: tokens.textMuted),
                isDense: true,
                filled: true,
                fillColor: tokens.subtlePillBg,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: tokens.hairline, width: 0.75),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide: BorderSide(color: tokens.cobalt, width: 1.0),
                ),
              ),
              onFieldSubmitted: onChanged,
            ),
          ),
        ],
      ),
    );
  });
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
  LuxGlyph? glyph,
}) {
  final tokens = LuxTokens.of(context);
  return ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    title: TText(
      title,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        color: tokens.textPrimary,
      ),
    ),
    subtitle: TText(
      subtitle,
      style: TextStyle(fontSize: 11, color: tokens.textMuted),
    ),
    trailing: busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: tokens.cobalt,
            ),
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.textPrimary,
              side: BorderSide(color: tokens.hairlineStrong, width: 0.75),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 29),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (glyph != null) ...[
                  LuxIcon(glyph, size: 12.5, color: tokens.textSecondary),
                  const SizedBox(width: 5),
                ] else if (icon != null) ...[
                  Icon(icon, size: 13.5, color: tokens.textSecondary),
                  const SizedBox(width: 5),
                ],
                TText(
                  buttonLabel,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
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
  final tokens = LuxTokens.of(context);
  return ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
    title: TText(
      title,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        color: tokens.textPrimary,
      ),
    ),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TText(subtitle, style: TextStyle(fontSize: 11, color: tokens.textMuted)),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: luxMonoStyle(fontSize: 11, color: tokens.textSecondary),
        ),
      ],
    ),
    trailing: Tooltip(
      message: copied ? tl(context, 'Copied') : tl(context, 'Copy'),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onCopy,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: tokens.subtlePillBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: tokens.hairline, width: 0.75),
          ),
          child: Center(
            child: LuxIcon(
              copied ? LuxGlyph.check : LuxGlyph.copy,
              size: 13,
              color: copied ? tokens.emerald : tokens.textSecondary,
            ),
          ),
        ),
      ),
    ),
  );
}
