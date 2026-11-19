// Flutter 3.50.0 windowing is opt-in through internal SDK APIs.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' show AllocatorAlloc, Pointer, StructPointer, Void;
import 'dart:io';
import 'dart:ui' show FlutterView, PlatformDispatcher;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart' as flutter_features;
import 'package:flutter/src/widgets/_window.dart' as flutter_window;
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart' as win32;

const _runner = MethodChannel('window_control');
const _timeout = Duration(seconds: 5);

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('This smoke test requires Windows.');
    exit(1);
  }

  flutter_features.isWindowingEnabled = true;
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final frameworkErrors = <FlutterErrorDetails>[];
  FlutterError.onError = (error) {
    frameworkErrors.add(error);
    FlutterError.presentError(error);
  };
  try {
    await _checkWindows(binding).timeout(const Duration(seconds: 45));
    _require(frameworkErrors.isEmpty, 'Flutter reported a framework error');
    stdout.writeln('NATIVE_WINDOW_SMOKE PASSED');
    await stdout.flush();
    final view = binding.platformDispatcher.implicitView!;
    _postClose((await _windowHandle(view.viewId))!);
  } catch (error, stackTrace) {
    stderr.writeln('NATIVE_WINDOW_SMOKE FAILED: $error\n$stackTrace');
    exit(1);
  }
}

Future<void> _checkWindows(WidgetsBinding binding) async {
  final dispatcher = binding.platformDispatcher;
  final mainView = dispatcher.implicitView!;
  _require(dispatcher.views.single == mainView, 'expected one implicit view');
  final mainHandle = (await _windowHandle(mainView.viewId))!;
  final secondWindow = ValueNotifier<flutter_window.WindowController?>(null);
  FlutterView? mountedSecondView;
  var mainBuilds = 0;
  runApp(
    ValueListenableBuilder(
      valueListenable: secondWindow,
      builder: (context, controller, _) {
        _require(View.of(context) == mainView, 'main tree changed views');
        mainBuilds++;
        return ViewAnchor(
          view: controller == null
              ? null
              : flutter_window.Window(
                  controller: controller,
                  child: Builder(
                    builder: (context) {
                      mountedSecondView = View.of(context);
                      return const ColoredBox(color: Color(0xff345b70));
                    },
                  ),
                ),
          child: const ColoredBox(color: Color(0xffd8e0e6)),
        );
      },
    ),
  );
  await binding.endOfFrame;
  win32.ShowWindow(mainHandle, win32.SW_SHOW);
  win32.SetForegroundWindow(mainHandle);
  await _waitFor(
    () => win32.GetForegroundWindow() == mainHandle,
    'implicit window activation',
  );

  for (var attempt = 0; attempt < 2; attempt++) {
    final delegate = _CloseDelegate();
    final window = flutter_window.WindowController(
      size: const Size(640, 400),
      title: 'PiliPlus native window smoke',
      delegate: delegate,
    );
    final view = window.rootView;
    final hwnd = (await _windowHandle(view.viewId))!;
    _require(hwnd != mainHandle && win32.IsWindow(hwnd), 'invalid child HWND');
    _require(dispatcher.views.length == 2, 'expected exactly two views');

    secondWindow.value = window;
    await binding.endOfFrame;
    _require(mountedSecondView == view, 'child tree rendered into wrong view');
    window.activate();
    win32.SetForegroundWindow(hwnd);
    await _waitFor(
      () => window.isActivated && win32.GetForegroundWindow() == hwnd,
      'playback window activation',
    );

    if (attempt == 0) {
      await _checkFullscreen(window, hwnd, mainView);
    }

    _postClose(hwnd);
    await delegate.requested.future.timeout(_timeout);
    _require(win32.IsWindow(hwnd), 'window destroyed before its delegate');
    final buildsBeforeClose = mainBuilds;
    secondWindow.value = null;
    await binding.endOfFrame;
    await Future<void>.delayed(Duration.zero);
    window.destroy();
    await _waitFor(
      () => dispatcher.views.length == 1 && !win32.IsWindow(hwnd),
      'playback view and HWND removal',
    );
    window.dispose();
    _require(await _windowHandle(view.viewId) == null, 'retired view resolved');
    _require(
      dispatcher.views.single == mainView &&
          win32.IsWindow(mainHandle) &&
          mainBuilds > buildsBeforeClose,
      'main view stopped rendering after closing playback',
    );
    win32.SetForegroundWindow(mainHandle);
    await _waitFor(
      () => win32.GetForegroundWindow() == mainHandle,
      'main window activation after closing playback',
    );
    stdout.writeln('Native open/close cycle ${attempt + 1} passed');
  }
}

