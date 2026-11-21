// MeshCore Open TAK - the MediaMesh coverage controls (MediaMesh settings):
// record, show on the map, export, clear (mediamesh_coverage.dart), and
// sharing the points with an analyzer (mediamesh_coverage_share.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/mediamesh_coverage.dart';
import '../services/mediamesh_coverage_share.dart';
import '../team/coverage_layer.dart';

class MediaMeshCoverageTile extends StatelessWidget {
  const MediaMeshCoverageTile({super.key});

  @override
  Widget build(BuildContext context) {
    MediaMeshCoverageService cov;
    try {
      cov = context.watch<MediaMeshCoverageService>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final small = Theme.of(context).textTheme.bodySmall;
    final labels = {
      MediaMeshReach.good: l10n.coverage_good,
      MediaMeshReach.marginal: l10n.coverage_marginal,
      MediaMeshReach.out: l10n.coverage_out,
      MediaMeshReach.none: l10n.coverage_none,
    };
    final counts = {for (final r in MediaMeshReach.values) r: 0};
    for (final s in cov.samples) {
      counts[s.reach] = counts[s.reach]! + 1;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.coverage_title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            cov.recording ? Icons.fiber_manual_record : Icons.route_outlined,
            color: cov.recording ? Colors.red : null,
          ),
          title: Text(l10n.coverage_record),
          subtitle: Text(
            cov.problem ??
                (cov.asking ? l10n.coverage_asking : l10n.coverage_recordHelp),
          ),
          value: cov.recording,
          onChanged: (v) => unawaited(cov.setRecording(v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.layers_outlined),
          title: Text(l10n.coverage_show),
          subtitle: Text(l10n.coverage_points(cov.samples.length)),
          value: cov.show,
          onChanged: (v) => unawaited(cov.setShow(v)),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final r in MediaMeshReach.values)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 12, color: coverageColor(r)),
                  const SizedBox(width: 4),
                  Text('${labels[r]} ${counts[r]}', style: small),
                ],
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(l10n.coverage_help, style: small),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.ios_share),
              label: Text(l10n.coverage_export),
              onPressed: cov.samples.isEmpty
                  ? null
                  : () => unawaited(cov.export()),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.coverage_clear),
              onPressed: cov.samples.isEmpty || cov.recording
                  ? null
                  : () => unawaited(cov.clear()),
            ),
          ],
        ),
        const Divider(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            cov.share ? Icons.cloud_upload : Icons.cloud_off_outlined,
          ),
          title: Text(l10n.coverage_share),
          subtitle: Text(_shareLine(context, cov) ?? l10n.coverage_shareHelp),
          value: cov.share,
          onChanged: (v) => unawaited(cov.setShare(v)),
        ),
        _AnalyzerField(cov: cov),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: cov.sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload),
              label: Text(
                cov.sending ? l10n.coverage_sending : l10n.coverage_sendNow,
              ),
              onPressed: !cov.share || cov.sending
                  ? null
                  : () => unawaited(cov.sendNow()),
            ),
            TextButton.icon(
              icon: const Icon(Icons.person_remove_outlined),
              label: Text(l10n.coverage_removeMine),
              onPressed: cov.sending
                  ? null
                  : () => _confirmRemove(context, cov),
            ),
          ],
        ),
        const Divider(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            cov.shareReceipts
                ? Icons.mark_email_read_outlined
                : Icons.mail_outline,
          ),
          title: Text(l10n.coverage_shareReceipts),
          subtitle: Text(
            _receiptsLine(context, cov) ?? l10n.coverage_shareReceiptsHelp,
          ),
          value: cov.shareReceipts,
          onChanged: (v) => unawaited(cov.setShareReceipts(v)),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.person_remove_outlined),
              label: Text(l10n.coverage_receiptsRemove),
              onPressed: cov.sendingReceipts
                  ? null
                  : () => _confirmRemoveReceipts(context, cov),
            ),
          ],
        ),
      ],
    );
  }

  /// The last receipts send, or how many are waiting; null: the help text.
  String? _receiptsLine(BuildContext context, MediaMeshCoverageService cov) {
    final l10n = context.l10n;
    final s = cov.receiptsStatus;
    if (s == null) {
      return cov.shareReceipts && cov.receiptsWaiting > 0
          ? l10n.coverage_receiptsWaiting(cov.receiptsWaiting)
          : null;
    }
    final e = s.error;
    if (e == 'not-connected') return l10n.coverage_shareNotConnected;
    if (e == 'bad-address') return l10n.coverage_analyzerBad;
    if (e != null) return l10n.coverage_shareError(e);
    final when = s.at == null
        ? ''
        : ' · ${TimeOfDay.fromDateTime(s.at!).format(context)}';
    return (s.removedPoints
            ? l10n.coverage_receiptsRemoved(s.count)
            : l10n.coverage_receiptsSent(s.count)) +
        when;
  }

  Future<void> _confirmRemoveReceipts(
    BuildContext context,
    MediaMeshCoverageService cov,
  ) async {
    final l10n = context.l10n;
    final host = coverageEndpoint(cov.analyzer)?.host ?? cov.analyzer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.coverage_receiptsRemove),
        content: Text(l10n.coverage_receiptsRemoveConfirm(host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.common_remove),
          ),
        ],
      ),
    );
    if (ok == true) await cov.removeMyReceipts();
  }

  /// The last send's result, or null (the help text then).
  String? _shareLine(BuildContext context, MediaMeshCoverageService cov) {
    final l10n = context.l10n;
    final s = cov.shareStatus;
    if (s == null) return null;
    final e = s.error;
    if (e == 'not-connected') return l10n.coverage_shareNotConnected;
    if (e == 'bad-address') return l10n.coverage_analyzerBad;
    if (e != null) return l10n.coverage_shareError(e);
    final when = s.at == null
        ? ''
        : ' · ${TimeOfDay.fromDateTime(s.at!).format(context)}';
    return (s.removedPoints
            ? l10n.coverage_removed(s.count)
            : l10n.coverage_sent(s.count)) +
        when;
  }

  Future<void> _confirmRemove(
    BuildContext context,
    MediaMeshCoverageService cov,
  ) async {
    final l10n = context.l10n;
    final host = coverageEndpoint(cov.analyzer)?.host ?? cov.analyzer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.coverage_removeMine),
        content: Text(l10n.coverage_removeConfirm(host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.common_remove),
          ),
        ],
      ),
    );
    if (ok == true) await cov.removeMine();
  }
}

