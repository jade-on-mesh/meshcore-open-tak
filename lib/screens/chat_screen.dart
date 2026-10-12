import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/cyr2lat.dart';
import '../helpers/message_url_image_helper.dart';
import '../helpers/path_helper.dart';
import '../helpers/reaction_helper.dart';
import '../widgets/message_status_icon.dart';
import '../widgets/empty_state.dart';
import '../helpers/chat_scroll_controller.dart';
import '../helpers/gif_helper.dart';
import '../models/channel_message.dart';
import '../models/contact.dart';
import '../l10n/contact_localization.dart';
import '../models/message.dart';
import '../models/otp_theme.dart';
import '../models/translation_support.dart';
import '../services/app_settings_service.dart';
import '../services/chat_text_scale_service.dart';
import '../services/image_chunk_transport.dart';
import '../services/image_codec_service.dart';
import '../services/otp_chunk_service.dart';
import '../services/otp_service.dart';
import '../services/path_history_service.dart';
import '../services/received_image_store.dart';
import '../services/translation_service.dart';
import '../theme/mesh_theme.dart';
import '../theme/otp_bubble_colors.dart';
import '../widgets/chat_zoom_wrapper.dart';
import '../widgets/byte_count_input.dart';
import '../widgets/chat_day_separator.dart';
import 'app_settings_screen.dart';
import 'channel_message_path_screen.dart';
import 'map_screen.dart';
import 'otp_pad_screen.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/gif_message.dart';
import '../widgets/image_send_codec_binding.dart';
import '../widgets/image_send_preview_sheet.dart';
import '../widgets/jump_to_bottom_button.dart';
import '../widgets/gif_picker.dart';
import '../widgets/message_translation_button.dart';
import '../widgets/received_image_message.dart';
import '../widgets/routing_sheet.dart';
import '../widgets/radio_stats_entry.dart';
import '../widgets/signal_grade_indicator.dart';
import '../widgets/sync_progress_overlay.dart';
import '../widgets/translated_message_content.dart';
import '../l10n/l10n.dart';
import '../helpers/snack_bar_builder.dart';
import '../widgets/unread_divider.dart';
import '../widgets/mesh_ui.dart';
import 'telemetry_screen.dart';
import '../vox/image_send_sheet.dart';
import '../vox/voice_message_bubble.dart';
import '../vox/voice_record_sheet.dart';
import '../vox/voice_service.dart';
import '../vox/voice_wire.dart';

// Image messages here do NOT use the channel image feature's wire format:
// AEIC-over-GRP_DATA (`CMD_SEND_CHANNEL_DATA` 62 / GRP_DATA 0x06) addresses a
// channel index, not a contact key, and the companion protocol has no
// direct-message equivalent for it (there is no CMD_SEND_DATA — see
// `meshcore_protocol.dart`); sending a private photo on channel 0 to reach
// one contact would broadcast it to everyone on that channel. Instead, an
// OTP-enabled DM sends the same neural-codec bitstream (see
// `image_codec_service.dart`) OTP-encrypted, chunked over the ordinary OTP
// DM text-chunk pipeline (`otp_image_transport.dart` /
// `MeshCoreConnector.sendOtpImageToContact`) — never over GRP_DATA — so it is
// only available when OTP is enabled for this contact, unlike the channel
// feature.

class ChatScreen extends StatefulWidget {
  final Contact contact;
  final int initialUnreadCount;

