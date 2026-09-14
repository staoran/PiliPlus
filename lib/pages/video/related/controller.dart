import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';

class RelatedController
    extends CommonListController<List<HotVideoItemModel>?, HotVideoItemModel> {
  RelatedController({
    Future<LoadingState<List<HotVideoItemModel>?>> Function(String bvid)?
    requestRelatedVideos,
  }) : _requestRelatedVideos =
           requestRelatedVideos ??
           ((String bvid) => VideoHttp.relatedVideoList(bvid: bvid));

  final Future<LoadingState<List<HotVideoItemModel>?>> Function(String bvid)
  _requestRelatedVideos;

  String? _bvid;
  int _requestGeneration = 0;

  String? get bvid => _bvid;

  Future<void> loadForBvid(String targetBvid) async {
    final int requestGeneration = ++_requestGeneration;
    _bvid = targetBvid;
    isLoading = true;
    loadingState.value = LoadingState<List<HotVideoItemModel>?>.loading();

    try {
      final res = await _requestRelatedVideos(targetBvid);
      if (_isCurrentRequest(requestGeneration, targetBvid)) {
        loadingState.value = res;
      }
    } finally {
      if (_isCurrentRequest(requestGeneration, targetBvid)) {
        isLoading = false;
      }
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    final String? targetBvid = _bvid;
    return targetBvid == null ? Future<void>.value() : loadForBvid(targetBvid);
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>?>> customGetData() {
    final String? targetBvid = _bvid;
    if (targetBvid == null) {
      return Future<LoadingState<List<HotVideoItemModel>?>>.value(
        const Error('缺少相关视频目标'),
      );
    }
    return _requestRelatedVideos(targetBvid);
  }

  bool _isCurrentRequest(int requestGeneration, String targetBvid) =>
      !isClosed &&
      requestGeneration == _requestGeneration &&
      targetBvid == _bvid;
}
