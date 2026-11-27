import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:lux/util/window_surface.dart';

/// Semantic design tokens matching Lux's Option A macOS Liquid Glass (Porcelain
/// Light & Obsidian Dark) system, with automatic translucent vs. opaque
/// adjustments based on [WindowSurfaceTier].
@immutable
class LuxTokens extends ThemeExtension<LuxTokens> {
  final Color canvasOpaque;
  final Color canvasTranslucent;
  final Color sidebarOpaque;
  final Color sidebarTranslucent;
  final Color cardBg;
  final Color cardBgSelected;
  final Color hairline;
  final Color hairlineStrong;
  final Color specularRim;
  final Color subtlePillBg;
  final Color activeNavBg;
  final Color activeNavBorder;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color cobalt;
  final Color emerald;
  final Color teal;
  final Color amber;
  final Color danger;

  const LuxTokens({
    required this.canvasOpaque,
    required this.canvasTranslucent,
    required this.sidebarOpaque,
    required this.sidebarTranslucent,
    required this.cardBg,
    required this.cardBgSelected,
    required this.hairline,
    required this.hairlineStrong,
    required this.specularRim,
    required this.subtlePillBg,
    required this.activeNavBg,
    required this.activeNavBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.cobalt,
    required this.emerald,
    required this.teal,
    required this.amber,
    required this.danger,
  });

  static const light = LuxTokens(
    canvasOpaque: Color(0xFFF7F9FC),
    canvasTranslucent: Color(0xD8F8FAFD),
    sidebarOpaque: Color(0xFFF1F4F9),
    sidebarTranslucent: Color(0x66FFFFFF),
    cardBg: Color(0xF5FFFFFF),
    cardBgSelected: Color(0xFFF3F7FF),
    hairline: Color(0x160F172A),
    hairlineStrong: Color(0x240F172A),
    specularRim: Color(0xCCFFFFFF),
    subtlePillBg: Color(0x0D0F172A),
    activeNavBg: Color(0xB8FFFFFF),
    activeNavBorder: Color(0x180F172A),
    textPrimary: Color(0xFF1E293B),
    textSecondary: Color(0xFF526075),
    textMuted: Color(0xFF8A96A8),
    cobalt: Color(0xFF2563EB),
    emerald: Color(0xFF16A34A),
    teal: Color(0xFF0D9488),
    amber: Color(0xFFD98A16),
    danger: Color(0xFFDC4A38),
  );

