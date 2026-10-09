// apps/desktop/lib/ui/app_nav.dart
import 'package:flutter/material.dart';

/// App-wide navigation state for the title bar's Back button: pops a pushed
/// page (viewer…) first, otherwise returns to the previously visited section.
class AppNav extends ChangeNotifier {
  AppNav._();

  static final AppNav instance = AppNav._();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver observer = _Observer(this);

  int _routes = 0;
  final List<int> _tabs = [];
  int tab = 0;

  bool get canGoBack => _routes > 1 || _tabs.isNotEmpty;

  /// A page (viewer…) is open on top of the main screen.
  bool get hasPage => _routes > 1;

  /// Switch section and remember where we came from.
  void selectTab(int i) {
    if (i == tab) return;
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
    if (route is PageRoute) nav._routeCount(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) nav._routeCount(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) nav._routeCount(-1);
  }
}
