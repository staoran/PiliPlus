import 'dart:collection';
import 'dart:io' show File;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class PlDanmakuController {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource,
  ) : _mergeDanmaku = _plPlayerController.mergeDanmaku;

  final int _cid;
  final PlPlayerController _plPlayerController;
  final bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final Map<int, List<DanmakuElem>> _dmSegMap = HashMap();
  // 已请求的段落标记
  late final Set<int> _requestedSeg = HashSet();
  bool _disposed = false;
  bool _shownEmptyHint = false;
  bool _shownErrorHint = false;

  static const int segmentLength = 60 * 6 * 1000;

  void dispose() {
    _disposed = true;
    _dmSegMap.clear();
    _requestedSeg.clear();
  }

  static int calcSegment(int progress) {
    return progress ~/ segmentLength;
  }

  void _showEmptyHint(String message) {
    if (_disposed || _shownEmptyHint) {
      return;
    }
    _shownEmptyHint = true;
    SmartDialog.showToast(message);
  }

  void _showErrorHint(String message) {
    if (_disposed || _shownErrorHint) {
      return;
    }
    _shownErrorHint = true;
    SmartDialog.showToast(message);
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_disposed || _isFileSource) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex)) {
      return;
    }
    _requestedSeg.add(segmentIndex);
    final res = await DmGrpc.dmSegMobile(
      cid: _cid,
      segmentIndex: segmentIndex + 1,
    );
    if (_disposed) {
      return;
    }

    if (res case Success(:final response)) {
      if (response.state == 1) {
        _plPlayerController.dmState.add(_cid);
      }
      if (response.elems.isEmpty) {
        _showEmptyHint(
          response.state == 1 ? 'UP主已关闭弹幕' : '当前时间点暂无弹幕',
        );
        return;
      }
      handleDanmaku(response.elems);
    } else {
      _requestedSeg.remove(segmentIndex);
      _showErrorHint('弹幕加载失败');
    }
  }

  void handleDanmaku(List<DanmakuElem> elems) {
    if (elems.isEmpty) return;
    final uniques = HashMap<String, DanmakuElem>();

    final filters = _plPlayerController.filters;
    final danmakuWeight = DanmakuOptions.danmakuWeight;
    final shouldFilter = filters.count != 0;
    for (final element in elems) {
      if (_isLogin) {
        element.isSelf = element.midHash == _plPlayerController.midHash;
      }

      if (!element.isSelf) {
        if (_mergeDanmaku) {
          final elem = uniques[element.content];
          if (elem == null) {
            uniques[element.content] = element..count = 1;
          } else {
            elem.count++;
            continue;
          }
        }

        if (element.weight < danmakuWeight ||
            (shouldFilter && filters.remove(element))) {
          continue;
        }
      }

      final int pos = element.progress ~/ 100; //每0.1秒存储一次
      (_dmSegMap[pos] ??= []).add(element);
    }
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _dmSegMap[progress ~/ 100];
  }

  bool _fileDmLoaded = false;

  void initFileDmIfNeeded() {
    if (_fileDmLoaded) return;
    _fileDmLoaded = true;
    _initFileDm();
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final file = File(
        path.join(
          (_plPlayerController.dataSource as FileSource).dir,
          PathUtils.danmakuName,
        ),
      );
      if (_disposed) return;
      if (!file.existsSync()) {
        _showEmptyHint('当前视频暂无弹幕');
        return;
      }
      final bytes = await file.readAsBytes();
      if (_disposed) return;
      if (bytes.isEmpty) {
        _showEmptyHint('当前视频暂无弹幕');
        return;
      }
      final elem = DmSegMobileReply.fromBuffer(bytes).elems;
      handleDanmaku(elem);
    } catch (e, s) {
      Utils.reportError(e, s);
      _showErrorHint('弹幕加载失败');
    }
  }
}
