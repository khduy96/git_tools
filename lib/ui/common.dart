import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../git/models.dart';

/// Darcula / New UI dark palette.
abstract final class AppColors {
  static const background = Color(0xFF1E1F22);
  static const panel = Color(0xFF2B2D30);
  static const panelAlt = Color(0xFF27282C);
  static const border = Color(0xFF393B40);
  static const divider = Color(0xFF1E1F22);
  static const hover = Color(0xFF393B40);
  static const selection = Color(0xFF2E436E);
  static const selectionInactive = Color(0xFF393B40);
  static const text = Color(0xFFDFE1E5);
  static const textDim = Color(0xFF9DA0A8);
  static const textMuted = Color(0xFF6F737A);
  static const accent = Color(0xFF3574F0);
  static const accentHover = Color(0xFF4682FA);
  static const error = Color(0xFFDB5C5C);
  static const warning = Color(0xFFE5A54B);
  static const success = Color(0xFF5FB865);

  // File status colors.
  static const modified = Color(0xFF6CA0F5);
  static const added = Color(0xFF73BD79);
  static const deleted = Color(0xFF8C8C8C);
  static const untracked = Color(0xFFD1675A);
  static const conflict = Color(0xFFE06C75);
  static const renamed = Color(0xFF6CA0F5);

  // Diff colors.
  static const diffInsertedBg = Color(0xFF233B2A);
  static const diffInsertedHi = Color(0xFF2F5C3A);
  static const diffDeletedBg = Color(0xFF3A3C3F);
  static const diffDeletedHi = Color(0xFF55585C);
  static const diffModifiedBg = Color(0xFF1E3250);
  static const diffModifiedHi = Color(0xFF2C4D7D);
  static const diffFiller = Color(0xFF232427);
  static const diffInsertedMark = Color(0xFF4E9A5E);
  static const diffDeletedMark = Color(0xFF7A7D80);
  static const diffModifiedMark = Color(0xFF4F7FC6);

  // Ref labels.
  static const headRef = Color(0xFFE5C07B);
  static const localRef = Color(0xFF73BD79);
  static const remoteRef = Color(0xFFC678DD);
  static const tagRef = Color(0xFF56B6C2);

  static const graph = [
    Color(0xFF4F9DED),
    Color(0xFF73BD79),
    Color(0xFFE5A54B),
    Color(0xFFC678DD),
    Color(0xFFE06C75),
    Color(0xFF56B6C2),
    Color(0xFFD19A66),
    Color(0xFF98C379),
    Color(0xFFB57EDC),
    Color(0xFF61AFEF),
  ];
}

const monoFont = 'Consolas';
const monoFallback = ['JetBrains Mono', 'Cascadia Mono', 'Menlo', 'monospace'];

TextStyle monoStyle({double size = 13, Color color = AppColors.text}) =>
    TextStyle(
      fontFamily: monoFont,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      color: color,
      height: 1.25,
    );

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.panel,
      error: AppColors.error,
      onSurface: AppColors.text,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Segoe UI',
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.border,
    dividerTheme: const DividerThemeData(
        color: AppColors.border, thickness: 1, space: 1),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
      textStyle: TextStyle(fontSize: 12, color: AppColors.text),
      decoration: BoxDecoration(
        color: Color(0xFF393B40),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.panel,
      textStyle: TextStyle(fontSize: 13, color: AppColors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.panel),
        side: WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      ),
    ),
    menuButtonTheme: const MenuButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
        minimumSize: WidgetStatePropertyAll(Size(180, 30)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.background,
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13),
      labelStyle: TextStyle(color: AppColors.textDim, fontSize: 13),
    ),
    checkboxTheme: CheckboxThemeData(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: const BorderSide(color: AppColors.textMuted),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(72, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        minimumSize: const Size(72, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentHover,
        textStyle: const TextStyle(fontSize: 13),
      ),
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(8),
      thumbColor: WidgetStatePropertyAll(Color(0x55A0A4AA)),
      radius: Radius.circular(4),
    ),
  );
}

