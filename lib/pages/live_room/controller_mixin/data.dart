part of 'package:PiliPlus/pages/live_room/controller.dart';

mixin _LiveDataMixin on GetxController {
  final isLoaded = false.obs;

  int? ruid;
  int get roomId;
  BuildContext get pageContext;
  bool get isPlaybackPageActive;
  int get mid => Accounts.main.mid;
  bool get isMainLogin => Accounts.main.isLogin;
  Account get heartbeat => Accounts.heartbeat;
  bool get isHeartbeatLogin => heartbeat.isLogin;

  DanmakuController<DanmakuExtra>? danmakuController;
  PlPlayerController get plPlayerController;

  late final RxBool isPortrait = false.obs;
  late final roomInfoH5 = Rxn<RoomInfoH5Data>();
  late List<LiveQuality> acceptQnList = [];
  late final Rxn<LiveQuality> currentQn = Rxn<LiveQuality>(
    PlatformUtils.isMobile || Platform.isLinux
        ? null
        : .fromCode(Pref.liveQuality),
  );

  bool? isPlaying;
  String? videoUrl;
  late bool isFullScreen = false;

  @override
  void onClose() {
    danmakuController = null;
    super.onClose();
  }
}
