import 'package:PiliPlus/services/multi_window/player_window_navigation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get_navigation/src/routes/default_route.dart'
    show GetPageRoute;

final routeObserver = RouteObserver<GetPageRoute>();

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  PageRoute<dynamic>? _routeAwareRoute;
  RouteObserver<PageRoute<dynamic>>? _observer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _routeAwareRoute) {
      _observer?.unsubscribe(this);
      final observer = route is GetPageRoute
          ? routeObserver
          : PlayerWindowNavigation.maybeOf(context)?.observer;
      _observer = observer;
      observer?.subscribe(this, route);
      _routeAwareRoute = route;
    }
  }

  @override
  void dispose() {
    _observer?.unsubscribe(this);
    _observer = null;
    _routeAwareRoute = null;
    super.dispose();
  }
}
