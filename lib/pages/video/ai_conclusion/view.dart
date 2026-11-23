import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/pages/common/slide/common_slide_page.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:material_ui/material_ui.dart';

class AiConclusionPanel extends CommonSlidePage {
  final AiConclusionResult item;
  final ValueChanged<Duration> onSeek;

  const AiConclusionPanel({
    super.key,
    required this.item,
    required this.onSeek,
  });

  @override
  State<AiConclusionPanel> createState() => _AiDetailState();

  static Widget buildContent(
    BuildContext context,
    ThemeData theme,
    AiConclusionResult res, {
    Key? key,
    ValueChanged<Duration>? onSeek,
  }) {
    final tap = onSeek != null;
    final outline = res.outline;
    final hasOutline = outline != null && outline.isNotEmpty;
    return SelectionArea(
      child: CustomScrollView(
        key: key,
        shrinkWrap: !tap,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (res.summary?.isNotEmpty == true) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  res.summary!,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                ),
              ),
            ),
            if (hasOutline)
              SliverToBoxAdapter(
                child: Divider(
                  height: 20,
                  color: theme.dividerColor.withValues(alpha: 0.1),
                  thickness: 6,
                ),
              ),
          ],
          if (hasOutline)
            SliverPadding(
              padding: EdgeInsets.only(
                left: 14,
                right: 14,
                bottom: !tap
                    ? 0
                    : MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: SliverList.builder(
                itemCount: outline.length,
                itemBuilder: (context, index) {
                  final item = outline[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (index != 0) const SizedBox(height: 10),
                      Text(
                        item.title!,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...?item.partOutline?.map(
                        (item) => Wrap(
                          children: [
                            Text.rich(
                              TextSpan(
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurface,
                                  height: 1.5,
                                ),
                                children: [
                                  TextSpan(
                                    text: DurationUtils.formatDuration(
                                      item.timestamp,
                                    ),
                                    style: tap
                                        ? TextStyle(
                                            color: theme.colorScheme.primary,
                                          )
                                        : null,
                                    recognizer: tap
                                        ? (NoDeadlineTapGestureRecognizer()
                                            ..onTap = () => onSeek(
                                              Duration(
                                                seconds: item.timestamp!,
                                              ),
                                            ))
                                        : null,
                                  ),
                                  const TextSpan(text: ' '),
                                  TextSpan(text: item.content!),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AiDetailState extends State<AiConclusionPanel>
    with SingleTickerProviderStateMixin, CommonSlideMixin {
  @override
  Widget buildPage() {
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          GestureDetector(
            onTap: closeSlidePage,
            child: SizedBox(
              height: 35,
              child: Center(
                child: Container(
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: enableSlide ? slideList() : buildList(),
          ),
        ],
      ),
    );
  }

  late Key _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = PrimaryScrollController.of(context);
    _key = ValueKey(controller.hashCode);
  }

  @override
  Widget buildList() {
    return AiConclusionPanel.buildContent(
      context,
      theme,
      widget.item,
      onSeek: widget.onSeek,
      key: _key,
    );
  }
}
