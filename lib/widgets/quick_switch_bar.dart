import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../team/team_screen.dart';
import '../team/team_service.dart';
import '../team/watch_feed.dart';
import '../theme/mesh_theme.dart';

class QuickSwitchBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final int contactsUnreadCount;
  final int channelsUnreadCount;
  final bool highContrast;

  const QuickSwitchBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.contactsUnreadCount = 0,
    this.channelsUnreadCount = 0,
    this.highContrast = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium ?? const TextStyle();
    final background = highContrast ? MapPalette.panelDark : Colors.transparent;
    // The selected icon sits on the primary indicator pill, so it uses
    // onPrimary. The label sits below on the bar background, so it must use a
    // foreground color that contrasts with the surface (not onPrimary, which
    // is white-on-white in the light theme).
    final selectedIconColor = highContrast
        ? MapPalette.textPrimary
        : colorScheme.onPrimary;
    final selectedLabelColor = highContrast
        ? MapPalette.textPrimary
        : colorScheme.onSurface;
    final unselectedColor = highContrast
        ? MapPalette.textSecondary
        : colorScheme.onSurfaceVariant;
    final indicator = highContrast ? MapPalette.selected : colorScheme.primary;

    return SizedBox(
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border.all(
                color: highContrast
                    ? MapPalette.border
                    : colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                indicatorColor: indicator,
                labelTextStyle: WidgetStateProperty.resolveWith((states) {
                  final isSelected = states.contains(WidgetState.selected);
                  return labelStyle.copyWith(
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? selectedLabelColor : unselectedColor,
                  );
                }),
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  final isSelected = states.contains(WidgetState.selected);
                  return IconThemeData(
                    color: isSelected ? selectedIconColor : unselectedColor,
                  );
                }),
              ),
              child: NavigationBar(
                height: 60,
                selectedIndex: selectedIndex,
                onDestinationSelected: (i) {
                  // Tactical opens as its own screen rather than a tab.
                  if (i == 3) {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        // From the map, Tactical's Map tab goes back to it.
                        builder: (_) => TeamScreen(fromMap: selectedIndex == 2),
                      ),
                    );
                    return;
                  }
                  onDestinationSelected(i);
                },
                destinations: [
                  NavigationDestination(
                    icon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.people_outline),
                      contactsUnreadCount,
                    ),
                    selectedIcon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.people),
                      contactsUnreadCount,
                    ),
                    label: context.l10n.nav_contacts,
                  ),
                  NavigationDestination(
                    icon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.tag),
                      channelsUnreadCount,
                    ),
                    selectedIcon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.tag),
                      channelsUnreadCount,
                    ),
                    label: context.l10n.nav_channels,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.map_outlined),
                    selectedIcon: const Icon(Icons.map),
                    label: context.l10n.nav_map,
                  ),
                  NavigationDestination(
                    icon: _TacticalIcon(alertColor: colorScheme.error),
                    label: 'Tactical',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconWithBadge(BuildContext context, Icon icon, int count) {
    if (count <= 0) return icon;
    final label = count > 99 ? '99+' : '$count';
    return Badge(label: Text(label), child: icon);
  }
}

/// Tactical tab icon: red badge for active team alerts, otherwise the count
/// of new watch-feed reports.
class _TacticalIcon extends StatelessWidget {
  final Color alertColor;
  const _TacticalIcon({required this.alertColor});

  @override
  Widget build(BuildContext context) {
    var alerts = 0, unseen = 0;
    try {
      alerts = context.select<TeamService, int>((t) => t.activeAlerts.length);
      unseen = context.select<WatchFeedService, int>((w) => w.unseenCount);
    } on ProviderNotFoundException {
      // Screens shown without the team services (e.g. in tests).
    }
    const icon = Icon(Icons.shield_outlined);
    if (alerts > 0) {
      return Badge(
        backgroundColor: alertColor,
        label: const Text('SOS'),
        child: icon,
      );
    }
    if (unseen > 0) {
      return Badge(label: Text(unseen > 99 ? '99+' : '$unseen'), child: icon);
    }
    return icon;
  }
}
