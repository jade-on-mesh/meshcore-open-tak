import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/path_helper.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../theme/mesh_theme.dart';
import 'mesh_ui.dart';
import 'signal_ui.dart';

Contact? _getRepeaterPrefixMatchNearLocation(
  List<Contact> contacts,
  List<int> pubkeyPrefix, {
  String? contactKeyHex,
  LatLng? searchPoint,
  bool preferFavorites = false,
}) {
  if (contactKeyHex != null) {
    for (final c in contacts) {
      if (c.publicKeyHex == contactKeyHex) {
        return c;
      }
    }
  }

  final candidates = contacts
      .where(
        (c) =>
            c.publicKey.length >= pubkeyPrefix.length &&
            listEquals(
              c.publicKey.sublist(0, pubkeyPrefix.length),
              pubkeyPrefix,
            ) &&
            (c.type == advTypeRepeater || c.type == advTypeRoom),
      )
      .toList();

  if (candidates.isEmpty) return null;

  candidates.sort((a, b) {
    if (preferFavorites) {
      final favA = a.isFavorite ? 1 : 0;
      final favB = b.isFavorite ? 1 : 0;
      final favCompare = favB.compareTo(favA);
      if (favCompare != 0) return favCompare;
    }

    final seenCompare = b.lastSeen.compareTo(a.lastSeen);
    if (seenCompare != 0) return seenCompare;

    return a.publicKeyHex.compareTo(b.publicKeyHex);
  });

  if (searchPoint == null) {
    return candidates.first;
  }

  final distance = Distance();
  Contact best = candidates.first;
  var bestDistance = double.infinity;

  for (final c in candidates) {
    if (c.hasLocation && c.latitude != null && c.longitude != null) {
      final d = distance(searchPoint, LatLng(c.latitude!, c.longitude!));
      if (d < bestDistance) {
        bestDistance = d;
        best = c;
      }
    }
  }

  return best;
}

class SNRUi {
  final IconData icon;
  final Color color;
  final String text;
  const SNRUi(this.icon, this.color, this.text);
}

List<double> getSNRfromSF(int spreadingFactor) {
  switch (spreadingFactor) {
    case 7:
      return [4.0, -2.0, -4.0, -6.0];
    case 8:
      return [4.0, -4.0, -6.0, -8.0];
    case 9:
      return [4.0, -6.0, -8.0, -10.0];
    case 10:
      return [4.0, -8.0, -10.0, -13.0];
    case 11:
      return [4.0, -10.0, -12.5, -15.0];
    case 12:
      return [4.0, -12.5, -15.0, -18.0];
    default:
      return []; // Or throw Exception('Invalid SF: $spreadingFactor');
  }
}

SNRUi snrUiFromSNR(double? snr, int? spreadingFactor) {
  if (snr == null ||
      spreadingFactor == null ||
      spreadingFactor < 7 ||
      spreadingFactor > 12) {
    return const SNRUi(Icons.signal_cellular_off, Colors.grey, '—');
  }

  final snrLevels = getSNRfromSF(spreadingFactor);

  String text = '${snr.toStringAsFixed(1)} dB';
  final tier = snr >= snrLevels[0]
      ? 0
      : snr >= snrLevels[1]
      ? 1
      : snr >= snrLevels[2]
      ? 2
      : snr >= snrLevels[3]
      ? 3
      : 4;
  final signalUi = signalUiForStrengthTier(tier);

  return SNRUi(signalUi.icon, signalUi.color, text);
}

class SNRIndicator extends StatefulWidget {
  final MeshCoreConnector connector;

  const SNRIndicator({super.key, required this.connector});

  @override
  State<SNRIndicator> createState() => _SNRIndicatorState();
}

class _SNRIndicatorState extends State<SNRIndicator> {
  void _openList(List<DirectRepeater> list) =>
      NearbyRepeaters.show(context, widget.connector, list);

