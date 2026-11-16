import 'package:flutter/material.dart';

import '../screens/channels_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/map_screen.dart';
import 'route_transitions.dart';

/// Shows the main screens as the only route once a radio has connected.
void navigateToMainAfterConnect(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const ChannelsScreen()),
    (_) => false,
  );
}

/// The main tabs, left to right in the bottom bar. Tactical opens as a screen
/// of its own (QuickSwitchBar does that).
abstract final class MainTab {
  static const contacts = 0;
  static const nodes = 1;
  static const channels = 2;
  static const map = 3;
  static const tactical = 4;
}

/// Switches to main tab [index] from tab [current]: replaces this screen with
/// that tab's, as the bottom bar does. Nothing for the tab already showing.
void switchMainTab(BuildContext context, int index, {required int current}) {
  FocusManager.instance.primaryFocus?.unfocus();
  if (index == current) return;
  final Widget? page = switch (index) {
    MainTab.contacts => const ContactsScreen(hideBackButton: true),
    MainTab.nodes => const ContactsScreen(
      hideBackButton: true,
      scope: ContactsScope.nodes,
    ),
    MainTab.channels => const ChannelsScreen(hideBackButton: true),
    MainTab.map => const MapScreen(hideBackButton: true),
    _ => null,
  };
  if (page == null) return;
  Navigator.pushReplacement(context, buildQuickSwitchRoute(page));
}
