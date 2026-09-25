import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

Widget _playerPage() => Material(
  child: MiniScaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => MiniScaffold.of(context).showBottomSheet(
            (_) => SizedBox(
              height: 220,
              child: MiniScaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      const Text('评论详情'),
                      TextButton(
                        onPressed: () =>
                            MiniScaffold.of(context).showBottomSheet(
                              (_) => const SizedBox(
                                height: 100,
                                child: Text('对话列表'),
                              ),
                            ),
                        child: const Text('展开对话'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          child: const Text('展开评论'),
        ),
      ),
    ),
  ),
);

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    GetMaterialApp(
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => const SizedBox()),
        GetPage(name: '/middle', page: () => const SizedBox()),
        GetPage(name: '/videoV', page: _playerPage),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openComments(WidgetTester tester) async {
  await tester.tap(find.text('展开评论'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('评论详情'), findsOneWidget);
}

Future<void> _closeComments(WidgetTester tester) async {
  Get.back();
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('评论详情'), findsNothing);
  expect(find.text('展开评论'), findsOneWidget);
}

void main() {
  tearDown(Get.reset);

  testWidgets(
    'opens comments on first use and after reusing the player route',
    (
      tester,
    ) async {
      await _pumpApp(tester);

      for (final video in ['first', 'next']) {
        Get.offAllNamed('/videoV', arguments: video);
        await tester.pumpAndSettle();
        expect(Get.arguments, video);

        await _openComments(tester);
        await _closeComments(tester);
        await _openComments(tester);
        await _closeComments(tester);
      }
    },
  );

  testWidgets('opens comments before and after returning from another page', (
    tester,
  ) async {
    await _pumpApp(tester);
    Get.toNamed('/videoV');
    await tester.pumpAndSettle();
    await _openComments(tester);
    await _closeComments(tester);

    // Publishing a reply pushes a route through the same Navigator.
    Get.key.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('发表评论')),
    );
    await tester.pumpAndSettle();
    Get.back();
    await tester.pumpAndSettle();
    await _openComments(tester);
    await _closeComments(tester);
  });

  testWidgets('keeps sheet history on its owner after removing a lower route', (
    tester,
  ) async {
    await _pumpApp(tester);
    Get.toNamed('/middle');
    await tester.pumpAndSettle();
    final middleRoute = Get.routing.route!;
    Get.toNamed('/videoV');
    await tester.pumpAndSettle();
    Get.key.currentState!.removeRoute(middleRoute);
    await tester.pumpAndSettle();

    await _openComments(tester);
    await _closeComments(tester);
  });

  testWidgets('back closes nested dialogue before the parent comment sheet', (
    tester,
  ) async {
    await _pumpApp(tester);
    Get.offAllNamed('/videoV');
    await tester.pumpAndSettle();
    await _openComments(tester);

    await tester.tap(find.text('展开对话'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('对话列表'), findsOneWidget);

    Get.back();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('对话列表'), findsNothing);
    expect(find.text('评论详情'), findsOneWidget);
    await _closeComments(tester);
  });

  testWidgets('rejects a missing owner route before starting an animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(builder: (_, _) => _playerPage()),
    );
    final scaffold = tester.state<MiniScaffoldState>(find.byType(MiniScaffold));
    expect(
      () => scaffold.showBottomSheet((_) => const SizedBox()),
      throwsA(
        isA<FlutterError>().having(
          (error) => error.message,
          'message',
          contains(
            'MiniScaffold.showBottomSheet requires an enclosing ModalRoute',
          ),
        ),
      ),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
