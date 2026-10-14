import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common.dart';

/// Standard dialog frame: title bar, body and right-aligned buttons.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.width = 460,
    this.height,
    this.onSubmit,
    this.leftActions = const [],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final List<Widget> leftActions;
  final double width;
  final double? height;

  /// Called on Ctrl+Enter.
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            ?onSubmit,
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    ToolButton(
                      icon: Icons.close,
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (height != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: child,
                  ),
                )
              else
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: child,
                  ),
                ),
              if (actions.isNotEmpty || leftActions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Row(
                    children: [
                      ...leftActions,
                      const Spacer(),
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        actions[i],
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: title,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: true,
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
      child: Text(message, style: const TextStyle(fontSize: 13, height: 1.4)),
    ),
  );
  return r ?? false;
}

Future<String?> showInput(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String confirmLabel = 'OK',
  String? Function(String)? validator,
  bool multiline = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _InputDialog(
      title: title,
      label: label,
      initial: initial,
      confirmLabel: confirmLabel,
      validator: validator,
      multiline: multiline,
    ),
  );
}

class _InputDialog extends StatefulWidget {
  const _InputDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmLabel,
    required this.validator,
    required this.multiline,
  });

  final String title;
  final String label;
  final String initial;
  final String confirmLabel;
  final String? Function(String)? validator;
  final bool multiline;

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final _ctrl = TextEditingController(text: widget.initial)
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  String? _error;

  void _submit() {
    final v = _ctrl.text;
    final err = widget.validator?.call(v);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: widget.title,
      onSubmit: _submit,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label,
              style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
          const SizedBox(height: 6),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: widget.multiline ? 5 : 1,
            maxLines: widget.multiline ? 12 : 1,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(errorText: _error),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: widget.multiline ? null : (_) => _submit(),
          ),
        ],
      ),
    );
  }
}

/// Validates a git ref name (simplified `git check-ref-format`).
String? validateRefName(String name, {Iterable<String> existing = const []}) {
  final n = name.trim();
  if (n.isEmpty) return 'Name cannot be empty';
  if (RegExp(r'[\s~^:?*\[\\]').hasMatch(n) ||
      n.contains('..') ||
      n.contains('@{') ||
      n.startsWith('-') ||
      n.startsWith('/') ||
      n.endsWith('/') ||
      n.endsWith('.') ||
      n.endsWith('.lock')) {
    return 'Invalid name';
  }
  if (existing.contains(n)) return 'A branch named "$n" already exists';
  return null;
}
