// apps/desktop/lib/ui/lr_dialog.dart
import 'dart:async';

import 'package:flutter/material.dart';

import 'light_look.dart';

/// Every dialog in Keepnear: the light look of the home page and library
/// (white, rounded, dark text), whichever page opens it.
Future<T?> showLrDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Future<Object?>? closeWhen,
}) {
  // [closeWhen]: closes THIS dialog when it completes — even with another
  // dialog or panel opened over it (Navigator.pop would close that one).
  Route<dynamic>? route;
  var due = false;
  final when = closeWhen;
  if (when != null) {
    unawaited(when.then((_) {}, onError: (Object _) {}).whenComplete(() {
      due = true;
      closeDialogRoute(route);
    }));
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor ?? const Color(0x661B2433),
    barrierLabel: barrierLabel,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: (c) {
      if (route == null) {
        route = ModalRoute.of(c);
        // Done before the dialog was even built: close it right away.
        if (due) WidgetsBinding.instance.addPostFrameCallback((_) => closeDialogRoute(route));
      }
      return Theme(data: lightDialogTheme(Theme.of(c)), child: Builder(builder: builder));
    },
  );
}

/// Closes [route] itself, wherever it is in the stack (not just the top one).
void closeDialogRoute(Route<dynamic>? route) {
  if (route == null || !route.isActive) return;
  final nav = route.navigator;
  if (nav == null) return;
  if (route.isCurrent) {
    nav.pop();
  } else {
    nav.removeRoute(route);
  }
}

/// The light theme for dialogs (fonts kept from [base]).
ThemeData lightDialogTheme(ThemeData base) {
  final t = LightLook.theme(base);
  const radius = BorderRadius.all(Radius.circular(20));
  return t.copyWith(
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Color(0x401F3B70),
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: Color(0xFFE3E8F2))),
      titleTextStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: LightLook.text, height: 1.35),
      contentTextStyle: TextStyle(fontSize: 14, height: 1.55, color: Color(0xFF4A566B)),
    ),
    textTheme: t.textTheme.apply(fontFamily: base.textTheme.bodyMedium?.fontFamily, fontFamilyFallback: base.textTheme.bodyMedium?.fontFamilyFallback),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LightLook.blue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LightLook.blue,
        side: const BorderSide(color: Color(0xFFC9D5EE)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: LightLook.blue)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF5F7FC),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDCE3F0))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDCE3F0))),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFFE6EBF3), space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(textColor: LightLook.text, iconColor: LightLook.muted),
  );
}
