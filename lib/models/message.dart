import 'dart:typed_data';
import '../connector/meshcore_protocol.dart';
import '../helpers/reaction_helper.dart';
import 'translation_support.dart';

// `waiting`: an outgoing OTP single-shot send that exhausted its normal
// retry budget and was handed off to store-and-forward instead of being
// marked failed outright - it sits queued for this contact and is retried
// automatically once something is heard from them again (or on a slow
// background timer), per MeshCoreConnector's waiting-queue machinery. See
// waitingSinceAt below. Ports OTP_3_RC1.lua's `waiting_queue`/"Waiting for
// a path" bubble.
enum MessageStatus { pending, sent, delivered, failed, waiting }

class Message {
  static const Object _unset = Object();

  final Uint8List senderKey; // For outgoing msgs, gets used as recipientKey
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final bool isCli;
  final MessageStatus status;
  final String? originalText;
  final String? translatedText;
  final String? translatedLanguageCode;
  final MessageTranslationStatus translationStatus;
  final String? translationModelId;

  // OTP: for an outgoing message that was OTP-encrypted, `text` holds the
  // stable "OTP1|<hex>" ciphertext actually placed on the wire (and resent
  // verbatim on retries — see message_retry_service.dart), while this field
  // holds what the sender actually typed, purely so their own sent bubble
  // shows readable text instead of hex. Never set for incoming messages —
  // those get decrypted in place, so `text` is already plaintext.
  final String? otpPlaintext;

  // NEW: Retry logic fields
  final String messageId;
  final int retryCount;
  final int? estimatedTimeoutMs;
  final int? expectedAckHash;
  final DateTime? sentAt;
  final DateTime? deliveredAt;
  // When this message entered MessageStatus.waiting (store-and-forward),
  // so the UI can show a relative "waiting since" caption the same way it
  // does for sentAt/deliveredAt. Never set for any other status.
  final DateTime? waitingSinceAt;
  final int? tripTimeMs;
  final int? pathLength;
  final Uint8List pathBytes;
  final Map<String, List<String?>> reactions;
  final Map<String, MessageStatus> reactionStatuses;
  final Uint8List fourByteRoomContactKey;

  // OTP: only set while this outgoing message is an in-flight multi-part
  // chunked send (see meshcore_connector.dart's _OtpContactChunkSend) —
  // chunkIndex is the 0-based part currently being sent/awaiting its ack,
  // chunkTotal the part count. Lets the UI show real progress ("2/5")
  // instead of a generic pending spinner for the whole transfer. Stays
  // set (and simply unused) once status leaves `pending`, since nothing
  // renders it outside that state.
  final int? chunkIndex;
  final int? chunkTotal;

  Message({
    required this.senderKey,
    required this.text,
    required this.timestamp,
    required this.isOutgoing,
    this.isCli = false,
    this.status = MessageStatus.pending,
    String? messageId,
    this.originalText,
    this.translatedText,
    this.translatedLanguageCode,
    this.translationStatus = MessageTranslationStatus.none,
    this.translationModelId,
    this.otpPlaintext,
    this.retryCount = 0,
    this.estimatedTimeoutMs,
    this.expectedAckHash,
    this.sentAt,
    this.deliveredAt,
    this.waitingSinceAt,
    this.tripTimeMs,
    this.pathLength,
    Uint8List? pathBytes,
    Uint8List? fourByteRoomContactKey,
    Map<String, List<String?>>? reactions,
    Map<String, MessageStatus>? reactionStatuses,
    this.chunkIndex,
    this.chunkTotal,
  }) : messageId =
           messageId ??
           '${timestamp.millisecondsSinceEpoch}_${pubKeyToHex(senderKey)}_${text.hashCode}',
       pathBytes = pathBytes ?? Uint8List(0),
       fourByteRoomContactKey = fourByteRoomContactKey ?? Uint8List(0),
       reactions = reactions ?? {},
       reactionStatuses = reactionStatuses ?? {};

  String get senderKeyHex => pubKeyToHex(senderKey);