/// Where the points go: the analyzer's address, kept when it is one.
class _AnalyzerField extends StatefulWidget {
  const _AnalyzerField({required this.cov});
  final MediaMeshCoverageService cov;

  @override
  State<_AnalyzerField> createState() => _AnalyzerFieldState();
}

class _AnalyzerFieldState extends State<_AnalyzerField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.cov.analyzer,
  );
  final FocusNode _focus = FocusNode();
  bool _bad = false;

  @override
  void didUpdateWidget(covariant _AnalyzerField old) {
    super.didUpdateWidget(old);
    // loaded from settings after the field was built
    if (!_bad && !_focus.hasFocus && _c.text != widget.cov.analyzer) {
      _c.text = widget.cov.analyzer;
    }
  }

  Future<void> _save() async {
    final ok = await widget.cov.setAnalyzer(_c.text);
    if (!mounted) return;
    setState(() => _bad = !ok);
    if (ok && _c.text.trim().isEmpty) _c.text = widget.cov.analyzer;
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _c,
        focusNode: _focus,
        keyboardType: TextInputType.url,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: l10n.coverage_analyzer,
          hintText: defaultCoverageAnalyzer,
          helperText: l10n.coverage_analyzerHelp,
          errorText: _bad ? l10n.coverage_analyzerBad : null,
          prefixIcon: const Icon(Icons.dns_outlined),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (_) => unawaited(_save()),
        onTapOutside: (_) {
          if (!_focus.hasFocus) return;
          _focus.unfocus();
          unawaited(_save());
        },
      ),
    );
  }
}
