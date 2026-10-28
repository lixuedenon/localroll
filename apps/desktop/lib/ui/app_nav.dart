// apps/desktop/lib/ui/app_nav.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../services/win_screen.dart';

/// App-wide navigation state for the title bar's Back button: pops a pushed
/// page (viewer…) first, otherwise returns to the previously visited section.
class AppNav extends ChangeNotifier {
  AppNav._();

  static final AppNav instance = AppNav._();

  /// Main sections (left rail), in order.
  static const int home = 0;
  static const int devices = 1;
  static const int library = 2;
  static const int player = 3;
  static const int screen = 4;
  static const int convert = 5;
  static const int settings = 6;

  /// Receiving, sending and the family group all live on "Devices" now.
  static const int receive = devices;
  static const int send = devices;
  static const int family = devices;

  /// Something arrived that needs the person ("X wants to send files"):
  /// "Send and receive" in the rail and the taskbar button flash until it
  /// is answered.
  final ValueNotifier<int> attention = ValueNotifier(0);

  void needAttention(bool on) {
    attention.value = (attention.value + (on ? 1 : -1)).clamp(0, 99);
    if (Platform.isWindows) WinScreen.flashTaskbar(attention.value > 0);
  }

  /// The player is full screen: the title bar steps aside.
  final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  /// A device to show opened on the Devices page (set from Home etc.).
  final ValueNotifier<String?> deviceFocus = ValueNotifier(null);

  /// Go to Devices with [id] opened.
  /// The library, newest arrival first (from "See all" on Home): the
  /// library page switches its order when this goes up.
  final ValueNotifier<int> libraryRecent = ValueNotifier(0);

  bool _recentAsked = false;

  void openLibraryRecent() {
    _recentAsked = true;
    selectTab(library);
    libraryRecent.value++;
  }

  /// Asked for and not yet shown (the library page may be built only now).
  bool takeLibraryRecent() {
    final r = _recentAsked;
    _recentAsked = false;
    return r;
  }

  void openDevice(String id) {
    deviceFocus.value = id;
    selectTab(devices);
  }

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer = _Observer(this);

  int _routes = 0;
  final List<int> _tabs = [];
  int tab = 0;

  bool get canGoBack => _routes > 1 || _tabs.isNotEmpty;

  /// A page (viewer…) is open on top of the main screen.
  bool get hasPage => _routes > 1;

  /// Switch section and remember where we came from.
  static const List<String> _names = ['home', 'devices', 'library', 'player', 'screen', 'convert', 'settings'];

  void selectTab(int i) {
    if (i == tab) return;
    DiagLog.log('ui', 'section: ${i >= 0 && i < _names.length ? _names[i] : i}');
    _tabs.add(tab);
    if (_tabs.length > 30) _tabs.removeAt(0);
    tab = i;
    notifyListeners();
  }

  /// Start-up section, without history.
  void initialTab(int i) {
    tab = i;
    _tabs.clear();
  }

  void back() {
    final nav = navigatorKey.currentState;
    if (_routes > 1 && nav != null) {
      nav.maybePop();
      return;
    }
    if (_tabs.isNotEmpty) {
      tab = _tabs.removeLast();
      notifyListeners();
    }
  }

  void _routeCount(int delta) {
    _routes = (_routes + delta).clamp(0, 1 << 20);
    // Observers fire while the Navigator builds; repaint the title bar after.
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }
}

class _Observer extends NavigatorObserver {
  _Observer(this.nav);

  final AppNav nav;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DiagLog.log('ui', 'open ${_what(route)}');
    if (route is PageRoute) nav._routeCount(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DiagLog.log('ui', 'close ${_what(route)}');
    if (route is PageRoute) nav._routeCount(-1);
  }

  /// Page, dialog or menu (for the log; no content).
  static String _what(Route<dynamic> route) =>
      route.settings.name ?? (route is PageRoute ? 'page' : route.runtimeType.toString().replaceAll('_', ''));

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) nav._routeCount(-1);
  }
}
