import 'package:flutter/widgets.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_navigation/src/routes/default_route.dart'
    show GetPageRoute;

final routeObserver = RouteObserver<GetPageRoute>();

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  @override
  void initState() {
    super.initState();
    final route = Get.routing.route;
    if (route is GetPageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }
}
