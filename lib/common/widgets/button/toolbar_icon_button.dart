import 'package:PiliPlus/common/widgets/loading_widget/button_loading.dart';
import 'package:material_ui/material_ui.dart';

class ToolbarIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Icon icon;
  final bool selected;
  final String? tooltip;
  final bool isLoading;

  const ToolbarIconButton({
    super.key,
    this.onPressed,
    required this.icon,
    required this.selected,
    this.tooltip,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        tooltip: tooltip,
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? buttonLoadingIndicator(
                color: selected
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.outline,
              )
            : icon,
        highlightColor: colorScheme.secondaryContainer,
        color: selected
            ? colorScheme.onSecondaryContainer
            : colorScheme.outline,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          backgroundColor: WidgetStatePropertyAll(
            selected ? colorScheme.secondaryContainer : null,
          ),
        ),
      ),
    );
  }
}
