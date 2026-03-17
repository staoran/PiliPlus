import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

class DownloadManager {
  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;

  int _retryCount = 0;
  late final int _maxRetries;
  late final int _retryDelayMs;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
  }) {
    _maxRetries = Pref.retryCount;
    _retryDelayMs = Pref.retryDelay;
    task = _start();
  }

  Future<void> _start() async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    Future<void> onError(Object e, {bool delete = false}) async {
      try {
        await sink.close();
      } catch (_) {}
      if (_status == DownloadStatus.downloading) {
        // 判断是否可以重试
        if (_shouldRetry(e) && _retryCount < _maxRetries) {
          _retryCount++;
          // 等待指数退避时间后重试
          await Future.delayed(
            Duration(milliseconds: _retryCount * _retryDelayMs),
          );
          // 如果任务未被取消，则重试
          if (!_cancelToken.isCancelled) {
            await _start();
            return;
          }
        }

        _status = DownloadStatus.failDownload;
        if (delete && file.existsSync()) {
          await file.tryDel();
        }
      }
      onDone(e);
    }

    Response<ResponseBody> response;
    try {
      response = await Request.http11Dio.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null &&
              (status == 416 || (status >= 200 && status < 300)),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      await onError(e, delete: true);
      return;
    }
    final data = response.data!;
    final contentLength = data.contentLength + received;

    if (received == 0) {
      onReceiveProgress?.call(0, contentLength);
    }

    int? last;
    try {
      await for (final chunk in data.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (last != now) {
          last = now;
          onReceiveProgress?.call(received, contentLength);
        }
      }
      await sink.close();
      _status = DownloadStatus.completed;
      onDone();
    } catch (e) {
      await onError(e);
      return;
    }
  }

  /// 判断错误是否应该重试
  bool _shouldRetry(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.unknown:
          return true;
        default:
          return false;
      }
    }
    // 对于非 Dio 异常（如流读取错误），也尝试重试
    return error is SocketException || error is TimeoutException;
  }

  Future<void> cancel({required bool isDelete}) {
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel();
    }
    return task;
  }
}