Color changeColor(ChangeType t) => switch (t) {
      ChangeType.modified || ChangeType.typeChanged => AppColors.modified,
      ChangeType.added || ChangeType.copied => AppColors.added,
      ChangeType.deleted => AppColors.deleted,
      ChangeType.renamed => AppColors.renamed,
      ChangeType.untracked => AppColors.untracked,
      ChangeType.conflicted => AppColors.conflict,
    };

IconData fileIcon(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot < 0 ? '' : lower.substring(dot + 1);
  return switch (ext) {
    'dart' || 'kt' || 'java' || 'js' || 'ts' || 'py' || 'c' || 'cpp' ||
    'h' || 'cs' || 'go' || 'rs' || 'swift' || 'm' || 'tsx' || 'jsx' ||
    'gradle' || 'kts' =>
      Icons.code,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'ico' =>
      Icons.image_outlined,
    'json' || 'yaml' || 'yml' || 'xml' || 'toml' || 'properties' ||
    'arb' || 'plist' =>
      Icons.data_object,
    'md' || 'txt' => Icons.description_outlined,
    'lock' => Icons.lock_outline,
    _ => Icons.insert_drive_file_outlined,
  };
}

String formatDate(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  if (day == today) return 'Today $time';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $time';
  return '${two(t.day)}/${two(t.month)}/${t.year} $time';
}

String formatDateFull(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Small square icon button used in tool window toolbars.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.selected = false,
    this.size = 16,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        hoverColor: AppColors.hover,
        child: Container(
          width: size + 10,
          height: size + 10,
          decoration: selected
              ? BoxDecoration(
                  color: AppColors.hover,
                  borderRadius: BorderRadius.circular(4))
              : null,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: size,
            color: enabled
                ? (color ?? AppColors.textDim)
                : AppColors.textMuted.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Header strip of a tool window / panel.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ?leading,
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.text)),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class RefChip extends StatelessWidget {
  const RefChip(this.label, {super.key});

  final RefLabel label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label.kind) {
      RefKind.head => AppColors.headRef,
      RefKind.localBranch => AppColors.localRef,
      RefKind.remoteBranch => AppColors.remoteRef,
      RefKind.tag => AppColors.tagRef,
    };
    final icon = switch (label.kind) {
      RefKind.head => Icons.my_location,
      RefKind.tag => Icons.sell_outlined,
      _ => Icons.call_split,
    };
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          if (label.kind != RefKind.head) ...[
            const SizedBox(width: 3),
            Text(label.name,
                style: TextStyle(fontSize: 11, color: color, height: 1.1)),
          ],
        ],
      ),
    );
  }
}

/// Hoverable, selectable list row.
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapDown,
    this.height = 24,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final void Function(TapDownDetails)? onSecondaryTapDown;
  final double height;
  final EdgeInsets padding;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: Container(
          height: widget.height,
          padding: widget.padding,
          color: widget.selected
              ? AppColors.selection
              : _hover
                  ? AppColors.hover.withValues(alpha: 0.5)
                  : null,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Shows a context menu at [position] built from [items].
Future<T?> showContextMenu<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

PopupMenuItem<T> menuItem<T>(
  T value,
  String label, {
  IconData? icon,
  bool enabled = true,
  String? shortcut,
  Color? color,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: 30,
    child: Row(
      children: [
        SizedBox(
          width: 24,
          child: icon == null
              ? null
              : Icon(icon,
                  size: 15,
                  color: enabled ? (color ?? AppColors.textDim) : AppColors.textMuted),
        ),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: enabled ? (color ?? AppColors.text) : AppColors.textMuted)),
        ),
        if (shortcut != null)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(shortcut,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ),
      ],
    ),
  );
}

void copyToClipboard(BuildContext context, String text, {String? label}) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text(label ?? 'Copied to clipboard'),
    duration: const Duration(seconds: 2),
    behavior: SnackBarBehavior.floating,
    width: 320,
  ));
}

/// Compact text displayed when a panel has nothing to show.
class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 36, color: AppColors.textMuted),
            if (icon != null) const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
