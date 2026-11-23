import 'package:PiliPlus/common/widgets/loading_widget/button_loading.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/services/multi_window/player_window_navigation.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class FavPanel extends StatefulWidget {
  const FavPanel({
    super.key,
    required this.ctr,
    this.scrollController,
  });

  final FavMixin ctr;
  final ScrollController? scrollController;

  @override
  State<FavPanel> createState() => _FavPanelState();
}

class _FavPanelState extends State<FavPanel> {
  LoadingState loadingState = LoadingState.loading();
  late ColorScheme colorScheme;

  @override
  void initState() {
    super.initState();
    _queryVideoInFolder();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    colorScheme = ColorScheme.of(context);
  }

  Future<void> _queryVideoInFolder() async {
    final res = await widget.ctr.queryVideoInFolder();
    if (mounted) {
      loadingState = res;
      setState(() {});
    }
  }

  void _closePanel() => Navigator.pop(context);

  Future<void> _submit() async {
    if (widget.ctr.isActionLoading(IntroAction.favorite)) return;
    feedBack();
    final inPlayerWindow = PlayerWindowNavigation.maybeOf(context) != null;
    if (!inPlayerWindow) SmartDialog.showLoading(msg: '请求中');
    final LoadingState<bool>? result;
    try {
      result = await widget.ctr.actionFavVideo();
    } finally {
      if (!inPlayerWindow) SmartDialog.dismiss(status: SmartStatus.loading);
    }
    if (!mounted ||
        result == null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final message = switch (result) {
      Success(:final response) => '${response ? '' : '取消'}收藏成功',
      _ => result.toString(),
    };
    PlayerWindowNavigation.showToast(context, message);
    if (result.isSuccess) _closePanel();
  }

  Widget _buildBody(bool isSaving) {
    switch (loadingState) {
      case Loading():
        return m3eLoading;
      case Success():
        final list = widget.ctr.favFolderData.value.list!;
        return ListView.builder(
          controller: widget.scrollController,
          itemCount: list.length,
          itemBuilder: (context, index) {
            FavFolderInfo item = list[index];
            return Material(
              type: .transparency,
              child: Builder(
                builder: (context) {
                  final isChecked = item.favState == 1;

                  void onTap() {
                    item
                      ..favState = isChecked ? 0 : 1
                      ..mediaCount += isChecked ? -1 : 1;
                    (context as Element).markNeedsBuild();
                  }

                  final isFull =
                      BiliUtils.isFavFolderFull(item.attr, item.mediaCount) &&
                      !isChecked;
                  TextStyle? textStyle;
                  if (isFull) {
                    textStyle = TextStyle(color: colorScheme.outline);
                  }

                  return ListTile(
                    onTap: isFull || isSaving ? null : onTap,
                    dense: true,
                    leading: BiliUtils.isPublicFav(item.attr)
                        ? isFull
                              ? Icon(
                                  Icons.folder_outlined,
                                  color: colorScheme.outline,
                                )
                              : const Icon(Icons.folder_outlined)
                        : isFull
                        ? Icon(
                            Icons.lock_outline,
                            color: colorScheme.outline,
                          )
                        : const Icon(Icons.lock_outline),
                    minLeadingWidth: 0,
                    title: Text(item.title),
                    subtitle: Text(
                      '${NumUtils.numFormat(item.mediaCount)}个内容${isFull ? '(已满)' : ''} · ${BiliUtils.isPublicFavText(item.attr)}',
                      style: textStyle,
                    ),
                    trailing: isFull
                        ? Padding(
                            padding: const .only(right: 8),
                            child: Icon(
                              size: 21.6,
                              color: colorScheme.outline,
                              Icons.indeterminate_check_box_outlined,
                            ),
                          )
                        : Transform.scale(
                            scale: 0.9,
                            alignment: .centerRight,
                            child: Checkbox(
                              value: isChecked,
                              materialTapTargetSize: .shrinkWrap,
                              onChanged: isSaving ? null : (_) => onTap(),
                            ),
                          ),
                  );
                },
              ),
            );
          },
        );
      case Error(:final errMsg):
        return scrollErrorWidget(
          errMsg: errMsg,
          controller: widget.scrollController,
          onReload: _queryVideoInFolder,
        );
    }
  }

  @override
  Widget build(BuildContext context) => Obx(_buildPanel);

  Widget _buildPanel() {
    final isSaving = widget.ctr.isActionLoading(IntroAction.favorite);
    return Column(
      children: [
        AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            tooltip: '关闭',
            onPressed: _closePanel,
            icon: const Icon(Icons.close_outlined),
          ),
          title: const Text('添加到收藏夹'),
          actions: [
            TextButton.icon(
              onPressed: isSaving
                  ? null
                  : () =>
                        PlayerWindowNavigation.openInMain(
                          context,
                          '/createFav',
                        )?.then((data) {
                          if (data is FavFolderInfo && mounted) {
                            widget.ctr.favFolderData.value.list?.insert(
                              1,
                              data
                                ..favState = 1
                                ..mediaCount = 1,
                            );
                            setState(() {});
                          }
                        }),
              icon: Icon(Icons.add, color: colorScheme.primary),
              label: const Text('新建收藏夹'),
              style: const ButtonStyle(
                visualDensity: .compact,
                padding: WidgetStatePropertyAll(
                  .symmetric(horizontal: 18, vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        Expanded(child: _buildBody(isSaving)),
        Divider(
          height: 1,
          color: colorScheme.outline.withValues(alpha: 0.1),
        ),
        Padding(
          padding: .only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
          ),
          child: Row(
            spacing: 25,
            mainAxisAlignment: .end,
            children: [
              FilledButton.tonal(
                onPressed: _closePanel,
                style: FilledButton.styleFrom(
                  visualDensity: .compact,
                  foregroundColor: colorScheme.outline,
                  backgroundColor: colorScheme.onInverseSurface,
                ),
                child: const Text('取消'),
              ),
              FilledButton.tonal(
                onPressed: isSaving || loadingState is! Success
                    ? null
                    : _submit,
                style: const ButtonStyle(visualDensity: .compact),
                child: LoadingButtonChild(
                  isLoading: isSaving,
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
