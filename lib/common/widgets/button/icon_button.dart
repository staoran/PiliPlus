import 'package:PiliPlus/common/widgets/loading_widget/button_loading.dart';
import 'package:material_ui/material_ui.dart';

Widget iconButton({
  BuildContext? context,
  String? tooltip,
  required Widget icon,
  required VoidCallback? onPressed,
  double size = 36,
  double? iconSize,
  Color? bgColor,
  Color? iconColor,
  bool isLoading = false,
  double loadingSize = 16,
  Color? loadingColor,
}) {
  Color? backgroundColor = bgColor;
  Color? foregroundColor = iconColor;
  if (context != null) {
    final colorScheme = ColorScheme.of(context);
    backgroundColor = colorScheme.secondaryContainer;
    foregroundColor = colorScheme.onSecondaryContainer;
  }
  return SizedBox(
    width: size,
    height: size,
    child: IconButton(
      icon: isLoading
          ? buttonLoadingIndicator(
              size: loadingSize,
              color: loadingColor ?? foregroundColor,
            )
          : icon,
      tooltip: tooltip,
      onPressed: isLoading ? null : onPressed,
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        iconSize: iconSize ?? size / 2,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      ),
    ),
  );
}
