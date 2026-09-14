import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/services/multi_window/player_window_identity.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _videoArguments({
  required VideoType videoType,
  required int aid,
  required String bvid,
  required int cid,
  int? epId,
  int? seasonId,
  int? pgcType,
  Object? sourceType,
  int? progress,
  int? progressAid,
  String? progressBvid,
  int? progressCid,
}) {
  return <String, dynamic>{
    'videoType': videoType,
    'aid': aid,
    'bvid': bvid,
    'cid': cid,
    'epId': epId,
    'seasonId': seasonId,
    'pgcType': pgcType,
    'sourceType': sourceType,
    'progress': progress,
    'progressAid': progressAid,
    'progressBvid': progressBvid,
    'progressCid': progressCid,
  };
}

void main() {
  group('PlayerWindowIdentity.shouldSkipVideoNavigation', () {
    test(
      'uses the live target after autoplay instead of the initial route',
      () {
        final routeA = _videoArguments(
          videoType: VideoType.ugc,
          aid: 1,
          bvid: 'BV1',
          cid: 101,
          sourceType: 'watchLater',
        );
        final requestA = Map<String, dynamic>.from(routeA);
        final requestB = _videoArguments(
          videoType: VideoType.ugc,
          aid: 2,
          bvid: 'BV2',
          cid: 202,
          sourceType: 'watchLater',
        );

        expect(
          PlayerWindowIdentity.shouldSkipVideoNavigation(
            routeArguments: routeA,
            nextArguments: requestA,
            currentVideoType: VideoType.ugc,
            currentAid: 2,
            currentBvid: 'BV2',
            currentCid: 202,
          ),
          isFalse,
        );
        expect(
          PlayerWindowIdentity.shouldSkipVideoNavigation(
            routeArguments: routeA,
            nextArguments: requestB,
            currentVideoType: VideoType.ugc,
            currentAid: 2,
            currentBvid: 'BV2',
            currentCid: 202,
          ),
          isTrue,
        );
      },
    );

    test('uses the route target before the video controller is ready', () {
      final routeA = _videoArguments(
        videoType: VideoType.ugc,
        aid: 1,
        bvid: 'BV1',
        cid: 101,
        sourceType: 'watchLater',
      );

      expect(
        PlayerWindowIdentity.shouldSkipVideoNavigation(
          routeArguments: routeA,
          nextArguments: Map<String, dynamic>.from(routeA),
        ),
        isTrue,
      );
    });

    test('distinguishes UGC parts and PGC episodes', () {
      final ugcRoute = _videoArguments(
        videoType: VideoType.ugc,
        aid: 1,
        bvid: 'BV1',
        cid: 101,
      );
      final pgcRoute = _videoArguments(
        videoType: VideoType.pgc,
        aid: 2,
        bvid: 'BV2',
        cid: 202,
        epId: 20,
        seasonId: 2,
        pgcType: 1,
      );

      expect(
        PlayerWindowIdentity.shouldSkipVideoNavigation(
          routeArguments: ugcRoute,
          nextArguments: _videoArguments(
            videoType: VideoType.ugc,
            aid: 1,
            bvid: 'BV1',
            cid: 102,
          ),
          currentVideoType: VideoType.ugc,
          currentAid: 1,
          currentBvid: 'BV1',
          currentCid: 101,
        ),
        isFalse,
      );
      expect(
        PlayerWindowIdentity.shouldSkipVideoNavigation(
          routeArguments: pgcRoute,
          nextArguments: _videoArguments(
            videoType: VideoType.pgc,
            aid: 2,
            bvid: 'BV2',
            cid: 202,
            epId: 21,
            seasonId: 2,
            pgcType: 1,
          ),
          currentVideoType: VideoType.pgc,
          currentAid: 2,
          currentBvid: 'BV2',
          currentCid: 202,
          currentEpId: 20,
        ),
        isFalse,
      );
    });

    test('preserves source and explicit progress navigation semantics', () {
      final route = _videoArguments(
        videoType: VideoType.ugc,
        aid: 1,
        bvid: 'BV1',
        cid: 101,
        sourceType: 'watchLater',
      );

      expect(
        PlayerWindowIdentity.shouldSkipVideoNavigation(
          routeArguments: route,
          nextArguments: _videoArguments(
            videoType: VideoType.ugc,
            aid: 1,
            bvid: 'BV1',
            cid: 101,
            sourceType: 'favorite',
          ),
          currentVideoType: VideoType.ugc,
          currentAid: 1,
          currentBvid: 'BV1',
          currentCid: 101,
        ),
        isFalse,
      );
      expect(
        PlayerWindowIdentity.shouldSkipVideoNavigation(
          routeArguments: route,
          nextArguments: _videoArguments(
            videoType: VideoType.ugc,
            aid: 1,
            bvid: 'BV1',
            cid: 101,
            sourceType: 'watchLater',
            progress: 1000,
            progressAid: 1,
            progressBvid: 'BV1',
            progressCid: 101,
          ),
          currentVideoType: VideoType.ugc,
          currentAid: 1,
          currentBvid: 'BV1',
          currentCid: 101,
        ),
        isFalse,
      );
    });
  });
}
