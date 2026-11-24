import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../screens/channel_chat_screen.dart';
import '../screens/chat_screen.dart';
import 'notification_reply.dart';
import 'notification_service.dart';

/// Opens the conversation behind a tapped message notification instead of
/// leaving the user on whatever screen they last had open.
///
/// A channel notification names the message it shows, and the chat opens
/// scrolled to it (highlighted briefly); a channel already open just scrolls.
///
/// Needs the radio's contacts/channels (live or the saved copy). A tap that
/// arrives before they are there (the app launched by the tap) waits for them
/// for up to [_waitForRadio], then is dropped.
class NotificationNavigator {
  /// Asks the open [ChannelChatScreen] of `index` to scroll to `messageId`.
  static final ValueNotifier<({int index, String messageId})?> channelJump =
      ValueNotifier(null);

  static const Duration _waitForRadio = Duration(minutes: 2);

  final GlobalKey<NavigatorState> navigatorKey;
  final MeshCoreConnector connector;
  final NotificationService notifications;

  NotificationNavigator({
    required this.navigatorKey,
    required this.connector,
    required this.notifications,
  });

  String? _waiting;
  DateTime? _waitingSince;
  bool _listening = false;

  void attach() {
    notifications.pendingTap.addListener(_handleTap);
    _handleTap();
  }

  void dispose() {
    notifications.pendingTap.removeListener(_handleTap);
    _stopWaiting();
  }

  void _handleTap() {
    final payload = notifications.pendingTap.value;
    if (payload == null) return;
    notifications.pendingTap.value = null;
    _waiting = payload;
    _waitingSince = DateTime.now();
    _tryOpen();
  }

  void _tryOpen() {
    final payload = _waiting;
    if (payload == null) return _stopWaiting();
    if (DateTime.now().difference(_waitingSince!) > _waitForRadio) {
      _waiting = null;
      return _stopWaiting();
    }
    final navigator = navigatorKey.currentState;
    // Offline the last radio's saved chats still open (read-only).
    if (navigator == null || !connector.hasRadioData) {
      if (!_listening) {
        _listening = true;
        connector.addListener(_tryOpen);
      }
      // The navigator may only be missing for this frame.
      if (navigator == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _tryOpen());
      }
      return;
    }
    _waiting = null;
    _stopWaiting();

    final sep = payload.indexOf(':');
    if (sep <= 0) return;
    final kind = payload.substring(0, sep);
    final value = payload.substring(sep + 1);

    if (kind == 'message') {
      if (connector.activeContactKey == value) return;
      final contact = connector.getContactByPubKeyHex(value);
      if (contact == null ||
          (contact.type != advTypeChat && contact.type != advTypeRoom)) {
        return;
      }
      final unread = connector.getUnreadCountForContactKey(value);
      connector.markContactRead(value);
      navigator.push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(contact: contact, initialUnreadCount: unread),
        ),
      );
    } else if (kind == 'channel') {
      final parsed = parseChannelNotificationPayload(value);
      if (parsed == null) return;
      final index = parsed.index;
      final messageId = parsed.messageId;
      if (connector.activeChannelIndex == index) {
        if (messageId != null) {
          channelJump.value = (index: index, messageId: messageId);
        }
        return;
      }
      final channel = connector.channels
          .where((c) => c.index == index)
          .firstOrNull;
      if (channel == null) return;
      final unread = connector.getUnreadCountForChannelIndex(index);
      connector.markChannelRead(index);
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChannelChatScreen(
            channel: channel,
            initialUnreadCount: unread,
            initialMessageId: messageId,
          ),
        ),
      );
    }
  }

  void _stopWaiting() {
    if (!_listening) return;
    _listening = false;
    connector.removeListener(_tryOpen);
  }
}
