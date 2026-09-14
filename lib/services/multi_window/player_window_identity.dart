class PlayerWindowIdentity {
  const PlayerWindowIdentity._();

  static String heroTag({
    int? aid,
    String? bvid,
    int? cid,
    int? seasonId,
    int? epId,
    int? pgcType,
    Object? videoType,
    Object? sourceType,
  }) {
    final parts = <String>[
      'playerWindow',
      'aid:${aid ?? 0}',
      'bvid:${bvid ?? ''}',
      'cid:${cid ?? 0}',
      'season:${seasonId ?? 0}',
      'ep:${epId ?? 0}',
      'pgc:${pgcType ?? 0}',
      'video:${_identityPart(videoType)}',
      'source:${_identityPart(sourceType)}',
    ];
    return parts.join('|');
  }

  static bool shouldSkipVideoNavigation({
    required Map routeArguments,
    required Map nextArguments,
    Object? currentVideoType,
    int? currentAid,
    String? currentBvid,
    int? currentCid,
    int? currentEpId,
  }) {
    final hasCurrentVideoIdentity =
        currentVideoType != null &&
        currentAid != null &&
        currentBvid != null &&
        currentCid != null;
    final currentVideoArguments = hasCurrentVideoIdentity
        ? <String, dynamic>{
            'videoType': currentVideoType,
            'aid': currentAid,
            'bvid': currentBvid,
            'cid': currentCid,
            'epId': currentEpId,
          }
        : routeArguments;

    return currentVideoArguments['aid'] == nextArguments['aid'] &&
        currentVideoArguments['bvid'] == nextArguments['bvid'] &&
        currentVideoArguments['cid'] == nextArguments['cid'] &&
        currentVideoArguments['epId'] == nextArguments['epId'] &&
        routeArguments['seasonId'] == nextArguments['seasonId'] &&
        routeArguments['pgcType'] == nextArguments['pgcType'] &&
        currentVideoArguments['videoType'] == nextArguments['videoType'] &&
        routeArguments['sourceType'] == nextArguments['sourceType'] &&
        routeArguments['progress'] == nextArguments['progress'] &&
        routeArguments['progressAid'] == nextArguments['progressAid'] &&
        routeArguments['progressBvid'] == nextArguments['progressBvid'] &&
        routeArguments['progressCid'] == nextArguments['progressCid'];
  }

  static String _identityPart(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is Enum) {
      return value.name;
    }
    return value.toString();
  }
}
