import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show MultiSelectData;
import 'package:collection/collection.dart';

List<DownloadSeasonInfo> groupDownloadEntries(
  Iterable<BiliDownloadEntryInfo> entries,
) {
  final list = <DownloadSeasonInfo>[];
  for (final entry in entries) {
    final pageId = entry.pageId;
    final seasonInfo = entry.seasonInfo;
    final season = seasonInfo != null
        ? list.firstWhereOrNull((e) => e.seasonInfo == seasonInfo)
        : list.firstWhereOrNull((e) => e.pageId == pageId);
    if (season != null) {
      final page = season.pages.firstWhereOrNull((e) => e.pageId == pageId);
      if (page != null) {
        final sortKey = seasonInfo?.index ?? entry.sortKey;
        if (sortKey < page.sortKey) {
          page
            ..cover = entry.cover
            ..sortKey = sortKey;
        }
        page.entries.add(entry);
      } else {
        season.pages.add(
          entry.toDownloadPageInfo(pageId, sortKey: seasonInfo!.index),
        );
      }
    } else {
      list.add(
        DownloadSeasonInfo(
          pageId: pageId,
          seasonInfo: seasonInfo,
          pages: [entry.toDownloadPageInfo(pageId, sortKey: seasonInfo?.index)],
        ),
      );
    }
  }
  return list;
}

class DownloadPageInfo with MultiSelectData {
  final String pageId;
  final String dirPath;
  final String title;
  String cover;
  int sortKey;
  final int? seasonType;
  final List<BiliDownloadEntryInfo> entries;

  DownloadPageInfo({
    required this.pageId,
    required this.dirPath,
    required this.title,
    required this.cover,
    required this.sortKey,
    this.seasonType,
    required this.entries,
  });
}

class DownloadSeasonInfo with MultiSelectData {
  SeasonInfo? seasonInfo;
  final String pageId;
  final List<DownloadPageInfo> pages;

  DownloadSeasonInfo({
    required this.seasonInfo,
    required this.pageId,
    required this.pages,
  });
}