Future<void> _checkFullscreen(
  flutter_window.WindowController window,
  win32.HWND hwnd,
  FlutterView mainView,
) async {
  final view = window.rootView;
  final mainSize = mainView.physicalSize;
  const resized = Size(720, 440);
  window.setSize(resized);
  await _waitFor(
    () => view.physicalSize == resized * view.devicePixelRatio,
    'logical resize at current DPI',
  );
  final initialDisplay = view.display;
  final initialDpi = win32.GetDpiForWindow(hwnd);
  _require(initialDpi / 96 == view.devicePixelRatio, 'native DPI disagrees');
  final otherDisplay = PlatformDispatcher.instance.displays
      .where((display) => display.devicePixelRatio != view.devicePixelRatio)
      .firstOrNull;
  final targetDisplay = otherDisplay ?? initialDisplay;
  window.setFullscreen(true, display: targetDisplay);
  await _waitFor(
    () =>
        window.isFullscreen &&
        view.physicalSize == targetDisplay.size &&
        view.display.id == targetDisplay.id &&
        _clientSize(hwnd) == targetDisplay.size,
    'native fullscreen size and display',
  );
  final fullscreenDpi = win32.GetDpiForWindow(hwnd);
  _require(
    fullscreenDpi / 96 == targetDisplay.devicePixelRatio &&
        view.devicePixelRatio == targetDisplay.devicePixelRatio,
    'fullscreen window DPI disagrees with display',
  );
  _require(mainView.physicalSize == mainSize, 'fullscreen resized main window');
  stdout.writeln(
    'Fullscreen display ${targetDisplay.size}, '
    'native DPI $initialDpi -> $fullscreenDpi',
  );
  if (otherDisplay == null) {
    stdout.writeln('Mixed-DPI test skipped: no display has a different DPI');
  }
  window.setFullscreen(false);
  await _waitFor(
    () => !window.isFullscreen && view.physicalSize != targetDisplay.size,
    'exit fullscreen',
  );
}

Future<win32.HWND?> _windowHandle(int viewId) async {
  final address = await _runner.invokeMethod<int>('getWindowHandle', viewId);
  return address == null
      ? null
      : win32.HWND(Pointer<Void>.fromAddress(address));
}

Size _clientSize(win32.HWND hwnd) => using((arena) {
  final rect = arena<win32.RECT>();
  _require(win32.GetClientRect(hwnd, rect).value, 'GetClientRect failed');
  return Size(
    (rect.ref.right - rect.ref.left).toDouble(),
    (rect.ref.bottom - rect.ref.top).toDouble(),
  );
});

void _postClose(win32.HWND hwnd) {
  final posted = win32.PostMessage(
    hwnd,
    win32.WM_CLOSE,
    const win32.WPARAM(0),
    const win32.LPARAM(0),
  );
  _require(posted.value, 'posting WM_CLOSE failed with ${posted.error}');
}

Future<void> _waitFor(bool Function() ready, String operation) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    _require(timer.elapsed < _timeout, 'timed out waiting for $operation');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

final class _CloseDelegate with flutter_window.WindowControllerDelegate {
  final requested = Completer<void>();

  @override
  void onWindowCloseRequested(flutter_window.WindowController controller) {
    if (!requested.isCompleted) requested.complete();
  }
}
