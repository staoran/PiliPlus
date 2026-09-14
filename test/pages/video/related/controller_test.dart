import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:flutter_test/flutter_test.dart';

HotVideoItemModel _video(String bvid) => HotVideoItemModel.fromJson({
  'aid': 1,
  'cid': 1,
  'bvid': bvid,
  'title': bvid,
  'duration': 1,
  'owner': <String, dynamic>{},
  'stat': <String, dynamic>{},
});

void main() {
  group('RelatedController', () {
    test('does not request videos before a target BVID is provided', () async {
      int requestCount = 0;
      final controller = RelatedController(
        requestRelatedVideos: (String bvid) {
          requestCount++;
          return Future.value(const Success(<HotVideoItemModel>[]));
        },
      );

      await controller.queryData();

      expect(requestCount, 0);
    });

    test('ignores an old successful response after switching BVID', () async {
      final responseA = Completer<LoadingState<List<HotVideoItemModel>?>>();
      final responseB = Completer<LoadingState<List<HotVideoItemModel>?>>();
      final controller = RelatedController(
        requestRelatedVideos: (String bvid) => switch (bvid) {
          'BV-A' => responseA.future,
          'BV-B' => responseB.future,
          _ => Future.value(const Error('unexpected BVID')),
        },
      );

      final loadA = controller.loadForBvid('BV-A');
      final loadB = controller.loadForBvid('BV-B');
      responseB.complete(Success(<HotVideoItemModel>[_video('related-B')]));
      await loadB;
      responseA.complete(Success(<HotVideoItemModel>[_video('related-A')]));
      await loadA;

      final state = controller.loadingState.value;
      expect(state, isA<Success<List<HotVideoItemModel>?>>());
      expect(
        (state as Success<List<HotVideoItemModel>?>).response!.single.bvid,
        'related-B',
      );
    });

    test('ignores an old error response after switching BVID', () async {
      final responseA = Completer<LoadingState<List<HotVideoItemModel>?>>();
      final responseB = Completer<LoadingState<List<HotVideoItemModel>?>>();
      final controller = RelatedController(
        requestRelatedVideos: (String bvid) => switch (bvid) {
          'BV-A' => responseA.future,
          'BV-B' => responseB.future,
          _ => Future.value(const Error('unexpected BVID')),
        },
      );

      final loadA = controller.loadForBvid('BV-A');
      final loadB = controller.loadForBvid('BV-B');
      responseB.complete(Success(<HotVideoItemModel>[_video('related-B')]));
      await loadB;
      responseA.complete(const Error('request for A failed'));
      await loadA;

      final state = controller.loadingState.value;
      expect(state, isA<Success<List<HotVideoItemModel>?>>());
      expect(
        (state as Success<List<HotVideoItemModel>?>).response!.single.bvid,
        'related-B',
      );
    });
  });
}