  static const dark = LuxTokens(
    canvasOpaque: Color(0xFF0B0E14),
    canvasTranslucent: Color(0xC80B0E14),
    sidebarOpaque: Color(0xFF0F131B),
    sidebarTranslucent: Color(0x4D121722),
    cardBg: Color(0xE8141924),
    cardBgSelected: Color(0xFF172033),
    hairline: Color(0x17FFFFFF),
    hairlineStrong: Color(0x28FFFFFF),
    specularRim: Color(0x1FFFFFFF),
    subtlePillBg: Color(0x12FFFFFF),
    activeNavBg: Color(0x1AFFFFFF),
    activeNavBorder: Color(0x24FFFFFF),
    textPrimary: Color(0xFFE6ECF5),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF6B788E),
    cobalt: Color(0xFF4F8FF7),
    emerald: Color(0xFF34D399),
    teal: Color(0xFF2DD4BF),
    amber: Color(0xFFF5B041),
    danger: Color(0xFFEF6B5B),
  );

  Color canvasFor(WindowSurfaceTier tier) =>
      tier.isTranslucent ? canvasTranslucent : canvasOpaque;

  Color sidebarFor(WindowSurfaceTier tier) =>
      tier.isTranslucent ? sidebarTranslucent : sidebarOpaque;

  static LuxTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<LuxTokens>();
    if (ext != null) return ext;
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  @override
  LuxTokens copyWith({
    Color? canvasOpaque,
    Color? canvasTranslucent,
    Color? sidebarOpaque,
    Color? sidebarTranslucent,
    Color? cardBg,
    Color? cardBgSelected,
    Color? hairline,
    Color? hairlineStrong,
    Color? specularRim,
    Color? subtlePillBg,
    Color? activeNavBg,
    Color? activeNavBorder,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? cobalt,
    Color? emerald,
    Color? teal,
    Color? amber,
    Color? danger,
  }) =>
      LuxTokens(
        canvasOpaque: canvasOpaque ?? this.canvasOpaque,
        canvasTranslucent: canvasTranslucent ?? this.canvasTranslucent,
        sidebarOpaque: sidebarOpaque ?? this.sidebarOpaque,
        sidebarTranslucent: sidebarTranslucent ?? this.sidebarTranslucent,
        cardBg: cardBg ?? this.cardBg,
        cardBgSelected: cardBgSelected ?? this.cardBgSelected,
        hairline: hairline ?? this.hairline,
        hairlineStrong: hairlineStrong ?? this.hairlineStrong,
        specularRim: specularRim ?? this.specularRim,
        subtlePillBg: subtlePillBg ?? this.subtlePillBg,
        activeNavBg: activeNavBg ?? this.activeNavBg,
        activeNavBorder: activeNavBorder ?? this.activeNavBorder,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textMuted: textMuted ?? this.textMuted,
        cobalt: cobalt ?? this.cobalt,
        emerald: emerald ?? this.emerald,
        teal: teal ?? this.teal,
        amber: amber ?? this.amber,
        danger: danger ?? this.danger,
      );

  @override
  LuxTokens lerp(ThemeExtension<LuxTokens>? other, double t) {
    if (other is! LuxTokens) return this;
    return LuxTokens(
      canvasOpaque: Color.lerp(canvasOpaque, other.canvasOpaque, t)!,
      canvasTranslucent:
          Color.lerp(canvasTranslucent, other.canvasTranslucent, t)!,
      sidebarOpaque: Color.lerp(sidebarOpaque, other.sidebarOpaque, t)!,
      sidebarTranslucent:
          Color.lerp(sidebarTranslucent, other.sidebarTranslucent, t)!,
      cardBg: Color.lerp(cardBg, other.cardBg, t)!,
      cardBgSelected: Color.lerp(cardBgSelected, other.cardBgSelected, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hairlineStrong: Color.lerp(hairlineStrong, other.hairlineStrong, t)!,
      specularRim: Color.lerp(specularRim, other.specularRim, t)!,
      subtlePillBg: Color.lerp(subtlePillBg, other.subtlePillBg, t)!,
      activeNavBg: Color.lerp(activeNavBg, other.activeNavBg, t)!,
      activeNavBorder: Color.lerp(activeNavBorder, other.activeNavBorder, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      cobalt: Color.lerp(cobalt, other.cobalt, t)!,
      emerald: Color.lerp(emerald, other.emerald, t)!,
      teal: Color.lerp(teal, other.teal, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// Shared tabular-numerals monospace style for IPs, latencies, and live speeds.
TextStyle luxMonoStyle({
  double fontSize = 11.5,
  Color? color,
  FontWeight fontWeight = FontWeight.w400,
}) {
  return TextStyle(
    fontSize: fontSize,
    color: color,
    fontWeight: fontWeight,
    fontFamily: 'SF Mono',
    fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// The [AppTheme] defines Porcelain Light and Obsidian Dark themes for Lux.
abstract final class AppTheme {
  static TextTheme _refineTypography(TextTheme base, Color primaryText) {
    TextStyle? soften(TextStyle? s, {FontWeight? weight}) {
      if (s == null) return null;
      return s.copyWith(
        color: primaryText,
        fontWeight: weight ?? FontWeight.w400,
      );
    }

    return base.copyWith(
      titleLarge: soften(base.titleLarge, weight: FontWeight.w500),
      titleMedium: soften(base.titleMedium, weight: FontWeight.w500),
      titleSmall: soften(base.titleSmall, weight: FontWeight.w500),
      bodyLarge: soften(base.bodyLarge, weight: FontWeight.w400),
      bodyMedium: soften(base.bodyMedium, weight: FontWeight.w400),
      bodySmall: soften(base.bodySmall, weight: FontWeight.w400),
      labelLarge: soften(base.labelLarge, weight: FontWeight.w500),
      labelMedium: soften(base.labelMedium, weight: FontWeight.w400),
      labelSmall: soften(base.labelSmall, weight: FontWeight.w400),
    );
  }

  // Porcelain Light mode ThemeData.
  static ThemeData get light {
    final base = FlexThemeData.light(
      scheme: FlexScheme.shadBlue,
      swapLegacyOnMaterial3: true,
      lightIsWhite: true,
      bottomAppBarElevation: 0.0,
      subThemesData: const FlexSubThemesData(
        interactionEffects: true,
        blendOnLevel: 6,
        useM2StyleDividerInM3: true,
        splashType: FlexSplashType.instantSplash,
        splashTypeAdaptive: FlexSplashType.instantSplash,
        adaptiveElevationShadowsBack: FlexAdaptive.all(),
        adaptiveAppBarScrollUnderOff: FlexAdaptive.all(),
        defaultRadius: 8.0,
        elevatedButtonSchemeColor: SchemeColor.onPrimaryContainer,
        elevatedButtonSecondarySchemeColor: SchemeColor.primaryContainer,
        outlinedButtonSchemeColor: SchemeColor.onSurface,
        outlinedButtonOutlineSchemeColor: SchemeColor.outlineVariant,
        toggleButtonsBorderSchemeColor: SchemeColor.outlineVariant,
        segmentedButtonSchemeColor: SchemeColor.primary,
        segmentedButtonBorderSchemeColor: SchemeColor.outlineVariant,
        switchThumbSchemeColor: SchemeColor.onPrimaryContainer,
        switchAdaptiveCupertinoLike: FlexAdaptive.all(),
        unselectedToggleIsColored: true,
        sliderValueTinted: true,
        sliderTrackHeight: 6,
        inputDecoratorIsDense: true,
        inputDecoratorContentPadding:
            EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
        inputDecoratorBorderSchemeColor: SchemeColor.primary,
        inputDecoratorBorderType: FlexInputBorderType.outline,
        inputDecoratorRadius: 8.0,
        inputDecoratorBorderWidth: 0.75,
        inputDecoratorFocusedBorderWidth: 1.5,
        chipSchemeColor: SchemeColor.secondaryContainer,
        chipSelectedSchemeColor: SchemeColor.primaryContainer,
        chipFontSize: 11.5,
        chipIconSize: 15,
        chipPadding: EdgeInsetsDirectional.fromSTEB(4, 2, 4, 2),
        cardRadius: 12.0,
        cardElevation: 0.0,
        popupMenuRadius: 10.0,
        popupMenuElevation: 3.0,
        alignedDropdown: true,
        tooltipRadius: 6,
        tooltipSchemeColor: SchemeColor.surfaceContainerHigh,
        tooltipOpacity: 0.96,
        dialogBackgroundSchemeColor: SchemeColor.surfaceContainerLowest,
        dialogRadius: 14.0,
        snackBarRadius: 8,
        snackBarElevation: 4,
        snackBarBackgroundSchemeColor: SchemeColor.surfaceContainerLow,
        appBarBackgroundSchemeColor: SchemeColor.surfaceContainerLowest,
        appBarScrolledUnderElevation: 0.0,
        menuRadius: 10.0,
        menuElevation: 3.0,
        menuSchemeColor: SchemeColor.surfaceContainerLowest,
        menuPadding: EdgeInsetsDirectional.fromSTEB(6, 8, 6, 8),
        menuIndicatorBackgroundSchemeColor: SchemeColor.surfaceContainerHigh,
        menuIndicatorRadius: 6.0,
        scaffoldBackgroundSchemeColor: SchemeColor.surfaceContainerHighest,
        cardBackgroundSchemeColor: SchemeColor.white,
      ),
      keyColors: const FlexKeyColors(
        useSecondary: true,
        useTertiary: true,
        useError: true,
        keepPrimary: true,
        keepSecondary: true,
        keepError: true,
        keepTertiaryContainer: true,
      ),
      tones: FlexSchemeVariant.chroma
          .tones(Brightness.light)
          .higherContrastFixed()
          .monochromeSurfaces(),
      visualDensity: FlexColorScheme.comfortablePlatformDensity,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      cupertinoOverrideTheme: const CupertinoThemeData(applyThemeToAll: true),
    );
    return base.copyWith(
      scaffoldBackgroundColor: LuxTokens.light.canvasOpaque,
      canvasColor: const Color(0xFFFFFFFF),
      dividerColor: LuxTokens.light.hairline,
      textTheme: _refineTypography(base.textTheme, LuxTokens.light.textPrimary),
      iconTheme: IconThemeData(color: LuxTokens.light.textSecondary, size: 18),
      cardTheme: CardThemeData(
        color: LuxTokens.light.cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: LuxTokens.light.hairline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFFFFFFFF),
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shadowColor: const Color(0x2E0F172A),
        barrierColor: const Color(0x470F172A),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: LuxTokens.light.hairlineStrong, width: 1),
        ),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: LuxTokens.light.textPrimary,
        ),
        contentTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: LuxTokens.light.textSecondary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        labelStyle: TextStyle(fontSize: 12.5, color: LuxTokens.light.textSecondary),
        floatingLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: LuxTokens.light.cobalt,
        ),
        hintStyle: TextStyle(fontSize: 12.5, color: LuxTokens.light.textMuted),
        helperStyle: TextStyle(fontSize: 11, color: LuxTokens.light.textMuted),
        errorStyle: TextStyle(fontSize: 11, color: LuxTokens.light.danger),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.light.hairlineStrong, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.light.hairlineStrong, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.light.cobalt, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.light.danger, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.light.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return LuxTokens.light.subtlePillBg;
            }
            return LuxTokens.light.cobalt;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return LuxTokens.light.textMuted;
            }
            return Colors.white;
          }),
          elevation: const WidgetStatePropertyAll(0),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(LuxTokens.light.textSecondary),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(LuxTokens.light.textPrimary),
          side: WidgetStatePropertyAll(
            BorderSide(color: LuxTokens.light.hairlineStrong),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFFFFFFFF),
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: LuxTokens.light.hairlineStrong),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LuxTokens.light.cobalt;
          }
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: LuxTokens.light.hairlineStrong, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        backgroundColor: const Color(0xF21E293B),
        contentTextStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: Color(0xFFF8FAFC),
        ),
        actionTextColor: const Color(0xFF93C5FD),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        dismissDirection: DismissDirection.horizontal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: LuxTokens.light.hairlineStrong, width: 0.75),
        ),
      ),
      extensions: const <ThemeExtension<dynamic>>[LuxTokens.light],
    );
  }

  // Obsidian Dark mode ThemeData.
  static ThemeData get dark {
    final base = FlexThemeData.dark(
      scheme: FlexScheme.shadBlue,
      swapLegacyOnMaterial3: true,
      bottomAppBarElevation: 0.0,
      subThemesData: const FlexSubThemesData(
        interactionEffects: true,
        blendOnLevel: 14,
        blendOnColors: true,
        useM2StyleDividerInM3: true,
        splashType: FlexSplashType.instantSplash,
        splashTypeAdaptive: FlexSplashType.instantSplash,
        adaptiveElevationShadowsBack: FlexAdaptive.all(),
        adaptiveAppBarScrollUnderOff: FlexAdaptive.all(),
        defaultRadius: 8.0,
        elevatedButtonSchemeColor: SchemeColor.onPrimaryContainer,
        elevatedButtonSecondarySchemeColor: SchemeColor.primaryContainer,
        outlinedButtonSchemeColor: SchemeColor.onSurface,
        outlinedButtonOutlineSchemeColor: SchemeColor.outlineVariant,
        toggleButtonsBorderSchemeColor: SchemeColor.outlineVariant,
        segmentedButtonSchemeColor: SchemeColor.primary,
        segmentedButtonBorderSchemeColor: SchemeColor.outlineVariant,
        switchThumbSchemeColor: SchemeColor.onPrimaryContainer,
        switchAdaptiveCupertinoLike: FlexAdaptive.all(),
        unselectedToggleIsColored: true,
        sliderValueTinted: true,
        sliderTrackHeight: 6,
        inputDecoratorIsDense: true,
        inputDecoratorContentPadding:
            EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
        inputDecoratorBorderSchemeColor: SchemeColor.primary,
        inputDecoratorBorderType: FlexInputBorderType.outline,
        inputDecoratorRadius: 8.0,
        inputDecoratorBorderWidth: 0.75,
        inputDecoratorFocusedBorderWidth: 1.5,
        chipSchemeColor: SchemeColor.secondaryContainer,
        chipSelectedSchemeColor: SchemeColor.primaryContainer,
        chipFontSize: 11.5,
        chipIconSize: 15,
        chipPadding: EdgeInsetsDirectional.fromSTEB(4, 2, 4, 2),
        cardRadius: 12.0,
        cardElevation: 0.0,
        popupMenuRadius: 10.0,
        popupMenuElevation: 4.0,
        alignedDropdown: true,
        tooltipRadius: 6,
        tooltipSchemeColor: SchemeColor.surfaceContainerHigh,
        tooltipOpacity: 0.96,
        dialogBackgroundSchemeColor: SchemeColor.surfaceContainerHigh,
        dialogRadius: 14.0,
        snackBarRadius: 8,
        snackBarElevation: 4,
        snackBarBackgroundSchemeColor: SchemeColor.surfaceContainerLow,
        appBarBackgroundSchemeColor: SchemeColor.surfaceContainerLowest,
        appBarScrolledUnderElevation: 0.0,
        menuRadius: 10.0,
        menuElevation: 4.0,
        menuSchemeColor: SchemeColor.surfaceContainerHigh,
        menuPadding: EdgeInsetsDirectional.fromSTEB(6, 8, 6, 8),
        menuIndicatorBackgroundSchemeColor: SchemeColor.surfaceContainerHighest,
        menuIndicatorRadius: 6.0,
      ),
      keyColors: const FlexKeyColors(
        useSecondary: true,
        useTertiary: true,
        useError: true,
        keepPrimary: true,
        keepSecondary: true,
        keepError: true,
        keepTertiaryContainer: true,
      ),
      tones: FlexSchemeVariant.chroma
          .tones(Brightness.dark)
          .higherContrastFixed()
          .monochromeSurfaces(),
      visualDensity: FlexColorScheme.comfortablePlatformDensity,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      cupertinoOverrideTheme: const CupertinoThemeData(applyThemeToAll: true),
    );
    return base.copyWith(
      scaffoldBackgroundColor: LuxTokens.dark.canvasOpaque,
      canvasColor: const Color(0xFF141A26),
      dividerColor: LuxTokens.dark.hairline,
      colorScheme: base.colorScheme.copyWith(
        surface: LuxTokens.dark.canvasOpaque,
        surfaceContainerLowest: LuxTokens.dark.sidebarOpaque,
        surfaceContainerLow: LuxTokens.dark.cardBg,
        surfaceContainer: LuxTokens.dark.cardBg,
        surfaceContainerHigh: const Color(0xFF141A26),
        primary: LuxTokens.dark.cobalt,
        onPrimary: Colors.white,
        onSurface: LuxTokens.dark.textPrimary,
        onSurfaceVariant: LuxTokens.dark.textSecondary,
        outlineVariant: LuxTokens.dark.hairlineStrong,
      ),
      textTheme: _refineTypography(base.textTheme, LuxTokens.dark.textPrimary),
      iconTheme: IconThemeData(color: LuxTokens.dark.textSecondary, size: 18),
      cardTheme: CardThemeData(
        color: LuxTokens.dark.cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: LuxTokens.dark.hairline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF141A26),
        surfaceTintColor: Colors.transparent,
        elevation: 18,
        shadowColor: const Color(0xA6000000),
        barrierColor: const Color(0x9905070B),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: LuxTokens.dark.hairlineStrong, width: 1),
        ),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: LuxTokens.dark.textPrimary,
        ),
        contentTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: LuxTokens.dark.textSecondary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0D111A),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        labelStyle: TextStyle(fontSize: 12.5, color: LuxTokens.dark.textSecondary),
        floatingLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: LuxTokens.dark.cobalt,
        ),
        hintStyle: TextStyle(fontSize: 12.5, color: LuxTokens.dark.textMuted),
        helperStyle: TextStyle(fontSize: 11, color: LuxTokens.dark.textMuted),
        errorStyle: TextStyle(fontSize: 11, color: LuxTokens.dark.danger),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.dark.hairlineStrong, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.dark.hairlineStrong, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.dark.cobalt, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.dark.danger, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: LuxTokens.dark.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return LuxTokens.dark.subtlePillBg;
            }
            return LuxTokens.dark.cobalt;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return LuxTokens.dark.textMuted;
            }
            return Colors.white;
          }),
          elevation: const WidgetStatePropertyAll(0),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(LuxTokens.dark.textSecondary),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(LuxTokens.dark.textPrimary),
          side: WidgetStatePropertyAll(
            BorderSide(color: LuxTokens.dark.hairlineStrong),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF161D2B),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: LuxTokens.dark.hairlineStrong),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LuxTokens.dark.cobalt;
          }
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: LuxTokens.dark.hairlineStrong, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 3,
        backgroundColor: const Color(0xF51A2233),
        contentTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: LuxTokens.dark.textPrimary,
        ),
        actionTextColor: LuxTokens.dark.cobalt,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        dismissDirection: DismissDirection.horizontal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: LuxTokens.dark.hairlineStrong, width: 0.75),
        ),
      ),
      extensions: const <ThemeExtension<dynamic>>[LuxTokens.dark],
    );
  }
}