  Message copyWith({
    String? text,
    MessageStatus? status,
    int? retryCount,
    int? estimatedTimeoutMs,
    int? expectedAckHash,
    DateTime? sentAt,
    DateTime? deliveredAt,
    Object? waitingSinceAt = _unset,
    int? tripTimeMs,
    int? pathLength,
    Uint8List? pathBytes,
    bool? isCli,
    Object? originalText = _unset,
    Object? translatedText = _unset,
    Object? translatedLanguageCode = _unset,
    MessageTranslationStatus? translationStatus,
    Object? translationModelId = _unset,
    Object? otpPlaintext = _unset,
    Map<String, List<String?>>? reactions,
    Map<String, MessageStatus>? reactionStatuses,
    Uint8List? fourByteRoomContactKey,
    int? chunkIndex,
    int? chunkTotal,
  }) {
    return Message(
      senderKey: senderKey,
      text: text ?? this.text,
      timestamp: timestamp,
      isOutgoing: isOutgoing,
      isCli: isCli ?? this.isCli,
      status: status ?? this.status,
      messageId: messageId,
      originalText: originalText == _unset
          ? this.originalText
          : originalText as String?,
      translatedText: translatedText == _unset
          ? this.translatedText
          : translatedText as String?,
      translatedLanguageCode: translatedLanguageCode == _unset
          ? this.translatedLanguageCode
          : translatedLanguageCode as String?,
      translationStatus: translationStatus ?? this.translationStatus,
      translationModelId: translationModelId == _unset
          ? this.translationModelId
          : translationModelId as String?,
      otpPlaintext: otpPlaintext == _unset
          ? this.otpPlaintext
          : otpPlaintext as String?,
      retryCount: retryCount ?? this.retryCount,
      estimatedTimeoutMs: estimatedTimeoutMs ?? this.estimatedTimeoutMs,
      expectedAckHash: expectedAckHash ?? this.expectedAckHash,
      sentAt: sentAt ?? this.sentAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      waitingSinceAt: waitingSinceAt == _unset
          ? this.waitingSinceAt
          : waitingSinceAt as DateTime?,
      tripTimeMs: tripTimeMs ?? this.tripTimeMs,
      pathLength: pathLength ?? this.pathLength,
      pathBytes: pathBytes ?? this.pathBytes,
      reactions: reactions ?? this.reactions,
      reactionStatuses: reactionStatuses ?? this.reactionStatuses,
      fourByteRoomContactKey:
          fourByteRoomContactKey ?? this.fourByteRoomContactKey,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      chunkTotal: chunkTotal ?? this.chunkTotal,
    );
  }

  static Message? fromFrame(Uint8List frame, Uint8List selfPubKey) {
    if (frame.length < msgTextOffset + 1) return null;
    final reader = BufferReader(frame);
    try {
      final code = reader.readByte();
      if (code != respCodeContactMsgRecv && code != respCodeContactMsgRecvV3) {
        return null;
      }

      final senderKey = reader.readBytes(pubKeySize);
      final timestampRaw = reader.readInt32LE();
      final flags = reader.readByte();
      if ((flags >> 2) != txtTypePlain) {
        return null;
      }
      final text = reader.readCString();

      return Message(
        senderKey: senderKey,
        text: text,
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestampRaw * 1000),
        isOutgoing: false,
        isCli: false,
        status: MessageStatus.delivered,
        pathBytes: Uint8List(0),
      );
    } catch (e) {
      return null;
    }
  }

  static Message outgoing(
    Uint8List recipientKey,
    String text, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
    String? otpPlaintext,
    int? pathLength,
    Uint8List? pathBytes,
    int? chunkIndex,
    int? chunkTotal,
  }) {
    return Message(
      senderKey: recipientKey,
      text: text,
      originalText: originalText,
      translatedLanguageCode: translatedLanguageCode,
      translationModelId: translationModelId,
      otpPlaintext: otpPlaintext,
      timestamp: DateTime.now(),
      isOutgoing: true,
      isCli: false,
      status: MessageStatus.pending,
      pathLength: pathLength,
      pathBytes: pathBytes,
      chunkIndex: chunkIndex,
      chunkTotal: chunkTotal,
    );
  }

  /// What should actually be shown in the UI: the sender's own typed
  /// plaintext for an OTP-encrypted outgoing message, otherwise `text` as
  /// usual (already plaintext for everything else, including OTP messages
  /// received from someone else — those are decrypted in place on arrival).
  String get displayText => otpPlaintext ?? text;

  static ReactionInfo? parseReaction(String text) {
    return ReactionHelper.parseReaction(text);
  }
}
