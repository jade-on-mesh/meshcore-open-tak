import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../services/notification_service.dart';
import '../theme/mesh_theme.dart';
import '../utils/main_navigation.dart';
import '../review_mode/review_mode_banner.dart';
import '../vox/voice_wire.dart';
import '../widgets/app_bar.dart';
import '../widgets/empty_state.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/quick_switch_bar.dart';
import '../widgets/sync_progress_overlay.dart';
import '../widgets/unread_badge.dart';
import 'chat_screen.dart';

/// One person's direct conversation, as the DMs tab lists it.
@visibleForTesting
class DmConversation {
  final Contact contact;
  final int unread;
  final Message? last;

  const DmConversation({required this.contact, required this.unread, this.last});

  /// When it last moved: the newest message's local arrival time, else when
  /// a message was last noted for the contact.
  DateTime get lastAt => last?.receivedAt ?? contact.lastMessageAt;
}

/// The DMs tab's two groups: conversations with unread messages (newest
/// first), then the rest (newest first). People only: room servers' chats
/// are on the Nodes tab. A person with no messages isn't listed.
@visibleForTesting
({List<DmConversation> unread, List<DmConversation> read}) groupDmConversations(
  Iterable<DmConversation> all, {
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  final unread = <DmConversation>[];
  final read = <DmConversation>[];
  for (final c in all) {
    if (isNodeContactType(c.contact.type)) continue;
    if (c.last == null && c.unread == 0) continue;
    if (q.isNotEmpty && !c.contact.name.toLowerCase().contains(q)) continue;
    (c.unread > 0 ? unread : read).add(c);
  }
  int newestFirst(DmConversation a, DmConversation b) =>
      b.lastAt.compareTo(a.lastAt);
  unread.sort(newestFirst);
  read.sort(newestFirst);
  return (unread: unread, read: read);
}

/// The DMs tab (far left of the bottom bar): every direct conversation with a
/// person, unread ones pinned on top, so an unread message is never lost
/// among the contacts.
class DmsScreen extends StatefulWidget {
  final bool hideBackButton;

  const DmsScreen({super.key, this.hideBackButton = false});

  @override
  State<DmsScreen> createState() => _DmsScreenState();
}

class _DmsScreenState extends State<DmsScreen> {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(Contact contact) {
    final connector = context.read<MeshCoreConnector>();
    final unread = connector.getUnreadCountForContactKey(contact.publicKeyHex);
    connector.markContactRead(contact.publicKeyHex);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(contact: contact, initialUnreadCount: unread),
      ),
    );
  }

  void _markAllRead(List<DmConversation> unread) {
    final connector = context.read<MeshCoreConnector>();
    for (final c in unread) {
      connector.markContactRead(c.contact.publicKeyHex);
    }
  }

  String _relativeTime(AppLocalizations l10n, DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return l10n.channels_timeNow;
    if (diff.inMinutes < 60) return l10n.channels_timeMinutes(diff.inMinutes);
    if (diff.inHours < 24) return l10n.channels_timeHours(diff.inHours);
    return l10n.channels_timeDays(diff.inDays);
  }

  String _preview(AppLocalizations l10n, Message? m) {
    if (m == null) return '';
    final raw = m.displayText.trim();
    final text =
        VoxVoiceEnvelope.previewText(raw) ??
        NotificationService.formatNotificationText(raw, l10n);
    return m.isOutgoing ? l10n.dms_youPrefix(text) : text;
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final l10n = context.l10n;
    final groups = groupDmConversations([
      for (final contact in connector.contacts)
        DmConversation(
          contact: contact,
          unread: connector.getUnreadCountForContactKey(contact.publicKeyHex),
          last: connector.getMessages(contact).lastOrNull,
        ),
    ], query: _searching ? _search.text : '');
    final unreadTotal = connector.getTotalPeopleUnreadCount();
    final scheme = Theme.of(context).colorScheme;

    final children = <Widget>[];
    if (groups.unread.isNotEmpty) {
      children.add(
        SectionHeader(
          l10n.dms_unreadSection,
          trailing: TextButton(
            onPressed: () => _markAllRead(groups.unread),
            child: Text(l10n.dms_markAllRead),
          ),
        ),
      );
      for (final c in groups.unread) {
        children.add(_tile(context, c, l10n));
      }
    } else if (groups.read.isNotEmpty && !_searching) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.dms_noneUnread,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (groups.read.isNotEmpty) {
      children.add(
        SectionHeader(
          groups.unread.isEmpty
              ? l10n.dms_recentSection
              : l10n.dms_earlierSection,
        ),
      );
      for (final c in groups.read) {
        children.add(_tile(context, c, l10n));
      }
    }

    return PopScope(
      canPop: !connector.isConnected,
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.dms_search,
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}),
                )
              : AppBarTitle(l10n.dms_title),
          centerTitle: !_searching,
          automaticallyImplyLeading: !widget.hideBackButton,
          bottom: const SyncProgressAppBarBottom(),
          actions: [
            IconButton(
              tooltip: _searching ? l10n.dms_closeSearch : l10n.dms_search,
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              }),
            ),
          ],
        ),
        body: Column(
          children: [
            const ReviewModeBanner(),
            Expanded(
              child: children.isEmpty
                  ? EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: _searching ? l10n.dms_noMatches : l10n.dms_empty,
                      subtitle: _searching ? null : l10n.dms_emptyHint,
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: children,
                    ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: QuickSwitchBar(
            selectedIndex: MainTab.dms,
            onDestinationSelected: (index) =>
                switchMainTab(context, index, current: MainTab.dms),
            dmsUnreadCount: unreadTotal,
            nodesUnreadCount: connector.getTotalNodesUnreadCount(),
            channelsUnreadCount: connector.getTotalChannelsUnreadCount(),
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, DmConversation c, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final unread = c.unread > 0;
    final preview = _preview(l10n, c.last);
    return MeshCard(
      key: ValueKey('dm_${c.contact.publicKeyHex}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: () => _open(c.contact),
      child: Row(
        children: [
          AvatarCircle(
            name: c.contact.name,
            size: 44,
            photoKey: c.contact.publicKeyHex,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.contact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _relativeTime(l10n, c.lastAt),
                      style: MeshTheme.mono(
                        fontSize: 12,
                        color: unread ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (preview.isNotEmpty || unread) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: unread
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        UnreadBadge(count: c.unread),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