  @override
  Widget build(BuildContext context) {
    final directRepeaters = widget.connector.directRepeaters;
    final directBestRepeaters = List.of(directRepeaters)
      ..sort((a, b) => (b.ranking).compareTo(a.ranking));
    final directRepeater = directBestRepeaters.isEmpty
        ? null
        : directBestRepeaters.first;

    final snrUi = snrUiFromSNR(
      directBestRepeaters.isNotEmpty ? directRepeater!.snr : null,
      widget.connector.currentSf,
    );

    final stale =
        directRepeater != null &&
        DateTime.now().difference(directRepeater.lastUpdated) >
            const Duration(minutes: 10);
    final color = stale ? snrUi.color.withValues(alpha: 0.45) : snrUi.color;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      child: InkWell(
        onTap: directRepeater != null
            ? () => _openList(directBestRepeaters)
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(snrUi.icon, size: 18, color: color),
                  if (directRepeaters.length > 1)
                    Positioned(
                      right: -9,
                      top: -4,
                      child: Text(
                        '${directRepeaters.length}',
                        style: MeshTheme.mono(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: muted,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                snrUi.text,
                style: MeshTheme.mono(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The radio's direct (zero-hop) repeaters: the list dialog and helpers
/// shared by the SNR indicator and the header's repeater label.
abstract final class NearbyRepeaters {
  static bool _isValidSelfLocation(double lat, double lon) {
    const double epsilon = 1e-6;
    return (lat.abs() > epsilon || lon.abs() > epsilon) &&
        lat >= -90.0 &&
        lat <= 90.0 &&
        lon >= -180.0 &&
        lon <= 180.0;
  }

  static LatLng? _selfPoint(MeshCoreConnector c) {
    final lat = c.selfLatitude, lon = c.selfLongitude;
    if (lat == null || lon == null) return null;
    return _isValidSelfLocation(lat, lon) ? LatLng(lat, lon) : null;
  }

  static String age(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);
    if (diff.isNegative) {
      return "0s";
    }
    if (diff.inMinutes < 1) {
      return "${diff.inSeconds}s";
    }
    if (diff.inMinutes < 60) {
      return "${diff.inMinutes}m";
    }
    if (diff.inHours < 24) {
      final hours = diff.inHours;
      return "${hours}h";
    }
    final days = diff.inDays;
    return "${days}d";
  }

  static void show(
    BuildContext context,
    MeshCoreConnector connector,
    List<DirectRepeater> directBestRepeaters,
  ) {
    final l10n = context.l10n;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.snrIndicator_nearByRepeaters),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.snrIndicator_nearByRepeatersDescription,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Scrollbar(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: directBestRepeaters.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final repeater = directBestRepeaters[index];
                      final allContacts = connector.allContacts;

                      final selfLat = connector.selfLatitude;
                      final selfLon = connector.selfLongitude;

                      LatLng? selfPoint;
                      if (selfLat != null &&
                          selfLon != null &&
                          _isValidSelfLocation(selfLat, selfLon)) {
                        selfPoint = LatLng(selfLat, selfLon);
                      }

                      final contact = _getRepeaterPrefixMatchNearLocation(
                        allContacts,
                        repeater.pubkeyPrefix,
                        contactKeyHex: repeater.contactKeyHex,
                        searchPoint: selfPoint,
                        preferFavorites: true,
                      );

                      final name = contact?.name;
                      final prefixLabel = PathHelper.formatHopHex(
                        repeater.pubkeyPrefix,
                      );
                      final snrColor = MeshTheme.snrColor(
                        repeater.snr,
                        blocked: false,
                      );
                      final colorScheme = Theme.of(context).colorScheme;

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            AvatarCircle(
                              name: name ?? prefixLabel,
                              size: 36,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name ?? prefixLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colorScheme.onSurface,
                                        ),
                                  ),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.circle,
                                        size: 8,
                                        color: snrColor,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${repeater.snr.toStringAsFixed(1)} dB • ${age(repeater.lastUpdated)}',
                                        style: MeshTheme.mono(
                                          fontSize: 12,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_close),
          ),
        ],
      ),
    );
  }
}

/// The best direct repeater in tiny type for the header: its name, then
/// how many repeaters are direct, its prefix and how long since it was heard.
/// Tap for the full list.
class RepeaterLabel extends StatefulWidget {
  final MeshCoreConnector connector;

  const RepeaterLabel({super.key, required this.connector});

  @override
  State<RepeaterLabel> createState() => _RepeaterLabelState();
}

class _RepeaterLabelState extends State<RepeaterLabel> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps the "heard ago" age current between radio updates.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connector = widget.connector;
    final repeaters = List.of(connector.directRepeaters)
      ..sort((a, b) => b.ranking.compareTo(a.ranking));
    if (repeaters.isEmpty) return const SizedBox.shrink();
    final best = repeaters.first;
    final name = _getRepeaterPrefixMatchNearLocation(
      connector.allContacts,
      best.pubkeyPrefix,
      contactKeyHex: best.contactKeyHex,
      searchPoint: NearbyRepeaters._selfPoint(connector),
      preferFavorites: true,
    )?.name;
    final scheme = Theme.of(context).colorScheme;
    final details = [
      '${repeaters.length}',
      if (name != null) best.pubkeyPrefixHex,
      NearbyRepeaters.age(best.lastUpdated),
    ].join(' · ');

    return InkWell(
      onTap: () => NearbyRepeaters.show(context, connector, repeaters),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name ?? best.pubkeyPrefixHex,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                details,
                style: MeshTheme.mono(
                  fontSize: 9,
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
