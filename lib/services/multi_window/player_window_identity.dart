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
