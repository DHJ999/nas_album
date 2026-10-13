/// App 视觉规范 —— 全部样式收口于此，页面不要散落硬编码颜色。
///
/// 视觉规范（色板与圆角）：
///   · 主色「主题蓝」 #2B7FFF（登录按钮 / 开关 / 选中态 / 聚合标记）
///   · 页面浅灰背景   #F5F6FA，卡片纯白无边框
///   · 输入框浅灰填充 #F2F3F7、无描边、圆角 12（聚焦时蓝描边）
///   · 按钮蓝色胶囊（StadiumBorder）
///   · 顶栏白底、无阴影、标题居中 17 w600
///   · 底部导航白底，选中态淡蓝胶囊指示 + 加粗标签
///   · 卡片圆角 14、缩略图圆角 10
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 品牌色板
class FnosColors {
  static const primary = Color(0xFF2B7FFF); // 主题蓝
  static const bg = Color(0xFFF5F6FA); // 页面浅灰背景
  static const card = Colors.white; // 卡片
  static const field = Color(0xFFF2F3F7); // 输入框填充
  static const textMain = Color(0xFF1A1A1A); // 主文字
  static const textSub = Color(0xFF9A9FA8); // 次要文字
  static const line = Color(0xFFEFEFF2); // 分隔线
  static const danger = Color(0xFFFA5151); // 危险操作
}

/// 统一圆角
class FnosRadius {
  static const card = 14.0;
  static const thumb = 10.0;
  static const field = 12.0;
}

/// 应用主题（亮色，fnOS风格）
ThemeData buildFnosTheme() {
  final cs = ColorScheme.fromSeed(
    seedColor: FnosColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: FnosColors.primary,
    surface: Colors.white,
    error: FnosColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: cs,
    scaffoldBackgroundColor: FnosColors.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0.6,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      iconTheme: IconThemeData(color: FnosColors.textMain),
      titleTextStyle: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: FnosColors.textMain),
    ),
    cardTheme: CardThemeData(
      color: FnosColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FnosRadius.card)),
    ),
    dividerTheme: const DividerThemeData(
        color: FnosColors.line, thickness: 0.6, space: 0.6),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FnosColors.field,
      hintStyle: const TextStyle(color: FnosColors.textSub, fontSize: 15),
      labelStyle: const TextStyle(color: FnosColors.textSub, fontSize: 15),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FnosRadius.field),
          borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FnosRadius.field),
          borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FnosRadius.field),
          borderSide:
              const BorderSide(color: FnosColors.primary, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: FnosColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: const StadiumBorder(),
        textStyle:
            const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: FnosColors.primary),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 0,
      height: 66,
      indicatorColor: const Color(0x142B7FFF), // 8% 主题蓝
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? FnosColors.textMain
              : FnosColors.textSub)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 11.5,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: s.contains(WidgetState.selected)
              ? FnosColors.textMain
              : FnosColors.textSub)),
    ),
    listTileTheme: const ListTileThemeData(iconColor: FnosColors.textMain),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: FnosColors.primary),
  );
}

/// 深色主题（跟随系统时兜底，同样以主题蓝为种子）
ThemeData buildFnosDarkTheme() {
  final cs = ColorScheme.fromSeed(
    seedColor: FnosColors.primary,
    brightness: Brightness.dark,
  ).copyWith(primary: FnosColors.primary);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: cs,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0.6,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
  );
}

/// fnOS风格的页面大标题（左对齐，用于首页一级 tab）。
/// 直接继承 AppBar，可安全用于 Scaffold.appBar。
class FnosLargeTitle extends AppBar {
  FnosLargeTitle(
      {super.key, required String text, super.actions})
      : super(
          centerTitle: false,
          automaticallyImplyLeading: false,
          title: Text(text,
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: FnosColors.textMain)),
        );
}
