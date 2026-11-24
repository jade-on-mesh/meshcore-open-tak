import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/model_auto_download.dart';
import 'mesh_ui.dart';

/// A card with a progress bar while [ModelAutoDownloader] fetches a model
/// (photo upscaler, voice restorer, Mimi, photo codec, translation). Shows
/// nothing when no download is running, or the running one has no label.
class ModelDownloadProgress extends StatelessWidget {
  const ModelDownloadProgress({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AutoDownloadModel?>(
      valueListenable: ModelAutoDownloader.current,
      builder: (context, model, _) {
        if (model == null || model.label == null) {
          return const SizedBox.shrink();
        }
        return _ModelDownloadCard(key: ValueKey(model.id), model: model);
      },
    );
  }
}

class _ModelDownloadCard extends StatefulWidget {
  const _ModelDownloadCard({super.key, required this.model});

  final AutoDownloadModel model;

  @override
  State<_ModelDownloadCard> createState() => _ModelDownloadCardState();
}

class _ModelDownloadCardState extends State<_ModelDownloadCard> {
  Timer? _timer;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _progress = _read();
    // The services report progress as plain getters, so poll them.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final p = _read();
      if (p != _progress && mounted) setState(() => _progress = p);
    });
  }

  double? _read() {
    final p = widget.model.progress?.call();
    if (p == null || p.isNaN) return null;
    return p.clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final name = widget.model.label!(l10n);
    final p = _progress;
    return MeshCard(
      child: Semantics(
        label: l10n.modelDownload_title(name),
        value: p == null ? null : '${(p * 100).round()}%',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.downloading, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.modelDownload_title(name),
                    style: text.titleSmall?.copyWith(color: scheme.onSurface),
                  ),
                ),
                if (p != null)
                  Text(
                    '${(p * 100).round()}%',
                    style: text.labelLarge?.copyWith(
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.modelDownload_subtitle,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