  const ChatScreen({
    super.key,
    required this.contact,
    this.initialUnreadCount = 0,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ChatScrollController();
  final _textFieldFocusNode = FocusNode();
  final GlobalKey _unreadScrollKey = GlobalKey();
  bool _isLoadingOlder = false;
  MeshCoreConnector? _connector;
  Message? _pendingUnreadScrollTarget;
  String? _unreadDividerMessageId;
  DateTime? _lastTextSendAt;
  // OTP DM image send progress — mirrors channel_chat_screen.dart's own
  // _imageSendTotal/_imageSendSent, but this is chunk progress from the OTP
  // chunk-ack pipeline, not GRP_DATA blob-send progress.
  bool _sendingOtpImage = false;

  @override
  void initState() {
    super.initState();
    _textFieldFocusNode.addListener(_onTextFieldFocusChange);
    _scrollController.onScrollNearTop = _loadOlderMessages;
    _scrollController.showJumpToBottom.addListener(_clearDividerAtBottom);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final connector = context.read<MeshCoreConnector>();
      final settings = context.read<AppSettingsService>().settings;
      final keyHex = widget.contact.publicKeyHex;
      final unread = widget.initialUnreadCount;
      final messages = connector.getMessages(widget.contact);
      Message? anchor;
      if (unread > 0) {
        anchor = _findOldestUnreadAnchor(messages, unread);
      }
      setState(() {
        if (anchor != null) _unreadDividerMessageId = anchor.messageId;
        if (anchor != null && settings.jumpToOldestUnread) {
          _pendingUnreadScrollTarget = anchor;
        }
      });
      connector.setActiveContact(keyHex);
      _connector = connector;
      if (anchor != null && settings.jumpToOldestUnread) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollController.jumpToEstimatedOffset(
            unreadCount: unread,
            totalMessages: messages.length,
            onJumped: () async {
              if (!mounted) return;
              final ctx = _unreadScrollKey.currentContext;
              if (ctx != null) {
                await Scrollable.ensureVisible(
                  ctx,
                  duration: const Duration(milliseconds: 350),
                  alignment: 0.15,
                );
              }
              if (mounted) {
                setState(() => _pendingUnreadScrollTarget = null);
              }
            },
          );
        });
      }
    });
  }

  Message? _findOldestUnreadAnchor(List<Message> messages, int unreadCount) {
    if (unreadCount <= 0 || messages.isEmpty) return null;
    var n = 0;
    Message? oldest;
    for (final m in messages.reversed) {
      if (m.isOutgoing || m.isCli) continue;
      n++;
      oldest = m;
      if (n >= unreadCount) break;
    }
    return oldest;
  }

  void _clearDividerAtBottom() {
    if (!_scrollController.showJumpToBottom.value &&
        _unreadDividerMessageId != null) {
      setState(() => _unreadDividerMessageId = null);
    }
  }

  void _onTextFieldFocusChange() {
    if (_textFieldFocusNode.hasFocus && mounted) {
      _scrollController.handleKeyboardOpen();
      // About to type a reply — check the pad's still in sync now,
      // before any bytes get spent, rather than only finding out after
      // a send fails to decrypt on the other end.
      _connector?.notifyComposeStartedForContact(widget.contact.publicKeyHex);
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder) return;
    setState(() => _isLoadingOlder = true);

    final connector = context.read<MeshCoreConnector>();
    await connector.loadOlderMessages(widget.contact.publicKeyHex);

    if (mounted) {
      setState(() => _isLoadingOlder = false);
    }
  }

  @override
  void dispose() {
    _connector?.setActiveContact(null);
    _scrollController.showJumpToBottom.removeListener(_clearDividerAtBottom);
    _textFieldFocusNode.removeListener(_onTextFieldFocusChange);
    _textFieldFocusNode.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer2<PathHistoryService, MeshCoreConnector>(
          builder: (context, pathService, connector, _) {
            final contact = _resolveContact(connector);
            final pathLabel = _currentPathLabel(contact);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  contact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      ContactRoutingSheet.show(context, contact: contact),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      pathLabel,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.normal,
                        decoration: TextDecoration.underline,
                        decorationStyle: TextDecorationStyle.dotted,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        centerTitle: false,
        bottom: const SyncProgressAppBarBottom(),
        actions: [
          const SignalGradeIndicator(),
          const RadioStatsIconButton(),
          Consumer<MeshCoreConnector>(
            builder: (context, connector, _) {
              final contact = _resolveContact(connector);
              final otpEnabled = connector.isContactOtpEnabled(
                contact.publicKeyHex,
              );
              if (!otpEnabled) return const SizedBox.shrink();
              // Ports OTP_3_RC1.lua's chat-screen "ReSync" button: force-
              // reload this contact's pad from storage (discarding
              // whatever's cached — see resyncContact's own doc comment)
              // and fire an immediate, unthrottled sync-check, without
              // waiting for the next periodic/backed-off automatic one.
              return IconButton(
                tooltip: 'ReSync',
                icon: const Icon(Icons.sync),
                onPressed: () {
                  final ok = connector.resyncContact(contact.publicKeyHex);
                  showDismissibleSnackBar(
                    context,
                    content: Text(
                      ok
                          ? 'Pad reloaded — sync check sent'
                          : 'No OTP pad for this contact',
                    ),
                  );
                },
              );
            },
          ),
          Consumer<MeshCoreConnector>(
            builder: (context, connector, _) {
              final contact = _resolveContact(connector);
              final otpEnabled = connector.isContactOtpEnabled(
                contact.publicKeyHex,
              );
              return IconButton(
                tooltip: otpEnabled ? 'OTP Pad (encrypting)' : 'OTP Pad',
                icon: Icon(
                  otpEnabled ? Icons.lock : Icons.lock_open,
                  color: otpEnabled ? MeshPalette.blue : null,
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OtpPadScreen.forContact(contact),
                  ),
                ),
              );
            },
          ),
          Consumer<MeshCoreConnector>(
            builder: (context, connector, _) {
              final contact = _resolveContact(connector);

              return PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'routing':
                      ContactRoutingSheet.show(context, contact: contact);
                    case 'info':
                      _showContactInfo(context);
                    case 'settings':
                      _showContactSettings(context);
                    case 'telemetry':
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              TelemetryScreen(contact: widget.contact),
                        ),
                      );
                    case 'clearChat':
                      _confirmClearChat(context, connector);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'routing',
                    child: Row(
                      children: [
                        const Icon(Icons.route, size: 20),
                        const SizedBox(width: 12),
                        Text(context.l10n.routing_title),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'info',
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 20),
                        const SizedBox(width: 12),
                        Text(context.l10n.contact_info),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'telemetry',
                    child: Row(
                      children: [
                        const Icon(Icons.bar_chart, size: 20),
                        const SizedBox(width: 12),
                        Text(context.l10n.contact_telemetry),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Row(
                      children: [
                        const Icon(Icons.settings, size: 20),
                        const SizedBox(width: 12),
                        Text(context.l10n.contact_settings),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'clearChat',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete,
                          size: 20,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          context.l10n.contact_clearChat,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Consumer<MeshCoreConnector>(
        builder: (context, connector, child) {
          final messages = connector.getMessages(widget.contact);
          return Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    messages.isEmpty
                        ? _buildEmptyState()
                        : _buildMessageList(messages, connector),
                    JumpToBottomButton(scrollController: _scrollController),
                  ],
                ),
              ),
              _buildPadStatusBar(connector),
              _buildInputBar(connector),
            ],
          );
        },
      ),
    );
  }

  // Matches the Wadamesh/Lua app's live "N bytes available" line just above
  // the compose box (see refresh_chat_bytes() in OTP_3_RC1.lua) — this app
  // otherwise only surfaces the pad budget on a separate screen (the lock
  // icon → OtpPadScreen), one tap away and not visible while actually
  // composing. Only shown for an OTP-enabled contact; hidden entirely
  // otherwise, unlike Lua where the whole app is OTP-only.
  static const int _padLowBytesThreshold = 100;

  Widget _buildPadStatusBar(MeshCoreConnector connector) {
    final contact = _resolveContact(connector);
    if (!connector.isContactOtpEnabled(contact.publicKeyHex)) {
      return const SizedBox.shrink();
    }
    final pad = connector.getContactOtpPad(contact.publicKeyHex);
    if (pad == null) return const SizedBox.shrink();
    final remaining = pad.myBytesRemaining;
    final scheme = Theme.of(context).colorScheme;
    // Text matches Lua's refresh_chat_bytes() byte-for-byte ("%d bytes
    // available" + " - pad exhausted"/" - running low") so a screenshot from
    // either app reads identically — this is what Jade compares side by
    // side when diagnosing pad issues across platforms. Color escalation
    // (tertiary/error) is a Flutter-only enhancement Lua's label doesn't
    // have; keeping it doesn't break the text parity.
    final String label;
    final Color color;
    if (remaining <= 0) {
      label = '$remaining bytes available - pad exhausted';
      color = scheme.error;
    } else if (remaining < _padLowBytesThreshold) {
      label = '$remaining bytes available - running low';
      color = scheme.tertiary;
    } else {
      label = '$remaining bytes available';
      color = scheme.onSurfaceVariant;
    }
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 3),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }

  // Mirrors OTP_3_RC1.lua's compose_counter_text()/update_compose_preview_and_counter()
  // format exactly: "<headroom before single-shot cap> | <typed>/<pad avail>"
  // plus " (N chunks)" once typed exceeds the single-shot threshold, colored
  // red once typed exceeds the CURRENT pad balance (not just the chunking
  // cap). Lua's own "remaining" figure is headroom-before-cap clamped at 0,
  // not the pad balance — the pad balance is the counter's third number.
  // This is deliberately a different shape than the generic
  // ByteCountedTextField default ("used / max against the hard chunking
  // cap") so the two apps' live compose counters read identically.
  String _otpComposeCounterText(
    MeshCoreConnector connector,
    String contactKeyHex,
    int used,
  ) {
    final singleShotCap = OtpService.maxPlaintextBytesForContact();
    final pad = connector.getContactOtpPad(contactKeyHex);
    final avail = pad?.myBytesRemaining ?? 0;
    final headroom = (singleShotCap - used).clamp(0, singleShotCap);
    var text = '$headroom | $used/$avail';
    if (used > singleShotCap) {
      final perChunk = singleShotCap - OtpChunkService.chunkOverheadBytes;
      if (perChunk > 0) {
        final chunks = (used / perChunk).ceil().clamp(1, 255);
        text += ' ($chunks chunks)';
      }
    }
    return text;
  }

  Color _otpComposeCounterColor(
    MeshCoreConnector connector,
    String contactKeyHex,
    int used,
    Color defaultColor,
  ) {
    final pad = connector.getContactOtpPad(contactKeyHex);
    final avail = pad?.myBytesRemaining ?? 0;
    return used > avail
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.chat_bubble_outline,
      title: context.l10n.chat_noMessages,
      subtitle: context.l10n.chat_sendMessageTo(
        _resolveContact(context.read<MeshCoreConnector>()).name,
      ),
    );
  }

  Widget _buildMessageList(
    List<Message> messages,
    MeshCoreConnector connector,
  ) {
    // Reverse messages so newest appear at bottom with reverse: true
    final reversedMessages = messages.reversed.toList();
    final itemCount = reversedMessages.length + (_isLoadingOlder ? 1 : 0);

    // Auto-scroll to bottom if user is already at bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pendingUnreadScrollTarget != null) return;
      _scrollController.scrollToBottomIfAtBottom();
    });

    return ChatZoomWrapper(
      child: ListView.builder(
        reverse: true, // List grows from bottom up
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          // Loading indicator now appears at end (bottom) of reversed list
          if (_isLoadingOlder && index == itemCount - 1) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final messageIndex = index;
          Contact contact = _resolveContact(connector);
          final bool isRoom = contact.type == advTypeRoom;
          final message = reversedMessages[messageIndex];
          String fourByteHex = '';
          Contact? roomAuthor;
          if (isRoom) {
            // Room-server messages carry the original author's 4-byte prefix
            // separately from message.text; use it only for resolving the name.
            roomAuthor = _resolveContactFrom4Bytes(
              connector,
              message.fourByteRoomContactKey.isEmpty
                  ? Uint8List.fromList([0, 0, 0, 0])
                  : message.fourByteRoomContactKey,
            );
            fourByteHex = message.fourByteRoomContactKey
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase();
            // Only adopt the author identity when we actually know them; never
            // fall back to the room server's own name as the sender.
            if (roomAuthor != null) contact = roomAuthor;
          }

          return Builder(
            builder: (context) {
              final textScale = context.select<ChatTextScaleService, double>(
                (service) => service.scale,
              );
              final bubble = _MessageBubble(
                message: message,
                senderName: isRoom
                    ? (roomAuthor != null
                          ? "${roomAuthor.name} [$fourByteHex]"
                          : "[$fourByteHex]")
                    : contact.name,
                sourceId: widget.contact.publicKeyHex,
                textScale: textScale,
                onLongPress: () => _showMessageActions(message, contact),
                onRetryReaction: (msg, emoji) =>
                    _sendReaction(msg, contact, emoji),
              );
              final isUnreadAnchor =
                  _unreadDividerMessageId != null &&
                  message.messageId == _unreadDividerMessageId;
              final startsDay =
                  messageIndex == reversedMessages.length - 1 ||
                  !isSameChatDay(
                    reversedMessages[messageIndex + 1].timestamp,
                    message.timestamp,
                  );
              final child = isUnreadAnchor || startsDay
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (startsDay) ChatDaySeparator(day: message.timestamp),
                        if (isUnreadAnchor) const UnreadDivider(),
                        bubble,
                      ],
                    )
                  : bubble;
              if (identical(message, _pendingUnreadScrollTarget)) {
                return KeyedSubtree(key: _unreadScrollKey, child: child);
              }
              return child;
            },
          );
        },
      ),
    );
  }

  void _markAsUnread(Message message) {
    final connector = context.read<MeshCoreConnector>();
    final messages = connector.getMessages(widget.contact);
    var count = 0;
    var found = false;
    for (final m in messages) {
      if (m.messageId == message.messageId) found = true;
      if (found && !m.isOutgoing && !m.isCli) count++;
    }
    connector.setContactUnreadCount(widget.contact.publicKeyHex, count);
  }

  Widget _buildInputBar(MeshCoreConnector connector) {
    final contactKeyHex = _resolveContact(connector).publicKeyHex;
    final otpEnabled = connector.isContactOtpEnabled(contactKeyHex);
    final maxBytes = otpEnabled
        // Longer OTP messages now get automatically split into multiple
        // packets (see otp_chunk_service.dart), so the compose-box limit is
        // the much larger multi-chunk cap, not the single-packet one.
        ? OtpChunkService.maxChunkedPlaintextBytesForContact()
        : maxContactMessageBytes();
    final scheme = Theme.of(context).colorScheme;
    final settings = context.watch<AppSettingsService>().settings;
    // Only ever offered on an OTP-enabled DM: the codec bitstream rides the
    // OTP chunk-send pipeline (see the note at the top of this file), which
    // has nothing to encrypt with otherwise.
    final showImageAction =
        otpEnabled && !_sendingOtpImage && connector.canSendOtpImageToContact(contactKeyHex);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.gif_box_outlined),
                tooltip: context.l10n.chat_sendGif,
                onPressed: () => _showGifPicker(context),
              ),
              if (showImageAction)
                IconButton(
                  icon: const Icon(Icons.enhanced_encryption_outlined),
                  tooltip: context.l10n.chat_sendImageLora,
                  onPressed:
                      _imageCodec?.availability == ImageCodecAvailability.ready
                      ? () => _showOtpImageSendPreview(connector)
                      : null,
                ),
              VoxImageButton(
                recipientLabel: _resolveContact(connector).name,
                onSend: (image) => context
                    .read<VoxVoiceService>()
                    .sendImageToContact(_resolveContact(connector), image),
              ),
              VoxMicButton(
                recipientLabel: _resolveContact(connector).name,
                codecTarget: VoxVoiceService.contactTarget(
                  _resolveContact(connector),
                ),
                onSend: (clip) => context
                    .read<VoxVoiceService>()
                    .sendClipToContact(_resolveContact(connector), clip),
              ),
              if (settings.translationEnabled)
                MessageTranslationButton(
                  enabled: settings.composerTranslationEnabled,
                  languageCode: settings.translationTargetLanguageCode,
                  onPressed: _showTranslationOptions,
                ),
              // No image button here: the image wire format is GRP_DATA, a
              // channel primitive with no DM equivalent (see the note at the
              // top of this file).
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _textController,
                  builder: (context, value, child) {
                    final gifId = GifHelper.parseGif(value.text);
                    if (gifId != null) {
                      return Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              (event.logicalKey == LogicalKeyboardKey.enter ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.numpadEnter)) {
                            _sendMessage(connector);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: GifMessage(
                                  url:
                                      'https://media.giphy.com/media/$gifId/giphy.gif',
                                  backgroundColor:
                                      scheme.surfaceContainerHighest,
                                  fallbackTextColor: scheme.onSurface
                                      .withValues(alpha: 0.6),
                                  maxSize: 160,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: context.l10n.chat_removeGif,
                              onPressed: () {
                                _textController.clear();
                                _textFieldFocusNode.requestFocus();
                              },
                            ),
                          ],
                        ),
                      );
                    }
                    return ByteCountedTextField(
                      maxBytes: maxBytes,
                      softLimitBytes:
                          maxTextPayloadBytesAfterFullLengthAttempts,
                      softLimitNote: context.l10n.chat_longMessageRetryNote(
                        maxFullLengthTextAttempt + 1,
                      ),
                      controller: _textController,
                      focusNode: _textFieldFocusNode,
                      hintText: context.l10n.chat_typeMessage,
                      onSubmitted: (_) => _sendMessage(connector),
                      counterTextBuilder: otpEnabled
                          ? (used, max) => _otpComposeCounterText(
                              connector,
                              contactKeyHex,
                              used,
                            )
                          : null,
                      counterColorBuilder: otpEnabled
                          ? (used, max, defaultColor) =>
                                _otpComposeCounterColor(
                                  connector,
                                  contactKeyHex,
                                  used,
                                  defaultColor,
                                )
                          : null,
                      encoder:
                          (connector.isContactSmazEnabled(
                                widget.contact.publicKeyHex,
                              ) ||
                              connector.isContactCyr2LatEnabled(
                                widget.contact.publicKeyHex,
                              ))
                          ? (text) => connector.prepareContactOutboundText(
                              widget.contact,
                              text,
                            )
                          : null,
                      decoration: InputDecoration(
                        hintText: context.l10n.chat_typeMessage,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(MeshRadii.md),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(MeshRadii.md),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(MeshRadii.md),
                          borderSide: BorderSide(
                            color: scheme.primary,
                            width: 1.5,
                          ),
                        ),
                        filled: true,
                        fillColor: scheme.surfaceContainerLow,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 6),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (context, value, _) {
                  final hasText = value.text.trim().isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInOut,
                    child: IconButton.filled(
                      icon: const Icon(Icons.send, size: 20),
                      tooltip: context.l10n.chat_sendMessageTo(
                        _resolveContact(connector).name,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: hasText
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                        foregroundColor: hasText
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                        minimumSize: const Size(40, 40),
                        shape: const CircleBorder(),
                      ),
                      onPressed: hasText
                          ? () {
                              HapticFeedback.lightImpact();
                              _sendMessage(connector);
                            }
                          : null,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGifPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => GifPicker(
        onGifSelected: (gifId) {
          _textController.text = GifHelper.encodeGif(gifId);
        },
      ),
    );
  }

  /// The image codec, or null when it is not registered (screen tests).
  ImageCodecService? get _imageCodec {
    try {
      return context.read<ImageCodecService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Picks a photo, encodes it with the neural codec, and (if the user
  /// confirms the preview) OTP-encrypts and chunk-sends it to this contact —
  /// the DM equivalent of `channel_chat_screen.dart`'s
  /// `_showImageSendPreview`, but riding the OTP DM chunk pipeline instead
  /// of GRP_DATA (see the note at the top of this file and
  /// `otp_image_transport.dart`).
  Future<void> _showOtpImageSendPreview(MeshCoreConnector connector) async {
    final codec = _imageCodec;
    if (codec == null) return;
    final contact = _resolveContact(connector);

    // The picked bytes are kept past the preview on purpose: the sender's
    // own bubble renders from them (see [_sendOtpImage]), not from a decode
    // of the bitstream, which would cost ~2.16 GiB and ~1 s to reproduce an
    // image this device is already holding.
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // The codec centre-crops to 512x512 anyway, so there is nothing to
        // gain from decoding a 12 MP original — but stay well above 512 so
        // the crop still has detail to work with.
        maxWidth: 2048,
        maxHeight: 2048,
      );
    } on Exception catch (e) {
      debugPrint('image pick failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.chat_imagePickFailed)),
      );
      return;
    }
    if (picked == null) return; // cancelled at the picker

    final Uint8List sourceBytes;
    final int originalFileBytes;
    try {
      sourceBytes = await picked.readAsBytes();
      originalFileBytes = await picked.length();
    } on Exception catch (e) {
      debugPrint('image read failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.chat_imagePickFailed)),
      );
      return;
    }

    if (!mounted) return;
    final result = await showImageSendPreviewSheet(
      context: context,
      imageBytes: sourceBytes,
      originalFileBytes: originalFileBytes,
      codec: codec,
      // A DM image never carries an XOR parity chunk: the OTP chunk pipeline
      // already has its own per-chunk ack/retry, so a lost chunk is simply
      // retried, not reconstructed from parity. The sheet's parity toggle is
      // otherwise meaningless here (irrelevant, since sendOtpImageToContact
      // ignores includeParity below).
      initialParity: false,
    );
    if (result == null) return; // cancelled at the preview
    if (!mounted) return;
    await _sendOtpImage(connector, contact, result, sourceBytes: sourceBytes);
  }

  /// Sends the already-encoded [result] to [contact] over the OTP DM chunk
  /// pipeline.
  ///
  /// NOTE: the preview sheet's packet-count/airtime estimate reflects the
  /// channel GRP_DATA chunk geometry (`kImageChunkBlobBytes`), not this
  /// pipeline's actual per-chunk capacity — a known, documented cosmetic gap
  /// (see the project doc) rather than a functional one: the real chunking
  /// below (`OtpChunkService.splitPlaintextBytes`) is unaffected by whatever
  /// number the sheet showed.
  Future<void> _sendOtpImage(
    MeshCoreConnector connector,
    Contact contact,
    ImageSendPreviewResult result, {
    required Uint8List sourceBytes,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;

    setState(() => _sendingOtpImage = true);
    try {
      final previewPng = await _squarePreviewPng(sourceBytes);
      if (previewPng == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.chat_imagePickFailed)),
        );
        return;
      }
      final aspectCode = await _aspectCodeOf(sourceBytes);
      final sent = await connector.sendOtpImageToContact(
        contact,
        codecBitstream: result.payload,
        previewPng: previewPng,
        rate: result.rate,
        aspectCode: aspectCode,
      );
      // No success snackbar: unlike the channel feature (where GRP_DATA
      // sends nothing the sender's own transcript otherwise shows), this
      // send immediately produces a real message bubble with its own
      // chunk-progress display — exactly like an ordinary chunked OTP text
      // message — so a second "sent" confirmation would be redundant.
      if (!sent && mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.imageSend_deviceUnsupported)),
        );
      }
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.imageSend_sendFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _sendingOtpImage = false);
    }
  }

  /// The [kImageAspectCodes] entry matching [imageBytes]'s shape. Mirrors
  /// `channel_chat_screen.dart`'s helper of the same name.
  static Future<int> _aspectCodeOf(Uint8List imageBytes) async {
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      image = (await codec.getNextFrame()).image;
      return imageAspectCodeFor(image.width, image.height);
    } on Exception catch (error) {
      debugPrint('aspect probe failed: $error');
      return kImageAspectUnknown;
    } finally {
      image?.dispose();
    }
  }

  /// [imageBytes] stretched to 512x512, as PNG — what the codec actually
  /// encoded, so the sender's own bubble matches what the receiver sees.
  /// Mirrors `channel_chat_screen.dart`'s helper of the same name.
  static Future<Uint8List?> _squarePreviewPng(Uint8List imageBytes) async {
    ui.Image? source;
    ui.Image? square;
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      source = (await codec.getNextFrame()).image;
      final dst = kImageCodecSquareSize.toDouble();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        source,
        ui.Rect.fromLTWH(
          0,
          0,
          source.width.toDouble(),
          source.height.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, dst, dst),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      square = await recorder.endRecording().toImage(
        kImageCodecSquareSize,
        kImageCodecSquareSize,
      );
      final data = await square.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } on Exception catch (error) {
      debugPrint('outgoing image preview render failed: $error');
      return null;
    } finally {
      source?.dispose();
      square?.dispose();
    }
  }

  Future<void> _showTranslationOptions() async {
    final settingsService = context.read<AppSettingsService>();
    final settings = settingsService.settings;
    await showMessageTranslationSheet(
      context: context,
      enabled: settings.composerTranslationEnabled,
      selectedLanguageCode: settings.translationTargetLanguageCode,
      onEnabledChanged: settingsService.setComposerTranslationEnabled,
      onLanguageSelected: settingsService.setTranslationTargetLanguageCode,
    );
  }

  Future<void> _sendMessage(MeshCoreConnector connector) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final now = DateTime.now();
    if (_lastTextSendAt != null &&
        now.difference(_lastTextSendAt!) < const Duration(seconds: 1)) {
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.chat_sendCooldown),
      );
      return;
    }
    _lastTextSendAt = now;

    final settings = context.read<AppSettingsService>().settings;
    final translationService = context.read<TranslationService>();
    var outgoingText = text;
    String? originalText;
    String? translatedLanguageCode;
    String? translationModelId;
    if (settings.translationEnabled) {
      final targetLanguageCode = translationService.resolvedTargetLanguageCode(
        Localizations.localeOf(context).languageCode,
      );
      if (translationService.shouldTranslateOutgoing(
        text: text,
        targetLanguageCode: targetLanguageCode,
      )) {
        final result = await translationService.translateOutgoingText(
          text: text,
          targetLanguageCode: targetLanguageCode,
        );
        if (!mounted) return;
        if (result != null &&
            result.status == MessageTranslationStatus.completed &&
            result.translatedText.isNotEmpty) {
          outgoingText = result.translatedText;
          originalText = text;
          translatedLanguageCode = result.targetLanguageCode;
          translationModelId = result.modelId;
        }
      }
    }
    final otpEnabled = connector.isContactOtpEnabled(
      _resolveContact(connector).publicKeyHex,
    );

    if (otpEnabled) {
      // OTP budget check: messages over one packet's worth of plaintext are
      // automatically split into multiple chunked packets (see
      // otp_chunk_service.dart), so the real ceiling here is the much
      // larger multi-chunk cap, not the single-packet
      // OtpService.maxPlaintextBytesForContact() figure — checking
      // prepareContactOutboundText() here would be checking the wrong thing
      // (that only transforms plaintext with Smaz/Cyr2Lat).
      final maxPlainBytes = OtpChunkService.maxChunkedPlaintextBytesForContact();
      if (OtpService.plaintextByteLength(outgoingText) > maxPlainBytes) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.chat_messageTooLong(maxPlainBytes)),
        );
        return;
      }
      // Skip Smaz/Cyr2Lat entirely — connector.sendMessage()'s OTP path
      // encrypts outgoingText as-is, and prepareContactOutboundText already
      // bypasses both transforms for OTP1|-prefixed ciphertext, so running
      // Cyr2Lat here first would just transliterate the plaintext that's
      // about to be encrypted, corrupting what the recipient decrypts to.
    } else {
      final maxBytes = maxContactMessageBytes();
      final outboundText = connector.prepareContactOutboundText(
        _resolveContact(connector),
        outgoingText,
      );
      if (utf8.encode(outboundText).length > maxBytes) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.chat_messageTooLong(maxBytes)),
        );
        return;
      }

      // This is only for cyr2lat compression - to see the message being sent in the same format as the other person will receive
      try {
        if (connector.isContactCyr2LatEnabled(
          _resolveContact(connector).publicKeyHex,
        )) {
          outgoingText = Cyr2Lat.encode(outgoingText);
        }
      } catch (_) {
        // TODO maybe log
      }
      // end transform
    }

    _textController.clear();
    _textFieldFocusNode.requestFocus();
    connector.sendMessage(
      _resolveContact(connector),
      outgoingText,
      originalText: originalText,
      translatedLanguageCode: translatedLanguageCode,
      translationModelId: translationModelId,
    );
  }

  Future<void> _confirmClearChat(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.contact_clearChat),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      connector.clearMessagesForContact(widget.contact);
    }
  }

  int _resolveContactIndex = -1;

  Contact _resolveContact(MeshCoreConnector connector) {
    if (_resolveContactIndex >= 0 &&
        _resolveContactIndex < connector.contacts.length &&
        connector.contacts[_resolveContactIndex].publicKeyHex ==
            widget.contact.publicKeyHex) {
      return connector.contacts[_resolveContactIndex];
    }
    _resolveContactIndex = connector.contacts.indexWhere(
      (c) => c.publicKeyHex == widget.contact.publicKeyHex,
    );
    if (_resolveContactIndex == -1) {
      return widget.contact;
    }
    return connector.contacts[_resolveContactIndex];
  }

  Contact? _resolveContactFrom4Bytes(
    MeshCoreConnector connector,
    Uint8List key4Bytes,
  ) {
    // Match against saved contacts first, then nodes only seen via discovery —
    // a room poster you haven't saved may still be in the discovered list.
    return connector.allContactsUnfiltered.cast<Contact?>().firstWhere(
      (c) =>
          c != null &&
          listEquals(c.publicKey.sublist(0, 4), key4Bytes.sublist(0, 4)),
      orElse: () => null,
    );
  }

  String _currentPathLabel(Contact contact) {
    final connector = context.read<MeshCoreConnector>();

    // Check if user has set a path override
    if (contact.pathOverride != null) {
      if (contact.pathOverride! < 0) return context.l10n.chat_floodForced;
      if (contact.pathOverride == 0) return context.l10n.chat_directForced;
      final bytes = contact.pathOverrideBytes ?? Uint8List(0);
      final hopCount = _displayHopCount(
        bytes,
        contact.pathOverride!,
        connector.pathHashByteWidth,
      );
      return context.l10n.chat_hopsForced(hopCount);
    }

    // Use device's path
    if (contact.pathLength < 0) return context.l10n.chat_floodAuto;
    if (contact.pathLength == 0) return context.l10n.chat_direct;
    final hopCount = _displayHopCount(
      contact.path,
      contact.pathLength,
      contact.pathHashWidth,
    );
    return context.l10n.chat_hopsCount(hopCount);
  }

  int _displayHopCount(List<int> pathBytes, int storedHopCount, int hashWidth) {
    if (pathBytes.isEmpty) return storedHopCount;
    return PathHelper.splitPathBytes(pathBytes, hashWidth).length;
  }

  void _showContactInfo(BuildContext context) {
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    final contact = _resolveContact(connector);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: SelectableText(contact.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(
                context.l10n.chat_type,
                contact.typeLabel(context.l10n),
              ),
              _buildInfoRow(
                context.l10n.chat_path,
                contact.pathLabel(
                  context.l10n,
                  pathHashByteWidth: connector.pathHashByteWidth,
                ),
              ),
              _buildInfoRow(
                context.l10n.contact_lastSeen,
                _formatContactLastMessage(contact.lastMessageAt),
              ),
              if (contact.hasLocation)
                _buildInfoRow(
                  context.l10n.chat_location,
                  '${contact.latitude?.toStringAsFixed(4)}, ${contact.longitude?.toStringAsFixed(4)}',
                ),
              _buildInfoRow(context.l10n.chat_publicKey, contact.publicKeyHex),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    );
  }

  void _showContactSettings(BuildContext context) {
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    final appSettingsService = Provider.of<AppSettingsService>(
      context,
      listen: false,
    );
    connector.ensureContactSmazSettingLoaded(widget.contact.publicKeyHex);
    connector.ensureContactCyr2LatSettingLoaded(widget.contact.publicKeyHex);
    final contact = widget.contact;
    bool smazEnabled = connector.isContactSmazEnabled(contact.publicKeyHex);
    bool cyr2latEnabled = connector.isContactCyr2LatEnabled(
      contact.publicKeyHex,
    );
    bool urlImagesEnabled = connector.isContactUrlImagesEnabled(
      contact.publicKeyHex,
    );
    String? selectedCyr2LatProfileId = connector.getContactCyr2LatProfileId(
      contact.publicKeyHex,
    );
    bool teleBaseEnabled = contact.teleBaseEnabled;
    bool teleLocEnabled = contact.teleLocEnabled;
    bool teleEnvEnabled = contact.teleEnvEnabled;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.contact_settings),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (contact.hasLocation) ...[
                  _buildInfoRow(
                    context.l10n.chat_location,
                    '${contact.latitude?.toStringAsFixed(4)}, ${contact.longitude?.toStringAsFixed(4)}',
                  ),
                  const Divider(height: 8),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.channels_smazCompression),
                  subtitle: Text(context.l10n.chat_compressOutgoingMessages),
                  value: smazEnabled,
                  onChanged: (value) {
                    connector.setContactSmazEnabled(
                      contact.publicKeyHex,
                      value,
                    );
                    connector.setContactCyr2LatEnabled(
                      contact.publicKeyHex,
                      false,
                    );
                    setDialogState(() {
                      smazEnabled = value;
                      if (smazEnabled) {
                        cyr2latEnabled = false;
                      }
                    });
                  },
                ),
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.channels_cyr2latCompression),
                  subtitle: Text(context.l10n.channels_cyr2latCompressionDscr),
                  value: cyr2latEnabled,
                  onChanged: (value) {
                    connector.setContactCyr2LatEnabled(
                      contact.publicKeyHex,
                      value,
                    );
                    connector.setContactSmazEnabled(
                      contact.publicKeyHex,
                      false,
                    );
                    setDialogState(() {
                      cyr2latEnabled = value;
                      if (cyr2latEnabled) {
                        smazEnabled = false;
                      }
                    });
                  },
                ),
                if (cyr2latEnabled) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedCyr2LatProfileId,
                      decoration: InputDecoration(
                        labelText:
                            context.l10n.channels_cyr2latSettingsSubheading,
                        border: const OutlineInputBorder(),
                      ),
                      items: appSettingsService.settings.cyr2latProfiles.map((
                        profile,
                      ) {
                        return DropdownMenuItem(
                          value: profile.id,
                          child: Text(profile.name),
                        );
                      }).toList(),
                      onChanged: (value) {
                        connector.setContactCyr2LatProfileId(
                          contact.publicKeyHex,
                          value,
                        );
                        setDialogState(() {
                          selectedCyr2LatProfileId = value;
                        });
                      },
                    ),
                  ),
                ],
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.urlImage_enable),
                  value: urlImagesEnabled,
                  onChanged: (value) {
                    connector.setContactUrlImagesEnabled(
                      contact.publicKeyHex,
                      value,
                    );
                    setDialogState(() => urlImagesEnabled = value);
                  },
                ),
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.contact_teleBase),
                  subtitle: Text(context.l10n.contact_teleBaseSubtitle),
                  value: teleBaseEnabled,
                  onChanged: (value) {
                    setDialogState(() => teleBaseEnabled = value);
                  },
                ),
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.contact_teleLoc),
                  subtitle: Text(context.l10n.contact_teleLocSubtitle),
                  value: teleLocEnabled,
                  onChanged: (value) {
                    setDialogState(() => teleLocEnabled = value);
                  },
                ),
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.contact_teleEnv),
                  subtitle: Text(context.l10n.contact_teleEnvSubtitle),
                  value: teleEnvEnabled,
                  onChanged: (value) {
                    setDialogState(() => teleEnvEnabled = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                connector.setContactFlags(
                  contact,
                  teleBase: teleBaseEnabled,
                  teleLoc: teleLocEnabled,
                  teleEnv: teleEnvEnabled,
                );
                Navigator.pop(context);
              },
              child: Text(context.l10n.common_close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  String _formatContactLastMessage(DateTime timestamp) {
    final diff = DateTime.now().difference(timestamp);
    if (diff.isNegative || diff.inMinutes < 5) {
      return context.l10n.contacts_lastSeenNow;
    }
    if (diff.inMinutes < 60) {
      return context.l10n.contacts_lastSeenMinsAgo(diff.inMinutes);
    }
    if (diff.inHours < 24) {
      final hours = diff.inHours;
      return hours == 1
          ? context.l10n.contacts_lastSeenHourAgo
          : context.l10n.contacts_lastSeenHoursAgo(hours);
    }
    final days = diff.inDays;
    return days == 1
        ? context.l10n.contacts_lastSeenDayAgo
        : context.l10n.contacts_lastSeenDaysAgo(days);
  }

  void _openChat(BuildContext context, Contact contact) {
    final connector = context.read<MeshCoreConnector>();
    final unread = connector.getUnreadCountForContactKey(contact.publicKeyHex);
    connector.markContactRead(contact.publicKeyHex);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ChatScreen(contact: contact, initialUnreadCount: unread),
      ),
    );
  }

  void _openMessagePath(
    Message message,
    Contact contact, {
    bool openMap = false,
  }) {
    final connector = context.read<MeshCoreConnector>();
    final fourByteHex = message.fourByteRoomContactKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final String senderName;
    if (message.isOutgoing) {
      senderName = connector.selfName ?? context.l10n.chat_me;
    } else if (_resolveContact(connector).type == advTypeRoom) {
      // An unresolved author leaves `contact` as the room server itself; show
      // only the prefix rather than mislabeling the post with the room's name.
      senderName = contact.type == advTypeRoom
          ? "[$fourByteHex]"
          : "${contact.name} [$fourByteHex]";
    } else {
      senderName = _resolveContact(connector).name;
    }
    final pathMessage = ChannelMessage(
      senderKey: null,
      senderName: senderName,
      text: message.text,
      timestamp: message.timestamp,
      isOutgoing: message.isOutgoing,
      status: ChannelMessageStatus.sent,
      repeatCount: 0,
      pathLength: message.pathLength,
      pathBytes: message.pathBytes,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => openMap
            ? ChannelMessagePathMapScreen(message: pathMessage)
            : ChannelMessagePathScreen(message: pathMessage),
      ),
    );
  }

  void _showMessageActions(Message message, Contact contact) {
    final translationService = context.read<TranslationService>();
    final canTranslateMessage =
        translationService.canTranslateIncoming(
          text: message.text,
          isCli: message.isCli,
          isOutgoing: message.isOutgoing,
        ) &&
        (message.translatedText?.trim().isEmpty ?? true);

    showMeshSheet(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BottomSheetHeader(
              title: message.displayText.characters.length > 40
                  ? '${message.displayText.characters.take(40)}…'
                  : message.displayText,
            ),
            // Can't react to your own messages
            if (!message.isOutgoing)
              ListTile(
                leading: const Icon(Icons.add_reaction_outlined),
                title: Text(context.l10n.chat_addReaction),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showEmojiPicker(message, contact);
                },
              ),
            ListTile(
              leading: const Icon(Icons.route),
              title: Text(context.l10n.chat_path),
              onTap: () {
                Navigator.pop(sheetContext);
                _openMessagePath(message, contact);
              },
            ),
            if (message.pathBytes.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: Text(context.l10n.chat_viewPathOnMap),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openMessagePath(message, contact, openMap: true);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(context.l10n.common_copy),
              onTap: () {
                Navigator.pop(sheetContext);
                _copyMessageText(message.displayText);
              },
            ),
            if (canTranslateMessage)
              ListTile(
                leading: const Icon(Icons.translate),
                title: Text(context.l10n.translation_translateMessage),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    context.read<MeshCoreConnector>().translateContactMessage(
                      widget.contact.publicKeyHex,
                      message,
                      manualTranslation: true,
                    ),
                  );
                },
              ),
            if (!message.isOutgoing)
              ListTile(
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: Text(context.l10n.chat_markAsUnread),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _markAsUnread(message);
                },
              ),
            if (message.isOutgoing &&
                (message.status == MessageStatus.failed ||
                    // A queued store-and-forward message can also be
                    // retried by hand rather than waiting for the next
                    // automatic trigger (something heard from the contact,
                    // or the background sweep) - resendMessage's
                    // delete-then-send also correctly drops it out of the
                    // waiting queue first.
                    message.status == MessageStatus.waiting))
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(context.l10n.common_retry),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _retryMessage(message);
                },
              ),
            if (_resolveContact(context.read<MeshCoreConnector>()).type ==
                advTypeRoom)
              ListTile(
                leading: const Icon(Icons.chat),
                title: Text(context.l10n.contacts_openChat),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openChat(context, contact);
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                context.l10n.common_delete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _deleteMessage(message);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _copyMessageText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.chat_messageCopied),
    );
  }

  Future<void> _deleteMessage(Message message) async {
    await context.read<MeshCoreConnector>().deleteMessage(message);
    if (!mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.chat_messageDeleted),
    );
  }

  void _retryMessage(Message message) {
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    connector.resendMessage(_resolveContact(connector), message);
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.chat_retryingMessage),
    );
  }

  void _showEmojiPicker(Message message, Contact senderContact) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => EmojiPicker(
        onEmojiSelected: (emoji) {
          _sendReaction(message, senderContact, emoji);
        },
      ),
    );
  }

  void _sendReaction(Message message, Contact senderContact, String emoji) {
    final connector = context.read<MeshCoreConnector>();
    final emojiIndex = ReactionHelper.emojiToIndex(emoji);
    if (emojiIndex == null) return; // Unknown emoji, skip
    final timestampSecs = message.timestamp.millisecondsSinceEpoch ~/ 1000;

    // For room servers, include sender name (like channels) since multiple users
    // For 1:1 chats, sender is implicit (null)
    final liveContact = _resolveContact(connector);
    final senderName = liveContact.type == advTypeRoom
        ? senderContact.name
        : null;
    appLogger.info('Sending reaction using senderName: $senderName');
    final hash = ReactionHelper.computeReactionHash(
      timestampSecs,
      senderName,
      message.text,
    );
    final reactionText = ReactionHelper.encodeReaction(hash, emojiIndex);
    connector.sendMessage(_resolveContact(connector), reactionText);
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final String senderName;
  final VoidCallback? onLongPress;
  final void Function(Message message, String emoji)? onRetryReaction;
  final double textScale;
  final String sourceId;

  const _MessageBubble({
    required this.message,
    required this.senderName,
    required this.sourceId,
    required this.textScale,
    this.onLongPress,
    this.onRetryReaction,
  });

  @override
  Widget build(BuildContext context) {
    final settingsService = context.watch<AppSettingsService>();
    final enableTracing = settingsService.settings.enableMessageTracing;
    final isOutgoing = message.isOutgoing;
    // Request: in OTP mode, own messages sit on the LEFT and the other
    // party's on the RIGHT - the mirror of the usual layout - matching the
    // identical flip in OTP_3_RC1.lua's chat screen. Only the SIDE a
    // bubble is drawn on flips; isOutgoing itself (and everything below
    // that's about identity rather than position - bubbleColor/
    // bubbleBorder/textColor, whether the sender's name is shown, retry/
    // status-tick visibility, trip-time coloring) stays tied to who
    // actually sent the message, so a bubble's color and content still
    // always mean "mine" regardless of which side it ends up on.
    final otpActive = context.select<MeshCoreConnector, bool>(
      (connector) => connector.isContactOtpEnabled(sourceId),
    );
    final layoutOutgoing = otpActive ? !isOutgoing : isOutgoing;
    final scheme = Theme.of(context).colorScheme;
    final voxEnvelope = VoxVoiceEnvelope.tryParse(message.displayText);
    final gifId = voxEnvelope != null ? null : GifHelper.parseGif(message.text);
    // An OTP DM image (otp_image_transport.dart) carries this sentinel in
    // `text`; ReceivedImageStore owns the bytes.
    final otpImageStreamId = voxEnvelope != null
        ? null
        : ReceivedImageRef.parse(message.text);
    // GIF and OTP image bubbles draw their own chrome.
    final compactChrome = gifId != null || otpImageStreamId != null;
    final poi = voxEnvelope != null ? null : parseMarkerText(message.text);
    final isFailed = message.status == MessageStatus.failed;
    final urlImagesEnabled = context.select<MeshCoreConnector, bool>(
      (connector) => connector.isContactUrlImagesEnabled(sourceId),
    );

    // Bubble colors — outgoing uses MeshPalette.me / meBorder / meInk,
    // unless OTP is active for this contact: then every bubble is colored
    // by the chosen OTP theme and the message's own state (sent/delivered/
    // retrying/waiting/failed on the outgoing side, or the sender's own
    // assigned color on the incoming side) — ported from OTP_3_RC1.lua's
    // refresh_chat_view, see otp_bubble_colors.dart.
    final otpColors = otpActive
        ? (isOutgoing
              ? otpOutgoingBubbleColors(
                  theme: OtpTheme.all[settingsService.settings.otpThemeIndex],
                  textMode: settingsService.settings.otpTextMode,
                  failed: isFailed,
                  delivered: message.status == MessageStatus.delivered,
                  waiting: message.status == MessageStatus.waiting,
                  retrying:
                      !isFailed &&
                      message.status != MessageStatus.delivered &&
                      message.status != MessageStatus.waiting &&
                      message.retryCount > 0,
                  pending: message.status == MessageStatus.pending,
                )
              : otpReceivedBubbleColors(
                  theme: OtpTheme.all[settingsService.settings.otpThemeIndex],
                  textMode: settingsService.settings.otpTextMode,
                  senderName: senderName,
                  failed: isFailed,
                ))
        : null;

    final bubbleColor =
        otpColors?.fill ??
        (isFailed
            ? scheme.errorContainer
            : isOutgoing
            ? MeshPalette.me
            : scheme.surfaceContainerLow);
    final bubbleBorder =
        otpColors?.outline ??
        (isFailed
            ? scheme.error
            : isOutgoing
            ? MeshPalette.meBorder
            : scheme.outlineVariant);
    final textColor =
        otpColors?.text ??
        (isFailed
            ? scheme.onErrorContainer
            : isOutgoing
            ? MeshPalette.meInk
            : scheme.onSurface);
    final metaColor = textColor.withValues(alpha: 0.65);
    const bodyFontSize = 14.0;

    // Asymmetric radius: outgoing — top-left large, others also large; outgoing bottom-right tight.
    // Follows layoutOutgoing (not isOutgoing) - the tight "tail" corner
    // should point toward whichever edge the bubble is actually drawn at.
    final borderRadius = layoutOutgoing
        ? const BorderRadius.only(
            topLeft: Radius.circular(MeshRadii.lg),
            topRight: Radius.circular(MeshRadii.lg),
            bottomLeft: Radius.circular(MeshRadii.lg),
            bottomRight: Radius.circular(MeshRadii.xs),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(MeshRadii.xs),
            topRight: Radius.circular(MeshRadii.lg),
            bottomLeft: Radius.circular(MeshRadii.lg),
            bottomRight: Radius.circular(MeshRadii.lg),
          );

    // Do not strip room-server author bytes here: the parser stores them in
    // fourByteRoomContactKey, so message.text is safe to render as-is.
    // displayText resolves to the sender's own typed plaintext for an
    // outgoing OTP message (message.text is the ciphertext actually on the
    // wire); for everything else it's just message.text unchanged.
    final messageText = message.displayText;
    final translatedDisplayText =
        message.translatedText != null &&
            message.translatedText!.trim().isNotEmpty
        ? message.translatedText!.trim()
        : messageText;
    final originalDisplayText = isOutgoing
        ? message.originalText
        : (translatedDisplayText != messageText ? messageText : null);

    Widget buildTextContent() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: TranslatedMessageContent(
              displayText: translatedDisplayText,
              originalText: originalDisplayText,
              style: TextStyle(
                color: textColor,
                fontSize: bodyFontSize * textScale,
              ),
              originalStyle: TextStyle(
                color: textColor.withValues(alpha: 0.72),
                fontSize: bodyFontSize * textScale,
              ),
              onSecondaryTap: PlatformInfo.isDesktop ? onLongPress : null,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: layoutOutgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              onLongPress: onLongPress,
              onSecondaryTapUp: PlatformInfo.isDesktop
                  ? (_) => onLongPress?.call()
                  : null,
              child: Row(
                mainAxisAlignment: layoutOutgoing
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!layoutOutgoing) ...[
                    _buildAvatar(senderName),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Container(
                      padding: compactChrome
                          ? const EdgeInsets.all(4)
                          : const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.72,
                      ),
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: borderRadius,
                        border: Border.all(color: bubbleBorder, width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isOutgoing) ...[
                            Padding(
                              padding: compactChrome
                                  ? const EdgeInsets.only(
                                      left: 8,
                                      top: 4,
                                      bottom: 4,
                                    )
                                  : EdgeInsets.zero,
                              child: Text(
                                senderName,
                                style: MeshTheme.mono(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: _colorForName(senderName),
                                ),
                              ),
                            ),
                            if (!compactChrome) const SizedBox(height: 2),
                          ],
                          if (voxEnvelope != null)
                            VoxVoiceMessageContent(
                              envelope: voxEnvelope,
                              isOutgoing: isOutgoing,
                              textColor: textColor,
                              sender: isOutgoing
                                  ? null
                                  : context
                                        .read<VoxVoiceService>()
                                        .contactByKeyHex(sourceId),
                            )
                          else if (poi != null)
                            _buildPoiMessage(
                              context,
                              poi,
                              textColor,
                              metaColor,
                              textScale,
                              senderName,
                            )
                          else if (gifId != null)
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: GifMessage(
                                    url:
                                        'https://media.giphy.com/media/$gifId/giphy.gif',
                                    backgroundColor: Colors.transparent,
                                    fallbackTextColor: textColor.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else if (otpImageStreamId != null)
                            ReceivedImageMessage(
                              streamId: otpImageStreamId,
                              isOutgoing: isOutgoing,
                              fallbackTextColor: textColor,
                              strings: _receivedImageStrings(context),
                              onOpenCodecSettings: () => Navigator.of(
                                context,
                              ).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const AppSettingsScreen(
                                    focusImageMessages: true,
                                  ),
                                ),
                              ),
                            )
                          else if (urlImagesEnabled)
                            MessageUrlImageFutureBuilder(
                              messageId: message.messageId,
                              text: message.text,
                              builder: (context, snapshot) {
                                final imageAttachment = snapshot.data;

                                if (imageAttachment != null) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Align(
                                          alignment: layoutOutgoing
                                              ? Alignment.centerRight
                                              : Alignment.centerLeft,
                                          child: MessageUrlImagePreview(
                                            imageUrl: imageAttachment,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: TranslatedMessageContent(
                                          displayText: translatedDisplayText,
                                          originalText: originalDisplayText,
                                          style: TextStyle(
                                            color: textColor,
                                            fontSize: bodyFontSize * textScale,
                                          ),
                                          originalStyle: TextStyle(
                                            color: textColor.withValues(
                                              alpha: 0.72,
                                            ),
                                            fontSize: bodyFontSize * textScale,
                                          ),
                                          onSecondaryTap: PlatformInfo.isDesktop
                                              ? onLongPress
                                              : null,
                                        ),
                                      ),
                                    ],
                                  );
                                }

                                return buildTextContent();
                              },
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (MessageUrlImageHelper.hasPotentialImageUrl(
                                  message.text,
                                ))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      context.l10n.urlImage_possible,
                                      style: TextStyle(
                                        color: metaColor,
                                        fontSize: 11 * textScale,
                                      ),
                                    ),
                                  ),
                                buildTextContent(),
                              ],
                            ),
                          if (enableTracing &&
                              isOutgoing &&
                              message.retryCount > 0) ...[
                            const SizedBox(height: 3),
                            Padding(
                              padding: compactChrome
                                  ? const EdgeInsets.symmetric(horizontal: 8)
                                  : EdgeInsets.zero,
                              child: Text(
                                context.l10n.chat_retryCount(
                                  message.retryCount,
                                  context
                                      .read<AppSettingsService>()
                                      .settings
                                      .maxMessageRetries,
                                ),
                                style: MeshTheme.mono(
                                  fontSize: 9.5 * textScale,
                                  color: metaColor,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 3),
                          // Meta row: timestamp + status icon + optional tracing
                          Padding(
                            padding: compactChrome
                                ? const EdgeInsets.only(
                                    left: 8,
                                    right: 8,
                                    bottom: 4,
                                  )
                                : EdgeInsets.zero,
                            child: Wrap(
                              spacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  formatChatTime(context, message.timestamp),
                                  style: MeshTheme.mono(
                                    fontSize: 12 * textScale,
                                    color: metaColor,
                                  ),
                                ),
                                if (isOutgoing) ...[
                                  const SizedBox(width: 2),
                                  // Slick-UI: a multi-part OTP send has a
                                  // real part count while it's pending
                                  // (Message.chunkIndex/chunkTotal) — show
                                  // that instead of leaving the pending
                                  // spinner as the only signal for what can
                                  // be several seconds of transfer.
                                  if (message.status == MessageStatus.pending &&
                                      message.chunkTotal != null &&
                                      message.chunkTotal! > 1) ...[
                                    Text(
                                      '${(message.chunkIndex ?? 0) + 1}/${message.chunkTotal}',
                                      style: MeshTheme.mono(
                                        fontSize: 9.5 * textScale,
                                        color: metaColor,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                  ],
                                  MessageStatusIcon(
                                    size: 16 * textScale,
                                    onColor: metaColor,
                                    isAcked:
                                        message.status ==
                                        MessageStatus.delivered,
                                    isPending:
                                        message.status == MessageStatus.pending,
                                    isFailed:
                                        message.status == MessageStatus.failed,
                                    isWaiting:
                                        message.status == MessageStatus.waiting,
                                  ),
                                  // OTP store-and-forward: this send gave up
                                  // retrying and is sitting queued for this
                                  // contact - show how long, the same way a
                                  // "waiting for a path" caption would read on
                                  // the Lua side's chat bubble.
                                  if (message.status == MessageStatus.waiting &&
                                      message.waitingSinceAt != null) ...[
                                    const SizedBox(width: 2),
                                    Text(
                                      'Waiting for a path'
                                      '${_relativeTimeSuffix(message.waitingSinceAt!)}',
                                      style: MeshTheme.mono(
                                        fontSize: 9.5 * textScale,
                                        color: metaColor,
                                      ),
                                    ),
                                  ],
                                ],
                                if (enableTracing &&
                                    message.tripTimeMs != null &&
                                    message.status ==
                                        MessageStatus.delivered) ...[
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.speed,
                                    size: 10 * textScale,
                                    color: isOutgoing
                                        ? metaColor
                                        : scheme.tertiary,
                                  ),
                                  Text(
                                    '${(message.tripTimeMs! / 1000).toStringAsFixed(1)}s',
                                    style: MeshTheme.mono(
                                      fontSize: 11 * textScale,
                                      color: isOutgoing
                                          ? metaColor
                                          : scheme.tertiary,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (message.reactions.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.only(left: layoutOutgoing ? 0 : 42),
              child: _buildReactionsDisplay(context, message, scheme),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPoiMessage(
    BuildContext context,
    MarkerPayload poi,
    Color textColor,
    Color metaColor,
    double textScale,
    String senderName, {
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          icon: Icon(Icons.location_on_outlined, color: textColor),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () async {
            final selfName =
                context.read<MeshCoreConnector>().selfName ??
                context.l10n.chat_me;
            final fromName = message.isOutgoing ? selfName : senderName;
            final key = buildSharedMarkerKey(
              sourceId: sourceId,
              label: poi.label,
              fromName: fromName,
              flags: poi.flags,
              isChannel: false,
            );
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MapScreen(
                  highlightPosition: poi.position,
                  highlightLabel: poi.label,
                  highlightMarkerKey: key,
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.chat_poiShared,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 14 * textScale,
                ),
              ),
              if (poi.label.isNotEmpty)
                Text(
                  poi.label,
                  style: TextStyle(color: metaColor, fontSize: 12 * textScale),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 4), trailing],
      ],
    );
  }

  Widget _buildReactionsDisplay(
    BuildContext context,
    Message message,
    ColorScheme scheme,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: message.reactions.entries.map((entry) {
        final emoji = entry.key;
        final count = entry.value.length;
        final status = message.reactionStatuses[emoji];
        final isPending =
            status == MessageStatus.pending || status == MessageStatus.sent;
        final isFailed = status == MessageStatus.failed;

        return GestureDetector(
          onTap: isFailed && onRetryReaction != null
              ? () => onRetryReaction!(message, emoji)
              : null,
          child: Opacity(
            opacity: isPending ? 0.5 : 1.0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isFailed
                    ? scheme.errorContainer
                    : scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(MeshRadii.pill),
                border: Border.all(
                  color: isFailed ? scheme.error : scheme.outlineVariant,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    emoji,
                    style: MeshTheme.emoji(fontSize: 16),
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToFirstAscent: false,
                      applyHeightToLastDescent: false,
                    ),
                  ),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count',
                      style: MeshTheme.mono(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                  if (isPending) ...[
                    const SizedBox(width: 2),
                    SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                  if (isFailed) ...[
                    const SizedBox(width: 2),
                    Icon(Icons.replay, size: 10, color: scheme.error),
                  ],
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildAvatar(String senderName) {
    return AvatarCircle(name: senderName, size: 32);
  }

  // " (just now)" / " (5m)" / " (2h)" — same relative-time-ago shape used
  // elsewhere in this app (routing_sheet.dart/map_screen.dart), but plain
  // English rather than routed through l10n, matching every other
  // not-yet-localized string this store-and-forward feature added (see the
  // "no l10n" known gap).
  String _relativeTimeSuffix(DateTime since) {
    final diff = DateTime.now().difference(since);
    if (diff.inSeconds < 60) return ' (just now)';
    if (diff.inMinutes < 60) return ' (${diff.inMinutes}m)';
    if (diff.inHours < 24) return ' (${diff.inHours}h)';
    return ' (${diff.inDays}d)';
  }
}

/// Deterministic name-to-hue mapping consistent with [AvatarCircle].
Color _colorForName(String name) {
  const hues = [
    MeshPalette.blue,
    MeshPalette.magenta,
    MeshPalette.signal,
    MeshPalette.warn,
    Color(0xFF8FA8F0),
    Color(0xFF6FD9CE),
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return hues[h % hues.length];
}

/// Mirrors `channel_chat_screen.dart`'s private helper of the same name —
/// duplicated rather than shared, matching this codebase's existing
/// per-screen-helper convention.
ReceivedImageStrings _receivedImageStrings(BuildContext context) {
  final l10n = context.l10n;
  return ReceivedImageStrings(
    incoming: l10n.receivedImage_incoming,
    queued: l10n.receivedImage_queued,
    tapToDecode: l10n.receivedImage_tapToDecode,
    awaiting: l10n.receivedImage_awaiting,
    tapToProcess: l10n.receivedImage_tapToProcess,
    decoding: l10n.receivedImage_decoding,
    incomplete: l10n.receivedImage_incomplete,
    corrupt: l10n.receivedImage_corrupt,
    decoderMissing: l10n.receivedImage_decoderMissing,
    evicted: l10n.receivedImage_evicted,
    retry: l10n.receivedImage_retry,
    decodeAgain: l10n.receivedImage_decodeAgain,
    openSettings: l10n.receivedImage_openSettings,
  );
}
