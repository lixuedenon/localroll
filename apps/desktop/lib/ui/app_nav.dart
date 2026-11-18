// apps/desktop/lib/ui/app_nav.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localroll_core/localroll_core.dart';

import '../services/win_screen.dart';

/// App-wide navigation state for the title bar's Back button. The sections
/// are always one click away in the left rail, so Back only closes pages
/// opened on top (viewer, tool…): one at a time; "Main screen" closes all.
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

  /// The library showing one person's / device's photos (from Devices).
  final ValueNotifier<String?> libraryMember = ValueNotifier(null);

  void openLibraryMember(String member) {
    libraryMember.value = member;
    selectTab(library);
  }

  void openDevice(String id) {
    deviceFocus.value = id;
    selectTab(devices);
  }

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer = _Observer(this);

  /// When the user last went somewhere else (another section, a page or a
  /// dialog opening). Told after the frame, with the moment it happened.
  final ValueNotifier<DateTime?> wentElsewhere = ValueNotifier(null);

  void _wentElsewhere() {
    final at = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => wentElsewhere.value = at);
  }

  int _routes = 0;
  int tab = 0;

  /// A page is open (the main screen with the rail has no Back).
  bool get canGoBack => _routes > 1;

  /// A page (viewer…) is open on top of the main screen.
  bool get hasPage => _routes > 1;

  /// Two or more pages are open (PDF tool → change words): "Main screen"
  /// closes them all at once.
  bool get deep => _routes > 2;

  /// Switch section.
  static const List<String> _names = ['home', 'devices', 'library', 'player', 'screen', 'convert', 'settings'];

  void selectTab(int i) {
    if (i == tab) return;
    DiagLog.log('ui', 'section: ${i >= 0 && i < _names.length ? _names[i] : i}');
    tab = i;
    notifyListeners();
    _wentElsewhere();
  }

  /// Start-up section.
  void initialTab(int i) {
    tab = i;
  }

  /// Closes the page on top (a page with unsaved work asks first).
  void back() {
    final nav = navigatorKey.currentState;
    if (_routes > 1 && nav != null) nav.maybePop();
  }

  /// Closes every page, top first, back to the main screen. A page with
  /// unsaved work asks first, and the closing stops there.
  Future<void> toMain() async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    DiagLog.log('ui', 'to main screen');
    while (_routes > 1) {
      final before = _routes;
      await nav.maybePop();
      if (_routes >= before) return;
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
    nav._wentElsewhere();
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
