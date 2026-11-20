import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:audio_session/audio_session.dart';

class AudioSessionHandler {
  late final Future<AudioSession> _session;
  void Function()? _resume;
  void Function()? _restoreVolume;

  AudioSessionHandler() {
    _session = _initSession();
  }

  Future<bool> setActive(bool active) async =>
      (await _session).setActive(active);

  Future<AudioSession> _initSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    session.interruptionEventStream.listen(_onInterrupted);

    // 耳机拔出暂停
    session.becomingNoisyEventStream.listen((_) {
      videoPlayerServiceHandler?.onPause?.call() ??
          PlPlayerController.pauseIfExists();
    });
    return session;
  }

  void _onInterrupted(AudioInterruptionEvent event) {
    if (!event.begin) {
      switch (event.type) {
        case .duck:
          final restore = _restoreVolume;
          _restoreVolume = null;
          restore?.call();
        case .pause:
        case .unknown:
          final resume = _resume;
          _resume = null;
          if (event.type == .pause) resume?.call();
      }
      return;
    }

    final player = PlPlayerController.controlledPlayer;
    final owner = PlPlayerController.playOwner;
    final nativePlayer = player?.videoPlayerController;
    final dataSource = player?.cid;
    bool isCurrentVideo() =>
        identical(PlPlayerController.controlledPlayer, player) &&
        identical(player?.videoPlayerController, nativePlayer) &&
        PlPlayerController.playOwner == owner &&
        player?.cid == dataSource;
    if (event.type == .duck) {
      if (player != null && player.playerStatus.value.isPlaying) {
        final volume = player.volume.value;
        _restoreVolume = () {
          if (isCurrentVideo()) player.setVolume(volume, showIndicator: false);
        };
        player.setVolume(volume * 0.5, showIndicator: false);
      }
      return;
    }

    final handler = videoPlayerServiceHandler;
    final audioId = handler?.mediaItem.value?.id;
    final isAudioPlaying = handler?.isPlaying;
    final play = handler?.onPlay;
    if (isAudioPlaying != null) {
      if (isAudioPlaying()) {
        _resume = () {
          if (handler?.onPlay == play &&
              handler?.isPlaying == isAudioPlaying &&
              handler?.mediaItem.value?.id == audioId &&
              PlPlayerController.playOwner == owner) {
            play?.call();
          }
        };
        handler?.onPause?.call();
      }
    } else if (player != null && player.playerStatus.value.isPlaying) {
      _resume = () {
        if (isCurrentVideo()) player.play();
      };
      player.pause(isInterrupt: true);
    }
  }
}
