part of 'package:PiliPlus/pages/live_room/controller.dart';

mixin _LiveLikeMixin on GetxController, _LiveDataMixin {
  Timer? _likeClickTimer;
  final RxInt likeClickTime = 0.obs;

  void _stopLiveLikeTimer() {
    _likeClickTimer?.cancel();
    _likeClickTimer = null;
  }

  void onLikeTapDown(_) {
    _stopLiveLikeTimer();
    likeClickTime.value++;
  }

  void onLikeTapUp([_]) {
    _likeClickTimer ??= Timer(const Duration(milliseconds: 800), onLike);
  }

  Future<void> onLike() async {
    if (!isPlaybackPageActive || !isMainLogin) {
      likeClickTime.value = 0;
      return;
    }
    final target = roomId;
    final account = heartbeat;
    final res = await LiveHttp.liveLikeReport(
      clickTime: likeClickTime.value,
      roomId: target,
      uid: mid,
      anchorId: roomInfoH5.value?.roomInfo?.uid,
    );
    likeClickTime.value = 0;
    if (!isPlaybackPageActive ||
        !pageContext.mounted ||
        roomId != target ||
        !identical(account, heartbeat)) {
      return;
    }
    PlayerWindowNavigation.showToast(
      pageContext,
      res.isSuccess ? '点赞成功' : res.toString(),
    );
  }

  @override
  void onClose() {
    _stopLiveLikeTimer();
    super.onClose();
  }
}
