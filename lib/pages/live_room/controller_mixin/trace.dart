part of 'package:PiliPlus/pages/live_room/controller.dart';

mixin _LiveTraceMixin on GetxController, _LiveDataMixin {
  Timer? _liveTraceTimer;
  Account? _traceAccount;
  int _traceVersion = 0;
  LiveTraceReq? _liveTraceReq;
  LiveTraceResp? _liveTraceResp;
  int get _liveTraceInterval =>
      _liveTraceResp?.interval ?? LiveTraceResp.kInterval;

  Future<void> _initLiveTraceIfNeeded() async {
    if (!isPlaybackPageActive || !isLoaded.value || !heartbeat.isLogin) return;
    final account = heartbeat;
    final version = _traceVersion;
    final currentRoom = roomId;
    try {
      // id
      final ruid = this.ruid!;
      final roomInfo = roomInfoH5.rawValue?.roomInfo;
      if (roomInfo == null) {
        Utils.reportError('liveTrace: null roomInfo');
        return;
      }
      final parentAreaId = roomInfo.parentAreaId!;
      final areaId = roomInfo.areaId!;

      // liveBuvid
      final cookies = await account.cookieJar.loadForRequest(
        Uri.parse(HttpString.baseUrl),
      );
      final liveBuvid = cookies
          .firstWhereOrNull((cookie) => cookie.name == 'LIVE_BUVID')
          ?.value;
      if (!isPlaybackPageActive ||
          version != _traceVersion ||
          roomId != currentRoom ||
          !identical(account, heartbeat)) {
        return;
      }
      if (liveBuvid == null) {
        Utils.reportError('liveTrace: null liveBuvid');
        return;
      }

      _traceAccount = account;
      _liveTraceReq = LiveTraceReq(
        parentAreaId: parentAreaId,
        areaId: areaId,
        roomId: roomId,
        liveBuvid: liveBuvid,
        ruid: ruid,
      );
      _startLiveTraceTimer();
    } catch (_) {
      if (kDebugMode) rethrow;
    }
  }

  void _startLiveTraceTimer() {
    if (!isPlaybackPageActive || _liveTraceTimer != null) return;
    final previous = _liveTraceReq;
    if (previous == null || !identical(_traceAccount, heartbeat)) {
      return;
    }
    _liveTraceReq = LiveTraceReq(
      parentAreaId: previous.parentAreaId,
      areaId: previous.areaId,
      roomId: previous.roomId,
      liveBuvid: previous.liveBuvid,
      liveUuid: previous.liveUuid,
      ruid: previous.ruid,
    );
    _liveTraceResp = null;
    _liveTraceTimer = Timer(Duration.zero, _onLiveTrace);
  }

  void _stopLiveTraceTimer() {
    _traceVersion++;
    _liveTraceTimer?.cancel();
    _liveTraceTimer = null;
  }

  Future<void> _onLiveTrace([_]) async {
    final req = _liveTraceReq;
    final account = _traceAccount;
    final version = _traceVersion;
    if (req == null ||
        account == null ||
        !isPlaybackPageActive ||
        !identical(account, heartbeat)) {
      _stopLiveTraceTimer();
      return;
    }
    final res = req.seqId == 0
        ? await LiveHttp.liveTraceE(
            traceReq: req,
            heartbeat: account,
          )
        : await LiveHttp.liveTraceX(
            traceReq: req,
            traceResp: _liveTraceResp!,
            heartbeat: account,
          );
    if (!isPlaybackPageActive ||
        version != _traceVersion ||
        !identical(account, heartbeat)) {
      return;
    }
    if (res case Success(:final response)) {
      _liveTraceResp = response;
      _liveTraceTimer = Timer(
        Duration(seconds: _liveTraceInterval),
        _onLiveTrace,
      );
    } else {
      Utils.reportError('live trace error: $res');
      _stopLiveTraceTimer();
    }
  }
}
