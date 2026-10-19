import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:meshcore_open/storage/region_store.dart';
import 'package:pointycastle/export.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import '../models/channel.dart';
import '../models/channel_message.dart';
import '../models/companion_radio_stats.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../models/otp_pad.dart';
import '../models/otp_sync_status.dart';
import '../models/path_selection.dart';
import '../models/translation_support.dart';
import '../helpers/reaction_helper.dart';
import '../helpers/channel_resend_coverage.dart';
import '../helpers/cyr2lat.dart';
import '../helpers/smaz.dart';
import '../storage/otp_pad_store.dart';
import '../storage/passphrase_lock_store.dart';
import '../services/app_debug_log_service.dart';
import '../services/otp_service.dart';
import '../services/otp_chunk_service.dart';
import '../services/otp_channel_offset_service.dart';
import '../services/otp_sync_service.dart';
import '../services/passphrase_lock_service.dart';
import '../services/ble_debug_log_service.dart';
import '../services/linux_ble_error_classifier.dart';
import '../services/linux_ble_pairing_service_stub.dart'
    if (dart.library.io) '../services/linux_ble_pairing_service.dart';
import '../services/image_chunk_transport.dart'
    show
        ImageChunkOutcome,
        ImageChunkStatus,
        ImageChunkTransport,
        ImageReassemblyResult,
        ImageStreamKey,
        ImageStreamMetadata,
        buildSendChannelDataFrame,
        dataTypeAeicImage,
        outPathUnknown,
        respCodeChannelDataRecv,
        senderPrefixFromKey;
import '../services/image_codec_service.dart';
import '../services/otp_image_transport.dart';
import '../services/received_image_store.dart';
import '../widgets/image_send_codec_binding.dart'
    show ImageCodecRatePoint, kImageCodecSquareSize;
import '../models/image_codec_support.dart' show aeicRatePointForUi;
import '../services/message_retry_service.dart';
import '../services/path_history_service.dart';
import '../services/app_settings_service.dart';
import '../services/background_service.dart';
import '../services/timeout_prediction_service.dart';
import '../services/translation_service.dart';
import '../services/notification_reply.dart';
import '../services/notification_service.dart';
import 'meshcore_connector_usb.dart';
import 'meshcore_connector_tcp.dart';
import '../storage/channel_message_store.dart';
import '../storage/channel_order_store.dart';
import '../storage/channel_settings_store.dart';
import '../storage/channel_region_store.dart';
import '../storage/channel_storage_migration.dart';
import '../storage/channel_store.dart';
import '../storage/contact_discovery_store.dart';
import '../storage/contact_settings_store.dart';
import '../storage/contact_store.dart';
import '../storage/message_store.dart';
import '../storage/unread_store.dart';
import '../review_mode/review_mode_storage.dart';
import '../review_mode/review_radio.dart';
import '../utils/app_logger.dart';
import '../utils/battery_utils.dart';
import '../utils/platform_info.dart';
import 'meshcore_uuids.dart';
import 'meshcore_protocol.dart';
import 'pending_command_replies.dart';
import 'raw_packet.dart';

/// Result of trying to OTP-decrypt+dispatch one incoming message — see the
/// "OTP receive dispatch" section of [MeshCoreConnector] for what each
/// combination means.
typedef _OtpDispatchResult = ({bool handled, String? displayText});

class DirectRepeater {
  static const int maxAgeMinutes = 30; // Max age for direct repeater info
  List<int> pubkeyPrefix;
  int pathHashWidth;
  String? contactKeyHex;
  double snr;
  DateTime lastUpdated;

  DirectRepeater({
    required List<int> pubkeyPrefix,
    required this.pathHashWidth,
    this.contactKeyHex,
    required this.snr,
    DateTime? lastUpdated,
  }) : pubkeyPrefix = List.unmodifiable(pubkeyPrefix),
       lastUpdated = lastUpdated ?? DateTime.now();

  String get pubkeyPrefixHex => pubkeyPrefix
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  bool matchesPrefix(List<int> prefix) {
    return pubkeyPrefix.length == prefix.length &&
        listEquals(pubkeyPrefix, prefix);
  }

  bool matchesPathStart(List<int> pathBytes, int pathHashByteWidth) {
    final width = pathHashByteWidth.clamp(1, 4).toInt();
    if (pathBytes.length < width || pubkeyPrefix.length != width) {
      return false;
    }
    return listEquals(pubkeyPrefix, pathBytes.sublist(0, width));
  }

  void update(
    double newSNR, {
    List<int>? pubkeyPrefix,
    int? pathHashWidth,
    String? contactKeyHex,
  }) {
    snr = newSNR;
    if (pubkeyPrefix != null &&
        pubkeyPrefix.length >= this.pubkeyPrefix.length) {
      this.pubkeyPrefix = List.unmodifiable(pubkeyPrefix);
    }
    if (pathHashWidth != null && pathHashWidth >= this.pathHashWidth) {
      this.pathHashWidth = pathHashWidth;
    }
    this.contactKeyHex ??= contactKeyHex;
    lastUpdated = DateTime.now();
  }

  int get ranking {
    if (isStale()) {
      return -1; // Stale repeaters get lowest rank
    }
    // Higher SNR gets higher rank and recency within maxAgeMinutes breaks ties.
    final ageMs =
        DateTime.now().millisecondsSinceEpoch -
        lastUpdated.millisecondsSinceEpoch;
    final maxAgeMs = maxAgeMinutes * 60 * 1000;
    final recencyScore = (maxAgeMs - ageMs).clamp(0, maxAgeMs);
    return ((snr - 31.75) * 1000).round() + recencyScore;
  }

  bool isStale() {
    return DateTime.now().difference(lastUpdated) >
        const Duration(minutes: maxAgeMinutes);
  }
}

enum MeshCoreConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
}

enum MeshCoreTransportType { bluetooth, usb, tcp, review }

class RepeaterBatterySnapshot {
  final int millivolts;
  final DateTime updatedAt;
  final String source;

  const RepeaterBatterySnapshot({
    required this.millivolts,
    required this.updatedAt,
    required this.source,
  });
}

class MeshCoreRadioStateSnapshot {
  final int freqHz;
  final int bwHz;
  final int sf;
  final int cr;
  final int txPowerDbm;

  const MeshCoreRadioStateSnapshot({
    required this.freqHz,
    required this.bwHz,
    required this.sf,
    required this.cr,
    required this.txPowerDbm,
  });
}

class MeshCoreConnector extends ChangeNotifier {
  // Message windowing to limit memory usage
  static const int _messageWindowSize = 200;

  // Cap on discovered (non-contact) nodes retained in memory. Adverts arrive
  // continuously from the whole mesh, so without a bound this list grows for
  // as long as the app stays connected. When full, the stalest node (oldest
  // lastSeen) is evicted to make room for a newly heard one.
  static const int maxDiscoveredContacts = 500;

  MeshCoreConnectionState _state = MeshCoreConnectionState.disconnected;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;
  String? _deviceDisplayName;
  String? _deviceId;
  BluetoothDevice? _lastDevice;
  String? _lastDeviceId;
  String? _lastDeviceDisplayName;
  bool _manualDisconnect = false;
  // Bumped by every BLE connect attempt so a superseded attempt can tell it
  // no longer owns the connector.
  int _bleConnectGeneration = 0;

  /// Non-null while [disconnect] is tearing the transport down. Connect paths
  /// join it so a teardown cannot finish after a new connection and reset the
  /// state to `disconnected`. USB made this reachable: its native close now
  /// waits out the kernel's closing_wait off the UI isolate, so the teardown
  /// can outlive the tap that starts the next connection.
  Future<void>? _activeDisconnect;

  /// Set by [dispose]. A teardown started before disposal can still be running
  /// (the USB native close waits out the kernel's closing_wait off the UI
  /// isolate), so state publication is suppressed once the connector is gone.
  bool _disposed = false;
  final MeshCoreUsbManager _usbManager = MeshCoreUsbManager();
  final LinuxBlePairingService _linuxBlePairingService =
      LinuxBlePairingService();
  StreamSubscription<Uint8List>? _usbFrameSubscription;
  final MeshCoreTcpConnector _tcpConnector = MeshCoreTcpConnector();
  MeshCoreTransportType _activeTransport = MeshCoreTransportType.bluetooth;
  ReviewRadio? _reviewRadio;
  StreamSubscription<Uint8List>? _reviewFrameSubscription;
  int _reviewConnectGeneration = 0;

  final List<ScanResult> _scanResults = [];
  final List<ScanResult> _linuxSystemScanResults = [];
  final List<Contact> _contacts = [];
  final List<Contact> _discoveredContacts = [];
  final List<Channel> _channels = [];
  final Map<String, List<Message>> _conversations = {};
  final Map<int, List<ChannelMessage>> _channelMessages = {};
  final List<String> _pendingChannelSentQueue = [];
  final PendingCommandReplies _pendingGenericAckQueue = PendingCommandReplies(
    staleAfter: _commandAckTimeout * 2,
  );
  // RESP_CODE_CLI_REPLY texts, consumed in order by runLocalCliCommand.
  final List<String> _cliReplies = [];
  Future<void> _cliChain = Future<void>.value();
  static const String _reactionSendQueuePrefix = '__reaction_send__';
  // TXT_TYPE_CLI_COMMAND (firmware TxtDataHelpers.h).
  static const int _txtTypeCliCommand = 3;
  // ERR_CODE_NOT_FOUND (companion MyMesh.cpp).
  static const int _errCodeNotFound = 2;
  int _reactionSendQueueSequence = 0;
  final Set<String> _loadedConversationKeys = {};
  // Self public key of the radio whose messages are held in memory.
  String? _messageStateOwnerKey;
  // Self public key whose persisted stores were loaded this link session.
  // Later SELF_INFO replies (refreshDeviceInfo after a settings change) skip
  // the reload while it still matches.
  String? _persistedStateLoadedKey;
  final Map<int, Set<String>> _processedChannelReactions =
      {}; // channelIndex -> Set of "targetHash_emoji"
  final Map<String, Set<String>> _processedContactReactions =
      {}; // contactPubKeyHex -> Set of "targetHash_emoji"

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<NotificationReply>? _notificationReplySubscription;
  Timer? _notifyListenersTimer;
  Timer? _selfInfoRetryTimer;
  Timer? _reconnectTimer;
  Timer? _batteryPollTimer;
  Timer? _gpsLocationPollTimer;
  static const _gpsLocationPollInterval = Duration(minutes: 1);
  Timer? _radioStatsPollTimer;
  int _radioStatsPollRefCount = 0;
  final ValueNotifier<CompanionRadioStats?> radioStatsNotifier =
      ValueNotifier<CompanionRadioStats?>(null);
  int _reconnectAttempts = 0;
  // Endpoint of the last TCP link that completed its handshake. Set only
  // after SELF_INFO, cleared on a manual disconnect or a user-started
  // connect, so a failed first attempt never loops on a bad address.
  String? _tcpReconnectHost;
  int? _tcpReconnectPort;
  // True while [connectTcp] runs on behalf of [_scheduleTcpReconnect].
  bool _tcpAutoReconnectAttempt = false;
  // Bumped by each [connectTcp] and by every disconnect, so an attempt that
  // was superseded mid-handshake cannot record a stale reconnect target.
  int _tcpConnectGeneration = 0;
  bool _notifyListenersDirty = false;
  static const Duration _notifyListenersDebounce = Duration(milliseconds: 50);

  final StreamController<Uint8List> _receivedFramesController =
      StreamController<Uint8List>.broadcast();

  Uint8List? _selfPublicKey;
  String? _selfName;
  int? _currentTxPower;
  int? _maxTxPower;
  int? _currentFreqHz;
  int? _currentBwHz;
  int? _currentSf;
  int? _currentCr;
  bool? _clientRepeat;
  MeshCoreRadioStateSnapshot? _rememberedNonRepeatRadioState;
  int? _firmwareVerCode;
  int _pathHashByteWidth = 1;
  CompanionRadioStats? _latestRadioStats;
  Stopwatch? _airtimeBumpStopwatch;
  int _prevTotalAirSecs = 0;
  int? _batteryMillivolts;
  double? _selfLatitude;
  double? _selfLongitude;
  final List<DirectRepeater> _directRepeaters = List.empty(growable: true);
  bool _isLoadingContacts = false;
  DateTime? _contactSyncRequestedAt;
  bool _hasLoadedContacts = false;
  bool _isLoadingChannels = false;
  bool _hasLoadedChannels = false;
  TimeoutPredictionService? _timeoutPredictionService;
  TranslationService? _translationService;
  ImageCodecService? _imageCodecService;
  // Holds the ImageReassembler, so partially received images survive across
  // frames (chunks of one image arrive in separate GRP_DATA frames, and via the
  // firmware offline queue they may be minutes apart).
  ImageChunkTransport? _imageTransport;
  void Function(ImageChunkOutcome outcome)? _onImageChunk;
  void Function(int senderPrefix)? _onImageSenderPrefix;
  // OTP-encrypted DM image transfer (see otp_image_transport.dart) reuses
  // this same store for its receive-side state/decode-queue/eviction —
  // injected here exactly like _imageCodecService/_imageTransport above,
  // rather than duplicating any of that machinery for the DM path.
  ReceivedImageStore? _receivedImageStore;

  /// Arbitrary, fixed `senderPrefix` values used only to keep
  /// [ReceivedImageStore]'s `(senderPrefix, imgId, channelIndex)` key space
  /// from colliding an incoming OTP DM image with an outgoing one that
  /// happens to reuse the same chunk-transfer id (`imgId`) on the same
  /// contact's virtual channel index. A DM has only two parties and each
  /// direction is always tagged consistently, so — unlike a real channel,
  /// where senderPrefix disambiguates N different senders — these never
  /// need to identify a real device.
  static const int _otpDmIncomingSenderPrefix = 1;
  static const int _otpDmOutgoingSenderPrefix = 2;
  // Intentionally global (not per-contact): tracks overall network activity.
  // Frequent RX from any source indicates a busy network with more collisions.
  DateTime _lastRxTime = DateTime.now();
  // Snapshot of _lastRxTime taken before the ACK frame updates it, so that
  // onDeliveryObserved records the pre-ACK elapsed time (matching prediction).
  DateTime _lastRxBeforeFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRadioRxTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastContactMsgRxTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastChannelMsgRxTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastZeroHopAdvertAt = DateTime.fromMillisecondsSinceEpoch(0);
  double? _lastZeroHopAdvertLatitude;
  double? _lastZeroHopAdvertLongitude;
  static const int _radioQuietMs = 3000;
  static const int _radioQuietMaxWaitMs = 3000;

  /// When companion radio stats are unavailable, keep the legacy fixed backoff.
  static const int _contactMsgBackoffFallbackMs = 5000;
  static const int _contactMsgBackoffMinMs = 500;
  static const int _contactMsgBackoffMaxMs = 15000;
  int _pollingInterval = 30;
  bool _batteryRequested = false;
  bool _awaitingSelfInfo = false;
  bool _hasReceivedDeviceInfo = false;
  String? _manufacturerName;
  String? _firmwareVersionString;
  String? _firmwareBuildDate;
  // Initial sync is serialized for predictable progress. Firmware exposes one
  // FIFO queued-message stream, so direct/room frames are buffered until after
  // contacts are known.
  bool _pendingInitialChannelSync = false;
  bool _pendingInitialContactsSync = false;
  bool _pendingInitialQueuedMessageSync = false;
  bool _bleInitialSyncStarted = false;
  bool _webInitialHandshakeRequestSent = false;
  bool _preserveContactsOnRefresh = false;
  bool _autoAddUsers = false;
  bool _autoAddRepeaters = false;
  bool _autoAddRoomServers = false;
  bool _autoAddSensors = false;
  bool _overwriteOldest = false;
  int? _autoAddMaxHops;
  bool _deviceConfigRequested = false;
  List<RepeatFreqRange>? _allowedRepeatFreqRanges;
  bool _contactsStorageFull = false;
  final StreamController<void> _contactsFullController =
      StreamController<void>.broadcast();
  bool _manualAddContacts = false;
  int _telemetryModeBase = 0;
  int _telemetryModeLoc = 0;
  int _telemetryModeEnv = 0;
  int _advertLocPolicy = 0;
  int _multiAcks = 0;

  static const int _defaultMaxContacts = 350;
  static const int _defaultMaxChannels = 40;
  int _maxContacts = _defaultMaxContacts;
  int _maxChannels = _defaultMaxChannels;
  int? _contactSyncTotal;
  int _contactSyncReceived = 0;
  bool _contactSyncUsesSinceFilter = false;
  bool _isSyncingQueuedMessages = false;
  bool _deferQueuedContactMessagesUntilContacts = false;
  bool _isProcessingDeferredQueuedContactMessages = false;
  bool _queuedMessageSyncInFlight = false;
  final List<Uint8List> _deferredQueuedContactMessageFrames = [];

  /// Channel frames that arrived before this session's slot map was
  /// confirmed. The firmware only sends them in reply to SYNC_NEXT_MESSAGE,
  /// which waits for the map, so this is a guard: their slot index cannot be
  /// resolved yet, and they are replayed once it can.
  final List<Uint8List> _channelFramesAwaitingMap = [];
  bool _pendingQueueSync = false;
  // CMD_APP_START stops the firmware's contact iterator (END_OF_CONTACTS is
  // then never sent), so APP_START requested during a contact sync is held
  // until the sync ends.
  bool _appStartDeferredForContactSync = false;
  // Ends a contact sync whose frames stopped arriving, so queued-message sync
  // and deferred processing cannot stay blocked behind it.
  Timer? _contactSyncWatchdog;
  static const Duration _contactSyncStallTimeout = Duration(seconds: 20);
  // Contact messages whose sender was not a known contact yet. The firmware
  // already removed them from its offline queue, so they are held and
  // replayed once the sender's CONTACT frame arrives (or the sync ends).
  final List<Uint8List> _unknownSenderMessageFrames = [];
  static const int _maxUnknownSenderMessageFrames = 32;
  Timer? _queueSyncTimeout;
  int _queueSyncRetries = 0;
  static const int _maxQueueSyncRetries = 3;
  static const int _queueSyncTimeoutMs = 5000; // 5 second timeout
  // Serializes path operations (setContactPath/clearContactPath) to prevent
  // interleaved async calls from leaving in-memory state inconsistent with device.
  Future<void> _pathOpLock = Future.value();
  // Flood scope is a global firmware setting, so scoped channel sends must not
  // overlap or a message may inherit another channel's region.
  Future<void> _channelScopedSendLock = Future.value();
  static const Duration _commandAckTimeout = Duration(seconds: 5);
  Map<String, String>? _currentCustomVars;

  /// Maps repeater pubkey-prefix hex (12 hex chars = first 6 bytes) → the
  /// repeater's RTC clock at the moment of the most recent successful login.
  /// Reported by firmware in the login-success push frame at byte offset 8.
  final Map<String, DateTime> _repeaterLoginClocks = {};

  // Channel syncing state (sequential pattern)
  bool _isSyncingChannels = false;
  bool _channelSyncInFlight = false;
  Timer? _channelSyncTimeout;
  int _channelSyncRetries = 0;
  int _nextChannelIndexToRequest = 0;
  int _totalChannelsToRequest = 0;
  List<Channel> _previousChannelsCache = [];
  // Slots whose GET_CHANNEL timed out in the last sync with no cached copy:
  // their contents are unknown, so UI must not treat them as free.
  final Set<int> _unconfirmedChannelSlots = {};
  // A slot timed out in this sync pass (restored from cache or unconfirmed).
  bool _channelSyncIncomplete = false;
  int _channelMapSyncRetries = 0;
  static const int _maxChannelMapSyncRetries = 2;
  // Completes when the running channel sync has applied its slot map.
  Completer<void>? _channelSyncCompleter;
  static const int _maxChannelSyncRetries = 3;
  @visibleForTesting
  int channelSyncTimeoutMs = 2000; // timeout per channel
  // Slot -> Channel.storageId for the connected radio. Persisted data is
  // keyed by channel ID while in-memory state stays keyed by slot; this map
  // is the only bridge between them. Seeded from the saved map at SELF_INFO
  // and replaced when a channel sync completes.
  final Map<int, String> _slotChannelIds = {};
  // Whether this session's channel sync has confirmed _slotChannelIds.
  // Queued channel frames carry only a slot index, so they wait for it.
  bool _channelMapConfirmed = false;
  int _channelSessionGeneration = 0;
  Future<void> _channelStorageReady = Future<void>.value();
  static const Duration _batteryPollInterval = Duration(seconds: 120);

  // Services
  MessageRetryService? _retryService;
  PathHistoryService? _pathHistoryService;
  AppSettingsService? _appSettingsService;

  double get _initialRouteWeight =>
      _appSettingsService?.settings.initialRouteWeight ?? 1.0;
  BackgroundService? _backgroundService;
  final NotificationService _notificationService = NotificationService();
  BleDebugLogService? _bleDebugLogService;
  AppDebugLogService? _appDebugLogService;
  final ChannelMessageStore _channelMessageStore = ChannelMessageStore();
  final MessageStore _messageStore = MessageStore();
  final ChannelOrderStore _channelOrderStore = ChannelOrderStore();
  final ChannelSettingsStore _channelSettingsStore = ChannelSettingsStore();
  final ChannelRegionStore _channelRegionStore = ChannelRegionStore();
  final ContactSettingsStore _contactSettingsStore = ContactSettingsStore();
  final OtpPadStore _otpPadStore = OtpPadStore();
  final ContactStore _contactStore = ContactStore();
  final ContactDiscoveryStore _discoveryContactStore = ContactDiscoveryStore();
  final ChannelStore _channelStore = ChannelStore();
  final UnreadStore _unreadStore = UnreadStore();
  List<Channel> _cachedChannels = [];
  final Map<int, bool> _channelSmazEnabled = {};
  final Map<int, bool> _channelCyr2LatEnabled = {};
  final Map<int, bool> _channelUrlImagesEnabled = {};
  final Map<int, String?> _channelCyr2LatProfileId = {};
  final Map<int, Region> _channelRegions = {};
  Region _defaultRegion = '';
  final Map<int, OtpPad?> _channelOtpPads = {};
  // Keyed by the raw "OTP1|<hex>" ciphertext string. Channel messages can
  // arrive via two independent paths — RESP_CODE_CHANNEL_MSG_RECV and the
  // raw RX packet log (pushCodeLogRxData → _handleLogRxData), decoded
  // separately from the same physical packet — and both can fire for one
  // logical message. Since OTP ciphertext is effectively unique per message
  // (pad-derived, never repeats), caching by ciphertext lets the second
  // delivery reuse the first's result instead of decrypting again and
  // silently burning a second slice of pad for something already decoded.
  // Capped and FIFO-trimmed; this only needs to outlive brief redelivery
  // windows, not the whole session.
  static const int _otpDecryptCacheLimit = 64;
  final Map<String, String> _otpDecryptCache = {};
  final List<String> _otpDecryptCacheOrder = [];
  // Chunked (multi-packet) OTP message state — see the "OTP chunking"
  // section further down for the full send/receive/ack machinery.
  //
  // Pending outbound chunked transfers, one per contact / one per channel
  // at a time (mirrors Lua's single in-flight `psend`).
  final Map<String, _OtpContactChunkSend> _pendingContactChunkSends = {};
  final Map<int, _OtpChannelChunkSend> _pendingChannelChunkSends = {};
  // Phase 2 channel-collision mitigation (cheap jitter delay, matching
  // OTP_3_RC1.lua's `pending_channel_send`/`channel_jitter_tick` — see
  // that file's comment for the full tradeoff discussion vs. a full
  // reserve/commit handshake). A channel send with OTP enabled does not
  // capture the pad offset or encrypt at the moment the user hits send;
  // it waits a short random delay first (`_channelJitterDelay`), so a
  // competing message that arrives during the wait gets to advance this
  // channel's pad offset FIRST — see `_encryptForChannel`, which always
  // reads the pad fresh at call time. This set blocks a second send to
  // the same channel while one is still in that delay window (mirrors
  // the `_pendingChannelChunkSends` guard above).
  final Set<int> _pendingChannelJitterChannels = {};
  static const Duration _channelJitterMin = Duration(milliseconds: 600);
  static const Duration _channelJitterMax = Duration(milliseconds: 2200);
  final _channelJitterRandom = math.Random();
  // Deliberately generous rather than tied to an exact hop count (not
  // knowable before an unseen competing message actually arrives) — see
  // the Lua-side constant of the same name for the full reasoning.
  Duration _channelJitterDelay() {
    final spanMs =
        _channelJitterMax.inMilliseconds - _channelJitterMin.inMilliseconds;
    return _channelJitterMin +
        Duration(milliseconds: _channelJitterRandom.nextInt(spanMs + 1));
  }

  // Inbound reassembly state, keyed by (contact-or-channel, tid) — unlike
  // Lua's single global `imt`, this app can have multiple contacts (and a
  // channel) each with their own in-flight inbound transfer concurrently.
  final Map<String, Map<int, _OtpChunkReassembly>> _contactChunkReassembly = {};
  final Map<int, Map<int, _OtpChunkReassembly>> _channelChunkReassembly = {};
  // Small cache of acks already sent for a given (scope, tid, idx), so a
  // duplicate-received chunk (redelivered before its first ack even lands)
  // reuses the already-computed ack ciphertext instead of re-encrypting
  // (and burning another slice of pad) for an ack that says the same thing.
  static const int _otpAckCacheLimit = 24;
  final Map<String, String> _otpAckCache = {};
  final List<String> _otpAckCacheOrder = [];
  // Remembers which already-decrypted ciphertext hexes (tracked in
  // _otpDecryptCache above) were chunk pieces, and their (tid, idx) — so a
  // redelivered chunk still gets its ack re-sent (the sender's own retry
  // means the first ack may not have landed) without ever re-decrypting or
  // re-consuming pad for it. Shares _otpDecryptCache's FIFO trimming since
  // an entry only exists here while it also exists there.
  final Map<String, ({int tid, int idx})> _otpChunkHexIndex = {};
  // ── OTP passphrase lock (Feature: passphrase lock + panic wipe) ──────
  final PassphraseLockStore _passphraseLockStore = PassphraseLockStore();
  // Held only in memory, only for this session — never persisted (matches
  // Lua's `session_key`). Non-null exactly when protection is enabled AND
  // unlocked; see otpProtectionEnabled/otpLocked.
  Uint8List? _otpSessionKey;
  bool _otpPanicArmed = false;
  DateTime? _otpPanicArmedAt;
  static const Duration _otpPanicConfirmWindow = Duration(seconds: 4);
  // ── OTP pad sync-check (Feature: pad sync-check) ──────────────────────
  final Map<String, OtpSyncStatus> _contactOtpSyncStatus = {};
  // channelIndex -> senderName -> status for that participant.
  final Map<int, Map<String, OtpSyncStatus>> _channelOtpSyncStatus = {};
  final Map<String, Timer> _otpSyncTimeoutTimers = {};
  static const Duration _otpSyncTimeout = Duration(seconds: 20);
  // ── OTP pad auto-resync ────────────────────────────────────────────────
  // Every send burns pad bytes off the sender's own local copy immediately,
  // before any confirmation the message was actually received - so a lost
  // packet (dropped over the mesh, a chunk that times out, a device
  // restarting mid-exchange) leaves the sender's counter ahead of the
  // receiver's, and every message after that decrypts against the wrong
  // slice of pad. Recovery is one-directional and safe by construction:
  // this device's own "how much of the peer's stream have I consumed"
  // counter (theirOffset for a DM, offset for a channel) can always be
  // advanced FORWARD to match what the peer reports having sent, without
  // ever reusing a pad byte - it only ever skips ahead past bytes the
  // sender already burned. The specific message(s) that got lost are gone
  // either way (that content was unrecoverable the moment the sender
  // burned its own copy); resyncing just stops it from corrupting every
  // message afterward too. This NEVER touches myOffset/this device's own
  // send counter - that's this device's own record of what it has
  // actually transmitted, not something to guess at from a peer's report.
  //
  // To avoid discarding a message that's merely still in flight (not
  // actually lost), a detected gap has to persist across the same value
  // for _resyncGracePeriod before it's acted on.
  static const Duration _resyncGracePeriod = Duration(seconds: 12);
  // What's tracked while waiting out the grace period is the PEER'S
  // REPORTED ABSOLUTE OFFSET (peerOffset), not a fixed byte count taken
  // at detection time. A byte count captured then would go stale if any
  // of the "missing" messages turn out not to have been lost after all —
  // still in flight, decrypting normally through the ordinary receive
  // path at any point during the wait, which advances theirOffset/offset
  // on its own, independently of this bookkeeping. Applying a stale byte
  // count at expiry would then skip PAST bytes still needed for the next
  // real message — corrupting it, permanently, since this correction
  // only ever moves the receive counter forward. Recomputing the gap
  // against the CURRENT offset right before acting (see
  // _maybeAutoResyncContact/_maybeAutoResyncChannel) is what makes this
  // safe: if the pad already caught up on its own, there's nothing left
  // to do.
  final Map<String, ({int peerOffset, DateTime firstSeen})>
  _pendingContactResync = {};
  // channelIndex -> senderName -> pending state for that participant.
  final Map<int, Map<String, ({int peerOffset, DateTime firstSeen})>>
  _pendingChannelResync = {};
  // Found from a real device report: hitting "resync" could drain a DM
  // pad straight to 0 bytes, then the reply this device sends back would
  // do the exact same thing to the OTHER side's pad — both ending up
  // "exhausted" from one resync. _maybeAutoResyncContact previously had
  // no ceiling at all on how much it would silently auto-consume in one
  // shot — only an all-or-nothing check (refuse if the WHOLE gap doesn't
  // fit, otherwise consume the whole gap, however large). A gap that's
  // merely large (not literally bigger than what's left) sailed straight
  // through and could eat most or all of a small pad in one call. This is
  // exactly the failure shape a same-role collision produces (see
  // resolveDmRole's doc comment on that being undetectable by the
  // ordinary in-sync check), but the cap below is real protection against
  // ANY cause of an implausibly large reported gap, not just that one.
  // _contactResyncStreak counts consecutive auto-resyncs for a contact
  // with no genuine, fully-confirmed in-sync in between (see
  // _maybeHandleContactSyncMessage, which resets it to 0 on a real
  // bidirectional match) — a gap that keeps reappearing after being
  // "fixed" indicates a persistent mismatch an automatic byte-skip can
  // never actually resolve, only mask one round at a time while eating
  // the pad down to nothing.
  final Map<String, int> _contactResyncStreak = {};
  static const double _maxAutoResyncFraction = 0.5;
  static const int _maxAutoResyncAbsBytes = 500;
  static const int _maxConsecutiveAutoResyncs = 3;
  final Map<String, Timer> _otpResyncTimers = {};
  Timer? _otpAutoSyncPollTimer;
  // Widened from 120s (2min) to 300s (5min), matching the Lua side's
  // AUTO_SYNC_INTERVAL_MS. A send, a receive, opening the chat, or focusing
  // the compose box already fire an event-driven check right when drift is
  // actually likely (see _requestPromptContactSyncCheck/
  // _requestPromptChannelSyncCheck), so this periodic timer only exists to
  // catch the rare "nothing happened for a while but we drifted anyway"
  // case — it doesn't need to be frequent, and every extra tick is one
  // more transmission that can collide with real chunk traffic on a busy
  // mesh.
  static const Duration _otpAutoSyncPollInterval = Duration(seconds: 300);
  // Airtime backoff: if a PERIODIC check gets no reply at all within
  // _syncBackoffTimeout, the peer is probably unreachable right now (off,
  // out of range, etc.) — polling it again every _otpAutoSyncPollInterval
  // just burns airtime for no benefit. Once backed off, the periodic poll
  // skips that target entirely until either something is heard from it
  // again (a sync-check reply or a fresh check it sent on its own — see
  // _maybeHandleContactSyncMessage/_maybeHandleChannelSyncMessage) or the
  // person starts typing/reopens the chat/sends/receives (all funnel
  // through _requestPromptContactSyncCheck/_requestPromptChannelSyncCheck,
  // which lifts it). A manual "Check Sync" tap always still works — this
  // only suppresses the automatic background probe.
  final Set<String> _contactSyncBackoff = {};
  final Set<int> _channelSyncBackoff = {};
  final Map<String, Timer> _otpBackoffTimers = {};
  static const Duration _syncBackoffTimeout = Duration(seconds: 30);
  // OTP store-and-forward (DMs only — channels have no clean single
  // "is this contact reachable" concept, matching Lua's own DM-only
  // scoping). Ports OTP_3_RC1.lua's waiting_queue/flush_waiting/
  // waiting_tick: a single-shot OTP send that exhausts MessageRetryService's
  // normal retry budget (see RetryServiceConfig.onMaxRetriesExceeded /
  // _handleOtpSendExhausted below) is queued here instead of failing
  // outright, and is retried either the moment something is heard from
  // that contact again (_flushWaitingQueue, called from
  // _maybeHandleContactSyncMessage) or on a slow background sweep
  // (_waitingQueueTickTimer) if nothing is heard at all. No time-based
  // expiry — only a bounded depth, matching Lua's WAITING_QUEUE_CAP.
  final Map<String, List<Message>> _waitingQueue = {};
  static const int _waitingQueueCap = 5;
  final Map<String, DateTime> _lastWaitingFlushAt = {};
  static const Duration _waitingFlushCooldown = Duration(seconds: 10);
  Timer? _waitingQueueTickTimer;
  static const Duration _waitingQueueTickInterval = Duration(minutes: 10);
  // Radio-stored default flood scope (GET_DEFAULT_FLOOD_SCOPE, ver 11+).
  // Null when the radio has none or has not reported it yet.
  String? _defaultFloodScopeName;
  Uint8List? _defaultFloodScopeKey;
  final Map<String, bool> _contactSmazEnabled = {};
  final Map<String, bool> _contactCyr2LatEnabled = {};
  final Map<String, bool> _contactUrlImagesEnabled = {};
  final Map<String, String?> _contactCyr2LatProfileId = {};
  final Map<String, OtpPad?> _contactOtpPads = {};
  final Set<String> _knownContactKeys = {};
  final Map<String, int> _contactUnreadCount = {};
  final Map<String, RepeaterBatterySnapshot> _repeaterBatterySnapshots = {};
  bool _unreadStateLoaded = false;
  int _cachedContactsUnreadTotal = 0;
  int _cachedChannelsUnreadTotal = 0;
  final Map<String, _RepeaterAckContext> _pendingRepeaterAcks = {};
  String? _activeContactKey;
  int? _activeChannelIndex;
  List<String> _channelOrder = [];

  int _storageUsedKb = -1;
  int _storageTotalKb = -1;

  // Getters
  MeshCoreConnectionState get state => _state;
  BluetoothDevice? get device => _device;
  String? get deviceId => _deviceId;
  String get deviceIdLabel => _deviceId ?? 'Unknown';

  /// Stable per-radio key for transport-agnostic per-device settings such as
  /// battery chemistry. On BLE this is the existing remoteId (so previously
  /// saved settings are preserved); on USB/TCP — where there is no BLE
  /// remoteId — it falls back to the node's public key, which identifies the
  /// same physical radio across transports. Null until a device identity is
  /// known.
  String? get batteryDeviceKey {
    if (_deviceId != null) return _deviceId;
    if (_selfPublicKey != null && _selfPublicKey!.isNotEmpty) {
      return selfPublicKeyHex;
    }
    return null;
  }

  MeshCoreTransportType get activeTransport => _activeTransport;
  String? get activeUsbPort => _usbManager.activePortKey;
  String? get activeUsbPortDisplayLabel => _usbManager.activePortDisplayLabel;
  bool get isUsbTransportConnected =>
      _state == MeshCoreConnectionState.connected &&
      _activeTransport == MeshCoreTransportType.usb;
  bool get isAutoReconnectScheduled =>
      (_shouldAutoReconnect || _shouldAutoReconnectTcp) &&
      (_reconnectTimer?.isActive ?? false);
  String? get activeTcpEndpoint => _tcpConnector.activeEndpoint;
  bool get isTcpTransportConnected =>
      _state == MeshCoreConnectionState.connected &&
      _activeTransport == MeshCoreTransportType.tcp;
  bool get isReviewMode =>
      _activeTransport == MeshCoreTransportType.review &&
      _state != MeshCoreConnectionState.disconnected;

  String get deviceDisplayName {
    if (_selfName != null && _selfName!.isNotEmpty) {
      return _selfName!;
    }
    final platformName = _device?.platformName;
    if (platformName != null && platformName.isNotEmpty) {
      return platformName;
    }
    if (_deviceDisplayName != null && _deviceDisplayName!.isNotEmpty) {
      return _deviceDisplayName!;
    }
    return 'Unknown Device';
  }

  List<ScanResult> get scanResults => List.unmodifiable(_scanResults);
  List<Contact> get contacts {
    final selfKey = _selfPublicKey;
    if (selfKey == null) {
      return List.unmodifiable(_contacts);
    }
    return List.unmodifiable(
      _contacts.where((contact) => !listEquals(contact.publicKey, selfKey)),
    );
  }

  Contact? getContactByPubKeyHex(String contactPubKeyHex) {
    return _contacts.cast<Contact?>().firstWhere(
      (c) => c?.publicKeyHex == contactPubKeyHex,
      orElse: () => null,
    );
  }

  List<Contact> get allContacts => List.unmodifiable([
    ..._contacts,
    ..._discoveredContacts.where(
      (c) => !c.isActive && c.publicKeyHex != selfPublicKeyHex,
    ),
  ]);

  List<Contact> get allContactsUnfiltered =>
      List.unmodifiable([..._contacts, ..._discoveredContacts]);

  List<Contact> get discoveredContacts {
    return List.unmodifiable(_discoveredContacts);
  }

  String exportDiscoveredContactsJson() {
    return _discoveryContactStore.exportContactsJson(_discoveredContacts);
  }

  /// Imports an export file into this radio's discovered contacts. Throws
  /// [FormatException] when the file is not a contacts list.
  Future<DiscoveredContactsImportResult> importDiscoveredContactsJson(
    String json,
  ) async {
    // The store is scoped to the connected radio; importing while
    // disconnected would overwrite its saved list with only the import.
    if (!isConnected) return DiscoveredContactsImportResult.empty;
    final result = _discoveryContactStore.importContactsJson(
      json: json,
      existingContacts: _discoveredContacts,
      knownContactKeys: _knownContactKeys,
      selfPublicKeyHex: selfPublicKeyHex,
    );
    if (result.imported == 0) return result;

    if (_evictDiscoveredContactsEnabled) {
      _trimDiscoveredContactsToLimit(_discoveredContacts);
    }
    await _persistDiscoveredContacts();
    notifyListeners();
    return result;
  }

  List<Channel> get channels => List.unmodifiable(_channels);
  bool get isConnected => _state == MeshCoreConnectionState.connected;
  bool get isLoadingContacts => _isLoadingContacts;
  bool get hasLoadedContacts => _hasLoadedContacts;
  bool get isLoadingChannels => _isLoadingChannels;
  bool get hasLoadedChannels => _hasLoadedChannels;
  Set<int> get unconfirmedChannelSlots =>
      Set.unmodifiable(_unconfirmedChannelSlots);

  /// [Channel.storageId] of the channel in radio slot [slot], as of the last
  /// channel sync, or null for an empty or unknown slot.
  String? channelIdForSlot(int slot) => _slotChannelIds[slot];

  @visibleForTesting
  bool get channelMapConfirmed => _channelMapConfirmed;
  Stream<Uint8List> get receivedFrames => _receivedFramesController.stream;

  /// MeshCore Open TAK: returns true to swallow an incoming DM (by sender key
  /// hex and text) before it is stored or notified.
  bool Function(String senderKeyHex, String text)? voxControlTextInterceptor;

  /// MeshCore Open TAK: told about every new incoming DM or channel message
  /// (used to auto-play voice clips as they arrive).
  void Function(
    String text, {
    String? senderKeyHex,
    String? senderName,
    int? channelIndex,
    DateTime? timestamp,
  })?
  voxIncomingTextObserver;
  Uint8List? get selfPublicKey => _selfPublicKey;
  String get selfPublicKeyHex => pubKeyToHex(_selfPublicKey ?? Uint8List(0));

  /// First 2 bytes of the local public key, big-endian: the `senderPrefix`
  /// stamped into every outgoing image chunk header. Null until SELF_INFO.
  int? get imageSenderPrefix => senderPrefixFromKey(_selfPublicKey);

  String? get selfName => _selfName;
  String? get manufacturerName => _manufacturerName;
  String? get firmwareVersionString => _firmwareVersionString;

  /// The firmware's build date as it reports it ("15 Oct 2026"), or null.
  String? get firmwareBuildDate => _firmwareBuildDate;
  double? get selfLatitude => _selfLatitude;
  double? get selfLongitude => _selfLongitude;
  List<DirectRepeater> get directRepeaters => _directRepeaters;
  int? get currentTxPower => _currentTxPower;
  int? get maxTxPower => _maxTxPower;

  int get pathHashByteWidth => _pathHashByteWidth;

  CompanionRadioStats? get latestRadioStats => _latestRadioStats;

  bool get supportsCompanionRadioStats => (_firmwareVerCode ?? 0) >= 8;

  bool get radioStatsAirActivityPulse {
    final sw = _airtimeBumpStopwatch;
    if (sw == null || !sw.isRunning) return false;
    return sw.elapsed < const Duration(seconds: 2);
  }

  int? get currentFreqHz => _currentFreqHz;
  int? get currentBwHz => _currentBwHz;
  int? get currentSf => _currentSf;
  int? get currentCr => _currentCr;
  MeshCoreRadioStateSnapshot? get rememberedNonRepeatRadioState =>
      _rememberedNonRepeatRadioState;
  bool? get autoAddUsers => _autoAddUsers;
  bool? get autoAddRepeaters => _autoAddRepeaters;
  bool? get autoAddRoomServers => _autoAddRoomServers;
  bool? get autoAddSensors => _autoAddSensors;
  bool? get autoAddOverwriteOldest => _overwriteOldest;

  /// autoadd_max_hops from GET_AUTOADD_CONFIG (0 = no limit), null when the
  /// firmware did not report it (pre-v1.13).
  int? get autoAddMaxHops => _autoAddMaxHops;

  /// CMD_GET/SET_AUTOADD_CONFIG exist from companion v1.12.0 (ver code 8).
  bool get supportsAutoAddConfig => (_firmwareVerCode ?? 0) >= 8;

  /// CMD_GET_ALLOWED_REPEAT_FREQ exists from ver code 9 (client repeat).
  bool get supportsAllowedRepeatFreq => (_firmwareVerCode ?? 0) >= 9;

  /// CMD_SEND_CONTROL_DATA / PUSH_CODE_CONTROL_DATA (node discover) exist
  /// from ver code 8.
  bool get supportsNodeDiscover => (_firmwareVerCode ?? 0) >= 8;

  /// CMD_GET/SET_DEFAULT_FLOOD_SCOPE exist from ver code 11 (v1.15.0).
  bool get supportsDefaultFloodScope => (_firmwareVerCode ?? 0) >= 11;

  /// CMD_SET_FLOOD_SCOPE `[54,1]` (send unscoped, overriding the radio's
  /// default scope) exists from ver code 12.
  bool get supportsExplicitUnscopedFlood => (_firmwareVerCode ?? 0) >= 12;

  /// Name of the radio's default flood scope, or null when none is set.
  String? get defaultFloodScopeName => _defaultFloodScopeName;
  Uint8List? get defaultFloodScopeKey => _defaultFloodScopeKey;

  /// Frequency ranges (kHz, inclusive) on which the firmware accepts client
  /// repeat mode. Null until RESP_ALLOWED_REPEAT_FREQ has been received.
  List<RepeatFreqRange>? get allowedRepeatFreqRanges =>
      _allowedRepeatFreqRanges;

  /// True after PUSH_CODE_CONTACTS_FULL: the firmware could not store a new
  /// contact. Cleared when a contact is removed or deleted.
  bool get contactsStorageFull => _contactsStorageFull;

  /// Fires on each PUSH_CODE_CONTACTS_FULL.
  Stream<void> get contactsFullEvents => _contactsFullController.stream;
  int get telemetryModeBase => _telemetryModeBase;
  int get telemetryModeLoc => _telemetryModeLoc;
  int get telemetryModeEnv => _telemetryModeEnv;
  int get advertLocationPolicy => _advertLocPolicy;
  int get multiAcks => _multiAcks;
  bool? get clientRepeat => _clientRepeat;

  /// Returns the repeater's RTC clock at the time of the most recent
  /// successful login, looked up by the contact's full public key.
  /// Returns null if no login response has been observed for this repeater
  /// since connection.
  DateTime? repeaterClockAtLogin(Uint8List publicKey) {
    if (publicKey.length < 6) return null;
    final prefix = pubKeyToHex(publicKey.sublist(0, 6));
    return _repeaterLoginClocks[prefix];
  }

  void rememberNonRepeatRadioState(MeshCoreRadioStateSnapshot snapshot) {
    _rememberedNonRepeatRadioState = snapshot;
  }

  int? get firmwareVerCode => _firmwareVerCode;
  Map<String, String>? get currentCustomVars => _currentCustomVars;
  int? get batteryMillivolts => _batteryMillivolts;
  int? get storageUsedKb => _storageUsedKb;
  int? get storageTotalKb => _storageTotalKb;
  int get maxContacts => _maxContacts;
  int get maxChannels => _maxChannels;
  Set<String> get knownContactKeys => Set.unmodifiable(_knownContactKeys);
  double? get contactSyncProgress {
    final total = _contactSyncTotal;
    if (!_isLoadingContacts || total == null || total <= 0) return null;
    return (_contactSyncReceived / total).clamp(0.0, 1.0).toDouble();
  }

  bool get isSyncingQueuedMessages =>
      _isSyncingQueuedMessages || _isProcessingDeferredQueuedContactMessages;
  bool get isShowingQueuedMessageSyncProgress =>
      _deferQueuedContactMessagesUntilContacts && isSyncingQueuedMessages;
  bool get isSyncingChannels => _isSyncingChannels;
  int get channelSyncProgress =>
      _isSyncingChannels && _totalChannelsToRequest > 0
      ? ((_nextChannelIndexToRequest / _totalChannelsToRequest) * 100).round()
      : 0;
  int? get batteryPercent => _batteryMillivolts == null
      ? null
      : estimateBatteryPercentFromMillivolts(
          _batteryMillivolts!,
          _batteryChemistryForDevice(),
        );
  RepeaterBatterySnapshot? getRepeaterBatterySnapshot(String contactKeyHex) =>
      _repeaterBatterySnapshots[contactKeyHex];
  int? getRepeaterBatteryMillivolts(String contactKeyHex) =>
      _repeaterBatterySnapshots[contactKeyHex]?.millivolts;

  void updateRepeaterBatterySnapshot(
    String contactKeyHex,
    int millivolts, {
    String source = 'unknown',
  }) {
    if (contactKeyHex.isEmpty || millivolts <= 0) return;
    final previous = _repeaterBatterySnapshots[contactKeyHex];
    final snapshot = RepeaterBatterySnapshot(
      millivolts: millivolts,
      updatedAt: DateTime.now(),
      source: source,
    );
    _repeaterBatterySnapshots[contactKeyHex] = snapshot;
    if (previous?.millivolts != millivolts) {
      notifyListeners();
    }
  }

  String _batteryChemistryForDevice() {
    final deviceId = batteryDeviceKey;
    if (deviceId == null || _appSettingsService == null) return 'nmc';
    return _appSettingsService!.batteryChemistryForDevice(deviceId);
  }

  List<Message> getMessages(Contact contact) {
    return _conversations[contact.publicKeyHex] ?? [];
  }

  Future<void> deleteMessage(Message message) async {
    final contactKeyHex = message.senderKeyHex;
    // Also strip it out of the OTP store-and-forward waiting queue if it's
    // sitting there (by messageId, not identity — a caller may be passing
    // in a re-fetched copy rather than the exact queued instance). A no-op
    // for a message that was never queued, or was already removed by
    // _flushWaitingQueue before calling here.
    _waitingQueue[contactKeyHex]?.removeWhere(
      (m) => m.messageId == message.messageId,
    );
    final messages = _conversations[contactKeyHex];
    if (messages == null) return;
    final removed = messages.remove(message);
    if (!removed) return;
    _retryService?.untrack(message.messageId);
    await _messageStore.saveMessages(contactKeyHex, messages);
    notifyListeners();
  }

  Future<void> resendMessage(Contact contact, Message message) async {
    await deleteMessage(message);
    await sendMessage(
      contact,
      // A manual resend is a deliberate new send, not an automatic retry —
      // re-encrypt from the original plaintext (spending a fresh slice of
      // pad) rather than replaying `message.text`, which for an OTP
      // message is already-spent ciphertext.
      message.otpPlaintext ?? message.text,
      originalText: message.originalText,
      translatedLanguageCode: message.translatedLanguageCode,
      translationModelId: message.translationModelId,
    );
  }

  Future<void> _loadMessagesForContact(String contactKeyHex) async {
    if (_loadedConversationKeys.contains(contactKeyHex)) return;
    _loadedConversationKeys.add(contactKeyHex);

    final allMessages = await _messageStore.loadMessages(contactKeyHex);
    if (allMessages.isNotEmpty) {
      // Keep only the most recent N messages in memory to bound memory usage
      final windowedMessages = allMessages.length > _messageWindowSize
          ? allMessages.sublist(allMessages.length - _messageWindowSize)
          : allMessages;
      final archivedMessages = allMessages.sublist(
        0,
        allMessages.length - windowedMessages.length,
      );

      final currentMessages =
          _conversations[contactKeyHex] ?? const <Message>[];
      final mergedMessages = <Message>[...windowedMessages];
      final persistedKeyCounts = <String, int>{};
      for (final message in windowedMessages) {
        final key = _messageMergeKey(message);
        persistedKeyCounts[key] = (persistedKeyCounts[key] ?? 0) + 1;
      }
      final currentKeyCounts = <String, int>{};

      for (final message in currentMessages) {
        final key = _messageMergeKey(message);
        final currentCount = (currentKeyCounts[key] ?? 0) + 1;
        currentKeyCounts[key] = currentCount;
        final persistedCount = persistedKeyCounts[key] ?? 0;

        // Preserve distinct duplicates without IDs (for example same text
        // received multiple times in the same second) by only skipping the
        // overlapping occurrences that already exist in persisted storage.
        if (currentCount > persistedCount) {
          mergedMessages.add(message);
        }
      }

      // Re-sort after merging persisted and in-memory messages so the
      // conversation window remains stable after optimistic inserts.
      mergedMessages.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
      final trimCount = mergedMessages.length > _messageWindowSize
          ? mergedMessages.length - _messageWindowSize
          : 0;
      final windowedMergedMessages = mergedMessages.sublist(trimCount);

      // Everything stored ahead of the window stays in storage on the next
      // save instead of being overwritten by the window.
      _messageStore.setArchived(contactKeyHex, [
        ...archivedMessages,
        ...mergedMessages.sublist(0, trimCount),
      ]);
      _conversations[contactKeyHex] = windowedMergedMessages;
      notifyListeners();
    } else {
      _messageStore.setArchived(contactKeyHex, const []);
    }
  }

  String _messageMergeKey(Message message) {
    final messageId = message.messageId;
    if (messageId.isNotEmpty) {
      return 'id:$messageId';
    }
    return 'fallback:${message.senderKeyHex}:${message.isOutgoing}:${message.isCli}:${message.timestamp.millisecondsSinceEpoch}:${message.text}';
  }

  /// Load older messages for a contact (pagination)
  Future<List<Message>> loadOlderMessages(
    String contactKeyHex, {
    int count = 50,
  }) async {
    final allMessages = await _messageStore.loadMessages(contactKeyHex);
    final currentMessages = _conversations[contactKeyHex] ?? [];

    // Storage holds the archived entries followed by the in-memory window.
    final currentOffset =
        (_messageStore.archivedCount(contactKeyHex) ??
                allMessages.length - currentMessages.length)
            .clamp(0, allMessages.length);
    if (currentOffset == 0) {
      return []; // No more messages to load
    }

    final fetchCount = count.clamp(0, currentOffset);
    final startIndex = currentOffset - fetchCount;

    final olderMessages = allMessages.sublist(startIndex, currentOffset);
    _messageStore.unarchiveNewest(contactKeyHex, olderMessages.length);

    // Prepend to current conversation
    _conversations[contactKeyHex] = [...olderMessages, ...currentMessages];
    notifyListeners();

    return olderMessages;
  }

  List<ChannelMessage> getChannelMessages(Channel channel) {
    return _channelMessages[_canonicalSlot(channel.index)] ?? [];
  }

  Future<void> deleteChannelMessage(ChannelMessage message) async {
    final channelIndex = message.channelIndex;
    if (channelIndex == null) return;
    final slot = _canonicalSlot(channelIndex);
    final messages = _channelMessages[slot];
    if (messages == null) return;
    final removed = messages.remove(message);
    if (!removed) return;
    await _saveChannelMessages(slot, messages);
    notifyListeners();
  }

  /// Storage ID for [slot], or null (logged) when the slot has none, in which
  /// case the caller skips persistence.
  String? _channelIdForSlot(int slot) {
    final id = _slotChannelIds[slot];
    if (id == null) {
      debugPrint(
        '[ChannelStorage] Slot $slot has no channel ID; not persisted',
      );
    }
    return id;
  }

  /// Lowest slot holding the same channel as [slot] in [slotIds], matching
  /// the firmware, which files a PSK held twice under its first slot. Both
  /// slots share that slot's in-memory history.
  static int _canonicalSlotIn(Map<int, String> slotIds, int slot) {
    final id = slotIds[slot];
    if (id == null) return slot;
    return _lowestSlotFor(slotIds, id) ?? slot;
  }

  static int? _lowestSlotFor(Map<int, String> slotIds, String channelId) {
    int? lowest;
    for (final entry in slotIds.entries) {
      if (entry.value == channelId && (lowest == null || entry.key < lowest)) {
        lowest = entry.key;
      }
    }
    return lowest;
  }

  int _canonicalSlot(int slot) => _canonicalSlotIn(_slotChannelIds, slot);

  Future<void> _saveChannelMessages(int slot, List<ChannelMessage> messages) {
    final id = _channelIdForSlot(slot);
    if (id == null) return Future<void>.value();
    return _channelMessageStore.saveChannelMessages(id, messages);
  }

  int getUnreadCountForContact(Contact contact) {
    if (contact.type == advTypeRepeater) return 0;
    return getUnreadCountForContactKey(contact.publicKeyHex);
  }

  int getUnreadCountForContactKey(String contactKeyHex) {
    if (!_unreadStateLoaded) return 0;
    if (!_shouldTrackUnreadForContactKey(contactKeyHex)) return 0;
    return _contactUnreadCount[contactKeyHex] ?? 0;
  }

  int getUnreadCountForChannel(Channel channel) {
    return getUnreadCountForChannelIndex(channel.index);
  }

  int getUnreadCountForChannelIndex(int channelIndex) {
    if (!_unreadStateLoaded) return 0;
    return _findChannelByIndex(channelIndex)?.unreadCount ?? 0;
  }

  int getTotalUnreadCount() {
    if (!_unreadStateLoaded) return 0;
    return getTotalContactsUnreadCount() + getTotalChannelsUnreadCount();
  }

  int getTotalContactsUnreadCount() {
    if (!_unreadStateLoaded) return 0;
    return _cachedContactsUnreadTotal;
  }

  int getTotalChannelsUnreadCount() {
    if (!_unreadStateLoaded) return 0;
    return _cachedChannelsUnreadTotal;
  }

  /// Recalculates both cached unread totals from scratch.
  /// Called when unread state is first loaded.
  void _recalculateCachedUnreadTotals() {
    _recalculateCachedContactsUnreadTotal();
    _recalculateCachedChannelsUnreadTotal();
  }

  void _recalculateCachedContactsUnreadTotal() {
    int total = 0;
    _contactUnreadCount.forEach((contactKeyHex, count) {
      if (_shouldTrackUnreadForContactKey(contactKeyHex)) {
        total += count;
      }
    });
    _cachedContactsUnreadTotal = total;
  }

  void _recalculateCachedChannelsUnreadTotal() {
    final allChannels = _channels.isNotEmpty ? _channels : _cachedChannels;
    _cachedChannelsUnreadTotal = allChannels.fold(
      0,
      (total, ch) => total + ch.unreadCount,
    );
  }

  bool isChannelSmazEnabled(int channelIndex) {
    return _channelSmazEnabled[channelIndex] ?? false;
  }

  bool isContactSmazEnabled(String contactKeyHex) {
    return _contactSmazEnabled[contactKeyHex] ?? false;
  }

  bool isChannelUrlImagesEnabled(int channelIndex) {
    return _channelUrlImagesEnabled[channelIndex] ?? false;
  }

  bool isContactUrlImagesEnabled(String contactKeyHex) {
    _ensureContactUrlImagesSettingLoaded(contactKeyHex);
    return _contactUrlImagesEnabled[contactKeyHex] ?? false;
  }

  /// True when the channel has its own (real) region assigned.
  bool hasChannelRegion(int channelIndex) {
    return getChannelRegion(channelIndex).isNotEmpty;
  }

  /// The channel's own region, or '' when it follows the default or is set
  /// to "no region" (see [isChannelExplicitlyUnscoped]).
  Region getChannelRegion(int channelIndex) {
    final region = _channelRegions[channelIndex] ?? '';
    return region == kUnscopedRegion ? '' : region;
  }

  /// True when the user picked "no region" for this channel, overriding the
  /// app and radio defaults.
  bool isChannelExplicitlyUnscoped(int channelIndex) {
    return _channelRegions[channelIndex] == kUnscopedRegion;
  }

  /// The app default region ('' for none). [kUnscopedRegion] when the app
  /// default is "no region".
  Region get defaultRegion => _defaultRegion;

  /// The region a flood on this channel is scoped to by the app, as a real
  /// region name, or '' when the app sends without a region (in which case
  /// the radio's default flood scope, if any, may still apply — see
  /// [channelUsesRadioDefaultScope]).
  Region getEffectiveChannelRegion(int channelIndex) {
    final scope = _channelSendScope(channelIndex);
    return scope == kUnscopedRegion ? '' : scope;
  }

  /// True when floods on this channel fall through to the radio's default
  /// flood scope: no app region applies and the radio has a default that
  /// this firmware cannot (or was not asked to) override.
  bool channelUsesRadioDefaultScope(int channelIndex) {
    if (_defaultFloodScopeName == null) return false;
    final scope = _channelSendScope(channelIndex);
    if (scope.isEmpty) return true;
    return scope == kUnscopedRegion && !supportsExplicitUnscopedFlood;
  }

  /// Precedence: channel assignment (region or "no region"), then the app
  /// default (region or "no region"), then '' (the radio default applies).
  Region _channelSendScope(int channelIndex) {
    final own = _channelRegions[channelIndex] ?? '';
    if (own.isNotEmpty) return own;
    return _defaultRegion;
  }

  /// Stores [region] on the radio as its default flood scope ('' clears it),
  /// then re-reads it. Throws on firmware without the command, on ERR or on
  /// timeout.
  Future<void> setDefaultFloodScope(String region) async {
    if (!isConnected) return;
    if (!supportsDefaultFloodScope) {
      throw UnsupportedError('Firmware does not support default flood scope');
    }
    await sendFrame(
      buildSetDefaultFloodScopeFrame(region),
      waitForGenericAck: true,
    );
    await sendFrame(buildGetDefaultFloodScopeFrame());
  }

  Future<void> setDefaultRegion(Region region) async {
    _defaultRegion = region;
    notifyListeners();
    await _channelRegionStore.saveDefaultRegion(region);
  }

  void ensureContactSmazSettingLoaded(String contactKeyHex) {
    _ensureContactSmazSettingLoaded(contactKeyHex);
  }

  bool isChannelCyr2LatEnabled(int channelIndex) {
    _ensureChannelCyr2LatSettingLoaded(channelIndex);
    return _channelCyr2LatEnabled[channelIndex] ?? false;
  }

  bool isContactCyr2LatEnabled(String contactKeyHex) {
    _ensureContactCyr2LatSettingLoaded(contactKeyHex);
    return _contactCyr2LatEnabled[contactKeyHex] ?? false;
  }

  void ensureContactCyr2LatSettingLoaded(String contactKeyHex) {
    _ensureContactCyr2LatSettingLoaded(contactKeyHex);
  }

  // ── OTP ────────────────────────────────────────────────────────────────
  // Unlike the Smaz/Cyr2Lat loaders above (which wrap a technically-async
  // SharedPreferences read in a Future for historical reasons), pad reads
  // are written as plain synchronous getters — PrefsManager's underlying
  // SharedPreferences instance is already memory-resident by the time the
  // connector can be scoped to a self key, so there's nothing to await.

  OtpPad? getContactOtpPad(String contactKeyHex) {
    if (!_contactOtpPads.containsKey(contactKeyHex)) {
      _contactOtpPads[contactKeyHex] = _otpPadStore.loadContactPad(
        contactKeyHex,
      );
    }
    return _contactOtpPads[contactKeyHex];
  }

  /// True for the one channel every device on the mesh shares by
  /// construction (a fixed, well-known PSK - see [Channel.publicChannelPsk]
  /// - not by name, since a channel's display name is never a reliable
  /// signal: this one could be renamed, and nothing stops a *different*
  /// channel from being named "Public" too). False if [channelIndex]
  /// isn't a currently known channel at all.
  bool _isPublicChannel(int channelIndex) {
    return _channels.any((c) => c.index == channelIndex && c.isPublicChannel);
  }

  /// Returns null unconditionally for the Public channel, regardless of
  /// what's actually sitting in [_channelOtpPads] or on disk - see
  /// [setChannelOtpPad] for why nothing can ever get OTP-enabled there in
  /// the first place, but this is the funnel every OTP-channel check in
  /// this file goes through ([isChannelOtpEnabled], [_dispatchOtpChannel],
  /// every send path), so gating here is enough to keep the Public channel
  /// out of OTP everywhere without touching each of those call sites, and
  /// it also covers a pad that was somehow saved before this restriction
  /// existed - it's hidden from use, not deleted.
  OtpPad? getChannelOtpPad(int channelIndex) {
    if (_isPublicChannel(channelIndex)) return null;
    if (!_channelOtpPads.containsKey(channelIndex)) {
      _channelOtpPads[channelIndex] = _otpPadStore.loadChannelPad(channelIndex);
    }
    return _channelOtpPads[channelIndex];
  }

  bool isContactOtpEnabled(String contactKeyHex) {
    final pad = getContactOtpPad(contactKeyHex);
    return pad != null && pad.enabled;
  }

  bool isChannelOtpEnabled(int channelIndex) {
    final pad = getChannelOtpPad(channelIndex);
    return pad != null && pad.enabled;
  }

  /// Imports/replaces the pad for a contact and enables OTP for them.
  /// [padHex] is the shared secret pad material as hex (however it was
  /// obtained — pasted or scanned from a QR code). Overwrites any existing
  /// pad and resets both offsets to zero: only do this for a genuinely new
  /// pad, never to "fix" a desync, since that reuses already-spent bytes.
  Future<void> setContactOtpPad(
    String contactKeyHex,
    String padHex,
    OtpPadRole role, {
    String? label,
  }) async {
    // Refuse while store-and-forward still has messages queued for this
    // contact — a queued message's ciphertext was encrypted against the
    // OLD pad's byte offsets, and this resets both offsets to zero, so
    // replacing it out from under a queued send would corrupt it (or
    // silently desync the recipient) exactly like importing over an
    // in-flight chunked send. Mirrors OTP_3_RC1.lua's import_pad_hex
    // refusing while waiting_queue[id] is non-empty — the person has to
    // cancel or wait for the queue to drain first.
    final queuedCount = waitingQueueLength(contactKeyHex);
    if (queuedCount > 0) {
      throw OtpPadImportBlockedException(queuedCount);
    }
    final pad = OtpPad(
      padHex: padHex,
      role: role,
      enabled: true,
      label: label,
      importedAt: DateTime.now(),
    );
    _contactOtpPads[contactKeyHex] = pad;
    await _otpPadStore.saveContactPad(contactKeyHex, pad);
    _clearContactSyncState(contactKeyHex);
    notifyListeners();
  }

  /// [role] is accepted for call-site symmetry with [setContactOtpPad] but
  /// ignored — channels always use [OtpPadMode.sharedSequential] (no A/B
  /// split), mirroring Lua's `sync_party_mode_to_destination()`, which
  /// forces Multi mode for any channel destination.
  Future<void> setChannelOtpPad(
    int channelIndex,
    String padHex,
    OtpPadRole role, {
    String? label,
  }) async {
    if (_isPublicChannel(channelIndex)) {
      throw OtpPublicChannelBlockedException();
    }
    final pad = OtpPad(
      padHex: padHex,
      mode: OtpPadMode.sharedSequential,
      enabled: true,
      label: label,
      importedAt: DateTime.now(),
    );
    _channelOtpPads[channelIndex] = pad;
    await _otpPadStore.saveChannelPad(channelIndex, pad);
    _clearChannelSyncState(channelIndex);
    notifyListeners();
  }

  Future<void> setContactOtpEnabled(String contactKeyHex, bool enabled) async {
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null) return;
    final updated = pad.copyWith(enabled: enabled);
    _contactOtpPads[contactKeyHex] = updated;
    await _otpPadStore.saveContactPad(contactKeyHex, updated);
    notifyListeners();
  }

  Future<void> setChannelOtpEnabled(int channelIndex, bool enabled) async {
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null) return;
    final updated = pad.copyWith(enabled: enabled);
    _channelOtpPads[channelIndex] = updated;
    await _otpPadStore.saveChannelPad(channelIndex, updated);
    notifyListeners();
  }

  Future<void> clearContactOtpPad(String contactKeyHex) async {
    _contactOtpPads[contactKeyHex] = null;
    await _otpPadStore.clearContactPad(contactKeyHex);
    _clearContactSyncState(contactKeyHex);
    notifyListeners();
  }

  Future<void> clearChannelOtpPad(int channelIndex) async {
    _channelOtpPads[channelIndex] = null;
    await _otpPadStore.clearChannelPad(channelIndex);
    _clearChannelSyncState(channelIndex);
    notifyListeners();
  }

  /// A wiped or freshly-imported pad shouldn't carry over a stale
  /// resync countdown or status line from whatever the pad used to be.
  void _clearContactSyncState(String contactKeyHex) {
    _contactOtpSyncStatus.remove(contactKeyHex);
    _pendingContactResync.remove(contactKeyHex);
    _contactResyncStreak.remove(contactKeyHex);
    _otpResyncTimers.remove('rc:$contactKeyHex')?.cancel();
    _otpSyncTimeoutTimers.remove('c:$contactKeyHex')?.cancel();
    _lastPromptSyncCheckAt.remove('c:$contactKeyHex');
    _clearContactSyncBackoff(contactKeyHex);
  }

  void _clearChannelSyncState(int channelIndex) {
    final perChannel = _channelOtpSyncStatus.remove(channelIndex);
    final pendingPerChannel = _pendingChannelResync.remove(channelIndex);
    if (pendingPerChannel != null) {
      for (final senderName in pendingPerChannel.keys) {
        _otpResyncTimers.remove('rs:$channelIndex:$senderName')?.cancel();
      }
    }
    perChannel?.clear();
    _otpSyncTimeoutTimers.remove('s:$channelIndex')?.cancel();
    _clearChannelSyncBackoff(channelIndex);
    _lastPromptSyncCheckAt.remove('s:$channelIndex');
  }

  // ── OTP passphrase lock + panic wipe ─────────────────────────────────
  // Ported from WADAMESH OTP_2_RC15.lua's protection design (HMAC-SHA256
  // KDF, 3001 rounds, random 16-byte salt, fixed check-tag domain string —
  // see PassphraseLockCrypto). Scope decision (this app's own, not Lua's):
  // this gates the OTP pad-manager screen and, transitively, OTP pad
  // decrypt — NOT the whole app. Lua is a single-purpose OTP messenger
  // where a full-app lock screen is the only sensible design; this is a
  // general multi-contact MeshCore companion app where OTP is already an
  // opt-in per-contact/per-channel feature layered on top of otherwise-
  // normal messaging, so locking browsing contacts/channels/non-OTP chat
  // behind a passphrase would be needless friction the app's owner did not
  // ask for. The gating mechanism itself needs no extra "is locked" checks
  // scattered through the send/receive paths: while locked, OtpPadStore
  // simply can't decrypt a persisted pad blob (see its `sessionKey`), so
  // getContactOtpPad/getChannelOtpPad transparently return null and OTP
  // behaves as "not enabled" for that contact/channel until unlocked —
  // incoming ciphertext is left showing as raw hex (never mis-decrypted,
  // and never consumes pad bytes) rather than being displayed as plaintext.

  /// True once a passphrase has ever been set up (salt+tag persisted) —
  /// independent of whether the session is currently locked or unlocked.
  bool get otpProtectionEnabled => _passphraseLockStore.hasProtection;

  /// True when protection is enabled but this session doesn't (yet) hold
  /// the derived session key — i.e. OTP pads are currently inaccessible.
  bool get otpLocked => otpProtectionEnabled && _otpSessionKey == null;

  /// True for the ~4s window after a single "panic wipe" tap, during which
  /// a second tap confirms the wipe. The pad-manager/lock UI should show
  /// "tap again to confirm" while this is true.
  bool get otpPanicArmed {
    final armedAt = _otpPanicArmedAt;
    if (!_otpPanicArmed || armedAt == null) return false;
    if (DateTime.now().difference(armedAt) > _otpPanicConfirmWindow) {
      return false;
    }
    return true;
  }

  /// Sets up passphrase protection for the first time (or replaces it,
  /// though the UI should route a "change passphrase" flow through this the
  /// same way — there is no separate re-key path). Generates a fresh random
  /// salt, derives the session key from [passphrase], persists salt+tag
  /// (never the key or the passphrase), unlocks immediately with the new
  /// key, and re-encrypts every pad already on disk under it.
  Future<void> enableOtpProtection(String passphrase) async {
    final salt = PassphraseLockCrypto.randomSalt();
    final key = PassphraseLockCrypto.deriveKey(passphrase, salt);
    final tag = PassphraseLockCrypto.checkTag(key);
    await _passphraseLockStore.save(
      saltHex: OtpService.bytesToHex(salt),
      tagHex: tag,
    );
    _otpSessionKey = key;
    _otpPadStore.sessionKey = key;
    // Force every pad already cached in memory (plaintext, from before
    // protection existed) to reload from disk next time it's asked for —
    // migrateAllToEncrypted below re-saves the on-disk copies directly, so
    // this just keeps the in-memory cache from serving a stale (unencrypted
    // in spirit, though harmless in memory) copy instead of the fresh one.
    _contactOtpPads.clear();
    _channelOtpPads.clear();
    await _otpPadStore.migrateAllToEncrypted();
    notifyListeners();
  }

  /// Attempts to unlock with [passphrase]. Returns true and makes pads
  /// accessible again on a match; returns false (stays locked) on a
  /// mismatch. No-op (returns false) if protection was never enabled.
  Future<bool> unlockOtpProtection(String passphrase) async {
    final saltHex = _passphraseLockStore.loadSaltHex();
    final tagHex = _passphraseLockStore.loadTagHex();
    if (saltHex == null || tagHex == null) return false;
    final Uint8List salt;
    try {
      salt = hex2Uint8List(saltHex);
    } catch (_) {
      return false;
    }
    final key = PassphraseLockCrypto.deriveKey(passphrase, salt);
    if (PassphraseLockCrypto.checkTag(key) != tagHex) return false;
    _otpSessionKey = key;
    _otpPadStore.sessionKey = key;
    // MUST clear these: while locked, a lookup for any pad that only exists
    // encrypted on disk was cached here as `null` ("no pad"). Without this
    // clear, that stale null would keep shadowing the real pad forever,
    // even after a correct unlock.
    _contactOtpPads.clear();
    _channelOtpPads.clear();
    notifyListeners();
    return true;
  }

  /// Re-locks without touching any stored data — the opposite of
  /// [unlockOtpProtection]. No-op if protection isn't enabled.
  void lockOtpProtection() {
    if (!otpProtectionEnabled || _otpSessionKey == null) return;
    _otpSessionKey = null;
    _otpPadStore.sessionKey = null;
    _contactOtpPads.clear();
    _channelOtpPads.clear();
    notifyListeners();
  }

  /// Single tap arms the panic wipe and returns false (caller should show
  /// "tap again within 4s to confirm"); a second tap within
  /// [_otpPanicConfirmWindow] confirms it, performs the wipe, and returns
  /// true. Matches Lua exactly: wipes every pad, clears the stored
  /// salt/tag, and drops the session key — protection ends up fully
  /// DISABLED afterward (this is "destroy the secrets AND the lock", not
  /// "wipe secrets but stay locked").
  Future<bool> tapOtpPanicWipe() async {
    final now = DateTime.now();
    final armedAt = _otpPanicArmedAt;
    if (_otpPanicArmed &&
        armedAt != null &&
        now.difference(armedAt) <= _otpPanicConfirmWindow) {
      _otpPanicArmed = false;
      _otpPanicArmedAt = null;
      await _otpPadStore.wipeAllPads();
      _contactOtpPads.clear();
      _channelOtpPads.clear();
      await _passphraseLockStore.clear();
      _otpSessionKey = null;
      _otpPadStore.sessionKey = null;
      notifyListeners();
      return true;
    }
    _otpPanicArmed = true;
    _otpPanicArmedAt = now;
    notifyListeners();
    return false;
  }

  /// Cancels an armed-but-unconfirmed panic wipe (e.g. the user navigated
  /// away, or just tapped by accident).
  void cancelOtpPanicWipe() {
    if (!_otpPanicArmed) return;
    _otpPanicArmed = false;
    _otpPanicArmedAt = null;
    notifyListeners();
  }

  // ── OTP pad sync-check ────────────────────────────────────────────────
  // New (no Lua equivalent): a lightweight, user-triggered exchange of pad
  // POSITION COUNTERS ONLY — never pad bytes — to confirm two devices'
  // offsets haven't drifted apart, without spending any pad. See
  // otp_sync_service.dart for the wire format and the receive-path hooks in
  // _parseContactMessage/_handleIncomingChannelMessage/_handleLogRxData for
  // where sync-check messages (marker "z1", see otp_sync_service.dart) are
  // intercepted before OTP dispatch.

  OtpSyncStatus? getContactOtpSyncStatus(String contactKeyHex) =>
      _contactOtpSyncStatus[contactKeyHex];

  /// Per-participant sync status for a channel, keyed by sender display
  /// name (channel messages don't carry a resolvable sender public key —
  /// see the identical reasoning already documented on
  /// `_ackChunkFromChannelSender`).
  Map<String, OtpSyncStatus> getChannelOtpSyncStatuses(int channelIndex) =>
      Map.unmodifiable(_channelOtpSyncStatus[channelIndex] ?? const {});

  /// Subset of [getChannelOtpSyncStatuses] heard from — a sync-check reply,
  /// or an ordinary offset-bearing chat message (see
  /// _recordChannelParticipantHeard) — within the last [maxAge]. Used by
  /// the channel chat screen's participant strip, which is deliberately
  /// more aggressive about dropping stale names than the OTP Pad screen's
  /// all-time list: someone not heard from in a while has more likely
  /// stepped away or gone out of range than stayed present but perpetually
  /// unsynced, so the strip just stops showing them rather than leaving a
  /// permanently-greyed-out entry.
  Map<String, OtpSyncStatus> getActiveChannelParticipants(
    int channelIndex, {
    Duration maxAge = const Duration(minutes: 10),
  }) {
    final perChannel = _channelOtpSyncStatus[channelIndex];
    if (perChannel == null || perChannel.isEmpty) return const {};
    final cutoff = DateTime.now().subtract(maxAge);
    final result = <String, OtpSyncStatus>{};
    for (final entry in perChannel.entries) {
      final heardAt = entry.value.repliedAt ?? entry.value.checkedAt;
      if (heardAt.isAfter(cutoff)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Sends a sync-check request to [contactKeyHex]'s DM pad, reporting this
  /// device's own current counters. A reply (see
  /// _maybeHandleContactSyncMessage) updates [getContactOtpSyncStatus]; if
  /// nothing comes back within [_otpSyncTimeout], the status is left/marked
  /// as timed-out (unknown), never falsely "in sync" or "out of sync".
  void checkContactPadSync(String contactKeyHex) {
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null) return;
    final contact = _contacts.cast<Contact?>().firstWhere(
      (c) => c != null && c.publicKeyHex == contactKeyHex,
      orElse: () => null,
    );
    if (contact == null) return;
    final payload = pad.isSharedSequential
        ? OtpSyncService.buildShared(isReply: false, offset: pad.offset)
        : OtpSyncService.buildTwoParty(
            isReply: false,
            myOffset: pad.myOffset,
            theirOffset: pad.theirOffset,
            role: pad.role,
          );
    unawaited(
      sendFrame(
        buildSendTextMsgFrame(
          contact.publicKey,
          prepareContactOutboundText(contact, payload),
        ),
      ),
    );
    _contactOtpSyncStatus[contactKeyHex] = OtpSyncStatus(
      checkedAt: DateTime.now(),
    );
    _armOtpSyncTimeout('c:$contactKeyHex', () {
      final status = _contactOtpSyncStatus[contactKeyHex];
      if (status != null && status.isPending) {
        _contactOtpSyncStatus[contactKeyHex] = status.copyWith(timedOut: true);
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// Sends a sync-check to a channel — broadcast, since this is metadata
  /// only (never secret): every current participant that has this feature
  /// replies once, so one broadcast naturally populates
  /// [getChannelOtpSyncStatuses] for everyone who answers, not just the
  /// initiator.
  void checkChannelPadSync(int channelIndex) {
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null) return;
    final payload = OtpSyncService.buildShared(
      isReply: false,
      offset: pad.offset,
    );
    unawaited(
      sendFrame(
        buildSendChannelTextMsgFrame(
          channelIndex,
          prepareChannelOutboundText(channelIndex, payload),
        ),
      ),
    );
    _armOtpSyncTimeout('s:$channelIndex', () {
      // Per-participant entries carry their own pending/timedOut state
      // (set as each reply — or lack of one — is processed); this timer
      // just nudges listeners so a UI showing "waiting…" for the channel
      // as a whole knows the initial window has closed.
      notifyListeners();
    });
    notifyListeners();
  }

  void _armOtpSyncTimeout(String key, void Function() onTimeout) {
    _otpSyncTimeoutTimers[key]?.cancel();
    _otpSyncTimeoutTimers[key] = Timer(_otpSyncTimeout, onTimeout);
  }

  /// Manual "ReSync" action — ports OTP_3_RC1.lua's `resync_current_target()`
  /// (the chat screen's "ReSync" button). Two things, back to back: force-
  /// reload this contact's pad straight from storage, discarding whatever's
  /// cached in [_contactOtpPads] (a no-op almost every time, since the cache
  /// and storage don't normally drift — it only matters if the pad file was
  /// replaced on disk out from under an already-running session), then fire
  /// an immediate, unthrottled sync-check exactly like [checkContactPadSync]
  /// already does for the (currently nonexistent) manual "Check Sync"
  /// affordance. Returns false (and does nothing else) if there's no pad to
  /// resync, so the caller can show a "nothing to resync" message the same
  /// way Lua's toast does.
  bool resyncContact(String contactKeyHex) {
    _contactOtpPads.remove(contactKeyHex);
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null) return false;
    checkContactPadSync(contactKeyHex);
    return true;
  }

  /// Channel counterpart of [resyncContact] — ports the same Lua ReSync
  /// button for a channel target.
  bool resyncChannel(int channelIndex) {
    _channelOtpPads.remove(channelIndex);
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null) return false;
    checkChannelPadSync(channelIndex);
    return true;
  }

  /// Returns true if [text] was a sync-check control message (handled
  /// here, including sending the automatic reply) and must NOT be shown as
  /// a chat message — mirrors how a chunk piece/ack "handled" result
  /// suppresses display in [_dispatchOtpContact].
  static final RegExp _nackPattern = RegExp(r'^z4([CDG])z$');
  final Set<String> _nackRetryKeys = {};
  DateTime? _lastNackAt;

  bool _nackAllowed() {
    final now = DateTime.now();
    final last = _lastNackAt;
    if (last != null && now.difference(last).inSeconds < 3) return false;
    _lastNackAt = now;
    return true;
  }

  void _sendChannelNack(int channelIndex, String reason) {
    if (!_nackAllowed()) return;
    unawaited(
      sendFrame(
        buildSendChannelTextMsgFrame(
          channelIndex,
          prepareChannelOutboundText(channelIndex, 'z4${reason}z'),
        ),
      ),
    );
  }

  bool _maybeHandleContactNack(Contact contact, String text) {
    if (!_nackPattern.hasMatch(text.trim())) return false;
    final key = contact.publicKeyHex;
    final pending = _pendingContactChunkSends[key];
    if (pending != null) {
      _finishContactChunkSend(pending, success: false);
      notifyListeners();
      return true;
    }
    final messages = _conversations[key];
    if (messages != null) {
      for (var i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.isOutgoing &&
            (m.status == MessageStatus.sent ||
                m.status == MessageStatus.pending)) {
          _updateStoredContactMessage(
            key,
            m.messageId,
            (cur) => cur.copyWith(status: MessageStatus.failed),
          );
          break;
        }
      }
    }
    notifyListeners();
    return true;
  }

  bool _maybeHandleChannelNack(int channelIndex, String text) {
    final nack = _nackPattern.firstMatch(text.trim());
    if (nack == null) return false;
    final messages = _channelMessages[channelIndex];
    if (messages != null) {
      for (var i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.isOutgoing &&
            (m.status == ChannelMessageStatus.sent ||
                m.status == ChannelMessageStatus.pending)) {
          final plain = m.otpPlaintext;
          final key = '$channelIndex:$plain';
          final retry =
              nack.group(1) == 'C' &&
              plain != null &&
              !_nackRetryKeys.contains(key);
          if (retry) {
            _nackRetryKeys.add(key);
            Timer(
              const Duration(seconds: 60),
              () => _nackRetryKeys.remove(key),
            );
            _updateStoredChannelMessage(
              channelIndex,
              m.messageId,
              (cur) => cur.copyWith(status: ChannelMessageStatus.pending),
            );
            Timer(
              Duration(milliseconds: 2000 + _channelJitterRandom.nextInt(4000)),
              () {
                final list = _channelMessages[channelIndex];
                if (list != null) {
                  list.removeWhere((e) => e.messageId == m.messageId);
                  unawaited(_saveChannelMessages(channelIndex, list));
                }
                notifyListeners();
                for (final c in _channels) {
                  if (c.index == channelIndex) {
                    unawaited(sendChannelMessage(c, plain));
                    break;
                  }
                }
              },
            );
          } else {
            _nackRetryKeys.remove(key);
            _updateStoredChannelMessage(
              channelIndex,
              m.messageId,
              (cur) => cur.copyWith(status: ChannelMessageStatus.failed),
            );
          }
          break;
        }
      }
    }
    notifyListeners();
    return true;
  }

  bool _maybeHandleContactSyncMessage(Contact contact, String text) {
    if (!OtpSyncService.looksLikeSyncMessage(text)) return false;
    final payload = OtpSyncService.parse(text);
    if (payload == null) return true;
    // Any sync-check from this contact — a reply to one of ours, or one
    // they sent on their own — is proof they're actually reachable right
    // now, so lift any airtime backoff in effect.
    _clearContactSyncBackoff(contact.publicKeyHex);
    // Same "proof they're actually reachable right now" signal also drives
    // OTP store-and-forward: attempt the oldest queued message for them,
    // rate-limited — mirrors Lua's flush_waiting, driven from the same
    // handle_sync_message spot.
    _flushWaitingQueue(contact.publicKeyHex);
    final pad = getContactOtpPad(contact.publicKeyHex);
    if (pad != null && !pad.isSharedSequential && !payload.isSharedSequential) {
      // Explicit role-verification handshake (wire v3, "z3"): each side now
      // states its own resolved role directly on the wire, so a same-role
      // collision (both devices independently resolving to "A", say) can
      // be caught here directly instead of only being inferred after the
      // fact from implausible byte-count math. See the matching comment in
      // OtpSyncPayload/OtpPad.role's own doc comment about why this was
      // previously an undetectable failure mode.
      final roleCollision = payload.role != null && payload.role == pad.role;
      final peerMyOffset = payload.myOffset ?? 0;
      final peerTheirOffset = payload.theirOffset ?? 0;
      // In sync iff: what THEY say they've sent (their myOffset) matches
      // how much of THEIRS I've decrypted (my theirOffset), AND what THEY
      // say they've decrypted of MINE (their theirOffset) matches how much
      // I've actually sent (my myOffset). A brief, benign mismatch right
      // after a send (before the peer has decrypted it yet) is expected —
      // this is a diagnostic signal, not a hard correctness guarantee.
      final drift = pad.theirOffset - peerMyOffset;
      final otherDrift = pad.myOffset - peerTheirOffset;
      final inSync = !roleCollision && drift == 0 && otherDrift == 0;
      // A genuine, fully-confirmed in-sync (both directions agree, not
      // just "the one direction _maybeAutoResyncContact cares about")
      // clears the repeated-resync streak — only a real recovery should
      // reset it, not merely receiving another sync-check.
      if (inSync) _contactResyncStreak.remove(contact.publicKeyHex);
      final primaryDrift = drift != 0 ? drift : otherDrift;
      _contactOtpSyncStatus[contact.publicKeyHex] = OtpSyncStatus(
        checkedAt:
            _contactOtpSyncStatus[contact.publicKeyHex]?.checkedAt ??
            DateTime.now(),
        repliedAt: DateTime.now(),
        inSync: inSync,
        driftBytes: (inSync || roleCollision) ? 0 : primaryDrift,
        driftDirection: (inSync || roleCollision)
            ? null
            : (primaryDrift > 0 ? 'mine-ahead' : 'theirs-ahead'),
        roleCollision: roleCollision,
      );
      // A role collision means the counters on each side aren't even
      // comparable (both parties think they own the same half of the
      // pad), so any apparent "gap" here is meaningless and must NOT be
      // used to arm an auto-resync — that would just make things worse.
      // Only ever track/auto-fix the direction this device can safely fix
      // itself: "I'm behind on receiving what they say they've sent"
      // (peerMyOffset > pad.theirOffset). The other mismatch direction
      // (otherDrift) is THEIR receive lag, not fixable from here — it
      // resolves itself on their device via the identical logic once our
      // reply below reaches them.
      if (!roleCollision) {
        _trackContactResyncGap(contact.publicKeyHex, peerMyOffset);
        _maybeSkipSendSideContact(contact.publicKeyHex, peerTheirOffset);
      } else {
        _pendingContactResync.remove(contact.publicKeyHex);
      }
    }
    // Real hardware bug found in production: this reply used to fire
    // unconditionally for every original (non-reply) sync-check heard, no
    // throttle at all — so mesh-level packet retransmission, or another
    // contact/channel participant checking in again, produced its own
    // immediate, un-cooled-down radio transmission stacking on top of real
    // message chunk/ack traffic, tripping the firmware's "too fast" rate
    // limit. Sharing _shouldSendPromptSyncCheck's cooldown key with the
    // prompted/periodic checks means a reply just sent counts toward the
    // same floor those already respect.
    if (!payload.isReply &&
        pad != null &&
        _shouldSendPromptSyncCheck('c:${contact.publicKeyHex}')) {
      final livePad = getContactOtpPad(contact.publicKeyHex) ?? pad;
      final reply = livePad.isSharedSequential
          ? OtpSyncService.buildShared(isReply: true, offset: livePad.offset)
          : OtpSyncService.buildTwoParty(
              isReply: true,
              myOffset: livePad.myOffset,
              theirOffset: livePad.theirOffset,
              role: livePad.role,
            );
      unawaited(
        sendFrame(
          buildSendTextMsgFrame(
            contact.publicKey,
            prepareContactOutboundText(contact, reply),
          ),
        ),
      );
    }
    notifyListeners();
    return true;
  }

  /// Channel counterpart of [_maybeHandleContactSyncMessage]. [senderName]
  /// identifies the participant this counter belongs to (see
  /// [getChannelOtpSyncStatuses] doc).
  bool _maybeHandleChannelSyncMessage(
    int channelIndex,
    String senderName,
    String text,
  ) {
    if (!OtpSyncService.looksLikeSyncMessage(text)) return false;
    final payload = OtpSyncService.parse(text);
    if (payload == null) return true;
    _clearChannelSyncBackoff(channelIndex);
    final pad = getChannelOtpPad(channelIndex);
    if (pad != null && payload.isSharedSequential) {
      final peerOffset = payload.offset ?? 0;
      final drift = pad.offset - peerOffset;
      final perChannel = _channelOtpSyncStatus.putIfAbsent(
        channelIndex,
        () => {},
      );
      perChannel[senderName] = OtpSyncStatus(
        checkedAt: perChannel[senderName]?.checkedAt ?? DateTime.now(),
        repliedAt: DateTime.now(),
        inSync: drift == 0,
        driftBytes: drift,
        driftDirection: drift == 0
            ? null
            : (drift > 0 ? 'mine-ahead' : 'theirs-ahead'),
      );
      // Same reasoning as the contact side: only auto-fix "I'm behind
      // this participant's reported offset" (peerOffset > pad.offset).
      _trackChannelResyncGap(channelIndex, senderName, peerOffset);
    }
    // See the matching comment in _maybeHandleContactSyncMessage — this
    // reply used to fire unconditionally for every original sync-check
    // heard, which is exactly what produced the observed spam: a channel
    // has several participants, so each of THEIR original checks (plus any
    // the mesh itself retransmits) used to each cost this device its own
    // immediate, un-cooled-down reply transmission. Sharing the cooldown
    // key with the prompted/periodic channel checks closes that gap.
    if (!payload.isReply &&
        pad != null &&
        _shouldSendPromptSyncCheck('s:$channelIndex')) {
      final reply = OtpSyncService.buildShared(
        isReply: true,
        offset: pad.offset,
      );
      unawaited(
        sendFrame(
          buildSendChannelTextMsgFrame(
            channelIndex,
            prepareChannelOutboundText(channelIndex, reply),
          ),
        ),
      );
    }
    notifyListeners();
    return true;
  }

  /// Records that [senderName] was just heard from on [channelIndex]'s OTP
  /// channel — from an ordinary offset-bearing chat message, not a
  /// sync-check (see [_maybeHandleChannelSyncMessage] for that path, which
  /// writes into the same [_channelOtpSyncStatus] map). [claimedOffset]
  /// null means the message carried no offset framing (a legacy sender, or
  /// something that isn't OTP at all) — still counts as "heard" (keeps
  /// them from disappearing from the participant strip — see
  /// [getActiveChannelParticipants]), but leaves any previously known
  /// in-sync verdict alone rather than overwriting it with an unknown one.
  void _recordChannelParticipantHeard(
    int channelIndex,
    String senderName, {
    required int? claimedOffset,
    required int currentOffset,
  }) {
    final perChannel = _channelOtpSyncStatus.putIfAbsent(
      channelIndex,
      () => {},
    );
    final existing = perChannel[senderName];
    if (claimedOffset == null) {
      perChannel[senderName] =
          (existing ?? OtpSyncStatus(checkedAt: DateTime.now())).copyWith(
            repliedAt: DateTime.now(),
          );
      notifyListeners();
      return;
    }
    // Same sign convention as _maybeHandleChannelSyncMessage/OtpSyncStatus:
    // positive drift means THIS device's counter is ahead of theirs.
    final drift = currentOffset - claimedOffset;
    perChannel[senderName] = OtpSyncStatus(
      checkedAt: existing?.checkedAt ?? DateTime.now(),
      repliedAt: DateTime.now(),
      inSync: drift == 0,
      driftBytes: drift,
      driftDirection: drift == 0
          ? null
          : (drift > 0 ? 'mine-ahead' : 'theirs-ahead'),
    );
    // Some callers (the "ahead"/resync-gap branch in _dispatchOtpChannel)
    // return early with no chat message to display and no notifyListeners
    // of their own further down — without this, the participant strip
    // would only pick up this update whenever something else happens to
    // rebuild it.
    notifyListeners();
  }

  // ── OTP pad auto-resync ────────────────────────────────────────────────
  // See the field doc on `_resyncGracePeriod` above for the full reasoning.

  void _trackContactResyncGap(String contactKeyHex, int peerMyOffset) {
    final timerKey = 'rc:$contactKeyHex';
    final pad = getContactOtpPad(contactKeyHex);
    final gap = peerMyOffset - (pad?.theirOffset ?? 0);
    if (gap <= 0) {
      _pendingContactResync.remove(contactKeyHex);
      _otpResyncTimers.remove(timerKey)?.cancel();
      return;
    }
    final existing = _pendingContactResync[contactKeyHex];
    if (existing != null && existing.peerOffset == peerMyOffset) {
      return; // same reported offset, timer already running
    }
    _pendingContactResync[contactKeyHex] = (
      peerOffset: peerMyOffset,
      firstSeen: DateTime.now(),
    );
    _otpResyncTimers[timerKey]?.cancel();
    _otpResyncTimers[timerKey] = Timer(
      _resyncGracePeriod,
      () => _maybeAutoResyncContact(contactKeyHex),
    );
  }

  /// DM-only send-side repair. A peer can only have decrypted bytes this
  /// device actually sent, so peerTheirOffset > myOffset is never in-flight
  /// lag, only a desync (peer consumed bytes we never used). Burn our own
  /// unused send bytes up to the peer's count so the next message lines up.
  /// Never used for channels: shared counter, many writers.
  void _maybeSkipSendSideContact(String contactKeyHex, int peerTheirOffset) {
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null || pad.isSharedSequential) return;
    final gap = peerTheirOffset - pad.myOffset;
    if (gap <= 0) return;
    if (gap > pad.myBytesRemaining || gap > _maxAutoResyncAbsBytes) return;
    final updated = pad.copyWith(myOffset: pad.myOffset + gap);
    _contactOtpPads[contactKeyHex] = updated;
    unawaited(_otpPadStore.saveContactPad(contactKeyHex, updated));
    _contactOtpSyncStatus[contactKeyHex] = OtpSyncStatus(
      checkedAt: DateTime.now(),
      repliedAt: DateTime.now(),
      inSync: true,
      autoResyncedBytes: gap,
    );
  }

  void _maybeAutoResyncContact(String contactKeyHex) {
    final pending = _pendingContactResync.remove(contactKeyHex);
    if (pending == null) return;
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null) return;
    // Recompute the gap against the CURRENT offset, not a byte count
    // captured at detection time — see the doc on _pendingContactResync
    // above. If real messages decrypted normally during the grace-period
    // wait, theirOffset may already be partially or fully caught up on
    // its own.
    final gap = pending.peerOffset - pad.theirOffset;
    if (gap <= 0) {
      _contactResyncStreak.remove(contactKeyHex);
      return; // caught up on its own - nothing left to fix
    }
    if ((_contactResyncStreak[contactKeyHex] ?? 0) >=
        _maxConsecutiveAutoResyncs) {
      _contactOtpSyncStatus[contactKeyHex] =
          (_contactOtpSyncStatus[contactKeyHex] ??
                  OtpSyncStatus(checkedAt: DateTime.now()))
              .copyWith(
                inSync: false,
                driftBytes: gap,
                driftDirection: 'theirs-ahead',
              );
      notifyListeners();
      return;
    }
    if (pad.theirBytesRemaining < gap) {
      _contactOtpSyncStatus[contactKeyHex] =
          (_contactOtpSyncStatus[contactKeyHex] ??
                  OtpSyncStatus(checkedAt: DateTime.now()))
              .copyWith(
                inSync: false,
                driftBytes: gap,
                driftDirection: 'theirs-ahead',
              );
      notifyListeners();
      return;
    }
    // A gap is only auto-fixed up to a bounded ceiling (half of what's
    // actually left, capped at _maxAutoResyncAbsBytes) — a gap bigger
    // than that almost certainly means something is structurally wrong
    // (role mismatch, corrupted counters) rather than "missed a couple
    // of messages", and blindly paying it out of irreplaceable pad bytes
    // is the wrong response. See the field doc on _contactResyncStreak
    // above for the full reasoning.
    final cap = math.min(
      (pad.theirBytesRemaining * _maxAutoResyncFraction).floor(),
      _maxAutoResyncAbsBytes,
    );
    if (gap > cap) {
      _contactOtpSyncStatus[contactKeyHex] =
          (_contactOtpSyncStatus[contactKeyHex] ??
                  OtpSyncStatus(checkedAt: DateTime.now()))
              .copyWith(
                inSync: false,
                driftBytes: gap,
                driftDirection: 'theirs-ahead',
              );
      notifyListeners();
      return;
    }
    final updated = pad.copyWith(theirOffset: pad.theirOffset + gap);
    _contactOtpPads[contactKeyHex] = updated;
    unawaited(_otpPadStore.saveContactPad(contactKeyHex, updated));
    _contactResyncStreak[contactKeyHex] =
        (_contactResyncStreak[contactKeyHex] ?? 0) + 1;
    _contactOtpSyncStatus[contactKeyHex] = OtpSyncStatus(
      checkedAt: DateTime.now(),
      repliedAt: DateTime.now(),
      inSync: true,
      autoResyncedBytes: gap,
    );
    notifyListeners();
    checkContactPadSync(contactKeyHex); // confirm we're actually caught up now
  }

  void _trackChannelResyncGap(
    int channelIndex,
    String senderName,
    int peerOffset,
  ) {
    final timerKey = 'rs:$channelIndex:$senderName';
    final perChannel = _pendingChannelResync.putIfAbsent(
      channelIndex,
      () => {},
    );
    final pad = getChannelOtpPad(channelIndex);
    final gap = peerOffset - (pad?.offset ?? 0);
    if (gap <= 0) {
      perChannel.remove(senderName);
      _otpResyncTimers.remove(timerKey)?.cancel();
      return;
    }
    final existing = perChannel[senderName];
    if (existing != null && existing.peerOffset == peerOffset) return;
    perChannel[senderName] = (
      peerOffset: peerOffset,
      firstSeen: DateTime.now(),
    );
    _otpResyncTimers[timerKey]?.cancel();
    _otpResyncTimers[timerKey] = Timer(
      _resyncGracePeriod,
      () => _maybeAutoResyncChannel(channelIndex, senderName),
    );
  }

  void _maybeAutoResyncChannel(int channelIndex, String senderName) {
    final perChannel = _pendingChannelResync[channelIndex];
    final pending = perChannel?.remove(senderName);
    if (pending == null) return;
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null) return;
    // Recompute against the CURRENT shared offset, not the byte count
    // captured at detection time — same reasoning as the contact side.
    final gap = pending.peerOffset - pad.offset;
    if (gap <= 0) {
      return; // caught up on its own - nothing left to fix
    }
    final statuses = _channelOtpSyncStatus.putIfAbsent(channelIndex, () => {});
    if (pad.myBytesRemaining < gap) {
      statuses[senderName] =
          (statuses[senderName] ?? OtpSyncStatus(checkedAt: DateTime.now()))
              .copyWith(
                inSync: false,
                driftBytes: gap,
                driftDirection: 'theirs-ahead',
              );
      notifyListeners();
      return;
    }
    // advanceShared moves the ONE shared offset this pad's sending and
    // receiving both use (see OtpPad.advanceShared doc) - the same
    // operation a real receive would perform, just without decrypting
    // anything, since what would have been decrypted is unrecoverable.
    final updated = pad.advanceShared(gap);
    _channelOtpPads[channelIndex] = updated;
    unawaited(_otpPadStore.saveChannelPad(channelIndex, updated));
    statuses[senderName] = OtpSyncStatus(
      checkedAt: DateTime.now(),
      repliedAt: DateTime.now(),
      inSync: true,
      autoResyncedBytes: gap,
    );
    notifyListeners();
    checkChannelPadSync(channelIndex);
  }

  // ── OTP pad periodic + post-activity sync-checking ─────────────────────
  // Runs alongside battery polling (see the calls next to
  // _startBatteryPolling/_stopBatteryPolling) so it shares the same
  // connected-device lifecycle without a separate connect/disconnect path
  // to keep in sync.
  //
  // Deliberately scoped to ONLY whichever contact/channel screen is
  // currently open (_activeContactKey/_activeChannelIndex — the same
  // state ChatScreen/ChannelChatScreen already set on
  // setActiveContact/setActiveChannel for unread tracking), not every
  // OTP-enabled contact/channel in the address book. A sync-check is a
  // real mesh transmission, and this app can be running with dozens of
  // OTP contacts/channels configured but only ever one conversation open
  // at a time — polling all of them on a timer would multiply airtime
  // use by however many pads exist, for conversations nobody is
  // currently looking at. The tradeoff: drift in a conversation that
  // isn't open right now won't be caught until it's opened again (which
  // itself triggers an immediate check — see setActiveContact/
  // setActiveChannel below) or a message is sent/received in it (which
  // also triggers one — see _requestPromptContactSyncCheck/
  // _requestPromptChannelSyncCheck). Nothing is ever silently wrong for
  // longer than "until you open that chat."
  void _startOtpAutoSyncPolling() {
    _otpAutoSyncPollTimer?.cancel();
    _otpAutoSyncPollTimer = Timer.periodic(_otpAutoSyncPollInterval, (timer) {
      if (!isConnected) {
        timer.cancel();
        return;
      }
      _pollActiveOtpSyncCheck();
    });
  }

  void _stopOtpAutoSyncPolling() {
    _otpAutoSyncPollTimer?.cancel();
    _otpAutoSyncPollTimer = null;
  }

  // Background fallback for the store-and-forward waiting queue — a single
  // global periodic sweep (matching every other timer in this class:
  // _batteryPollTimer, _otpAutoSyncPollTimer, etc. are all one Timer.periodic
  // iterating internal state, not one Timer per contact) that attempts a
  // flush for every contact with a non-empty queue, every ~10 minutes,
  // mirroring OTP_3_RC1.lua's waiting_tick(). This is only the fallback —
  // the primary trigger is hearing anything at all from that contact (see
  // _flushWaitingQueue, called from _maybeHandleContactSyncMessage), which
  // fires far sooner in the common case of the contact coming back into
  // range.
  void _startWaitingQueueTicker() {
    _waitingQueueTickTimer?.cancel();
    _waitingQueueTickTimer = Timer.periodic(_waitingQueueTickInterval, (timer) {
      if (!isConnected) {
        timer.cancel();
        return;
      }
      for (final contactKeyHex in _waitingQueue.keys.toList()) {
        _flushWaitingQueue(contactKeyHex);
      }
    });
  }

  void _stopWaitingQueueTicker() {
    _waitingQueueTickTimer?.cancel();
    _waitingQueueTickTimer = null;
  }

  // Skips a target while a real chunked send or receive is actually in
  // flight for it (_pendingContactChunkSends/_pendingChannelChunkSends,
  // _contactChunkReassembly/_channelChunkReassembly) — never let this
  // device's own diagnostic probe compete with real message chunk/ack
  // traffic for airtime; that's exactly when reliable delivery matters
  // most, and is exactly the contention real hardware showed tripping the
  // firmware's "too fast" rate limit.
  void _pollActiveOtpSyncCheck() {
    final contactKeyHex = _activeContactKey;
    if (contactKeyHex != null &&
        !_contactSyncBackoff.contains(contactKeyHex) &&
        !_pendingContactChunkSends.containsKey(contactKeyHex) &&
        (_contactChunkReassembly[contactKeyHex]?.isNotEmpty ?? false) ==
            false &&
        getContactOtpPad(contactKeyHex)?.enabled == true) {
      checkContactPadSync(contactKeyHex);
      _armSyncBackoffTimer(
        'c:$contactKeyHex',
        () => _contactSyncBackoff.add(contactKeyHex),
      );
    }
    final channelIndex = _activeChannelIndex;
    if (channelIndex != null &&
        !_channelSyncBackoff.contains(channelIndex) &&
        !_pendingChannelChunkSends.containsKey(channelIndex) &&
        (_channelChunkReassembly[channelIndex]?.isNotEmpty ?? false) == false &&
        getChannelOtpPad(channelIndex)?.enabled == true) {
      checkChannelPadSync(channelIndex);
      _armSyncBackoffTimer(
        's:$channelIndex',
        () => _channelSyncBackoff.add(channelIndex),
      );
    }
  }

  void _armSyncBackoffTimer(String key, void Function() onTimeout) {
    _otpBackoffTimers.remove(key)?.cancel();
    _otpBackoffTimers[key] = Timer(_syncBackoffTimeout, onTimeout);
  }

  /// Lifts any airtime backoff in effect for [contactKeyHex]/[channelIndex]
  /// — called whenever something is heard from that target (a sync-check
  /// reply, or one it sent on its own) or the person starts typing/opens
  /// the chat/sends/receives (see call sites of
  /// _requestPromptContactSyncCheck/_requestPromptChannelSyncCheck and
  /// _maybeHandleContactSyncMessage/_maybeHandleChannelSyncMessage).
  void _clearContactSyncBackoff(String contactKeyHex) {
    _contactSyncBackoff.remove(contactKeyHex);
    _otpBackoffTimers.remove('c:$contactKeyHex')?.cancel();
  }

  void _clearChannelSyncBackoff(int channelIndex) {
    _channelSyncBackoff.remove(channelIndex);
    _otpBackoffTimers.remove('s:$channelIndex')?.cancel();
  }

  // Several independent events all want to "prompt a check soon": a
  // send/receive completing, opening the chat screen, and focusing the
  // compose field can all land within the same second or two of each
  // other (e.g. open a chat and immediately tap to type). Without a
  // cooldown that's an extra mesh transmission per event that fires in
  // that window, for no extra information. _lastPromptSyncCheckAt makes
  // a burst of triggers collapse into the one check that actually gets
  // sent, without adding a manual "did I already check recently"
  // condition at every call site.
  final Map<String, DateTime> _lastPromptSyncCheckAt = {};
  // Widened from 5s to 10s (matching the Lua side's SYNC_PROMPT_MIN_
  // SPACING_MS) now that this cooldown also gates reply-echo transmissions
  // (see _maybeHandleContactSyncMessage/_maybeHandleChannelSyncMessage) —
  // real hardware evidence showed 5s wasn't enough margin against the
  // firmware's "too fast" rate limit when a reply lands close to a real
  // message chunk/ack.
  static const Duration _promptSyncCheckCooldown = Duration(seconds: 10);

  bool _shouldSendPromptSyncCheck(String cooldownKey) {
    final last = _lastPromptSyncCheckAt[cooldownKey];
    final now = DateTime.now();
    if (last != null && now.difference(last) < _promptSyncCheckCooldown) {
      return false;
    }
    _lastPromptSyncCheckAt[cooldownKey] = now;
    return true;
  }

  /// Called right after a send, a receive, opening the chat, or focusing
  /// the compose field for [contactKeyHex], so drift gets caught quickly
  /// rather than waiting for the next periodic poll — cheap, since a
  /// sync-check is just a few bytes of plaintext metadata, and
  /// event-driven rather than timer-driven so it doesn't add to the
  /// periodic airtime budget above (see _shouldSendPromptSyncCheck for
  /// why a burst of these still only sends one).
  void _requestPromptContactSyncCheck(String contactKeyHex) {
    // Typing, sending, receiving, and reopening the chat are all real
    // signs of life for this conversation, so any of them lifts a
    // previously-armed airtime backoff — see _clearContactSyncBackoff.
    _clearContactSyncBackoff(contactKeyHex);
    if (getContactOtpPad(contactKeyHex)?.enabled == true &&
        _shouldSendPromptSyncCheck('c:$contactKeyHex')) {
      checkContactPadSync(contactKeyHex);
    }
  }

  void _requestPromptChannelSyncCheck(int channelIndex) {
    _clearChannelSyncBackoff(channelIndex);
    if (getChannelOtpPad(channelIndex)?.enabled == true &&
        _shouldSendPromptSyncCheck('s:$channelIndex')) {
      checkChannelPadSync(channelIndex);
    }
  }

  // ── OTP pad consumption ──────────────────────────────────────────────
  // A single, mode-aware pair of helpers used for EVERY pad consumption in
  // this app — single-shot encrypt/decrypt and every chunk/ack send or
  // receive all go through these two functions. For
  // OtpPadMode.sharedSequential (channels), send and receive both route
  // through the identical `pad.takeSharedKeyBytes`/`pad.advanceShared`
  // pair — this is genuinely one consumption operation, not two branches
  // that happen to compute the same thing, exactly mirroring how Lua's
  // `pdib()` collapses both directions to the same case in Multi mode. For
  // OtpPadMode.twoPartyHalfSplit (contacts), sending and receiving remain
  // genuinely different (mine vs theirs), unchanged from before.
  ({Uint8List keyBytes, OtpPad updated}) _consumePadForSend(
    OtpPad pad,
    int length,
  ) {
    if (pad.mode == OtpPadMode.sharedSequential) {
      final keyBytes = pad.takeSharedKeyBytes(length);
      return (keyBytes: keyBytes, updated: pad.advanceShared(length));
    }
    final keyBytes = pad.takeMyKeyBytes(length);
    return (
      keyBytes: keyBytes,
      updated: pad.copyWith(myOffset: pad.myOffset + length),
    );
  }

  ({Uint8List keyBytes, OtpPad updated}) _consumePadForReceive(
    OtpPad pad,
    int length,
  ) {
    if (pad.mode == OtpPadMode.sharedSequential) {
      final keyBytes = pad.takeSharedKeyBytes(length);
      return (keyBytes: keyBytes, updated: pad.advanceShared(length));
    }
    final keyBytes = pad.takeTheirKeyBytes(length);
    return (
      keyBytes: keyBytes,
      updated: pad.copyWith(theirOffset: pad.theirOffset + length),
    );
  }

  /// Encrypts [plaintext] for [contact], advancing and persisting the pad
  /// offset. Called exactly once per logical message — see the note on
  /// `sendMessage` for why this must never run again on retry.
  Future<String> _encryptForContact(Contact contact, String plaintext) async {
    final contactKeyHex = contact.publicKeyHex;
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null) {
      throw OtpPadExhaustedException(neededBytes: 0, availableBytes: 0);
    }
    final needed = OtpService.plaintextByteLength(plaintext);
    final consumption = _consumePadForSend(pad, needed);
    final ciphertext = OtpService.encrypt(plaintext, consumption.keyBytes);
    _contactOtpPads[contactKeyHex] = consumption.updated;
    await _otpPadStore.saveContactPad(contactKeyHex, consumption.updated);
    _requestPromptContactSyncCheck(contactKeyHex);
    return ciphertext;
  }

  /// Returns both the ciphertext and the pad offset it was encrypted
  /// against (captured BEFORE [_consumePadForSend] advances it) — the
  /// caller wraps that offset onto the OUTGOING wire text only (see
  /// [OtpChannelOffsetService]) so a receiver can detect a collision with
  /// another sender instead of just decrypting whatever's at its own
  /// current front. The stored/local ciphertext record stays unwrapped.
  Future<({String cipherHex, int claimedOffset})> _encryptForChannel(
    int channelIndex,
    String plaintext,
  ) async {
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null) {
      throw OtpPadExhaustedException(neededBytes: 0, availableBytes: 0);
    }
    final claimedOffset = pad.offset;
    final needed = OtpService.plaintextByteLength(plaintext);
    final consumption = _consumePadForSend(pad, needed);
    final ciphertext = OtpService.encrypt(plaintext, consumption.keyBytes);
    _channelOtpPads[channelIndex] = consumption.updated;
    await _otpPadStore.saveChannelPad(channelIndex, consumption.updated);
    _requestPromptChannelSyncCheck(channelIndex);
    return (cipherHex: ciphertext, claimedOffset: claimedOffset);
  }

  /// Records that ciphertext hex [hex] decrypted to [plaintext] (empty
  /// string for "processed but nothing to display" — an ack or a non-final
  /// chunk piece), so a redelivery of the same message via a different
  /// receive path — or a genuine mesh-level retransmission — reuses the
  /// result instead of decrypting (and consuming pad) again. [chunkInfo],
  /// when this hex was a chunk piece, lets a later cache-hit still re-send
  /// that chunk's ack (see [_dispatchOtpContact]/[_dispatchOtpChannel]).
  void _rememberOtpDecrypt(
    String hex,
    String plaintext, {
    ({int tid, int idx})? chunkInfo,
  }) {
    if (_otpDecryptCache.containsKey(hex)) return;
    _otpDecryptCache[hex] = plaintext;
    _otpDecryptCacheOrder.add(hex);
    if (chunkInfo != null) _otpChunkHexIndex[hex] = chunkInfo;
    if (_otpDecryptCacheOrder.length > _otpDecryptCacheLimit) {
      final oldest = _otpDecryptCacheOrder.removeAt(0);
      _otpDecryptCache.remove(oldest);
      _otpChunkHexIndex.remove(oldest);
    }
  }

  void _rememberOtpAck(String cacheKey, String hex) {
    if (_otpAckCache.containsKey(cacheKey)) return;
    _otpAckCache[cacheKey] = hex;
    _otpAckCacheOrder.add(cacheKey);
    if (_otpAckCacheOrder.length > _otpAckCacheLimit) {
      final oldest = _otpAckCacheOrder.removeAt(0);
      _otpAckCache.remove(oldest);
    }
  }

  // ── OTP receive dispatch ─────────────────────────────────────────────
  // Handles every incoming OTP-looking payload for a contact or channel:
  // ordinary single-shot messages, chunk pieces of a multi-packet message,
  // and app-level chunk acks. `handled: false` means "not OTP at all, or
  // OTP not enabled here — leave the message exactly as received".
  // `handled: true, displayText: null` means "this WAS OTP and has been
  // fully processed (an ack, or a non-final chunk) — show nothing for it".
  // `handled: true, displayText: <text>` is the plaintext to show (a
  // decrypted single-shot message, a completed reassembly, or an error
  // placeholder).

  _OtpDispatchResult _dispatchOtpContact(Contact contact, String rawText) {
    final contactKeyHex = contact.publicKeyHex;
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null || !pad.enabled) {
      return const (handled: false, displayText: null);
    }
    // DMs carry framed ciphertext only (an ack is 10 bytes, a part at least
    // 13), as bare hex: nothing shorter, nothing with other text around it.
    final hex =
        OtpService.looksLikeCiphertextHex(rawText) &&
            rawText.length >= OtpService.minFramedDmHexChars
        ? rawText
        : null;
    if (hex == null) return const (handled: false, displayText: null);

    // Covers EVERY already-decrypted hex — acks and non-final chunk pieces
    // included, not just displayable messages (empty string means "already
    // processed, nothing to show"). This is essential, not just an
    // optimization: contact messages, like channel messages, can be
    // redelivered (mesh-level retransmission, or the sender's own chunk/ack
    // retry landing twice before state updates) and OTP decrypt is
    // stateful — reusing a cached result instead of decrypting again is
    // what stops a redelivery from double-consuming pad and desyncing.
    final cached = _otpDecryptCache[hex];
    if (cached != null) {
      final chunkInfo = _otpChunkHexIndex[hex];
      if (chunkInfo != null) {
        // Idempotent chunk redelivery: never re-decrypt/re-consume pad, but
        // still re-send this chunk's ack — the sender is retrying because
        // their first ack may not have landed. buildAckFrame/pad-consuming
        // work for the ack itself is deduped separately by _otpAckCache.
        _sendChunkAckToContact(contact, chunkInfo.tid, chunkInfo.idx);
        return const (handled: true, displayText: null);
      }
      return (handled: true, displayText: cached.isEmpty ? null : cached);
    }

    final cipherByteLen = hex.length ~/ 2;
    Uint8List plainBytes;
    ({Uint8List keyBytes, OtpPad updated}) consumption;
    try {
      final freshPad = getContactOtpPad(contactKeyHex)!;
      consumption = _consumePadForReceive(freshPad, cipherByteLen);
      plainBytes = OtpService.decryptBytesFromHex(hex, consumption.keyBytes);
    } catch (e) {
      // Not enough pad left for this length: not ours to read. Leave it as
      // an ordinary message and let a sync check sort out any drift.
      _requestPromptContactSyncCheck(contactKeyHex);
      return const (handled: false, displayText: null);
    }

    final parsed = OtpChunkService.parse(plainBytes);
    if (parsed is! ParsedAckFrame && parsed is! ParsedChunkFrame) {
      // Decrypted to something unframed: a plain DM that happens to be hex
      // (a key, a hash, "cafe"...), or a real one sent against pad bytes we
      // are out of step with. Either way the pad is untouched and the text
      // shows as sent; a sync check repairs a genuine drift.
      _requestPromptContactSyncCheck(contactKeyHex);
      return const (handled: false, displayText: null);
    }
    _contactOtpPads[contactKeyHex] = consumption.updated;
    unawaited(_otpPadStore.saveContactPad(contactKeyHex, consumption.updated));
    _requestPromptContactSyncCheck(contactKeyHex);

    if (parsed is ParsedAckFrame) {
      _rememberOtpDecrypt(hex, '');
      _handleIncomingOtpAck(contactKeyHex, parsed.tid, parsed.idx);
      return const (handled: true, displayText: null);
    }
    if (parsed is ParsedChunkFrame) {
      final reassembled = _handleIncomingChunkForContact(contact, parsed);
      _rememberOtpDecrypt(
        hex,
        reassembled ?? '',
        chunkInfo: (tid: parsed.tid, idx: parsed.idx),
      );
      if (reassembled == null) return const (handled: true, displayText: null);
      return (handled: true, displayText: reassembled);
    }

    final plaintext = utf8.decode(plainBytes, allowMalformed: true);
    _rememberOtpDecrypt(hex, plaintext);
    return (handled: true, displayText: plaintext);
  }

  _OtpDispatchResult _dispatchOtpChannel(
    int channelIndex,
    String senderName,
    String rawText,
  ) {
    final pad = getChannelOtpPad(channelIndex);
    if (pad == null || !pad.enabled) {
      return const (handled: false, displayText: null);
    }

    // Channel-only explicit pad-offset framing (see OtpChannelOffsetService)
    // - the real architectural gap this fixes: a shared-sequential channel
    // pad has no per-sender split, so two participants who transmit close
    // enough together that neither has heard the other's message can
    // encrypt against the SAME pad bytes. Without a claimed offset to check
    // against, this device would just decrypt whatever's at its own
    // current front and get garbage for whichever collided message it
    // processes second. A message with no z2 prefix (an older build, or
    // the Lua side before this ships there) falls through unchanged -
    // claimedOffset stays null and every check below is skipped, exactly
    // as before this fix.
    int? claimedOffset;
    var text = rawText;
    final offsetFramed = OtpChannelOffsetService.parse(rawText);
    if (offsetFramed != null) {
      claimedOffset = offsetFramed.offset;
      text = offsetFramed.cipherHex;
    }

    // Feeds the participant-sync tracking (see getActiveChannelParticipants
    // / the channel chat screen's participant strip) from ordinary
    // conversation, not just explicit sync-check replies — every
    // offset-bearing message someone sends is itself a statement of where
    // they think the pad is, at least as good a signal as a sync-check.
    // Deliberately BEFORE the cache-hit/collision/ahead checks below: even
    // a duplicate, a collision, or a gap is still evidence this sender was
    // just heard from, which is exactly what the strip needs to know.
    _recordChannelParticipantHeard(
      channelIndex,
      senderName,
      claimedOffset: claimedOffset,
      currentOffset: pad.offset,
    );

    // Channel ciphertext always carries its claimed offset ("z2<b36>|hex"),
    // from this app, OTP_3_RC1.lua and Wadamesh alike. Without it the post is
    // ordinary text, however hex-like it looks.
    if (offsetFramed == null || !OtpService.looksLikeCiphertextHex(text)) {
      return const (handled: false, displayText: null);
    }
    final hex = text;

    final cached = _otpDecryptCache[hex];
    if (cached != null) {
      final chunkInfo = _otpChunkHexIndex[hex];
      if (chunkInfo != null) {
        // Same idempotent-redelivery reasoning as the contact path above.
        // This deliberately runs BEFORE the offset compare below: a chunk
        // the sender re-transmitted because it never heard our ack has a
        // "stale" offset by now too, and that's not a collision, it's a
        // duplicate we've already fully processed — the cache hit on exact
        // ciphertext content (not offset) is what correctly tells the two
        // apart.
        _ackChunkFromChannelSender(senderName, chunkInfo.tid, chunkInfo.idx);
        return const (handled: true, displayText: null);
      }
      return (handled: true, displayText: cached.isEmpty ? null : cached);
    }

    if (claimedOffset != null) {
      final currentOffset = pad.offset;
      if (claimedOffset < currentOffset) {
        // Collision: this exact ciphertext is new (missed the cache-hit
        // dedup above), but it claims pad bytes we've already spent — on
        // our own send or an earlier receive. There's no historical record
        // of past offsets to recover which slice it actually wanted, so
        // unlike a resync gap this specific message is simply gone; say so
        // plainly instead of attempting a decrypt that can only be wrong.
        appLogger.warn(
          'channel $channelIndex: collision from $senderName at offset '
          '$claimedOffset (we are at $currentOffset) - message lost',
        );
        // Force an immediate, unthrottled resync the moment a collision is
        // detected, rather than waiting for the next periodic/backed-off
        // check (which passes 6-7's throttling can space out by minutes) -
        // ports OTP_3_RC1.lua's newest collision-handling behavior. There
        // is no accompanying "resend": this device never had the lost
        // message's plaintext to resend (that ciphertext belonged to
        // whoever collided with it, and Phase 1 never decrypts a collided
        // message), so all that's actionable here is getting this
        // channel's own counter caught up as fast as possible.
        checkChannelPadSync(channelIndex);
        _sendChannelNack(channelIndex, 'C');
        return (
          handled: true,
          displayText:
              '⚠️ Channel message from $senderName lost — collided with '
              'another sender',
        );
      }
      if (claimedOffset > currentOffset) {
        // We're behind what this message needs - most likely a predecessor
        // we haven't received yet. Feed the EXISTING auto-resync
        // grace-period machinery (_trackChannelResyncGap) with this
        // concrete, certain offset - an actual message declaring it, not
        // just a self-reported sync-check counter - so catch-up doesn't
        // have to wait for the next throttled periodic check. This
        // message can't be decrypted yet either (its bytes are past our
        // current front), so it's suppressed, not buffered for a retry.
        _trackChannelResyncGap(channelIndex, senderName, claimedOffset);
        return const (handled: true, displayText: null);
      }
      // claimedOffset == currentOffset: exactly the next expected message -
      // fall through to the ordinary decrypt path below, unchanged.
    }

    final cipherByteLen = hex.length ~/ 2;
    Uint8List plainBytes;
    try {
      final freshPad = getChannelOtpPad(channelIndex)!;
      final consumption = _consumePadForReceive(freshPad, cipherByteLen);
      plainBytes = OtpService.decryptBytesFromHex(hex, consumption.keyBytes);
      _channelOtpPads[channelIndex] = consumption.updated;
      unawaited(_otpPadStore.saveChannelPad(channelIndex, consumption.updated));
      _requestPromptChannelSyncCheck(channelIndex);
    } catch (e) {
      appLogger.warn('OTP decrypt failed for channel $channelIndex: $e');
      _sendChannelNack(channelIndex, 'D');
      _requestPromptChannelSyncCheck(channelIndex);
      return (
        handled: true,
        displayText: '🔒 Could not decrypt — pad may be out of sync',
      );
    }

    final parsed = OtpChunkService.parse(plainBytes);
    if (parsed is ParsedAckFrame) {
      _rememberOtpDecrypt(hex, '');
      _handleIncomingOtpAck(null, parsed.tid, parsed.idx, viaChannel: true);
      return const (handled: true, displayText: null);
    }
    if (parsed is ParsedChunkFrame) {
      final reassembled = _handleIncomingChunkForChannel(
        channelIndex,
        senderName,
        parsed,
      );
      _rememberOtpDecrypt(
        hex,
        reassembled ?? '',
        chunkInfo: (tid: parsed.tid, idx: parsed.idx),
      );
      if (reassembled == null) return const (handled: true, displayText: null);
      return (handled: true, displayText: reassembled);
    }

    final plaintext = utf8.decode(plainBytes, allowMalformed: true);
    _rememberOtpDecrypt(hex, plaintext);
    return (handled: true, displayText: plaintext);
  }

  /// Resolves [senderName] to a known contact and, if found, sends them a
  /// chunk ack for (tid, idx) as a DM — shared by both the first-arrival
  /// path ([_handleIncomingChunkForChannel]) and the idempotent-redelivery
  /// cache-hit path in [_dispatchOtpChannel], so a redelivered channel
  /// chunk still gets re-acked without re-decrypting/re-consuming pad.
  void _ackChunkFromChannelSender(String senderName, int tid, int idx) {
    final senderContact = _contacts.cast<Contact?>().firstWhere(
      (c) => c != null && c.name == senderName,
      orElse: () => null,
    );
    if (senderContact != null) {
      _sendChunkAckToContact(senderContact, tid, idx);
    } else {
      appLogger.info(
        'OTP: cannot ack channel chunk from "$senderName" — not a known '
        'contact, skipping ack',
      );
    }
  }

  // ── OTP chunk receive (reassembly + acking) ─────────────────────────

  /// Stores one incoming chunk for a contact DM transfer, always sends an
  /// ack for it (idempotent — a duplicate-received chunk just re-sends the
  /// same cached ack rather than reprocessing), and returns the fully
  /// reassembled plaintext once every chunk of this transfer has arrived
  /// (null while more are still pending).
  String? _handleIncomingChunkForContact(
    Contact contact,
    ParsedChunkFrame frame,
  ) {
    final contactKeyHex = contact.publicKeyHex;
    final perContact = _contactChunkReassembly.putIfAbsent(
      contactKeyHex,
      () => {},
    );
    final state = perContact.putIfAbsent(
      frame.tid,
      () => _OtpChunkReassembly(frame.totCh),
    );
    state.chunks.putIfAbsent(frame.idx, () => frame.data);
    state.lastActivity = DateTime.now();

    _sendChunkAckToContact(contact, frame.tid, frame.idx);

    final joined = state.tryJoin();
    if (joined == null) return null;
    perContact.remove(frame.tid);

    // An OTP-encrypted image transfer (see otp_image_transport.dart) rides
    // over this exact chunk pipeline, so the only way to tell it apart from
    // ordinary chat text is to check the reassembled PLAINTEXT for its
    // marker before ever calling utf8.decode on it — the marker check must
    // come first because `allowMalformed: true` below would otherwise
    // silently mangle the binary bitstream into lossy replacement
    // characters, destroying it. This can't return synchronously through
    // `_dispatchOtpContact`'s displayText plumbing like ordinary chunked
    // text does: registering the image (and its preview bytes) with
    // ReceivedImageStore is async, so it's finished separately and posts
    // its own message once done (see _completeIncomingContactImage) —
    // nothing is shown for this frame in the meantime, exactly like a
    // non-final chunk.
    final imagePayload = OtpImageTransport.parse(joined);
    if (imagePayload != null) {
      unawaited(
        _completeIncomingContactImage(contact, imagePayload, frame.tid),
      );
      return null;
    }

    return utf8.decode(joined, allowMalformed: true);
  }

  /// Finishes an OTP DM image transfer once every chunk has reassembled and
  /// [OtpImageTransport.parse] has confirmed the marker: hands the bitstream
  /// to [ReceivedImageStore] exactly as an inbound channel image would (see
  /// `ImageStreamReassembler.addChunk` in main.dart), then posts the
  /// sentinel message itself.
  ///
  /// Best-effort throughout: by the time this runs, the transfer has already
  /// been fully received and acked, so a failure here (no store wired, a
  /// disk-write error) must not look like a lost message — it's logged and
  /// dropped rather than surfaced as a decrypt error.
  Future<void> _completeIncomingContactImage(
    Contact contact,
    OtpImagePayload payload,
    int tid,
  ) async {
    final store = _receivedImageStore;
    if (store == null) {
      appLogger.warn(
        'OTP image from ${contact.publicKeyHex} dropped: no '
        'ReceivedImageStore wired into this build',
      );
      return;
    }
    final channelIndex = OtpImageTransport.virtualChannelIndexFor(
      contact.publicKeyHex,
    );
    final outcome = ImageChunkOutcome(
      ImageChunkStatus.completed,
      result: ImageReassemblyResult(
        key: ImageStreamKey(
          senderPrefix: _otpDmIncomingSenderPrefix,
          imgId: tid,
          channelIndex: channelIndex,
        ),
        metadata: payload.metadata,
        data: payload.bitstream,
        recoveredWithParity: false,
        chunkCount: 1,
      ),
    );
    ReceivedImageEntry? entry;
    try {
      entry = await store.handleOutcome(outcome, channelIndex: channelIndex);
    } on Exception catch (error) {
      appLogger.warn(
        'OTP image from ${contact.publicKeyHex} failed to register: $error',
      );
      return;
    }
    if (entry == null) return;
    final message = Message(
      senderKey: contact.publicKey,
      text: ReceivedImageRef.encode(entry.streamId),
      timestamp: DateTime.now(),
      isOutgoing: false,
      isCli: false,
      status: MessageStatus.delivered,
      pathBytes: Uint8List(0),
    );
    _addMessage(contact.publicKeyHex, message);
    notifyListeners();
  }

  /// Same idea for a channel-received chunk. Per the wire format, the ack
  /// MUST go back to the original sender as a direct message, never as a
  /// channel broadcast — but this app's channel messages don't carry a
  /// resolvable sender public key (only a display name; see
  /// ChannelMessage.fromFrame / _splitSenderText), so acking is only
  /// possible when [senderName] happens to match a known contact who also
  /// has their own DM OTP pad configured with us. When it doesn't, we
  /// still store/reassemble the chunk correctly (so the message itself is
  /// never lost) — we just can't tell the sender we got it, so they'll
  /// keep retrying until they give up. This is an explicit, documented
  /// platform limitation: Lua's single-device model doesn't have this
  /// "is this participant even a known contact" ambiguity.
  String? _handleIncomingChunkForChannel(
    int channelIndex,
    String senderName,
    ParsedChunkFrame frame,
  ) {
    final perChannel = _channelChunkReassembly.putIfAbsent(
      channelIndex,
      () => {},
    );
    final state = perChannel.putIfAbsent(
      frame.tid,
      () => _OtpChunkReassembly(frame.totCh),
    );
    state.chunks.putIfAbsent(frame.idx, () => frame.data);
    state.lastActivity = DateTime.now();

    _ackChunkFromChannelSender(senderName, frame.tid, frame.idx);

    final joined = state.tryJoin();
    if (joined == null) return null;
    perChannel.remove(frame.tid);
    return utf8.decode(joined, allowMalformed: true);
  }

  /// Sends (or, for a duplicate, re-sends the cached) chunk ack to
  /// [contact] as a direct message, OTP-encrypted with the DM pad we share
  /// with them. Skips gracefully — never throws — if we don't actually
  /// have a usable pad with this contact, since an ack is best-effort: the
  /// original sender's own retry timer is what actually guarantees
  /// eventual delivery.
  void _sendChunkAckToContact(Contact contact, int tid, int idx) {
    final cacheKey = 'c:${contact.publicKeyHex}:$tid:$idx';
    final cachedHex = _otpAckCache[cacheKey];
    if (cachedHex != null) {
      unawaited(
        sendFrame(
          buildSendTextMsgFrame(
            contact.publicKey,
            prepareContactOutboundText(contact, cachedHex),
          ),
        ),
      );
      return;
    }
    final pad = getContactOtpPad(contact.publicKeyHex);
    if (pad == null || !pad.enabled) return;
    final frame = OtpChunkService.buildAckFrame(tid: tid, idx: idx);
    Uint8List cipherBytes;
    OtpPad updatedPad;
    try {
      final consumption = _consumePadForSend(pad, frame.length);
      cipherBytes = OtpService.encryptBytes(frame, consumption.keyBytes);
      updatedPad = consumption.updated;
    } on OtpPadExhaustedException catch (e) {
      appLogger.warn(
        'Cannot send chunk ack to ${contact.publicKeyHex}: pad exhausted: $e',
      );
      return;
    }
    _contactOtpPads[contact.publicKeyHex] = updatedPad;
    unawaited(_otpPadStore.saveContactPad(contact.publicKeyHex, updatedPad));
    final hex = OtpService.bytesToHex(cipherBytes);
    _rememberOtpAck(cacheKey, hex);
    unawaited(
      sendFrame(
        buildSendTextMsgFrame(
          contact.publicKey,
          prepareContactOutboundText(contact, hex),
        ),
      ),
    );
  }

  /// Advances whichever pending chunked SEND (contact or channel) this ack
  /// belongs to. [fromContactKeyHex] restricts contact-DM matching to the
  /// contact that actually sent the ack; channel sends accept an ack from
  /// ANY current participant for the current chunk index (a deliberate,
  /// documented generalization of Lua's single-recipient DM ack model to
  /// N-party channels — the first valid ack for the current chunk is
  /// enough to advance, since sharedSequential pad state is symmetric for
  /// everyone on the channel).
  void _handleIncomingOtpAck(
    String? fromContactKeyHex,
    int tid,
    int idx, {
    bool viaChannel = false,
  }) {
    if (!viaChannel && fromContactKeyHex != null) {
      final contactState = _pendingContactChunkSends[fromContactKeyHex];
      if (contactState != null &&
          contactState.tid == tid &&
          idx == contactState.sctr) {
        _advanceContactChunkSend(contactState);
        return;
      }
    }
    for (final state in _pendingChannelChunkSends.values.toList()) {
      if (state.tid == tid && idx == state.sctr) {
        _advanceChannelChunkSend(state);
        return;
      }
    }
  }

  // ── OTP chunk send (contact DM) ──────────────────────────────────────

  Future<void> _sendChunkedContactMessage(
    Contact contact,
    String plaintext,
    Uint8List plainBytes, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
  }) async {
    final capacity =
        OtpService.maxPlaintextBytesForContact() -
        OtpChunkService.chunkOverheadBytes;
    if (capacity <= 0) {
      appLogger.warn(
        'sendMessage: no room for chunk framing overhead on this contact',
      );
      return;
    }
    final dataChunks = OtpChunkService.splitPlaintextBytes(
      plainBytes,
      capacity,
    );
    if (dataChunks.length > 255) {
      appLogger.warn(
        'sendMessage: message too long even for chunking '
        '(${dataChunks.length} chunks needed)',
      );
      return;
    }

    final message = Message.outgoing(
      contact.publicKey,
      plaintext,
      originalText: originalText,
      translatedLanguageCode: translatedLanguageCode,
      translationModelId: translationModelId,
      chunkIndex: 0,
      chunkTotal: dataChunks.length,
    );
    _addMessage(contact.publicKeyHex, message);
    notifyListeners();

    final tid = math.Random.secure().nextInt(256);
    final state = _OtpContactChunkSend(
      contact: contact,
      tid: tid,
      chunks: dataChunks,
      localMessageId: message.messageId,
    );
    _pendingContactChunkSends[contact.publicKeyHex] = state;
    await _sendCurrentContactChunk(state);
  }

  /// True when this contact has an OTP pad configured and no chunked send
  /// (text or image) already in flight — the gate a "send photo" button
  /// should use to decide whether to show/enable itself.
  bool canSendOtpImageToContact(String contactKeyHex) {
    final pad = getContactOtpPad(contactKeyHex);
    if (pad == null || !pad.enabled) return false;
    return !_pendingContactChunkSends.containsKey(contactKeyHex);
  }

  /// Sends [codecBitstream] (the output of `ImageCodecService.encodeImageFile`
  /// — see `image_send_preview_sheet.dart`) as an OTP-encrypted DM to
  /// [contact], riding over the same chunked-send pipeline an ordinary long
  /// OTP text message uses (see `_sendChunkedContactMessage` above) rather
  /// than the channel-only GRP_DATA image transport.
  ///
  /// [previewPng] is the sender's own 512x512 crop (not a decode) — exactly
  /// what the channel image feature shows for the sender's own bubble — so
  /// this contact's own sent photo renders immediately without waiting on a
  /// round trip or a model decode. Returns false without sending anything
  /// if there's no usable OTP pad for this contact, a chunked send to them
  /// is already in flight, or the image is too large even chunked.
  Future<bool> sendOtpImageToContact(
    Contact contact, {
    required Uint8List codecBitstream,
    required Uint8List previewPng,
    required ImageCodecRatePoint rate,
    int aspectCode = 0,
    int resolution = kImageCodecSquareSize,
  }) async {
    if (!canSendOtpImageToContact(contact.publicKeyHex)) return false;
    final metadata = ImageStreamMetadata(
      rate: rate,
      squareSize: resolution,
      aspectCode: aspectCode,
    );
    Uint8List plaintext;
    try {
      plaintext = OtpImageTransport.buildPlaintext(
        metadata: metadata,
        bitstream: codecBitstream,
      );
    } on ArgumentError catch (e) {
      appLogger.warn('sendOtpImage: unrepresentable resolution: $e');
      return false;
    }
    return _sendChunkedContactImage(
      contact,
      plaintext,
      metadata: metadata,
      previewPng: previewPng,
    );
  }

  Future<bool> _sendChunkedContactImage(
    Contact contact,
    Uint8List plainBytes, {
    required ImageStreamMetadata metadata,
    required Uint8List previewPng,
  }) async {
    final capacity =
        OtpService.maxPlaintextBytesForContact() -
        OtpChunkService.chunkOverheadBytes;
    if (capacity <= 0) {
      appLogger.warn(
        'sendOtpImage: no room for chunk framing overhead on this contact',
      );
      return false;
    }
    final dataChunks = OtpChunkService.splitPlaintextBytes(
      plainBytes,
      capacity,
    );
    if (dataChunks.length > 255) {
      appLogger.warn(
        'sendOtpImage: image too large even for chunking '
        '(${dataChunks.length} chunks needed)',
      );
      return false;
    }

    // Placeholder bubble text until the transfer completes and
    // onSendCompleted swaps it for the real ReceivedImageRef sentinel — the
    // chunk progress machinery (chunkIndex/chunkTotal) already renders
    // "n/m" over whatever text is here in the meantime, exactly like a long
    // chunked text message.
    final message = Message.outgoing(
      contact.publicKey,
      '📷 Photo',
      chunkIndex: 0,
      chunkTotal: dataChunks.length,
    );
    _addMessage(contact.publicKeyHex, message);
    notifyListeners();

    final tid = math.Random.secure().nextInt(256);
    final state = _OtpContactChunkSend(
      contact: contact,
      tid: tid,
      chunks: dataChunks,
      localMessageId: message.messageId,
    );
    state.onSendCompleted = (success) async {
      if (!success) return;
      final store = _receivedImageStore;
      if (store == null) return;
      final channelIndex = OtpImageTransport.virtualChannelIndexFor(
        contact.publicKeyHex,
      );
      try {
        final entry = await store.registerOutgoing(
          channelIndex: channelIndex,
          senderPrefix: _otpDmOutgoingSenderPrefix,
          imgId: tid,
          previewPng: previewPng,
          rate: aeicRatePointForUi(metadata.rate),
          chunkCount: dataChunks.length,
        );
        _updateStoredContactMessage(
          contact.publicKeyHex,
          message.messageId,
          (m) => m.copyWith(text: ReceivedImageRef.encode(entry.streamId)),
        );
        notifyListeners();
      } on Exception catch (error) {
        appLogger.warn('outgoing OTP image registration failed: $error');
      }
    };
    _pendingContactChunkSends[contact.publicKeyHex] = state;
    await _sendCurrentContactChunk(state);
    return true;
  }

  Future<void> _sendCurrentContactChunk(_OtpContactChunkSend state) async {
    if (_pendingContactChunkSends[state.contact.publicKeyHex] != state) return;
    if (state.sctr >= state.chunks.length) {
      _finishContactChunkSend(state, success: true);
      return;
    }
    if (state.currentCipherHex == null) {
      final pad = getContactOtpPad(state.contact.publicKeyHex);
      if (pad == null) {
        _finishContactChunkSend(state, success: false);
        return;
      }
      final frame = OtpChunkService.buildChunkFrame(
        tid: state.tid,
        idx: state.sctr,
        totCh: state.chunks.length,
        chunkData: state.chunks[state.sctr],
      );
      try {
        final consumption = _consumePadForSend(pad, frame.length);
        final cipherBytes = OtpService.encryptBytes(
          frame,
          consumption.keyBytes,
        );
        _contactOtpPads[state.contact.publicKeyHex] = consumption.updated;
        await _otpPadStore.saveContactPad(
          state.contact.publicKeyHex,
          consumption.updated,
        );
        state.currentCipherHex = OtpService.bytesToHex(cipherBytes);
      } on OtpPadExhaustedException catch (e) {
        appLogger.warn(
          'Chunk send pad exhausted for ${state.contact.publicKeyHex}: $e',
        );
        _finishContactChunkSend(state, success: false);
        return;
      }
    }
    // Re-check ownership after the await above (pad consumption + disk
    // save) — if a second send for this same contact somehow started while
    // this one was suspended there, it would have replaced this state in
    // _pendingContactChunkSends already. Transmitting anyway would put a
    // stale, already-superseded ciphertext chunk on the air using pad
    // bytes real (unrelated) traffic may since have consumed past, and its
    // own retry timer would keep re-sending it. See the identical guard on
    // _sendCurrentChannelChunk for the fuller reasoning.
    if (_pendingContactChunkSends[state.contact.publicKeyHex] != state) return;
    // Slick-UI: keep the bubble's progress in step with which part is
    // actually going out, not just a static "sending" — see
    // Message.chunkIndex/chunkTotal.
    _updateStoredContactMessage(
      state.contact.publicKeyHex,
      state.localMessageId,
      (m) =>
          m.copyWith(chunkIndex: state.sctr, chunkTotal: state.chunks.length),
    );
    await _transmitContactChunkCipher(state.contact, state.currentCipherHex!);
    state.lastAttemptAt = DateTime.now();
    state.cancelRetryTimer();
    state.retryTimer = Timer(
      const Duration(seconds: 12),
      () => _handleContactChunkTimeout(state),
    );
  }

  Future<void> _transmitContactChunkCipher(
    Contact contact,
    String cipherHex,
  ) async {
    await _waitForRadioQuiet(lastInboundRxTime: _lastContactMsgRxTime);
    final outboundText = prepareContactOutboundText(contact, cipherHex);
    await sendFrame(buildSendTextMsgFrame(contact.publicKey, outboundText));
  }

  void _handleContactChunkTimeout(_OtpContactChunkSend state) {
    if (_pendingContactChunkSends[state.contact.publicKeyHex] != state) return;
    state.retryCount += 1;
    // Local retry policy only — the wire format (chunk framing, reused
    // ciphertext) is what has to match Lua, not this timer/count. Lua's
    // own retry policy is not ported verbatim; this app already has its
    // own delivery-reliability conventions (see message_retry_service.dart)
    // and this mirrors that spirit rather than Lua's millisecond timers.
    if (state.retryCount > 5) {
      _finishContactChunkSend(state, success: false);
      return;
    }
    unawaited(
      _transmitContactChunkCipher(state.contact, state.currentCipherHex!),
    );
    state.lastAttemptAt = DateTime.now();
    state.retryTimer = Timer(
      const Duration(seconds: 12),
      () => _handleContactChunkTimeout(state),
    );
  }

  void _advanceContactChunkSend(_OtpContactChunkSend state) {
    state.cancelRetryTimer();
    state.retryCount = 0;
    state.sctr += 1;
    state.currentCipherHex = null;
    if (state.sctr >= state.chunks.length) {
      _finishContactChunkSend(state, success: true);
    } else {
      unawaited(_sendCurrentContactChunk(state));
    }
  }

  void _finishContactChunkSend(
    _OtpContactChunkSend state, {
    required bool success,
  }) {
    state.cancelRetryTimer();
    if (_pendingContactChunkSends[state.contact.publicKeyHex] == state) {
      _pendingContactChunkSends.remove(state.contact.publicKeyHex);
    }
    _updateStoredContactMessage(
      state.contact.publicKeyHex,
      state.localMessageId,
      (m) => m.copyWith(
        status: success ? MessageStatus.delivered : MessageStatus.failed,
      ),
    );
    if (success) {
      _requestPromptContactSyncCheck(state.contact.publicKeyHex);
    }
    final onCompleted = state.onSendCompleted;
    if (onCompleted != null) {
      unawaited(onCompleted(success));
    }
  }

  Future<void> _sendCurrentChannelChunk(_OtpChannelChunkSend state) async {
    if (_pendingChannelChunkSends[state.channel.index] != state) return;
    if (state.sctr >= state.chunks.length) {
      _finishChannelChunkSend(state, success: true);
      return;
    }
    if (state.currentCipherHex == null) {
      final pad = getChannelOtpPad(state.channel.index);
      if (pad == null) {
        _finishChannelChunkSend(state, success: false);
        return;
      }
      final frame = OtpChunkService.buildChunkFrame(
        tid: state.tid,
        idx: state.sctr,
        totCh: state.chunks.length,
        chunkData: state.chunks[state.sctr],
      );
      try {
        final consumption = _consumePadForSend(pad, frame.length);
        final cipherBytes = OtpService.encryptBytes(
          frame,
          consumption.keyBytes,
        );
        _channelOtpPads[state.channel.index] = consumption.updated;
        await _otpPadStore.saveChannelPad(
          state.channel.index,
          consumption.updated,
        );
        state.currentCipherHex = OtpService.bytesToHex(cipherBytes);
      } on OtpPadExhaustedException catch (e) {
        appLogger.warn(
          'Chunk send pad exhausted for channel ${state.channel.index}: $e',
        );
        _finishChannelChunkSend(state, success: false);
        return;
      }
    }
    // Re-check ownership after the await above (pad consumption + disk
    // save) — if a second send for this same channel somehow started while
    // this one was suspended there, it would have replaced this state in
    // _pendingChannelChunkSends already (see sendChannelMessage/
    // _sendChunkedChannelMessage's now-in-flight guard). Transmitting
    // anyway would put a stale, already-superseded ciphertext chunk on the
    // air against pad bytes real traffic may since have consumed past —
    // silently corrupting the shared channel pad's sequential offset for
    // every participant, not just this device — and its own retry timer
    // would keep re-sending it indefinitely.
    if (_pendingChannelChunkSends[state.channel.index] != state) return;
    // Slick-UI: keep the bubble's progress in step with which part is
    // actually going out — see Message.chunkIndex/chunkTotal (mirrored
    // here on ChannelMessage).
    _updateStoredChannelMessage(
      state.channel.index,
      state.localMessageId,
      (m) =>
          m.copyWith(chunkIndex: state.sctr, chunkTotal: state.chunks.length),
    );
    await _transmitChannelChunkCipher(state.channel, state.currentCipherHex!);
    state.lastAttemptAt = DateTime.now();
    state.cancelRetryTimer();
    state.retryTimer = Timer(
      const Duration(seconds: 12),
      () => _handleChannelChunkTimeout(state),
    );
  }

  Future<void> _transmitChannelChunkCipher(
    Channel channel,
    String cipherHex,
  ) async {
    final outboundText = prepareChannelOutboundText(channel.index, cipherHex);
    await _runScopedChannelSend(() async {
      await _waitForRadioQuiet(lastInboundRxTime: _lastChannelMsgRxTime);
      await _sendFrameAndWaitForCommandAck(
        buildSendChannelTextMsgFrame(channel.index, outboundText),
      );
    }, region: getChannelRegion(channel.index));
  }

  void _handleChannelChunkTimeout(_OtpChannelChunkSend state) {
    if (_pendingChannelChunkSends[state.channel.index] != state) return;
    state.retryCount += 1;
    if (state.retryCount > 5) {
      _finishChannelChunkSend(state, success: false);
      return;
    }
    unawaited(
      _transmitChannelChunkCipher(state.channel, state.currentCipherHex!),
    );
    state.lastAttemptAt = DateTime.now();
    state.retryTimer = Timer(
      const Duration(seconds: 12),
      () => _handleChannelChunkTimeout(state),
    );
  }

  /// Call when the app returns to the foreground (see main.dart's
  /// didChangeAppLifecycleState). A backgrounded app can have its chunk-
  /// send retry Timers suspended by Android for far longer than their
  /// nominal 12s (Doze / background execution limits) — a transfer that
  /// was genuinely due for a retry while backgrounded just sits there
  /// instead, and since _pendingContactChunkSends/_pendingChannelChunkSends
  /// stay populated the whole time, that also blocks any further send to
  /// the same contact/channel — not just until the ~60s retry budget
  /// should have run out, but indefinitely, until the app happens to come
  /// back to the foreground. This re-evaluates every in-flight chunked
  /// send against wall-clock time (not the Timer that may never have
  /// fired) and forces the overdue ones through the normal timeout
  /// handler immediately, exactly as if their Timer had fired on time.
  void resumeStalledOtpChunkSends() {
    const overdueAfter = Duration(seconds: 12);
    final now = DateTime.now();
    for (final state in _pendingContactChunkSends.values.toList()) {
      final last = state.lastAttemptAt;
      if (last != null && now.difference(last) >= overdueAfter) {
        state.cancelRetryTimer();
        _handleContactChunkTimeout(state);
      }
    }
    for (final state in _pendingChannelChunkSends.values.toList()) {
      final last = state.lastAttemptAt;
      if (last != null && now.difference(last) >= overdueAfter) {
        state.cancelRetryTimer();
        _handleChannelChunkTimeout(state);
      }
    }
  }

  void _advanceChannelChunkSend(_OtpChannelChunkSend state) {
    state.cancelRetryTimer();
    state.retryCount = 0;
    state.sctr += 1;
    state.currentCipherHex = null;
    if (state.sctr >= state.chunks.length) {
      _finishChannelChunkSend(state, success: true);
    } else {
      unawaited(_sendCurrentChannelChunk(state));
    }
  }

  void _finishChannelChunkSend(
    _OtpChannelChunkSend state, {
    required bool success,
  }) {
    state.cancelRetryTimer();
    if (_pendingChannelChunkSends[state.channel.index] == state) {
      _pendingChannelChunkSends.remove(state.channel.index);
    }
    _updateStoredChannelMessage(
      state.channel.index,
      state.localMessageId,
      (m) => m.copyWith(
        status: success
            ? ChannelMessageStatus.sent
            : ChannelMessageStatus.failed,
      ),
    );
    if (success) {
      _requestPromptChannelSyncCheck(state.channel.index);
    }
  }

  Future<void> loadUnreadState() async {
    _contactUnreadCount
      ..clear()
      ..addAll(await _unreadStore.loadContactUnreadCount());
    _unreadStateLoaded = true;
    _recalculateCachedUnreadTotals();
    notifyListeners();
    syncAppBadge();
  }

  /// Sets the app icon badge to the current unread total, e.g. on resume, so
  /// a badge left by delivered notifications doesn't outlive the unreads.
  void syncAppBadge() {
    if (!_unreadStateLoaded) return;
    unawaited(_notificationService.setAppBadge(getTotalUnreadCount()));
  }

  Future<void> loadCachedChannels() async {
    _cachedChannels = await _channelStore.loadChannels();
    _recalculateCachedChannelsUnreadTotal();
  }

  void setActiveContact(String? contactKeyHex) {
    if (contactKeyHex != null &&
        !_shouldTrackUnreadForContactKey(contactKeyHex)) {
      _activeContactKey = null;
      return;
    }
    _activeContactKey = contactKeyHex;
    if (contactKeyHex != null) {
      markContactRead(contactKeyHex);
      // Opening a chat is exactly the moment the periodic poll above
      // would otherwise have to wait up to _otpAutoSyncPollInterval to
      // first check it — check right away instead.
      _requestPromptContactSyncCheck(contactKeyHex);
    }
  }

  void setActiveChannel(int? channelIndex) {
    _activeChannelIndex = channelIndex;
    if (channelIndex != null) {
      markChannelRead(channelIndex);
      _requestPromptChannelSyncCheck(channelIndex);
    }
  }

  /// Called when the message-compose field gains focus (i.e. the person is
  /// about to start typing a reply) so a drifted pad is caught BEFORE real
  /// pad bytes get burned sending into it, rather than only ever surfacing
  /// after the fact as a failed decrypt on the other end.
  void notifyComposeStartedForContact(String contactKeyHex) {
    _requestPromptContactSyncCheck(contactKeyHex);
  }

  void notifyComposeStartedForChannel(int channelIndex) {
    _requestPromptChannelSyncCheck(channelIndex);
  }

  void markContactRead(String contactKeyHex) {
    if (!_shouldTrackUnreadForContactKey(contactKeyHex)) return;
    final previousCount = _contactUnreadCount[contactKeyHex] ?? 0;
    if (previousCount > 0) {
      _contactUnreadCount[contactKeyHex] = 0;
      _cachedContactsUnreadTotal = (_cachedContactsUnreadTotal - previousCount)
          .clamp(0, _cachedContactsUnreadTotal);
      _appDebugLogService?.info(
        'Contact $contactKeyHex marked as read (was $previousCount unread)',
        tag: 'Unread',
      );
      _unreadStore.saveContactUnreadCount(
        Map<String, int>.from(_contactUnreadCount),
      );
      _notificationService.clearContactNotification(
        contactKeyHex,
        getTotalUnreadCount(),
      );
      notifyListeners();
    }
  }

  void setContactUnreadCount(String contactKeyHex, int count) {
    final previousCount = _contactUnreadCount[contactKeyHex] ?? 0;
    _contactUnreadCount[contactKeyHex] = count;
    if (_shouldTrackUnreadForContactKey(contactKeyHex)) {
      final total = _cachedContactsUnreadTotal + (count - previousCount);
      _cachedContactsUnreadTotal = total < 0 ? 0 : total;
    }
    _unreadStore.saveContactUnreadCount(
      Map<String, int>.from(_contactUnreadCount),
    );
    notifyListeners();
  }

  void setChannelUnreadCount(int channelIndex, int count) {
    final channel = _findChannelByIndex(channelIndex);
    if (channel != null) {
      final previousCount = channel.unreadCount;
      channel.unreadCount = count;
      final total = _cachedChannelsUnreadTotal + (count - previousCount);
      _cachedChannelsUnreadTotal = total < 0 ? 0 : total;
      unawaited(
        _channelStore.saveChannels(
          _channels.isNotEmpty ? _channels : _cachedChannels,
        ),
      );
      notifyListeners();
    }
  }

  void markChannelRead(int channelIndex) {
    final channel = _findChannelByIndex(channelIndex);
    if (channel != null && channel.unreadCount > 0) {
      final previousCount = channel.unreadCount;
      channel.unreadCount = 0;
      _cachedChannelsUnreadTotal = (_cachedChannelsUnreadTotal - previousCount)
          .clamp(0, _cachedChannelsUnreadTotal);
      _appDebugLogService?.info(
        'Channel ${channel.name.isNotEmpty ? channel.name : channelIndex} marked as read (was $previousCount unread)',
        tag: 'Unread',
      );
      unawaited(
        _channelStore.saveChannels(
          _channels.isNotEmpty ? _channels : _cachedChannels,
        ),
      );
      _notificationService.clearChannelNotification(
        channelIndex,
        getTotalUnreadCount(),
      );
      notifyListeners();
    }
  }

  /// Handles a reply or mark-as-read action from a message notification
  /// (notification shade, watch, or Android Auto).
  Future<void> handleNotificationReply(NotificationReply reply) async {
    if (reply.action == NotificationReplyAction.mute) {
      await _appSettingsService?.muteChannel(
        _channelDisplayName(reply.channelIndex!),
      );
      await _notificationService.clearChannelNotification(
        reply.channelIndex!,
        getTotalUnreadCount(),
      );
      return;
    }
    if (reply.action == NotificationReplyAction.markRead) {
      // markXRead only clears the notification when there were unread
      // messages; clear it here otherwise so the action always dismisses it.
      if (reply.isChannel) {
        final index = reply.channelIndex!;
        final hadUnread = getUnreadCountForChannelIndex(index) > 0;
        markChannelRead(index);
        if (!hadUnread) {
          await _notificationService.clearChannelNotification(
            index,
            getTotalUnreadCount(),
          );
        }
      } else {
        final key = reply.contactKeyHex!;
        final hadUnread = getUnreadCountForContactKey(key) > 0;
        markContactRead(key);
        if (!hadUnread) {
          await _notificationService.clearContactNotification(
            key,
            getTotalUnreadCount(),
          );
        }
      }
      return;
    }

    if (!isConnected) {
      await _notificationService.showReplyFailed(
        reply,
        NotificationReplyFailure.notConnected,
        badgeCount: getTotalUnreadCount(),
      );
      return;
    }

    final channel = reply.isChannel
        ? _findChannelByIndex(reply.channelIndex!)
        : null;
    final contact = reply.isChannel
        ? null
        : getContactByPubKeyHex(reply.contactKeyHex!);
    if (channel == null && contact == null) {
      await _notificationService.showReplyFailed(
        reply,
        NotificationReplyFailure.unavailable,
        badgeCount: getTotalUnreadCount(),
      );
      return;
    }

    // Same length limits and Cyr2Lat handling as the chat screens.
    final parts = splitMessageToFit(reply.text, (part) {
      if (channel != null) {
        return utf8
                .encode(prepareChannelOutboundText(channel.index, part))
                .length <=
            maxChannelMessageBytes(selfName);
      }
      return utf8.encode(prepareContactOutboundText(contact!, part)).length <=
          maxContactMessageBytes();
    });
    if (parts == null) {
      await _notificationService.showReplyFailed(
        reply,
        NotificationReplyFailure.tooLong,
        badgeCount: getTotalUnreadCount(),
      );
      return;
    }

    _appDebugLogService?.info(
      'Sending notification reply in ${parts.length} part(s)',
      tag: 'Notification',
    );
    for (final part in parts) {
      // sendMessage/sendChannelMessage silently do nothing when disconnected,
      // so check before every part in case the link dropped mid-reply.
      if (!isConnected) {
        await _notificationService.showReplyFailed(
          reply,
          NotificationReplyFailure.notConnected,
          badgeCount: getTotalUnreadCount(),
        );
        return;
      }
      var text = part;
      try {
        final cyr2lat = channel != null
            ? isChannelCyr2LatEnabled(channel.index)
            : isContactCyr2LatEnabled(contact!.publicKeyHex);
        if (cyr2lat) text = Cyr2Lat.encode(text);
      } catch (_) {}
      try {
        if (channel != null) {
          await sendChannelMessage(channel, text);
        } else {
          await sendMessage(contact!, text);
        }
      } catch (e) {
        appLogger.warn('Notification reply send failed: $e');
        await _notificationService.showReplyFailed(
          reply,
          isConnected
              ? NotificationReplyFailure.sendFailed
              : NotificationReplyFailure.notConnected,
          badgeCount: getTotalUnreadCount(),
        );
        return;
      }
    }
    await _notificationService.showOwnReply(
      reply,
      reply.text,
      badgeCount: getTotalUnreadCount(),
    );
  }

  /// Slots holding the same channel as [slot]. Settings are stored per
  /// channel ID, so the in-memory copy of every such slot must change too.
  List<int> _slotsSharingChannel(int slot) {
    final id = _slotChannelIds[slot];
    if (id == null) return [slot];
    return [
      for (final entry in _slotChannelIds.entries)
        if (entry.value == id) entry.key,
    ];
  }

  Future<void> setChannelSmazEnabled(int channelIndex, bool enabled) async {
    final slots = _slotsSharingChannel(channelIndex);
    for (final slot in slots) {
      _channelSmazEnabled[slot] = enabled;
    }
    final channelId = _channelIdForSlot(channelIndex);
    if (enabled) {
      for (final slot in slots) {
        _channelCyr2LatEnabled[slot] = false;
      }
      if (channelId != null) {
        await _channelSettingsStore.saveCyr2LatEnabled(channelId, false);
      }
    }
    if (channelId != null) {
      await _channelSettingsStore.saveSmazEnabled(channelId, enabled);
    }
    notifyListeners();
  }

  Future<void> setContactSmazEnabled(String contactKeyHex, bool enabled) async {
    _contactSmazEnabled[contactKeyHex] = enabled;
    await _contactSettingsStore.saveSmazEnabled(contactKeyHex, enabled);
    notifyListeners();
  }

  Future<void> setChannelUrlImagesEnabled(
    int channelIndex,
    bool enabled,
  ) async {
    for (final slot in _slotsSharingChannel(channelIndex)) {
      _channelUrlImagesEnabled[slot] = enabled;
    }
    final channelId = _channelIdForSlot(channelIndex);
    if (channelId != null) {
      await _channelSettingsStore.saveUrlImagesEnabled(channelId, enabled);
    }
    notifyListeners();
  }

  Future<void> setContactUrlImagesEnabled(
    String contactKeyHex,
    bool enabled,
  ) async {
    _contactUrlImagesEnabled[contactKeyHex] = enabled;
    await _contactSettingsStore.saveUrlImagesEnabled(contactKeyHex, enabled);
    notifyListeners();
  }

  Future<void> setChannelCyr2LatEnabled(int channelIndex, bool enabled) async {
    final slots = _slotsSharingChannel(channelIndex);
    for (final slot in slots) {
      _channelCyr2LatEnabled[slot] = enabled;
    }
    final channelId = _channelIdForSlot(channelIndex);
    if (enabled) {
      for (final slot in slots) {
        _channelSmazEnabled[slot] = false;
      }
      if (channelId != null) {
        await _channelSettingsStore.saveSmazEnabled(channelId, false);
      }
    }
    if (channelId != null) {
      await _channelSettingsStore.saveCyr2LatEnabled(channelId, enabled);
    }
    notifyListeners();
  }

  Future<void> setContactCyr2LatEnabled(
    String contactKeyHex,
    bool enabled,
  ) async {
    _contactCyr2LatEnabled[contactKeyHex] = enabled;
    await _contactSettingsStore.saveCyr2LatEnabled(contactKeyHex, enabled);
    notifyListeners();
  }

  Future<void> setChannelRegion(int channelIndex, String region) async {
    // Update in-memory state and notify synchronously so the UI reflects the
    // change immediately; persistence happens in the background.
    for (final slot in _slotsSharingChannel(channelIndex)) {
      _channelRegions[slot] = region;
    }
    notifyListeners();
    final channelId = _channelIdForSlot(channelIndex);
    if (channelId != null) {
      await _channelRegionStore.saveRegion(channelId, region);
    }
  }

  Future<void> _loadChannelOrder() async {
    _channelOrder = await _channelOrderStore.loadChannelOrder();
    _applyChannelOrder();
    notifyListeners();
  }

  /// History is stored by channel ID, so it may carry the slot the channel
  /// sat in when it was saved; rebind it to the slot it is shown in now.
  List<ChannelMessage> _bindToSlot(List<ChannelMessage> messages, int slot) => [
    for (final message in messages)
      message.channelIndex == slot
          ? message
          : message.copyWith(channelIndex: slot),
  ];

  /// Load persisted channel messages for a specific channel
  Future<void> _loadChannelMessages(int channelIndex) async {
    final channelId = _slotChannelIds[channelIndex];
    final allMessages = channelId == null
        ? <ChannelMessage>[]
        : _bindToSlot(
            await _channelMessageStore.loadChannelMessages(channelId),
            channelIndex,
          );
    // Keep only the most recent N messages in memory to bound memory usage
    final windowedMessages = allMessages.length > _messageWindowSize
        ? allMessages.sublist(allMessages.length - _messageWindowSize)
        : allMessages;
    if (channelId != null) {
      _channelMessageStore.setArchived(
        channelId,
        allMessages.sublist(0, allMessages.length - windowedMessages.length),
      );
    }
    // Replace even when nothing is stored so another radio's messages never
    // linger under this index.
    final hadMessages = _channelMessages[channelIndex]?.isNotEmpty ?? false;
    _channelMessages[channelIndex] = windowedMessages;
    if (hadMessages || windowedMessages.isNotEmpty) notifyListeners();
  }

  /// Load older channel messages (pagination)
  Future<List<ChannelMessage>> loadOlderChannelMessages(
    int channelIndex, {
    int count = 50,
  }) async {
    final slot = _canonicalSlot(channelIndex);
    final channelId = _channelIdForSlot(slot);
    if (channelId == null) return [];
    final allMessages = await _channelMessageStore.loadChannelMessages(
      channelId,
    );
    final currentMessages = _channelMessages[slot] ?? [];

    // Storage holds the archived entries followed by the in-memory window.
    final currentOffset =
        (_channelMessageStore.archivedCount(channelId) ??
                allMessages.length - currentMessages.length)
            .clamp(0, allMessages.length);
    if (currentOffset == 0) {
      return []; // No more messages to load
    }

    final fetchCount = count.clamp(0, currentOffset);
    final startIndex = currentOffset - fetchCount;

    final olderMessages = _bindToSlot(
      allMessages.sublist(startIndex, currentOffset),
      slot,
    );
    _channelMessageStore.unarchiveNewest(channelId, olderMessages.length);

    // Prepend to current conversation
    _channelMessages[slot] = [...olderMessages, ...currentMessages];
    notifyListeners();

    return olderMessages;
  }

  /// Loads the persisted messages of every channel in the slot map. Slots
  /// that hold no channel, or alias a lower slot with the same PSK, are
  /// emptied.
  Future<void> loadAllChannelMessages() async {
    var removed = false;
    for (final slot in _channelMessages.keys.toList()) {
      if (!_slotChannelIds.containsKey(slot) || _canonicalSlot(slot) != slot) {
        _channelMessages.remove(slot);
        _processedChannelReactions.remove(slot);
        removed = true;
      }
    }
    if (removed) notifyListeners();
    for (final slot in _slotChannelIds.keys.toList()..sort()) {
      if (_canonicalSlot(slot) == slot) await _loadChannelMessages(slot);
    }
  }

  void initialize({
    required MessageRetryService retryService,
    required PathHistoryService pathHistoryService,
    AppSettingsService? appSettingsService,
    TranslationService? translationService,
    BleDebugLogService? bleDebugLogService,
    AppDebugLogService? appDebugLogService,
    BackgroundService? backgroundService,
    TimeoutPredictionService? timeoutPredictionService,
    ImageCodecService? imageCodecService,
    ImageChunkTransport? imageTransport,
    ReceivedImageStore? receivedImageStore,
    void Function(ImageChunkOutcome outcome)? onImageChunk,
    void Function(int senderPrefix)? onImageSenderPrefix,
  }) {
    _retryService = retryService;
    _pathHistoryService = pathHistoryService;
    _appSettingsService = appSettingsService;
    _translationService = translationService;
    _imageCodecService = imageCodecService;
    _imageTransport = imageTransport;
    _receivedImageStore = receivedImageStore;
    _onImageChunk = onImageChunk;
    _onImageSenderPrefix = onImageSenderPrefix;
    _bleDebugLogService = bleDebugLogService;
    _appDebugLogService = appDebugLogService;
    _backgroundService = backgroundService;
    _timeoutPredictionService = timeoutPredictionService;
    _usbManager.setDebugLogService(_appDebugLogService);
    _tcpConnector.setDebugLogService(_appDebugLogService);

    // Initialize notification service
    _notificationService.initialize();
    _notificationReplySubscription ??= _notificationService.replies.listen(
      (reply) => unawaited(
        handleNotificationReply(reply).catchError((Object e) {
          appLogger.warn('Notification action failed: $e');
        }),
      ),
    );
    _loadChannelOrder();

    // Initialize retry service callbacks
    _retryService?.initialize(
      RetryServiceConfig(
        sendMessage: _sendMessageDirect,
        addMessage: _addMessage,
        updateMessage: _updateMessage,
        onMaxRetriesExceeded: _handleOtpSendExhausted,
        clearContactPath: clearContactPath,
        setContactPath: setContactPath,
        calculateTimeout:
            (
              pathLength,
              messageBytes, {
              String? contactKey,
              int? deviceTimeoutMs,
            }) => calculateTimeout(
              pathLength: pathLength,
              messageBytes: messageBytes,
              contactKey: contactKey,
              deviceTimeoutMs: deviceTimeoutMs,
            ),
        getSelfPublicKey: () => _selfPublicKey,
        prepareContactOutboundText: prepareContactOutboundText,
        appSettingsService: appSettingsService,
        debugLogService: _appDebugLogService,
        recordPathResult: _recordPathResult,
        selectRetryPath:
            (contactKey, attemptIndex, maxRetries, recentSelections) =>
                _selectAutoPathForAttempt(
                  contactKey,
                  attemptIndex: attemptIndex,
                  maxRetries: maxRetries,
                  recentSelections: recentSelections,
                ),
        onDeliveryObserved: (contactKey, pathLength, messageBytes, tripTimeMs) {
          final secSinceRx = DateTime.now()
              .difference(_lastRxBeforeFrame)
              .inSeconds;
          _timeoutPredictionService?.recordObservation(
            contactKey: contactKey,
            pathLength: pathLength,
            messageBytes: messageBytes,
            tripTimeMs: tripTimeMs,
            secondsSinceLastRx: secSinceRx,
          );
        },
      ),
    );
    final maxRetries = _appSettingsService?.settings.maxMessageRetries ?? 5;
    _retryService?.setMaxRetries(maxRetries);
  }

  Future<void> loadContactCache() async {
    _contactUrlImagesEnabled.clear();
    final cached = await _contactStore.loadContacts();
    _knownContactKeys
      ..clear()
      ..addAll(cached.map((c) => c.publicKeyHex));
    _contacts
      ..clear()
      ..addAll(cached);
    for (final contact in cached) {
      _ensureContactSmazSettingLoaded(contact.publicKeyHex);
      _ensureContactCyr2LatSettingLoaded(contact.publicKeyHex);
      _ensureContactUrlImagesSettingLoaded(contact.publicKeyHex);
    }
  }

  Future<void> _loadDiscoveredContactCache() async {
    final cached = await _discoveryContactStore.loadContacts();
    // When eviction is enabled, trim a previously-saved oversized list down to
    // the freshest entries so a device that grew unbounded before the cap
    // existed recovers on load.
    if (_evictDiscoveredContactsEnabled &&
        _trimDiscoveredContactsToLimit(cached)) {
      unawaited(_discoveryContactStore.saveContacts(cached));
    }
    _discoveredContacts
      ..clear()
      ..addAll(cached);
  }

  bool get _evictDiscoveredContactsEnabled =>
      _appSettingsService?.settings.evictDiscoveredContactsEnabled ?? true;

  bool _trimDiscoveredContactsToLimit(List<Contact> contacts) {
    if (contacts.length <= maxDiscoveredContacts) return false;
    contacts.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    contacts.removeRange(maxDiscoveredContacts, contacts.length);
    return true;
  }

  Future<void> trimDiscoveredContactsToLimit() async {
    if (!_trimDiscoveredContactsToLimit(_discoveredContacts)) return;
    await _persistDiscoveredContacts();
    notifyListeners();
  }

  /// Reloads the persisted settings of every channel in the slot map.
  Future<void> loadChannelSettings() async {
    _channelSmazEnabled.clear();
    _channelCyr2LatEnabled.clear();
    _channelUrlImagesEnabled.clear();
    _channelCyr2LatProfileId.clear();
    _channelRegions.clear();
    _defaultRegion = _channelRegionStore.loadDefaultRegion();
    for (final slot in _slotChannelIds.keys.toList()) {
      await _loadChannelSlotSettings(slot);
    }
  }

  Future<void> _loadChannelSlotSettings(int slot) async {
    final channelId = _slotChannelIds[slot];
    if (channelId == null) return;
    _channelSmazEnabled[slot] = await _channelSettingsStore.loadSmazEnabled(
      channelId,
    );
    _channelCyr2LatEnabled[slot] = await _channelSettingsStore
        .loadCyr2LatEnabled(channelId);
    _channelUrlImagesEnabled[slot] = await _channelSettingsStore
        .loadUrlImagesEnabled(channelId);
    _channelRegions[slot] = await _channelRegionStore.loadRegion(channelId);
  }

  /// After an incoming DM or channel message, wait before TX so we do not
  /// collide with mesh propagation. With companion stats, scale wait by RF
  /// conditions (up to [_contactMsgBackoffMaxMs]); otherwise use
  /// [_contactMsgBackoffFallbackMs].
  int _contactMessageBackoffTargetMs() {
    if (!supportsCompanionRadioStats || _latestRadioStats == null) {
      return _contactMsgBackoffFallbackMs;
    }
    final stats = _latestRadioStats!;
    final nf = stats.noiseFloorDbm.toDouble();
    // Quieter (more negative) → lower score; noisier → higher.
    const noiseQuietDbm = -118.0;
    const noiseNoisyDbm = -88.0;
    final noiseT = ((nf - noiseQuietDbm) / (noiseNoisyDbm - noiseQuietDbm))
        .clamp(0.0, 1.0);

    final snr = stats.lastSnrDb;
    const snrGood = 12.0;
    const snrBad = -2.0;
    final snrT = (1.0 - ((snr - snrBad) / (snrGood - snrBad))).clamp(0.0, 1.0);

    final airBusy = _recentAirtimeBusyFraction();
    final severity = (math.max(noiseT, snrT) * 0.82 + airBusy * 0.18).clamp(
      0.0,
      1.0,
    );

    return (_contactMsgBackoffMinMs +
            severity * (_contactMsgBackoffMaxMs - _contactMsgBackoffMinMs))
        .round();
  }

  /// 1.0 shortly after TX/RX airtime counters increase, decaying to 0 over ~8s.
  double _recentAirtimeBusyFraction() {
    final sw = _airtimeBumpStopwatch;
    if (sw == null || !sw.isRunning) return 0;
    final ms = sw.elapsedMilliseconds;
    const windowMs = 8000;
    if (ms >= windowMs) return 0;
    return 1.0 - (ms / windowMs);
  }

  /// Start of the post-inbound cool-down: the later of BLE message RX time and
  /// companion airtime bump ([_airtimeBumpStopwatch], same as the activity dot).
  DateTime _postTxBackoffAnchor(DateTime lastInboundRxTime) {
    if (!supportsCompanionRadioStats) return lastInboundRxTime;
    final sw = _airtimeBumpStopwatch;
    if (sw == null || !sw.isRunning) return lastInboundRxTime;
    final bumpAt = DateTime.now().subtract(sw.elapsed);
    return bumpAt.isAfter(lastInboundRxTime) ? bumpAt : lastInboundRxTime;
  }

  Future<void> _waitForRadioQuiet({required DateTime lastInboundRxTime}) async {
    // Wait for backoff after inbound traffic / RF airtime (avoid collision with
    // mesh propagation). Elapsed time uses the dot's airtime bump when newer.
    final backoffTargetMs = _contactMessageBackoffTargetMs();
    final anchor = _postTxBackoffAnchor(lastInboundRxTime);
    final msSinceAnchor = DateTime.now().difference(anchor).inMilliseconds;
    if (msSinceAnchor < backoffTargetMs) {
      final waitMs = backoffTargetMs - msSinceAnchor;
      debugPrint(
        'Post-inbound backoff: waiting ${waitMs}ms '
        '(target=${backoffTargetMs}ms, anchorAge=${msSinceAnchor}ms)',
      );
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }

    // Then wait for radio silence (no RF activity for 3s)
    final msSinceRx = DateTime.now()
        .difference(_lastRadioRxTime)
        .inMilliseconds;
    if (msSinceRx >= _radioQuietMs) return;

    final deadline = DateTime.now().add(
      const Duration(milliseconds: _radioQuietMaxWaitMs),
    );
    while (DateTime.now().isBefore(deadline)) {
      final quiet = DateTime.now().difference(_lastRadioRxTime).inMilliseconds;
      if (quiet >= _radioQuietMs) {
        debugPrint('Radio quiet for ${quiet}ms, proceeding with send');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    debugPrint(
      'Radio quiet wait exceeded ${_radioQuietMaxWaitMs}ms, sending anyway',
    );
  }

  Future<void> _sendMessageDirect(
    Contact contact,
    String text,
    int attempt,
    int timestampSeconds,
  ) async {
    if (!isConnected) throw StateError('Not connected');
    if (text.isEmpty) throw ArgumentError('Empty message text');
    try {
      await _waitForRadioQuiet(lastInboundRxTime: _lastContactMsgRxTime);
      final outboundText = prepareContactOutboundText(contact, text);
      // Wait for SENT so an ERR (unknown contact, packet pool full, text too
      // long for this attempt) fails the message instead of timing out.
      await sendFrame(
        buildSendTextMsgFrame(
          contact.publicKey,
          outboundText,
          attempt: attempt,
          timestampSeconds: timestampSeconds,
        ),
        waitForGenericAck: true,
      );
    } on TimeoutException catch (e) {
      appLogger.warn('No SENT reply for message: $e', tag: 'Connector');
    } catch (e) {
      appLogger.error('Failed to send message: $e', tag: 'Connector');
      rethrow;
    }
  }

  void _updateMessage(Message message) {
    final contactKey = pubKeyToHex(message.senderKey);
    final messages = _conversations[contactKey];
    if (messages != null) {
      final index = messages.indexWhere(
        (m) => m.messageId == message.messageId,
      );
      if (index != -1) {
        messages[index] = message;
        _messageStore.saveMessages(contactKey, messages);
        notifyListeners();
      }
    }

    // If this is a reaction message, update the target message's reaction status
    final reactionInfo = ReactionHelper.parseReaction(message.text);
    if (reactionInfo != null &&
        (message.status == MessageStatus.delivered ||
            message.status == MessageStatus.failed)) {
      final contactKey2 = pubKeyToHex(message.senderKey);
      _setReactionStatus(contactKey2, reactionInfo, message.status);
      _messageStore.saveMessages(
        contactKey2,
        _conversations[contactKey2] ?? [],
      );
      notifyListeners();
    }
  }

  // ===================== OTP store-and-forward =====================
  // Ports OTP_3_RC1.lua's waiting_queue/flush_waiting/waiting_tick (see the
  // dedicated project-doc section). DM-only, matching Lua: channels have no
  // clean single "is this contact reachable" signal, and a channel's shared
  // pad already has its own collision-coordination problem (see the channel
  // OTP-collision sections) that multi-party queuing would only compound.

  /// [RetryServiceConfig.onMaxRetriesExceeded] — called by MessageRetryService
  /// the moment an outgoing message would otherwise be marked failed. Claims
  /// only single-shot OTP sends (message.otpPlaintext != null); anything else
  /// (plaintext mesh messages, reactions) falls through to the normal failed
  /// handling exactly as before this feature, since Lua's store-and-forward
  /// only ever applied to OTP's own ssend path either.
  bool _handleOtpSendExhausted(Message message, Contact contact) {
    if (message.otpPlaintext == null) return false;
    final contactKeyHex = contact.publicKeyHex;
    final queue = _waitingQueue.putIfAbsent(contactKeyHex, () => []);
    // Refusing a NEW send once the queue is already at cap (see sendMessage)
    // is meant to keep this from ever happening — this is a safety net, not
    // the primary gate.
    if (queue.length >= _waitingQueueCap) {
      appLogger.warn(
        'OTP store-and-forward queue for $contactKeyHex is already at cap '
        '($_waitingQueueCap) — letting this send fail instead of growing '
        'the queue further unbounded',
      );
      return false;
    }
    final waitingMessage = message.copyWith(
      status: MessageStatus.waiting,
      waitingSinceAt: DateTime.now(),
    );
    queue.add(waitingMessage);
    _updateMessage(waitingMessage);
    appLogger.info(
      'OTP send to $contactKeyHex exhausted retries — queued for '
      'store-and-forward (${queue.length}/$_waitingQueueCap)',
    );
    return true;
  }

  /// Attempts the oldest queued message for [contactKeyHex], rate-limited by
  /// [_waitingFlushCooldown] so repeated "heard from them" triggers (several
  /// sync-check replies in a row, say) don't each cost a retransmission.
  /// Called both from _maybeHandleContactSyncMessage (the moment anything at
  /// all is heard from that contact — mirrors Lua's flush_waiting, driven
  /// from handle_sync_message) and from the background _waitingQueueTickTimer
  /// sweep (mirrors waiting_tick).
  void _flushWaitingQueue(String contactKeyHex) {
    final queue = _waitingQueue[contactKeyHex];
    if (queue == null || queue.isEmpty) return;
    final now = DateTime.now();
    final last = _lastWaitingFlushAt[contactKeyHex];
    if (last != null && now.difference(last) < _waitingFlushCooldown) return;
    // Never compete with a real send already in flight for this contact —
    // same reasoning as every other OTP transmission gate in this file.
    if (_pendingContactChunkSends.containsKey(contactKeyHex)) return;
    Contact? contact;
    for (final c in _contacts) {
      if (c.publicKeyHex == contactKeyHex) {
        contact = c;
        break;
      }
    }
    if (contact == null) return;
    _lastWaitingFlushAt[contactKeyHex] = now;
    final oldest = queue.removeAt(0);
    appLogger.info(
      'Flushing queued OTP message to $contactKeyHex '
      '(${queue.length} remaining)',
    );
    // Re-drive through the normal send path from the ORIGINAL plaintext,
    // not a replay of the old ciphertext bytes — the contact's pad offset
    // has very likely moved on since this was first queued (auto-resync,
    // or other messages sent in the meantime), so it must be re-encrypted
    // fresh against the current offset, exactly like Lua's flush_waiting
    // re-entering send_chat_message rather than retransmitting stale bytes.
    // The old "waiting" bubble is removed first so the person sees one
    // bubble transition from "waiting" to "sending", not two bubbles for
    // what they experience as a single message.
    final plaintext = oldest.otpPlaintext ?? oldest.text;
    deleteMessage(oldest);
    sendMessage(contact, plaintext);
  }

  /// Drains [contact]'s entire store-and-forward queue without attempting
  /// to send any of it — used when cancelling, or when the person would
  /// rather give up than keep waiting. Mirrors OTP_3_RC1.lua's
  /// cancel_send() draining waiting_queue oldest-first when nothing is
  /// actively sending.
  void cancelWaitingQueue(Contact contact) {
    final queue = _waitingQueue[contact.publicKeyHex];
    if (queue == null || queue.isEmpty) return;
    for (final message in List<Message>.from(queue)) {
      deleteMessage(message);
    }
  }

  /// How many messages are currently queued for this contact — surfaced to
  /// the UI (e.g. to refuse composing yet another send, or to show a queue
  /// depth badge) without exposing the queue's internal representation.
  int waitingQueueLength(String contactKeyHex) =>
      _waitingQueue[contactKeyHex]?.length ?? 0;

  Future<TranslationResult?> translateContactMessage(
    String contactKeyHex,
    Message message, {
    bool manualTranslation = false,
  }) async {
    try {
      if (message.translatedText?.trim().isNotEmpty == true ||
          (!manualTranslation &&
              message.translationStatus != MessageTranslationStatus.none)) {
        return null;
      }
      final service = _translationService;
      if (service == null ||
          !(manualTranslation
              ? service.canTranslateIncoming(
                  text: message.text,
                  isCli: message.isCli,
                  isOutgoing: message.isOutgoing,
                )
              : service.shouldAutoTranslateIncoming(
                  text: message.text,
                  isCli: message.isCli,
                  isOutgoing: message.isOutgoing,
                ))) {
        return null;
      }
      final targetLanguageCode = service.resolvedIncomingLanguageCode(
        _appSettingsService?.settings.languageOverride,
      );
      final result = await service.translateIncomingText(
        text: message.text,
        targetLanguageCode: targetLanguageCode,
      );
      if (result == null) {
        return null;
      }
      final translated = result.status == MessageTranslationStatus.completed
          ? result.translatedText
          : null;
      _updateStoredContactMessage(
        contactKeyHex,
        message.messageId,
        (current) => current.copyWith(
          translatedText: translated,
          translatedLanguageCode: result.detectedLanguageCode,
          translationStatus: result.status,
          translationModelId: result.modelId,
        ),
      );
      return result;
    } catch (error) {
      appLogger.warn('Translation failed for contact message: $error');
      return null;
    }
  }

  Future<TranslationResult?> translateChannelMessage(
    int channelIndex,
    ChannelMessage message, {
    bool manualTranslation = false,
  }) async {
    try {
      if (message.translatedText?.trim().isNotEmpty == true ||
          (!manualTranslation &&
              message.translationStatus != MessageTranslationStatus.none)) {
        return null;
      }
      final service = _translationService;
      if (service == null ||
          !(manualTranslation
              ? service.canTranslateIncoming(
                  text: message.text,
                  isCli: false,
                  isOutgoing: message.isOutgoing,
                )
              : service.shouldAutoTranslateIncoming(
                  text: message.text,
                  isCli: false,
                  isOutgoing: message.isOutgoing,
                ))) {
        return null;
      }
      final targetLanguageCode = service.resolvedIncomingLanguageCode(
        _appSettingsService?.settings.languageOverride,
      );
      final result = await service.translateIncomingText(
        text: message.text,
        targetLanguageCode: targetLanguageCode,
      );
      if (result == null) {
        return null;
      }
      var translated = result.status == MessageTranslationStatus.completed
          ? result.translatedText
          : null;
      // Strip replyInfo prefix from translated text to match stored message.text
      if (translated != null) {
        final regex = RegExp(r'^@\[[^\]]+\]\s+', dotAll: true);
        translated = translated.replaceFirst(regex, '');
      }
      _updateStoredChannelMessage(
        channelIndex,
        message.messageId,
        (current) => current.copyWith(
          translatedText: translated,
          translatedLanguageCode: result.detectedLanguageCode,
          translationStatus: result.status,
          translationModelId: result.modelId,
        ),
      );
      return result;
    } catch (error) {
      appLogger.warn('Translation failed for channel message: $error');
      return null;
    }
  }

  void _updateStoredContactMessage(
    String contactKeyHex,
    String messageId,
    Message Function(Message current) update,
  ) {
    final messages = _conversations[contactKeyHex];
    if (messages == null) {
      return;
    }
    final index = messages.indexWhere((entry) => entry.messageId == messageId);
    if (index < 0) {
      return;
    }
    messages[index] = update(messages[index]);
    _messageStore.saveMessages(contactKeyHex, messages);
    notifyListeners();
  }

  void _updateStoredChannelMessage(
    int channelIndex,
    String messageId,
    ChannelMessage Function(ChannelMessage current) update,
  ) {
    final slot = _canonicalSlot(channelIndex);
    final messages = _channelMessages[slot];
    if (messages == null) {
      return;
    }
    final index = messages.indexWhere((entry) => entry.messageId == messageId);
    if (index < 0) {
      return;
    }
    messages[index] = update(messages[index]);
    _saveChannelMessages(slot, messages);
    notifyListeners();
  }

  void _recordPathResult(
    String contactPubKeyHex,
    PathSelection selection,
    bool success,
    int? tripTimeMs,
  ) {
    if (_pathHistoryService == null) return;
    final settings = _appSettingsService?.settings;
    _pathHistoryService!.recordPathResult(
      contactPubKeyHex,
      selection,
      success: success,
      tripTimeMs: tripTimeMs,
      successIncrement: settings?.routeWeightSuccessIncrement ?? 0.2,
      failureDecrement: settings?.routeWeightFailureDecrement ?? 0.2,
      maxWeight: settings?.maxRouteWeight ?? 5.0,
    );

    // Flood path attribution: when a flood delivery succeeds, credit the
    // contact's current device path so the route the ACK traveled back
    // through gets a weight boost in the path history.
    if (selection.useFlood && success) {
      final contact = _contacts.cast<Contact?>().firstWhere(
        (c) => c?.publicKeyHex == contactPubKeyHex,
        orElse: () => null,
      );
      if (contact != null &&
          contact.pathLength >= 0 &&
          contact.path.isNotEmpty) {
        _pathHistoryService!.recordFloodPathAttribution(
          contactPubKeyHex: contactPubKeyHex,
          pathBytes: contact.path,
          hopCount: contact.pathLength,
          tripTimeMs: tripTimeMs,
          successIncrement: settings?.routeWeightSuccessIncrement ?? 0.2,
          maxWeight: settings?.maxRouteWeight ?? 5.0,
        );
      }

      // Request a fresh contact from the device so the next flood
      // attribution uses the most up-to-date path.
      if (contact != null) {
        unawaited(getContactByKey(contact.publicKey));
      }
    }
  }

  PathSelection? _selectAutoPathForAttempt(
    String contactPubKeyHex, {
    required int attemptIndex,
    required int maxRetries,
    List<PathSelection> recentSelections = const [],
  }) {
    final hasKnownPaths =
        _pathHistoryService?.getRecentPaths(contactPubKeyHex).isNotEmpty ??
        false;
    if (!hasKnownPaths) {
      return null;
    }

    final selection = _pathHistoryService?.selectPathForAttempt(
      contactPubKeyHex,
      attemptIndex: attemptIndex,
      maxRetries: maxRetries,
      recentSelections: recentSelections,
    );
    if (selection != null) {
      _pathHistoryService?.recordPathAttempt(contactPubKeyHex, selection);
    }
    return selection;
  }

  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_state == MeshCoreConnectionState.scanning) return;

    // A BLE scan must never disturb an active (or in-progress) non-BLE
    // connection. The connection state enum is shared across transports, so
    // entering the `scanning` state while connected over TCP/USB would clobber
    // the live `connected` state and later reset it to `disconnected`.
    if (_state != MeshCoreConnectionState.disconnected ||
        _tcpConnector.isConnected ||
        _usbManager.isConnected) {
      _appDebugLogService?.warn(
        'startScan ignored: not idle (state=$_state, '
        'tcp=${_tcpConnector.isConnected}, usb=${_usbManager.isConnected})',
        tag: 'BLE Scan',
      );
      return;
    }

    _scanResults.clear();
    _linuxSystemScanResults.clear();
    _setState(MeshCoreConnectionState.scanning);

    // Ensure any previous scan is fully stopped. Guard with isScanningNow to
    // avoid triggering stale native callbacks when no scan is active.
    if (FlutterBluePlus.isScanningNow) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        _appDebugLogService?.warn(
          'stopScan error in startScan (ignored): $e',
          tag: 'BLE Scan',
        );
      }
    }
    await _scanSubscription?.cancel();

    // On iOS/macOS, wait for Bluetooth to be powered on before scanning
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      // Wait for adapter state to be powered on
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        // Wait for the adapter to turn on, with timeout
        await FlutterBluePlus.adapterState
            .firstWhere((state) => state == BluetoothAdapterState.on)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                _setState(MeshCoreConnectionState.disconnected);
                throw Exception('Bluetooth adapter not available');
              },
            );
      }

      // Add a small delay to allow BLE stack to fully initialize
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (PlatformInfo.isLinux) {
      await _loadLinuxSystemDevicesForScan();
    }

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      _scanResults
        ..clear()
        ..addAll(results);
      _mergeLinuxSystemScanResults();
      notifyListeners();
    });

    try {
      // Filter by the Nordic UART Service UUID rather than by advertised
      // name. All MeshCore-compatible firmware (ESP32 + nRF52) advertises this
      // service UUID, so this matches every device regardless of the name it
      // chooses to advertise (e.g. community forks like the M5 Cardputer that
      // do not use a "MeshCore-" name prefix). This mirrors how the official
      // app discovers devices. Note: on Android `withKeywords` cannot be
      // combined with any other filter, which is why name keywords are not
      // used here.
      await FlutterBluePlus.startScan(
        withServices: [Guid(MeshCoreUuids.service)],
        webOptionalServices: [Guid(MeshCoreUuids.service)],
        timeout: timeout,
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (error) {
      _appDebugLogService?.warn('Scan/picker failure: $error', tag: 'BLE Scan');
      await stopScan();
      rethrow;
    }

    // Reset our shared state when the native scan ends — whether it was stopped
    // by the user (stopScan), by the platform timeout, or by Bluetooth turning
    // off. This replaces a blocking `Future.delayed(timeout)` tail that kept
    // startScan() pending for the whole timeout and made Stop appear ineffective.
    // `isScanning` is a re-emit stream that replays its latest value on listen,
    // so skip(1) to ignore that and only react to a genuine transition to false.
    await _isScanningSubscription?.cancel();
    _isScanningSubscription = FlutterBluePlus.isScanning.skip(1).listen((
      scanning,
    ) {
      if (!scanning && _state == MeshCoreConnectionState.scanning) {
        unawaited(stopScan());
      }
    });
  }

  Future<void> _loadLinuxSystemDevicesForScan() async {
    try {
      final systemDevices = await FlutterBluePlus.systemDevices([
        Guid(MeshCoreUuids.service),
      ]);
      // systemDevices is already filtered by the NUS service UUID above, so no
      // additional name-prefix filtering is applied here. This keeps Linux
      // discovery name-agnostic and consistent with the main scan path.
      _linuxSystemScanResults
        ..clear()
        ..addAll(
          systemDevices.map(
            (device) => ScanResult(
              device: device,
              advertisementData: AdvertisementData(
                advName: device.platformName,
                txPowerLevel: null,
                appearance: null,
                connectable: true,
                manufacturerData: const <int, List<int>>{},
                serviceData: const <Guid, List<int>>{},
                serviceUuids: <Guid>[Guid(MeshCoreUuids.service)],
              ),
              rssi: 0,
              timeStamp: DateTime.now(),
            ),
          ),
        );
      _mergeLinuxSystemScanResults();
      notifyListeners();
    } catch (error) {
      _appDebugLogService?.warn(
        'Failed loading Linux paired/system BLE devices: $error',
        tag: 'BLE Scan',
      );
    }
  }

  void _mergeLinuxSystemScanResults() {
    if (!PlatformInfo.isLinux || _linuxSystemScanResults.isEmpty) {
      return;
    }
    final existingIds = _scanResults
        .map((result) => result.device.remoteId.str)
        .toSet();
    for (final result in _linuxSystemScanResults) {
      if (existingIds.contains(result.device.remoteId.str)) {
        continue;
      }
      _scanResults.add(result);
    }
  }

  Future<void> stopScan() async {
    // Only call FlutterBluePlus.stopScan() when a scan is actually running.
    // Calling it when idle triggers a native BLE completion callback even
    // though no scan was started. After a hot restart Dart has already freed
    // those callback handles, so the callback crashes with
    // "Callback invoked after it has been deleted".
    if (FlutterBluePlus.isScanningNow) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        _appDebugLogService?.warn(
          'stopScan error (ignored): $e',
          tag: 'BLE Scan',
        );
      }
    }
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _isScanningSubscription?.cancel();
    _isScanningSubscription = null;

    if (_state == MeshCoreConnectionState.scanning) {
      // Restore to `connected` if a non-BLE transport is still live, so a stray
      // scan can never tear down the reported connection state. Normally there
      // is no live transport here and we fall through to `disconnected`.
      final restored = (_tcpConnector.isConnected || _usbManager.isConnected)
          ? MeshCoreConnectionState.connected
          : MeshCoreConnectionState.disconnected;
      _setState(restored);
    }
  }

  Future<List<String>> listUsbPorts() => _usbManager.listPorts();

  void setUsbRequestPortLabel(String label) {
    _usbManager.setRequestPortLabel(label);
  }

  void setUsbFallbackDeviceName(String label) {
    _usbManager.setFallbackDeviceName(label);
  }

  Future<void> connectUsb({
    required String portName,
    int baudRate = 115200,
  }) async {
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectUsb ignored: already $_state',
        tag: 'USB',
      );
      return;
    }

    _appDebugLogService?.info(
      'connectUsb: port=$portName baud=$baudRate',
      tag: 'USB',
    );

    await _awaitActiveDisconnect();
    // The await is a suspension point: another connect may have claimed the
    // connector while this one was waiting for the teardown.
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectUsb ignored: already $_state after disconnect wait',
        tag: 'USB',
      );
      return;
    }

    await stopScan();
    _cancelReconnectTimer();
    _clearTcpReconnectTarget();
    _manualDisconnect = false;
    _resetConnectionHandshakeState();
    _activeTransport = MeshCoreTransportType.usb;
    _setState(MeshCoreConnectionState.connecting);

    try {
      await _usbFrameSubscription?.cancel();
      _usbFrameSubscription = null;
      _appDebugLogService?.info('connectUsb: opening serial port…', tag: 'USB');
      await _usbManager.connect(portName: portName, baudRate: baudRate);
      _appDebugLogService?.info(
        'connectUsb: serial port opened, label=${_usbManager.activePortDisplayLabel}',
        tag: 'USB',
      );
      notifyListeners();
      if (PlatformInfo.isWeb) {
        await stopScan();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // The read pump can fail the instant the port opens (e.g. a device that
      // re-enumerates on open). That error is emitted on a broadcast stream
      // before the listener below attaches, so it would otherwise be lost and
      // the connect would stall until the SELF_INFO timeout. Check transport
      // liveness directly and abort fast with the real cause.
      if (!_usbManager.isConnected) {
        final cause = _usbManager.lastError;
        throw StateError(
          'USB device disconnected during connect'
          '${cause == null ? '' : ': $cause'}',
        );
      }

      _usbFrameSubscription = _usbManager.frameStream.listen(
        _handleFrame,
        onError: (error, stackTrace) {
          _appDebugLogService?.error('USB transport error: $error', tag: 'USB');
          unawaited(disconnect(manual: false));
        },
        onDone: () {
          _appDebugLogService?.warn('USB frame stream ended', tag: 'USB');
          unawaited(disconnect(manual: false));
        },
      );

      _setState(MeshCoreConnectionState.connected);
      unawaited(_backgroundService?.start());
      _pendingInitialChannelSync = true;
      _pendingInitialQueuedMessageSync = true;
      _pendingInitialContactsSync = true;
      _appDebugLogService?.info(
        'connectUsb: requesting device info…',
        tag: 'USB',
      );
      await _requestDeviceInfo();
      _startBatteryPolling();
      _startOtpAutoSyncPolling();
      _startWaitingQueueTicker();
      if (_radioStatsPollRefCount > 0) _startRadioStatsPolling();
      var gotSelfInfo = await _waitForSelfInfo(
        timeout: const Duration(seconds: 3),
      );
      if (!gotSelfInfo) {
        _appDebugLogService?.warn(
          'connectUsb: SELF_INFO timeout, retrying…',
          tag: 'USB',
        );
        await refreshDeviceInfo();
        gotSelfInfo = await _waitForSelfInfo(
          timeout: const Duration(seconds: 3),
        );
      }
      if (!gotSelfInfo) {
        throw StateError('Timed out waiting for SELF_INFO during connect');
      }

      _appDebugLogService?.info('connectUsb: syncing time…', tag: 'USB');
      await syncTime();
      _appDebugLogService?.info('connectUsb: complete', tag: 'USB');
    } catch (error) {
      _appDebugLogService?.error('USB connection error: $error', tag: 'USB');
      await disconnect(manual: false);
      rethrow;
    }
  }

  Future<void> connectTcp({required String host, required int port}) async {
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectTcp ignored: already $_state',
        tag: 'TCP',
      );
      return;
    }

    _appDebugLogService?.info('connectTcp: endpoint=$host:$port', tag: 'TCP');

    await _awaitActiveDisconnect();
    // The await is a suspension point: another connect may have claimed the
    // connector while this one was waiting for the teardown.
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectTcp ignored: already $_state after disconnect wait',
        tag: 'TCP',
      );
      return;
    }

    await stopScan();
    _cancelReconnectTimer();
    if (!_tcpAutoReconnectAttempt) {
      // A user-started connect replaces any earlier endpoint; it becomes the
      // reconnect target only once its handshake completes.
      _clearTcpReconnectTarget();
      _reconnectAttempts = 0;
    }
    _manualDisconnect = false;
    _resetConnectionHandshakeState();
    _activeTransport = MeshCoreTransportType.tcp;
    final tcpGeneration = ++_tcpConnectGeneration;
    _setState(MeshCoreConnectionState.connecting);

    try {
      Future<void> handleTcpConnectAbort({required String message}) async {
        _appDebugLogService?.warn(message, tag: 'TCP');
        final shouldResetState = shouldResetStateAfterTcpConnectAbort(
          state: _state,
          activeTransport: _activeTransport,
        );
        if (shouldResetState) {
          await disconnect(manual: false);
          return;
        }
        if (_tcpConnector.isConnected) {
          await _tcpConnector.disconnect();
        }
      }

      await _tcpConnector.cancelFrameSubscription();
      await _tcpConnector.connect(host: host, port: port);
      final isTcpConnectCancelled =
          _activeTransport != MeshCoreTransportType.tcp ||
          _state != MeshCoreConnectionState.connecting ||
          !_tcpConnector.isConnected;
      if (isTcpConnectCancelled) {
        await handleTcpConnectAbort(
          message:
              'connectTcp aborted before handshake: state=$_state transport=$_activeTransport connected=${_tcpConnector.isConnected}',
        );
        return;
      }
      notifyListeners();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      final isTcpConnectCancelledAfterDelay =
          _activeTransport != MeshCoreTransportType.tcp ||
          _state != MeshCoreConnectionState.connecting ||
          !_tcpConnector.isConnected;
      if (isTcpConnectCancelledAfterDelay) {
        await handleTcpConnectAbort(
          message:
              'connectTcp aborted after connect delay: state=$_state transport=$_activeTransport connected=${_tcpConnector.isConnected}',
        );
        return;
      }
      _tcpConnector.listenFrames(
        onFrame: _handleFrame,
        onError: (error, stackTrace) {
          _appDebugLogService?.error('TCP transport error: $error', tag: 'TCP');
          unawaited(disconnect(manual: false));
        },
        onDone: () {
          _appDebugLogService?.warn('TCP frame stream ended', tag: 'TCP');
          unawaited(disconnect(manual: false));
        },
      );

      _setState(MeshCoreConnectionState.connected);
      unawaited(_backgroundService?.start());
      _pendingInitialChannelSync = true;
      _pendingInitialQueuedMessageSync = true;
      _pendingInitialContactsSync = true;
      await _requestDeviceInfo();
      _startBatteryPolling();
      _startOtpAutoSyncPolling();
      _startWaitingQueueTicker();
      if (_radioStatsPollRefCount > 0) _startRadioStatsPolling();

      var gotSelfInfo = await _waitForSelfInfo(
        timeout: const Duration(seconds: 3),
      );
      if (!gotSelfInfo) {
        await refreshDeviceInfo();
        gotSelfInfo = await _waitForSelfInfo(
          timeout: const Duration(seconds: 3),
        );
      }
      if (!gotSelfInfo) {
        throw StateError('Timed out waiting for SELF_INFO during TCP connect');
      }
      if (tcpGeneration != _tcpConnectGeneration) {
        _appDebugLogService?.info(
          'connectTcp superseded after SELF_INFO; leaving the connector to '
          'the newer attempt',
          tag: 'TCP',
        );
        return;
      }
      _tcpReconnectHost = host;
      _tcpReconnectPort = port;
      _reconnectAttempts = 0;

      await syncTime();
    } catch (error) {
      _appDebugLogService?.error('TCP connection error: $error', tag: 'TCP');
      final tcpConnectCancelledBeforeHandshake =
          shouldIgnoreLateTcpConnectError(
            manualDisconnect: _manualDisconnect,
            state: _state,
            activeTransport: _activeTransport,
            tcpManagerConnected: _tcpConnector.isConnected,
          );
      if (tcpConnectCancelledBeforeHandshake) {
        _appDebugLogService?.info(
          'Ignoring late TCP connect error after cancellation/switch: state=$_state transport=$_activeTransport',
          tag: 'TCP',
        );
        return;
      }
      await disconnect(manual: false);
      rethrow;
    }
  }

  Future<void> connectReview() async {
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectReview ignored: already $_state',
        tag: 'Review',
      );
      return;
    }

    _appDebugLogService?.info('connectReview: starting', tag: 'Review');

    await _awaitActiveDisconnect();
    // The await is a suspension point: another connect may have claimed the
    // connector while this one was waiting for the teardown.
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      _appDebugLogService?.warn(
        'connectReview ignored: already $_state after disconnect wait',
        tag: 'Review',
      );
      return;
    }

    await stopScan();
    _cancelReconnectTimer();
    _clearTcpReconnectTarget();
    _manualDisconnect = false;
    _resetConnectionHandshakeState();
    _activeTransport = MeshCoreTransportType.review;
    _setState(MeshCoreConnectionState.connecting);

    // A disconnect (or a newer connect) bumps the generation, so this attempt
    // can tell after every await whether it still owns the connector.
    final generation = ++_reviewConnectGeneration;
    bool isCancelled() =>
        generation != _reviewConnectGeneration ||
        _activeTransport != MeshCoreTransportType.review ||
        _state == MeshCoreConnectionState.disconnecting ||
        _state == MeshCoreConnectionState.disconnected;

    try {
      // Every review session starts from a clean slate.
      await beginReviewModeSession(_appSettingsService);
      if (isCancelled()) return;
      await _reviewFrameSubscription?.cancel();
      _reviewFrameSubscription = null;
      _reviewRadio?.dispose();
      final radio = reviewRadioFactoryForTest?.call() ?? ReviewRadio();
      _reviewRadio = radio;
      _reviewFrameSubscription = radio.frames.listen(
        _handleFrame,
        onError: (error, stackTrace) {
          _appDebugLogService?.error(
            'Review radio error: $error',
            tag: 'Review',
          );
          unawaited(disconnect(manual: false));
        },
      );

      _setState(MeshCoreConnectionState.connected);
      unawaited(_backgroundService?.start());
      _pendingInitialChannelSync = true;
      _pendingInitialQueuedMessageSync = true;
      _pendingInitialContactsSync = true;
      await _requestDeviceInfo();
      _startBatteryPolling();
      if (_radioStatsPollRefCount > 0) _startRadioStatsPolling();

      var gotSelfInfo = await _waitForSelfInfo(
        timeout: const Duration(seconds: 3),
      );
      if (isCancelled()) return;
      if (!gotSelfInfo) {
        await refreshDeviceInfo();
        gotSelfInfo = await _waitForSelfInfo(
          timeout: const Duration(seconds: 3),
        );
      }
      if (isCancelled()) return;
      if (!gotSelfInfo) {
        throw StateError(
          'Timed out waiting for SELF_INFO during review connect',
        );
      }

      await syncTime();
      if (!isCancelled() && isConnected) {
        radio.start();
      }
    } catch (error) {
      if (isCancelled()) {
        _appDebugLogService?.info(
          'Ignoring review connect error after cancellation: $error',
          tag: 'Review',
        );
        return;
      }
      _appDebugLogService?.error(
        'Review connection error: $error',
        tag: 'Review',
      );
      await disconnect(manual: false);
      rethrow;
    }
  }

  @visibleForTesting
  ReviewRadio Function()? reviewRadioFactoryForTest;

  void sendReviewTestMessage() {
    if (!isReviewMode) return;
    _reviewRadio?.sendTestMessage();
  }

  @visibleForTesting
  void handleFrameForTest(List<int> data) => _handleFrame(data);

  @visibleForTesting
  static bool shouldIgnoreLateTcpConnectError({
    required bool manualDisconnect,
    required MeshCoreConnectionState state,
    required MeshCoreTransportType activeTransport,
    required bool tcpManagerConnected,
  }) {
    return manualDisconnect &&
        (state == MeshCoreConnectionState.disconnected ||
            state == MeshCoreConnectionState.disconnecting) &&
        (activeTransport != MeshCoreTransportType.tcp || !tcpManagerConnected);
  }

  @visibleForTesting
  static bool shouldResetStateAfterTcpConnectAbort({
    required MeshCoreConnectionState state,
    required MeshCoreTransportType activeTransport,
  }) {
    return state == MeshCoreConnectionState.connecting &&
        activeTransport == MeshCoreTransportType.tcp;
  }

  /// Fast (non-timeout) connect failures are usually a stale link left over
  /// from a previous session and recover on an immediate retry. Timeouts mean
  /// the device is likely off or out of range, so retrying would only delay
  /// genuine failure feedback.
  @visibleForTesting
  static bool shouldRetryBleConnectAfterError(String errorText) {
    final lowerErrorText = errorText.toLowerCase();
    return !lowerErrorText.contains('timed out') &&
        !lowerErrorText.contains('timeout');
  }

  Future<void> connect(
    BluetoothDevice device, {
    String? displayName,
    Future<String?> Function()? linuxPairingPinProvider,
  }) async {
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      return;
    }

    await _awaitActiveDisconnect();
    // The await is a suspension point: another connect may have claimed the
    // connector while this one was waiting for the teardown.
    if (_state == MeshCoreConnectionState.connecting ||
        _state == MeshCoreConnectionState.connected) {
      return;
    }

    _activeTransport = MeshCoreTransportType.bluetooth;

    await stopScan();
    _setState(MeshCoreConnectionState.connecting);
    final connectGeneration = ++_bleConnectGeneration;
    _device = device;
    _deviceId = device.remoteId.toString();
    if (displayName != null && displayName.trim().isNotEmpty) {
      _deviceDisplayName = displayName.trim();
    } else if (device.platformName.isNotEmpty) {
      _deviceDisplayName = device.platformName;
    }
    _lastDevice = device;
    _lastDeviceId = _deviceId;
    _lastDeviceDisplayName = _deviceDisplayName;
    _manualDisconnect = false;
    _cancelReconnectTimer();
    _clearTcpReconnectTarget();
    _bleInitialSyncStarted = false;
    if (PlatformInfo.isWeb) {
      _resetConnectionHandshakeState();
    }
    unawaited(_backgroundService?.start());
    notifyListeners();

    try {
      final connectLabel = _deviceDisplayName ?? _deviceId;
      _appDebugLogService?.info(
        'Starting connect to $connectLabel',
        tag: 'BLE Connect',
      );
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      await _notifySubscription?.cancel();
      _notifySubscription = null;
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && isConnected) {
          _handleDisconnection();
        }
      });

      if (PlatformInfo.isLinux) {
        final remoteId = device.remoteId.str;
        _appDebugLogService?.info(
          'Linux pre-connect BlueZ disconnect for $remoteId',
          tag: 'BLE Connect',
        );
        await _linuxBlePairingService.disconnectDevice(
          remoteId,
          onLog: (message) {
            _appDebugLogService?.info(message, tag: 'BLE Pair');
          },
        );
      }

      final connectTimeout = PlatformInfo.isLinux
          ? const Duration(seconds: 6)
          : const Duration(seconds: 15);
      _appDebugLogService?.info(
        'device.connect timeout set to ${connectTimeout.inSeconds}s',
        tag: 'BLE Connect',
      );
      if (PlatformInfo.isLinux) {
        Future<void> attemptConnect() {
          return device
              .connect(
                timeout: connectTimeout,
                mtu: null,
                license: License.nonprofit,
              )
              .timeout(
                connectTimeout + const Duration(seconds: 2),
                onTimeout: () {
                  throw TimeoutException(
                    'Linux connect hard-timeout after ${connectTimeout.inSeconds + 2}s',
                  );
                },
              );
        }

        try {
          await attemptConnect();
        } catch (error) {
          _appDebugLogService?.error(
            'device.connect() failure: $error',
            tag: 'BLE Connect',
          );
          final remoteId = device.remoteId.str;
          _appDebugLogService?.warn(
            'Linux immediate retry: forcing BlueZ disconnect before second connect attempt',
            tag: 'BLE Connect',
          );
          await _linuxBlePairingService.disconnectDevice(
            remoteId,
            onLog: (message) {
              _appDebugLogService?.info(message, tag: 'BLE Pair');
            },
          );
          await Future<void>.delayed(const Duration(milliseconds: 700));
          try {
            await attemptConnect();
            _appDebugLogService?.info(
              'Linux immediate retry connect succeeded',
              tag: 'BLE Connect',
            );
          } catch (retryError, retryStackTrace) {
            Object finalConnectError = retryError;
            StackTrace finalConnectStackTrace = retryStackTrace;
            final retryErrorText = retryError.toString().toLowerCase();
            final isAbortByLocal = retryErrorText.contains(
              'le-connection-abort-by-local',
            );
            var recoveredOnThirdAttempt = false;
            if (isAbortByLocal) {
              _appDebugLogService?.warn(
                'Linux immediate retry aborted by local stack; waiting and retrying once more',
                tag: 'BLE Connect',
              );
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              try {
                await attemptConnect();
                _appDebugLogService?.info(
                  'Linux third-attempt connect succeeded after local abort',
                  tag: 'BLE Connect',
                );
                recoveredOnThirdAttempt = true;
              } catch (thirdError, thirdStackTrace) {
                finalConnectError = thirdError;
                finalConnectStackTrace = thirdStackTrace;
                _appDebugLogService?.error(
                  'device.connect() third-attempt failure: $thirdError',
                  tag: 'BLE Connect',
                );
              }
            }
            if (!recoveredOnThirdAttempt) {
              final recoveredByPairing = await _recoverLinuxConnectFailure(
                device,
                attemptConnect: attemptConnect,
                onRequestPin: linuxPairingPinProvider,
              );
              if (recoveredByPairing) {
                _appDebugLogService?.info(
                  'Linux connect succeeded after pairing/trust recovery',
                  tag: 'BLE Connect',
                );
              } else {
                _appDebugLogService?.error(
                  'device.connect() retry failure: $finalConnectError',
                  tag: 'BLE Connect',
                );
                Error.throwWithStackTrace(
                  _wrapLinuxConnectStageError(finalConnectError),
                  finalConnectStackTrace,
                );
              }
            }
          }
        }
      } else {
        Future<void> attemptConnect() {
          return device.connect(
            timeout: connectTimeout,
            mtu: null,
            license: License.nonprofit,
          );
        }

        // A previous app session (e.g. killed from the iOS app switcher) can
        // leave the OS holding a stale link to the peripheral. Clear it before
        // connecting so the fresh attempt doesn't race the stale handle.
        if (!PlatformInfo.isWeb && device.isConnected) {
          _appDebugLogService?.warn(
            'Device reports an existing connection before connect; clearing stale link',
            tag: 'BLE Connect',
          );
          try {
            await device.disconnect(queue: false);
          } catch (cleanupError) {
            _appDebugLogService?.warn(
              'Stale-link cleanup disconnect failed (continuing): $cleanupError',
              tag: 'BLE Connect',
            );
          }
        }

        try {
          await attemptConnect();
        } catch (error) {
          _appDebugLogService?.error(
            'device.connect() failure: $error',
            tag: 'BLE Connect',
          );
          if (PlatformInfo.isWeb ||
              !shouldRetryBleConnectAfterError(error.toString())) {
            rethrow;
          }
          // Fast (non-timeout) failures are usually a stale connection left by
          // a previous session; clean up and retry once before surfacing.
          _appDebugLogService?.warn(
            'Retrying connect once after clearing possible stale connection',
            tag: 'BLE Connect',
          );
          try {
            await device.disconnect(queue: false);
          } catch (cleanupError) {
            _appDebugLogService?.warn(
              'Pre-retry cleanup disconnect failed (continuing): $cleanupError',
              tag: 'BLE Connect',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
          try {
            await attemptConnect();
            _appDebugLogService?.info(
              'Retry connect succeeded after stale-connection cleanup',
              tag: 'BLE Connect',
            );
          } catch (retryError) {
            _appDebugLogService?.error(
              'device.connect() retry failure: $retryError',
              tag: 'BLE Connect',
            );
            rethrow;
          }
        }
      }

      if (PlatformInfo.isLinux) {
        await _ensureLinuxBleBond(
          device,
          onRequestPin: linuxPairingPinProvider,
        );
      }

      // Request larger MTU only where the platform path supports it.
      if (!PlatformInfo.isWeb && !PlatformInfo.isLinux) {
        try {
          final mtu = await device.requestMtu(185);
          _appDebugLogService?.info('MTU set to: $mtu', tag: 'BLE Connect');
        } catch (e) {
          _appDebugLogService?.warn(
            'MTU request failed: $e, using default',
            tag: 'BLE Connect',
          );
        }
      } else if (PlatformInfo.isLinux) {
        _appDebugLogService?.info(
          'Skipping MTU request on Linux; flutter_blue_plus only supports requestMtu on Android',
          tag: 'BLE Connect',
        );
      }

      late final List<BluetoothService> services;
      try {
        services = await device.discoverServices();
      } catch (error) {
        _appDebugLogService?.error(
          'service discovery failure: $error',
          tag: 'BLE Connect',
        );
        if (PlatformInfo.isWeb &&
            error.toString().contains('GATT Server is disconnected')) {
          // Chrome Web Bluetooth intermittently disconnects between connect()
          // and service discovery; retry once to recover that transient state.
          _appDebugLogService?.warn(
            'retrying service discovery after transient web disconnect',
            tag: 'BLE Connect',
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await device.connect(
            timeout: const Duration(seconds: 15),
            mtu: null,
            license: License.nonprofit,
          );
          services = await device.discoverServices();
        } else {
          rethrow;
        }
      }

      BluetoothService? uartService;
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == MeshCoreUuids.service) {
          uartService = service;
          break;
        }
      }

      if (uartService == null) {
        throw Exception("MeshCore UART service not found");
      }

      for (var characteristic in uartService.characteristics) {
        String uuid = characteristic.uuid.toString().toLowerCase();
        if (uuid == MeshCoreUuids.rxCharacteristic) {
          _rxCharacteristic = characteristic;
        } else if (uuid == MeshCoreUuids.txCharacteristic) {
          _txCharacteristic = characteristic;
        }
      }

      if (_rxCharacteristic == null || _txCharacteristic == null) {
        throw Exception("MeshCore characteristics not found");
      }

      if (PlatformInfo.isWeb) {
        _appDebugLogService?.info(
          'Starting setNotifyValue(true)',
          tag: 'BLE Connect',
        );
        _appDebugLogService?.info(
          'Web: Calling setNotifyValue(true) without awaiting',
          tag: 'BLE Connect',
        );
        unawaited(() async {
          try {
            await _txCharacteristic!.setNotifyValue(true);
          } catch (error) {
            _appDebugLogService?.warn(
              'notify failure (web, ignored): $error',
              tag: 'BLE Connect',
            );
            _appDebugLogService?.warn(
              'Web setNotifyValue error (ignoring): $error',
              tag: 'BLE Connect',
            );
          }
        }());
        _appDebugLogService?.info(
          'setNotifyValue(true) configuration completed',
          tag: 'BLE Connect',
        );
      } else {
        bool notifySet = false;
        for (int attempt = 0; attempt < 3 && !notifySet; attempt++) {
          try {
            if (attempt > 0) {
              await Future.delayed(Duration(milliseconds: 500 * attempt));
            }
            await _txCharacteristic!.setNotifyValue(true);
            notifySet = true;
          } catch (e) {
            _appDebugLogService?.warn('notify failure: $e', tag: 'BLE Connect');
            _appDebugLogService?.warn(
              'setNotifyValue attempt ${attempt + 1}/3 failed: $e',
              tag: 'BLE Connect',
            );
            if (attempt == 2) rethrow;
          }
        }
      }
      _notifySubscription = _txCharacteristic!.onValueReceived.listen(
        _handleFrame,
      );

      _setState(MeshCoreConnectionState.connected);
      if (_shouldGateInitialChannelSync) {
        _hasReceivedDeviceInfo = false;
        _pendingInitialChannelSync = true;
      }
      await _startBleInitialSync();
      if (_selfPublicKey != null) {
        _reconnectAttempts = 0;
      }
    } catch (e) {
      // The user cancelled (manual disconnect) or a newer connect took over
      // while this attempt was in flight. Tearing down again here would
      // re-arm auto-reconnect or kill the newer connection.
      if (connectGeneration != _bleConnectGeneration ||
          _manualDisconnect ||
          !identical(_device, device)) {
        _appDebugLogService?.info(
          'Ignoring error from cancelled connect attempt: $e',
          tag: 'BLE Connect',
        );
        rethrow;
      }
      _appDebugLogService?.error('Connection error: $e', tag: 'BLE Connect');
      final errorText = e.toString();
      final lowerErrorText = errorText.toLowerCase();
      final isLinuxPairingFailure =
          PlatformInfo.isLinux && isLinuxBlePairingFailureText(errorText);
      final isLikelyPairingTimeout = isLikelyLinuxBlePairingTimeoutText(
        errorText,
      );
      final isConnectFailure = isLinuxBleConnectFailureText(errorText);
      final isConnectTimeoutFailure =
          isConnectFailure && lowerErrorText.contains('timed out');
      final isLinuxConnectFailure = PlatformInfo.isLinux && isConnectFailure;
      // Linux pairing failures should not enter auto-reconnect loops; user
      // needs to retry manually so they can re-enter PIN / resolve pairing.
      if (isLinuxPairingFailure) {
        _appDebugLogService?.warn(
          isLikelyPairingTimeout
              ? 'Linux pairing timed out: stopping reconnect until user retries manually'
              : 'Linux pairing failure: stopping reconnect until user retries manually',
          tag: 'BLE Connect',
        );
        await disconnect(manual: true);
      } else if (isLinuxConnectFailure) {
        _appDebugLogService?.warn(
          isConnectTimeoutFailure
              ? 'Linux connect timeout: issuing BlueZ disconnect before reconnect'
              : 'Linux connect failure: issuing BlueZ disconnect before reconnect',
          tag: 'BLE Connect',
        );
        final remoteId = _device?.remoteId.str;
        if (remoteId != null) {
          await _linuxBlePairingService.disconnectDevice(
            remoteId,
            onLog: (message) {
              _appDebugLogService?.info(message, tag: 'BLE Pair');
            },
          );
        }
        await disconnect(manual: false, skipBleDeviceDisconnect: true);
      } else {
        await disconnect(manual: false);
      }
      rethrow;
    }
  }

  Future<bool> _recoverLinuxConnectFailure(
    BluetoothDevice device, {
    required Future<void> Function() attemptConnect,
    Future<String?> Function()? onRequestPin,
  }) async {
    if (!PlatformInfo.isLinux ||
        !await _linuxBlePairingService.isBluetoothctlAvailable()) {
      return false;
    }
    final remoteId = device.remoteId.str;
    final pluginBondState = await _getLinuxPluginBondState(device);
    final trustedByBluez = await _linuxBlePairingService.isPairedAndTrusted(
      remoteId,
    );
    final needsBondRecovery =
        (pluginBondState != null &&
            pluginBondState != BmBondStateEnum.bonded) ||
        !trustedByBluez;
    if (!needsBondRecovery) {
      return false;
    }
    _appDebugLogService?.warn(
      pluginBondState == BmBondStateEnum.bonded
          ? 'Linux connect failed with an untrusted bond; attempting trust/pair recovery'
          : 'Linux connect failed before bond completed; attempting pairing fallback',
      tag: 'BLE Connect',
    );
    await _ensureLinuxBleBond(device, onRequestPin: onRequestPin);
    _appDebugLogService?.info(
      'Resetting BlueZ connection after Linux pairing/trust recovery',
      tag: 'BLE Connect',
    );
    await _linuxBlePairingService.disconnectDevice(
      remoteId,
      onLog: (message) {
        _appDebugLogService?.info(message, tag: 'BLE Pair');
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    try {
      await attemptConnect();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_wrapLinuxConnectStageError(error), stackTrace);
    }
    return true;
  }

  Object _wrapLinuxConnectStageError(Object error) {
    final errorText = error.toString();
    if (errorText.toLowerCase().contains(linuxConnectStageFailureMarker)) {
      return error;
    }
    return StateError('Linux connect stage failure: $error');
  }

  Future<BmBondStateEnum?> _getLinuxPluginBondState(
    BluetoothDevice device,
  ) async {
    try {
      final response = await FlutterBluePlusPlatform.instance.getBondState(
        BmBondStateRequest(remoteId: device.remoteId),
      );
      return response.bondState;
    } catch (error) {
      _appDebugLogService?.warn(
        'Linux getBondState unavailable for ${device.remoteId.str}: $error',
        tag: 'BLE Connect',
      );
      return null;
    }
  }

  Future<void> _ensureLinuxBleBond(
    BluetoothDevice device, {
    Future<String?> Function()? onRequestPin,
  }) async {
    final remoteId = device.remoteId.str;
    final bluetoothctlAvailable = await _linuxBlePairingService
        .isBluetoothctlAvailable();
    final beforeBondState = await _getLinuxPluginBondState(device);
    if (!bluetoothctlAvailable) {
      if (beforeBondState == BmBondStateEnum.bonded) {
        _appDebugLogService?.warn(
          'bluetoothctl unavailable; continuing with plugin bonded state',
          tag: 'BLE Connect',
        );
      } else if (beforeBondState == null) {
        _appDebugLogService?.warn(
          'bluetoothctl unavailable and plugin bond state is unknown; skipping Linux pairing fallback',
          tag: 'BLE Connect',
        );
      } else {
        _appDebugLogService?.warn(
          'bluetoothctl unavailable and device is not bonded; skipping Linux pairing fallback',
          tag: 'BLE Connect',
        );
      }
      return;
    }

    final trustedByBluez = await _linuxBlePairingService.isPairedAndTrusted(
      remoteId,
    );
    if (trustedByBluez) {
      _appDebugLogService?.info(
        'Linux BLE device already paired/trusted, skipping pairing flow',
        tag: 'BLE Connect',
      );
      return;
    }

    if (beforeBondState == BmBondStateEnum.bonded && !trustedByBluez) {
      _appDebugLogService?.warn(
        'Linux BLE device is bonded but not trusted in BlueZ; repairing trust',
        tag: 'BLE Connect',
      );
      final trustRepaired = await _linuxBlePairingService.trustDevice(
        remoteId,
        onLog: (message) {
          _appDebugLogService?.info(message, tag: 'BLE Pair');
        },
      );
      if (trustRepaired) {
        _appDebugLogService?.info(
          'Linux BLE trust repair succeeded without re-pairing',
          tag: 'BLE Connect',
        );
        return;
      }
      _appDebugLogService?.warn(
        'Linux BLE trust repair did not stick; retrying pairing flow',
        tag: 'BLE Connect',
      );
    }

    _appDebugLogService?.info(
      beforeBondState == BmBondStateEnum.bonded
          ? 'Linux BLE device still untrusted after repair; requesting pair'
          : beforeBondState == null
          ? 'Linux BLE device bond state unknown; requesting pair'
          : 'Linux BLE device not bonded, requesting pair',
      tag: 'BLE Connect',
    );
    final paired = await _linuxBlePairingService.pairAndTrust(
      remoteId: remoteId,
      onLog: (message) {
        _appDebugLogService?.info(message, tag: 'BLE Pair');
      },
      onRequestPin: onRequestPin,
    );
    if (!paired) {
      throw StateError('Linux pairing fallback failed');
    }

    final afterBondState = await _getLinuxPluginBondState(device);
    if (afterBondState != null && afterBondState != BmBondStateEnum.bonded) {
      throw StateError('Linux BLE pairing did not complete');
    } else if (afterBondState == null) {
      _appDebugLogService?.warn(
        'Linux plugin bond state unavailable after pairing; relying on BlueZ trust verification',
        tag: 'BLE Connect',
      );
    }
    final trustedAfter = await _linuxBlePairingService.isPairedAndTrusted(
      remoteId,
    );
    if (!trustedAfter) {
      throw StateError('Linux BLE trust repair did not complete');
    }
  }

  Future<bool> _waitForSelfInfo({required Duration timeout}) async {
    if (_selfPublicKey != null) return true;
    if (!isConnected) return false;

    final completer = Completer<bool>();
    late final VoidCallback listener;
    listener = () {
      if (_selfPublicKey != null) {
        if (!completer.isCompleted) {
          completer.complete(true);
        }
      } else if (!isConnected) {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      }
    };
    addListener(listener);

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    final result = await completer.future;
    timer.cancel();
    removeListener(listener);
    return result;
  }

  Future<void> _startBleInitialSync() async {
    if (_bleInitialSyncStarted ||
        !isConnected ||
        _activeTransport != MeshCoreTransportType.bluetooth) {
      return;
    }
    _bleInitialSyncStarted = true;
    _pendingInitialChannelSync = true;
    _pendingInitialContactsSync = true;
    _pendingInitialQueuedMessageSync = true;

    await _requestDeviceInfo();
    _startBatteryPolling();
    _startOtpAutoSyncPolling();
    _startWaitingQueueTicker();
    if (_radioStatsPollRefCount > 0) _startRadioStatsPolling();

    final gotSelfInfo = await _waitForSelfInfo(
      timeout: const Duration(seconds: 3),
    );
    if (!gotSelfInfo) {
      await refreshDeviceInfo();
      await _waitForSelfInfo(timeout: const Duration(seconds: 3));
    }

    await syncTime();
    _maybeStartInitialChannelSync();
  }

  void _resetConnectionHandshakeState() {
    _selfPublicKey = null;
    // Partially received images belong to the previous session's sender prefix.
    _imageTransport?.reassembler.clear();
    _selfName = null;
    _selfLatitude = null;
    _selfLongitude = null;
    _lastZeroHopAdvertLatitude = null;
    _lastZeroHopAdvertLongitude = null;
    _awaitingSelfInfo = false;
    _webInitialHandshakeRequestSent = false;
    _selfInfoRetryTimer?.cancel();
    _selfInfoRetryTimer = null;
    _hasReceivedDeviceInfo = false;
    _resetSyncProgressState();
    _bleInitialSyncStarted = false;
    _pathHashByteWidth = 1;
  }

  void _resetSyncProgressState() {
    _pendingInitialChannelSync = false;
    _pendingInitialContactsSync = false;
    _pendingInitialQueuedMessageSync = false;
    _contactSyncTotal = null;
    _contactSyncReceived = 0;
    _contactSyncUsesSinceFilter = false;
    _isLoadingContacts = false;
    _hasLoadedContacts = false;
    _isLoadingChannels = false;
    _hasLoadedChannels = false;
    _isSyncingQueuedMessages = false;
    _deferQueuedContactMessagesUntilContacts = false;
    _isProcessingDeferredQueuedContactMessages = false;
    _queuedMessageSyncInFlight = false;
    _deferredQueuedContactMessageFrames.clear();
    _channelFramesAwaitingMap.clear();
    _pendingQueueSync = false;
    _resetSyncFlowState();
    _queueSyncTimeout?.cancel();
    _queueSyncTimeout = null;
    _queueSyncRetries = 0;
    _isSyncingChannels = false;
    _channelSyncInFlight = false;
    _channelSyncTimeout?.cancel();
    _channelSyncTimeout = null;
    _channelSyncRetries = 0;
    _nextChannelIndexToRequest = 0;
    _totalChannelsToRequest = 0;
    _previousChannelsCache.clear();
    _unconfirmedChannelSlots.clear();
    _channelSyncIncomplete = false;
    _channelMapSyncRetries = 0;
    _channelMapConfirmed = false;
    _channelSessionGeneration++;
    final channelSync = _channelSyncCompleter;
    _channelSyncCompleter = null;
    if (channelSync != null && !channelSync.isCompleted) channelSync.complete();
  }

  bool get _shouldAutoReconnect =>
      !_disposed &&
      !_manualDisconnect &&
      _lastDeviceId != null &&
      _activeTransport == MeshCoreTransportType.bluetooth;

  /// TCP links drop when Android parks Wi-Fi in the background (#571), so a
  /// non-manual TCP disconnect reconnects to the last handshaked endpoint.
  /// USB is left alone: losing it almost always means the cable was pulled.
  bool get _shouldAutoReconnectTcp =>
      !_disposed &&
      !_manualDisconnect &&
      _tcpReconnectHost != null &&
      _tcpReconnectPort != null;

  void _clearTcpReconnectTarget() {
    _tcpReconnectHost = null;
    _tcpReconnectPort = null;
  }

  bool get _shouldGateInitialChannelSync =>
      _activeTransport == MeshCoreTransportType.usb ||
      _activeTransport == MeshCoreTransportType.tcp ||
      _activeTransport == MeshCoreTransportType.review ||
      (_activeTransport == MeshCoreTransportType.bluetooth &&
          PlatformInfo.isWeb);

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  int _nextReconnectDelayMs() {
    final attempt = _reconnectAttempts < 6 ? _reconnectAttempts : 6;
    _reconnectAttempts += 1;
    final delayMs = 1000 * (1 << attempt);
    return delayMs > 30000 ? 30000 : delayMs;
  }

  void _scheduleReconnect() {
    if (!_shouldAutoReconnect) return;
    if (_reconnectTimer?.isActive == true) return;

    final delayMs = _nextReconnectDelayMs();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!_shouldAutoReconnect) return;
      if (_state == MeshCoreConnectionState.connecting ||
          _state == MeshCoreConnectionState.connected) {
        return;
      }

      final device =
          _lastDevice ??
          (_lastDeviceId == null
              ? null
              : BluetoothDevice.fromId(_lastDeviceId!));
      if (device == null) return;

      try {
        await connect(device, displayName: _lastDeviceDisplayName);
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  void _scheduleTcpReconnect() {
    if (!_shouldAutoReconnectTcp) return;
    if (_reconnectTimer?.isActive == true) return;

    final delayMs = _nextReconnectDelayMs();
    _appDebugLogService?.info(
      'TCP reconnect to $_tcpReconnectHost:$_tcpReconnectPort in ${delayMs}ms '
      '(attempt $_reconnectAttempts)',
      tag: 'TCP',
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!_shouldAutoReconnectTcp) return;
      if (_state == MeshCoreConnectionState.connecting ||
          _state == MeshCoreConnectionState.connected) {
        return;
      }
      final host = _tcpReconnectHost!;
      final port = _tcpReconnectPort!;
      _tcpAutoReconnectAttempt = true;
      try {
        await connectTcp(host: host, port: port);
      } catch (_) {
        // A failed attempt tears down through disconnect(manual: false),
        // which already rescheduled; this only covers early failures.
        _scheduleTcpReconnect();
      } finally {
        _tcpAutoReconnectAttempt = false;
      }
    });
  }

  Future<void> disconnect({
    bool manual = true,
    bool skipBleDeviceDisconnect = false,
  }) {
    final inFlight = _activeDisconnect;
    if (inFlight != null) {
      if (manual) {
        // A teardown started as automatic must still honour a later manual
        // request, otherwise _manualDisconnect stays false and its tail
        // schedules an auto-reconnect the user did not ask for.
        _manualDisconnect = true;
        _cancelReconnectTimer();
        _clearTcpReconnectTarget();
        unawaited(_backgroundService?.stop());
      }
      return inFlight;
    }
    final teardown = _disconnectInternal(
      manual: manual,
      skipBleDeviceDisconnect: skipBleDeviceDisconnect,
    );
    _activeDisconnect = teardown;
    return teardown.whenComplete(() {
      if (identical(_activeDisconnect, teardown)) {
        _activeDisconnect = null;
      }
    });
  }

  /// Joins an in-flight [disconnect] so a new connection cannot be started
  /// while the previous teardown is still running.
  Future<void> _awaitActiveDisconnect() async {
    final pending = _activeDisconnect;
    if (pending == null) return;
    _appDebugLogService?.info(
      'Waiting for the in-flight disconnect to finish before connecting',
      tag: 'Connection',
    );
    try {
      await pending;
    } catch (_) {
      // Teardown failures are logged by the disconnect path.
    }
  }

  Future<void> _disconnectInternal({
    required bool manual,
    required bool skipBleDeviceDisconnect,
  }) async {
    final transportAtDisconnect = _activeTransport;
    final transportLabel = switch (transportAtDisconnect) {
      MeshCoreTransportType.bluetooth => 'BLE',
      MeshCoreTransportType.usb => 'USB',
      MeshCoreTransportType.tcp => 'TCP',
      MeshCoreTransportType.review => 'Review',
    };

    _appDebugLogService?.info(
      'Starting disconnect transport=$transportLabel manual=$manual',
      tag: 'Connection',
    );

    if (manual) {
      _manualDisconnect = true;
      _cancelReconnectTimer();
      _reconnectAttempts = 0;
      _clearTcpReconnectTarget();
      unawaited(_backgroundService?.stop());
    } else {
      _manualDisconnect = false;
      // BLE and handshaked TCP links reconnect on their own and keep the
      // foreground service; nothing keeps USB alive.
      final tcpWillReconnect =
          transportAtDisconnect == MeshCoreTransportType.tcp &&
          _shouldAutoReconnectTcp;
      if (transportAtDisconnect != MeshCoreTransportType.bluetooth &&
          !tcpWillReconnect) {
        unawaited(_backgroundService?.stop());
      }
    }
    _setState(MeshCoreConnectionState.disconnecting);
    _retryService?.failAllPending();
    _stopBatteryPolling();
    _stopOtpAutoSyncPolling();
    _stopWaitingQueueTicker();
    _stopRadioStatsPolling();

    await _usbFrameSubscription?.cancel();
    _usbFrameSubscription = null;
    await _usbManager.disconnect();
    await _tcpConnector.disconnect();
    final wasReviewMode = transportAtDisconnect == MeshCoreTransportType.review;
    _reviewConnectGeneration++;
    _tcpConnectGeneration++;
    await _reviewFrameSubscription?.cancel();
    _reviewFrameSubscription = null;
    _reviewRadio?.dispose();
    _reviewRadio = null;

    await _notifySubscription?.cancel();
    _notifySubscription = null;

    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _selfInfoRetryTimer?.cancel();
    _selfInfoRetryTimer = null;
    _queueSyncTimeout?.cancel();
    _queueSyncTimeout = null;
    _queueSyncRetries = 0;
    _channelSyncTimeout?.cancel();
    _channelSyncTimeout = null;
    _channelSyncRetries = 0;
    await _translationService?.releaseModel();
    // The decode graph is ~833 MB resident; drop it with the connection. The
    // connector never disposes services it does not own (main.dart does).
    //
    // Cancel first: `releaseModel` serialises behind the codec's exclusive
    // lock, so disconnecting mid-decode would otherwise block this teardown
    // for the ~1 s the inference takes and then tear the session out from
    // under a job whose result nobody is waiting for any more.
    _imageCodecService?.cancelCodecJob();
    await _imageCodecService?.releaseModel();
    // Partial images belong to this session's sender prefixes; a reconnect
    // starts over. Dropping them also stops `evictExpired` from firing "image
    // incomplete" failures into the store minutes after the radio went away.
    _imageTransport?.reassembler.clear();

    if (!skipBleDeviceDisconnect) {
      try {
        // Skip queued BLE operations so disconnect doesn't get stuck behind them.
        await _device?.disconnect(queue: false);
      } catch (e) {
        _appDebugLogService?.warn('Disconnect error: $e', tag: 'BLE Connect');
      }
    } else {
      _appDebugLogService?.info(
        'Skipping plugin BLE disconnect and continuing cleanup',
        tag: 'BLE Connect',
      );
    }

    _device = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _deviceDisplayName = null;
    _deviceId = null;
    _contacts.clear();
    _discoveredContacts.clear();
    _clearSessionMessageState();
    _resetLinkSessionState();
    _selfName = null;
    _selfLatitude = null;
    _selfLongitude = null;
    _lastZeroHopAdvertLatitude = null;
    _lastZeroHopAdvertLongitude = null;
    _clientRepeat = null;
    _rememberedNonRepeatRadioState = null;
    _firmwareVerCode = null;
    _allowedRepeatFreqRanges = null;
    _autoAddMaxHops = null;
    _contactsStorageFull = false;
    _repeaterBatterySnapshots.clear();

    _activeTransport = MeshCoreTransportType.bluetooth;
    if (wasReviewMode) {
      // Write the debounced unread counts now so they cannot land after the
      // review data has been deleted.
      await _unreadStore.flush();
      await endReviewModeSession(_appSettingsService);
    }

    _setState(MeshCoreConnectionState.disconnected);
    _appDebugLogService?.info(
      'Disconnect complete transport=$transportLabel manual=$manual',
      tag: 'Connection',
    );
    if (!manual && transportAtDisconnect == MeshCoreTransportType.bluetooth) {
      _scheduleReconnect();
    }
    if (!manual && transportAtDisconnect == MeshCoreTransportType.tcp) {
      _scheduleTcpReconnect();
    }
  }

  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    if (!isConnected) {
      throw Exception("Not connected to a MeshCore device");
    }
    _bleDebugLogService?.logFrame(data, outgoing: true);

    final pendingAck = _pendingGenericAckQueue.track(
      data,
      channelSendQueueId: channelSendQueueId,
      expectsOk: expectsGenericAck || waitForGenericAck,
      waitForReply: waitForGenericAck,
    );

    try {
      if (_activeTransport == MeshCoreTransportType.usb) {
        await _usbManager.write(data);
        // Brief pause so the device firmware can process each frame before the
        // next arrives. Without this, rapid-fire frames over USB can cause the
        // device to miss responses (especially on reconnect).
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } else if (_activeTransport == MeshCoreTransportType.tcp) {
        await _tcpConnector.write(data);
      } else if (_activeTransport == MeshCoreTransportType.review) {
        final radio = _reviewRadio;
        if (radio == null) {
          throw Exception("Review radio not available");
        }
        radio.handle(data);
      } else {
        if (_rxCharacteristic == null) {
          throw Exception("MeshCore RX characteristic not available");
        }
        // Prefer write without response when supported; fall back to write with response.
        final properties = _rxCharacteristic!.properties;
        final canWriteWithoutResponse = properties.writeWithoutResponse;
        final canWriteWithResponse = properties.write;
        if (!canWriteWithoutResponse && !canWriteWithResponse) {
          throw Exception("MeshCore RX characteristic does not support write");
        }
        await _rxCharacteristic!.write(
          data.toList(),
          withoutResponse: canWriteWithoutResponse,
        );
      }
    } catch (_) {
      if (pendingAck != null) {
        _pendingGenericAckQueue.remove(pendingAck);
      }
      rethrow;
    }

    if (pendingAck?.completer != null) {
      try {
        await pendingAck!.completer!.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Keep a tombstone: the firmware still answers this command later,
        // and that reply must not be credited to the next pending command.
        _pendingGenericAckQueue.markTimedOut(pendingAck!);
        throw TimeoutException(
          'Timed out waiting for firmware acknowledgement',
        );
      }
    }
  }

  /// Runs a local CLI command on the connected radio (CMD_RUN_CLI_COMMAND)
  /// and returns the reply text. Commands run one at a time. Throws when the
  /// firmware has no local CLI (it answers RESP_CODE_ERR) or does not answer.
  Future<String> runLocalCliCommand(String command) {
    final run = _cliChain.then((_) async {
      _cliReplies.clear();
      await sendFrame(
        buildRunCliCommandFrame(command),
        waitForGenericAck: true,
      );
      // The newest reply is this command's; an older one is a late answer to
      // a command that already timed out.
      final reply = _cliReplies.isEmpty ? '' : _cliReplies.last;
      _cliReplies.clear();
      return reply;
    });
    _cliChain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> requestBatteryStatus({bool force = false}) async {
    if (!isConnected) return;
    if (_batteryRequested && !force) return;
    _batteryRequested = true;
    await sendFrame(buildGetBattAndStorageFrame());
  }

  void _startBatteryPolling() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = Timer.periodic(_batteryPollInterval, (timer) {
      if (!isConnected) {
        timer.cancel();
        return;
      }
      unawaited(
        requestBatteryStatus(force: true).catchError(_logTimerSendError),
      );
    });
  }

  void _logTimerSendError(Object error) {
    _appDebugLogService?.warn('Periodic send failed: $error', tag: 'Connector');
  }

  void _stopBatteryPolling() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = null;
  }

  /// Start polling the radio's GPS-backed self-info every minute.
  /// No-op if already running. Triggered when the radio reports `gps=1`.
  void _startGpsLocationPolling() {
    if (_gpsLocationPollTimer != null) return;
    _gpsLocationPollTimer = Timer.periodic(_gpsLocationPollInterval, (timer) {
      if (!isConnected) {
        timer.cancel();
        _gpsLocationPollTimer = null;
        return;
      }
      // Skipped mid contact sync: APP_START would abort the firmware's
      // contact iteration. The next tick polls again.
      if (_isLoadingContacts) return;
      unawaited(_sendAppStart().catchError(_logTimerSendError));
    });
  }

  void _stopGpsLocationPolling() {
    _gpsLocationPollTimer?.cancel();
    _gpsLocationPollTimer = null;
  }

  void setPollingInterval(int i) {
    _pollingInterval = i.clamp(1, 60);
    if (isConnected) {
      _startRadioStatsPolling();
    }
  }

  void _startRadioStatsPolling() {
    _radioStatsPollTimer?.cancel();
    _radioStatsPollTimer = Timer.periodic(Duration(seconds: _pollingInterval), (
      _,
    ) {
      if (!isConnected) {
        _stopRadioStatsPolling();
        return;
      }
      unawaited(requestRadioStats());
    });
  }

  void _stopRadioStatsPolling() {
    _radioStatsPollTimer?.cancel();
    _radioStatsPollTimer = null;
  }

  void acquireRadioStatsPolling() {
    _radioStatsPollRefCount++;
    if (_radioStatsPollRefCount == 1 && isConnected) {
      _startRadioStatsPolling();
    }
  }

  void releaseRadioStatsPolling() {
    _radioStatsPollRefCount = (_radioStatsPollRefCount - 1).clamp(0, 999);
    if (_radioStatsPollRefCount == 0) {
      _stopRadioStatsPolling();
    }
  }

  Future<void> requestRadioStats() async {
    if (!isConnected) return;
    if (!supportsCompanionRadioStats) return;
    try {
      await sendFrame(buildGetStatsFrame(statsTypeRadio));
    } catch (_) {}
  }

  /// Sends CMD_SET_RADIO_PARAMS (same arguments as [buildSetRadioParamsFrame])
  /// and waits for the reply. Returns false when the firmware rejects it with
  /// ERR_ILLEGAL_ARG (values out of range, or [clientRepeat] on a frequency
  /// outside [allowedRepeatFreqRanges]) or does not answer in time.
  Future<bool> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) async {
    if (!isConnected) return false;
    try {
      await sendFrame(
        buildSetRadioParamsFrame(
          freqHz,
          bwHz,
          sf,
          cr,
          clientRepeat: clientRepeat,
        ),
        waitForGenericAck: true,
      );
      return true;
    } catch (e) {
      _appDebugLogService?.warn(
        'SET_RADIO_PARAMS rejected: $e',
        tag: 'Connector',
      );
      return false;
    }
  }

  Future<void> setPathHashMode(int mode) async {
    if (!isConnected) return;
    final clampedMode = mode.clamp(0, 2).toInt();
    await sendFrame(buildSetPathHashModeFrame(clampedMode));
    final nextWidth = clampedMode + 1;
    if (_pathHashByteWidth != nextWidth) {
      _pathHashByteWidth = nextWidth;
      _directRepeaters.clear();
      notifyListeners();
    }
  }

  bool _isPathLenValidForCurrentMode(int pathLen, List<int> pathBytes) {
    return _isPathLenValidForMode(pathLen, pathBytes, _pathHashByteWidth);
  }

  int? _encodePathLenForWidth(
    int pathLen,
    List<int> pathBytes,
    int pathHashWidth,
  ) {
    if (pathLen < 0 || pathLen == 0xFF) return pathLen;
    if (!_isPathLenValidForMode(pathLen, pathBytes, pathHashWidth)) {
      appLogger.warn(
        'Invalid path_len for mode: pathLen=$pathLen, '
        'bytesLen=${pathBytes.length}, width=$pathHashWidth',
        tag: 'Connector',
      );
      return null;
    }
    final mode = (pathHashWidth - 1) & 0x03;
    return (pathLen & 0x3F) | (mode << 6);
  }

  Future<void> refreshDeviceInfo() async {
    if (!isConnected) return;
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth &&
        _webInitialHandshakeRequestSent &&
        _selfPublicKey == null) {
      return;
    }
    _awaitingSelfInfo = true;
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth &&
        _selfPublicKey == null) {
      _webInitialHandshakeRequestSent = true;
    }
    await sendFrame(buildDeviceQueryFrame());
    await _sendAppStart();
    await requestBatteryStatus(force: true);
    await sendFrame(buildGetCustomVarsFrame());
    _deviceConfigRequested = false;
    _maybeRequestDeviceConfig();

    _scheduleSelfInfoRetry();
  }

  Future<void> _requestDeviceInfo() async {
    if (!isConnected || _awaitingSelfInfo) return;
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth &&
        _webInitialHandshakeRequestSent &&
        _selfPublicKey == null) {
      return;
    }
    _awaitingSelfInfo = true;
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth &&
        _selfPublicKey == null) {
      _webInitialHandshakeRequestSent = true;
    }
    await sendFrame(buildDeviceQueryFrame());
    await _sendAppStart();
    await sendFrame(buildGetCustomVarsFrame());
    await requestBatteryStatus();
    _deviceConfigRequested = false;
    _maybeRequestDeviceConfig();
    _scheduleSelfInfoRetry();
  }

  /// Version-gated config queries, sent once the firmware version (DEVICE_INFO)
  /// and SELF_INFO (which the auto-add reply handler relies on) are known.
  void _maybeRequestDeviceConfig() {
    if (_deviceConfigRequested ||
        !isConnected ||
        _firmwareVerCode == null ||
        _selfPublicKey == null) {
      return;
    }
    _deviceConfigRequested = true;
    if (supportsAutoAddConfig) {
      unawaited(
        sendFrame(buildGetAutoAddFlagsFrame()).catchError(_logTimerSendError),
      );
    }
    if (supportsAllowedRepeatFreq) {
      unawaited(
        sendFrame(
          buildGetAllowedRepeatFreqFrame(),
        ).catchError(_logTimerSendError),
      );
    }
    if (supportsDefaultFloodScope) {
      unawaited(
        sendFrame(
          buildGetDefaultFloodScopeFrame(),
        ).catchError(_logTimerSendError),
      );
    }
  }

  /// Sends CMD_APP_START unless a contact sync is running, in which case it is
  /// sent when the sync ends (see [_continueAfterContactSync]).
  Future<void> _sendAppStart() async {
    if (_isLoadingContacts) {
      _appStartDeferredForContactSync = true;
      return;
    }
    await sendFrame(buildAppStartFrame());
  }

  void _scheduleSelfInfoRetry() {
    _selfInfoRetryTimer?.cancel();
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth) {
      var attempts = 0;
      const maxAttempts = 3;
      _selfInfoRetryTimer = Timer.periodic(const Duration(seconds: 10), (
        timer,
      ) {
        if (!isConnected || !_awaitingSelfInfo) {
          timer.cancel();
          return;
        }
        if (_isLoadingContacts || _isSyncingChannels || _channelSyncInFlight) {
          return;
        }
        attempts += 1;
        unawaited(_sendAppStart().catchError(_logTimerSendError));
        if (attempts >= maxAttempts) {
          timer.cancel();
        }
      });
      return;
    }
    _selfInfoRetryTimer = Timer.periodic(const Duration(milliseconds: 3500), (
      timer,
    ) {
      if (!isConnected) {
        timer.cancel();
        return;
      }
      if (!_awaitingSelfInfo) {
        timer.cancel();
        return;
      }
      unawaited(_sendAppStart().catchError(_logTimerSendError));
    });
  }

  Contact getFromDiscovered(Contact contact) {
    final tmp = _discoveredContacts.firstWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
      orElse: () => contact,
    );
    final hasDeviceLocation =
        contact.latitude != null && contact.longitude != null;
    return contact.copyWith(
      rawPacket: tmp.rawPacket,
      latitude: hasDeviceLocation ? contact.latitude : tmp.latitude,
      longitude: hasDeviceLocation ? contact.longitude : tmp.longitude,
    );
  }

  Future<void> getContacts({int? since, bool preserveExisting = false}) async {
    if (!isConnected) return;
    // The firmware answers ERR_BAD_STATE while an iteration is running, and
    // clearing here would drop the contacts already received. A sync older
    // than a minute is assumed lost (e.g. END_OF_CONTACTS never arrived).
    final requestedAt = _contactSyncRequestedAt;
    if (_isLoadingContacts &&
        requestedAt != null &&
        DateTime.now().difference(requestedAt) < const Duration(minutes: 1)) {
      return;
    }

    _contactSyncRequestedAt = DateTime.now();
    _isLoadingContacts = true;
    _preserveContactsOnRefresh = preserveExisting;
    _contactSyncTotal = null;
    _contactSyncReceived = 0;
    _contactSyncUsesSinceFilter = since != null;
    if (!preserveExisting) {
      _hasLoadedContacts = false;
      _contacts.clear();
    }
    _armContactSyncWatchdog();
    notifyListeners();

    try {
      await sendFrame(buildGetContactsFrame(since: since));
    } catch (_) {
      _isLoadingContacts = false;
      notifyListeners();
      _continueAfterContactSync();
      rethrow;
    }
  }

  void _armContactSyncWatchdog() {
    _contactSyncWatchdog?.cancel();
    _contactSyncWatchdog = Timer(
      _contactSyncStallTimeout,
      _handleContactSyncStalled,
    );
  }

  void _handleContactSyncStalled() {
    _contactSyncWatchdog = null;
    if (!_isLoadingContacts || !isConnected) return;
    _appDebugLogService?.warn(
      'Contact sync stalled (no END_OF_CONTACTS); ending it after '
      '$_contactSyncReceived contacts',
      tag: 'Connector',
    );
    // The partial list is not persisted so the stored contacts survive.
    _isLoadingContacts = false;
    _preserveContactsOnRefresh = false;
    _contactSyncUsesSinceFilter = false;
    notifyListeners();
    _continueAfterContactSync();
  }

  /// Runs the work that waits for a contact sync to end, whether it finished
  /// with END_OF_CONTACTS, stalled, or failed to start.
  void _continueAfterContactSync() {
    _contactSyncWatchdog?.cancel();
    _contactSyncWatchdog = null;
    if (!isConnected) return;
    if (PlatformInfo.isWeb &&
        _activeTransport == MeshCoreTransportType.bluetooth &&
        _isSyncingChannels &&
        !_channelSyncInFlight) {
      unawaited(_requestNextChannel());
    }
    if (_appStartDeferredForContactSync) {
      _appStartDeferredForContactSync = false;
      unawaited(_sendAppStart().catchError(_logTimerSendError));
    }
    unawaited(_replayUnknownSenderMessages());
    if (_deferQueuedContactMessagesUntilContacts) {
      unawaited(_processDeferredQueuedContactMessages());
    } else if (_pendingQueueSync) {
      _pendingQueueSync = false;
      unawaited(syncQueuedMessages(force: true));
    }
  }

  /// Clears the contact-sync follow-up state. Call on connection teardown.
  void _resetSyncFlowState() {
    _contactSyncWatchdog?.cancel();
    _contactSyncWatchdog = null;
    _appStartDeferredForContactSync = false;
    _unknownSenderMessageFrames.clear();
  }

  void _holdUnknownSenderMessage(Uint8List frame) {
    if (_unknownSenderMessageFrames.length >= _maxUnknownSenderMessageFrames) {
      _unknownSenderMessageFrames.removeAt(0);
      appLogger.warn(
        'Too many messages from unknown contacts; dropping the oldest',
        tag: 'Connector',
      );
    }
    _unknownSenderMessageFrames.add(Uint8List.fromList(frame));
  }

  /// Replays held unknown-sender messages exactly once. With
  /// [onlyResolvable], frames whose sender is still unknown stay held (a
  /// single CONTACT frame arrived); otherwise unresolved frames are dropped.
  Future<void> _replayUnknownSenderMessages({
    bool onlyResolvable = false,
  }) async {
    if (_unknownSenderMessageFrames.isEmpty) return;
    final ready = <Uint8List>[];
    _unknownSenderMessageFrames.removeWhere((frame) {
      if (onlyResolvable) {
        final prefix = _extractSenderPrefix(frame);
        if (prefix == null ||
            !_contacts.any((c) => _matchesPrefix(c.publicKey, prefix))) {
          return false;
        }
      }
      ready.add(frame);
      return true;
    });
    for (final frame in ready) {
      await _handleIncomingMessage(
        frame,
        alreadyAdvancedQueueSync: true,
        isUnknownSenderReplay: true,
      );
    }
  }

  Future<void> refreshContacts() async {
    await getContacts(preserveExisting: true);
  }

  Future<void> refreshContactsSinceLastmod() async {
    await getContacts(since: _latestContactLastmod(), preserveExisting: true);
  }

  Future<void> getContactByKey(Uint8List pubKey) async {
    if (!isConnected) return;
    await sendFrame(buildGetContactByKeyFrame(pubKey));
  }

  Future<void> sendMessage(
    Contact contact,
    String text, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
  }) async {
    if (!isConnected || text.isEmpty) return;

    // Check if this is a reaction - apply locally with pending status and route through retry service
    final reactionInfo = ReactionHelper.parseReaction(text);

    // OTP: reactions are always sent in the clear (they're tiny emoji-coded
    // acks, not secret) — only real message text gets encrypted here.
    //
    // This MUST happen exactly once, right here, before `text` is ever
    // handed to the retry service. prepareContactOutboundText's ciphertext
    // bypass (below) makes every later call on the resulting ciphertext a
    // no-op, but the encryption step itself is stateful — it advances the
    // pad offset — so if it ran again on every retry attempt it would burn
    // a fresh slice of pad per attempt and produce a DIFFERENT ciphertext
    // each time. The firmware's ACK hash is computed from the outbound
    // text, so retries must resend byte-identical frames; encrypting once
    // and reusing the result is what makes that true.
    // OTP: refuse to start a second encrypted send to this contact while
    // one is already consuming pad (a chunked transfer in flight). Nothing
    // previously stopped a double-tap of Send, or any other re-entrant
    // call, from starting a second chunk-send state machine for the same
    // contact — the newer one would silently replace the older one in
    // _pendingContactChunkSends, but the older one's in-flight chunk keeps
    // being encrypted/transmitted off the now-shared pad regardless,
    // interleaving two messages' ciphertext on the air in an order that
    // doesn't match the order it was encrypted in and permanently
    // desyncing the receive side. Mirrors the Lua app's own `psend`/
    // `queued_cipher` guard ("still sending the previous message").
    if (reactionInfo == null &&
        isContactOtpEnabled(contact.publicKeyHex) &&
        _pendingContactChunkSends.containsKey(contact.publicKeyHex)) {
      appLogger.warn(
        'sendMessage: still sending the previous message to '
        '${contact.publicKeyHex}, dropping this send',
      );
      return;
    }

    // OTP store-and-forward: refuse a brand-new send once this contact's
    // waiting queue is already at cap, rather than letting it grow
    // unbounded — mirrors Lua's send_chat_message refusing a 6th queued
    // send outright. This is the primary gate; _handleOtpSendExhausted's
    // own cap check is only a safety net for the (shouldn't-happen) case
    // of a retry exhausting while the queue is already full.
    if (reactionInfo == null &&
        isContactOtpEnabled(contact.publicKeyHex) &&
        waitingQueueLength(contact.publicKeyHex) >= _waitingQueueCap) {
      appLogger.warn(
        'sendMessage: store-and-forward queue for ${contact.publicKeyHex} '
        'is full ($_waitingQueueCap queued) — refusing this send',
      );
      return;
    }

    if (reactionInfo == null && isContactOtpEnabled(contact.publicKeyHex)) {
      final plainBytes = Uint8List.fromList(utf8.encode(text));
      // Every OTP DM goes out framed (MSGCHNK parts, each acked), even when
      // it fits one packet, exactly as OTP_3_RC1.lua and Wadamesh's OTP
      // Messenger send. That is what lets a receiver tell ciphertext from a
      // plain DM that merely looks like hex ("cafe", "1234"): only a framed
      // message is ever decrypted, so plain words never burn pad.
      {
        await _sendChunkedContactMessage(
          contact,
          text,
          plainBytes,
          originalText: originalText,
          translatedLanguageCode: translatedLanguageCode,
          translationModelId: translationModelId,
        );
        return;
      }
    }

    String wireText = text;
    String? otpPlaintext;
    if (reactionInfo == null && isContactOtpEnabled(contact.publicKeyHex)) {
      try {
        wireText = await _encryptForContact(contact, text);
        otpPlaintext = text;
      } on OtpPadExhaustedException catch (e) {
        // Fail closed: never fall through and send plaintext. The UI's
        // compose-box preflight check should catch this before the user
        // even gets here, but this is the last line of defense.
        appLogger.warn(
          'sendMessage: OTP pad exhausted for ${contact.publicKeyHex}: $e',
        );
        return;
      }
    }

    final outboundBytes = utf8.encode(
      prepareContactOutboundText(contact, wireText),
    );
    if (outboundBytes.length > maxTextPayloadBytes) {
      debugPrint(
        'sendMessage: dropping overlong message '
        '(${outboundBytes.length} > $maxTextPayloadBytes bytes)',
      );
      return;
    }

    if (reactionInfo != null) {
      appLogger.info('Sending reaction: ${reactionInfo.identifier()}');
      _conversations.putIfAbsent(contact.publicKeyHex, () => []);
      final messages = _conversations[contact.publicKeyHex]!;

      // No check for duplicates. If you want to do it again to resend, you can.
      final String reactionID = reactionInfo.identifier();
      _processedContactReactions.putIfAbsent(contact.publicKeyHex, () => {});
      _processedContactReactions[contact.publicKeyHex]!.add(reactionID);

      // Apply reaction locally with pending status
      _processOutgoingContactReaction(messages, reactionInfo, contact);
      _setReactionStatus(
        contact.publicKeyHex,
        reactionInfo,
        MessageStatus.pending,
      );
      _messageStore.saveMessages(contact.publicKeyHex, messages);
      notifyListeners();

      // Route through retry service (same as normal messages)
      // Don't use auto-rotation for reactions — just send directly
      if (_retryService != null) {
        _retryService!.sendMessageWithRetry(contact: contact, text: text);
      } else {
        final outboundText = prepareContactOutboundText(contact, text);
        await sendFrame(buildSendTextMsgFrame(contact.publicKey, outboundText));
      }
      return;
    }

    if (_retryService != null) {
      await _retryService!.sendMessageWithRetry(
        contact: contact,
        text: wireText,
        originalText: originalText,
        translatedLanguageCode: translatedLanguageCode,
        translationModelId: translationModelId,
        otpPlaintext: otpPlaintext,
      );
    } else {
      // Fallback to old behavior if retry service not initialized
      final resolved = resolvePathSelection(contact);
      final message = Message.outgoing(
        contact.publicKey,
        wireText,
        pathLength: resolved.useFlood ? -1 : resolved.hopCount,
        pathBytes: Uint8List.fromList(resolved.pathBytes),
        originalText: originalText,
        translatedLanguageCode: translatedLanguageCode,
        translationModelId: translationModelId,
        otpPlaintext: otpPlaintext,
      );
      _addMessage(contact.publicKeyHex, message); // recipient as "sender"
      notifyListeners();
      final outboundText = prepareContactOutboundText(contact, wireText);
      await sendFrame(buildSendTextMsgFrame(contact.publicKey, outboundText));
    }
  }

  /// [pathHashWidth] defaults to the width implied by [customPath], falling
  /// back to the radio's current mode (e.g. for zero-hop paths).
  Future<void> setContactPath(
    Contact contact,
    Uint8List customPath,
    int pathLen, {
    int? pathHashWidth,
  }) async {
    // Serialize path operations to prevent interleaved async calls from
    // leaving in-memory state inconsistent with the device.
    final prev = _pathOpLock;
    final completer = Completer<void>();
    _pathOpLock = completer.future;
    await prev;
    try {
      if (!isConnected) return;

      final width =
          pathHashWidth ??
          (pathLen > 0 && customPath.length % pathLen == 0
              ? customPath.length ~/ pathLen
              : _pathHashByteWidth);
      final encodedPathLen = _encodePathLenForWidth(pathLen, customPath, width);
      if (encodedPathLen == null) {
        return;
      }
      await sendFrame(
        buildUpdateContactPathFrame(
          contact.publicKey,
          customPath,
          encodedPathLen,
          type: contact.type,
          flags: contact.flags,
          name: contact.name,
          lastAdvert: _deviceLastAdvert(contact),
        ),
      );
      // USB writes return instantly (no BLE flow control), so give the firmware
      // time to persist the path change before subsequent commands.
      if (_activeTransport == MeshCoreTransportType.usb) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final idx = _contacts.indexWhere(
        (c) => c.publicKeyHex == contact.publicKeyHex,
      );
      if (idx != -1) {
        _contacts[idx] = _contacts[idx].copyWith(
          pathLength: pathLen,
          path: customPath,
          pathHashWidth: width,
        );
        notifyListeners();
      }
    } finally {
      completer.complete();
    }
  }

  /// The advert timestamp the firmware holds for [contact] (Contact.lastSeen
  /// is parsed from that field); the stored copy is freshest.
  DateTime _deviceLastAdvert(Contact contact) {
    for (final c in _contacts) {
      if (c.publicKeyHex == contact.publicKeyHex) return c.lastSeen;
    }
    return contact.lastSeen;
  }

  Future<void> setContactFlags(
    Contact contact, {
    bool? isFavorite,
    bool? teleBase,
    bool? teleLoc,
    bool? teleEnv,
  }) async {
    if (!isConnected) return;
    final latestContact =
        await _fetchContactSnapshotFromDevice(contact.publicKey) ?? contact;
    int updatedFlags = isFavorite != null
        ? (isFavorite
              ? (latestContact.flags | contactFlagFavorite)
              : (latestContact.flags & ~contactFlagFavorite))
        : latestContact.flags;
    updatedFlags = teleBase != null
        ? (teleBase
              ? (updatedFlags | contactFlagTeleBase)
              : (updatedFlags & ~contactFlagTeleBase))
        : updatedFlags;
    updatedFlags = teleLoc != null
        ? (teleLoc
              ? (updatedFlags | contactFlagTeleLoc)
              : (updatedFlags & ~contactFlagTeleLoc))
        : updatedFlags;
    updatedFlags = teleEnv != null
        ? (teleEnv
              ? (updatedFlags | contactFlagTeleEnv)
              : (updatedFlags & ~contactFlagTeleEnv))
        : updatedFlags;

    final encodedPathLen = _encodePathLenForWidth(
      latestContact.pathLength,
      latestContact.path,
      latestContact.pathHashWidth,
    );
    if (encodedPathLen == null) return;
    await sendFrame(
      buildUpdateContactPathFrame(
        latestContact.publicKey,
        latestContact.path,
        encodedPathLen,
        type: latestContact.type,
        flags: updatedFlags,
        name: latestContact.name,
        lastAdvert: latestContact.lastSeen,
      ),
    );

    final index = _contacts.indexWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );
    if (index >= 0) {
      _contacts[index] = _contacts[index].copyWith(
        type: latestContact.type,
        name: latestContact.name,
        pathLength: latestContact.pathLength,
        path: latestContact.path,
        pathHashWidth: latestContact.pathHashWidth,
        flags: updatedFlags,
      );
      notifyListeners();
      unawaited(_persistContacts());
    }
  }

  Future<Contact?> _fetchContactSnapshotFromDevice(
    Uint8List pubKey, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!isConnected) return null;
    final expectedKeyHex = pubKeyToHex(pubKey);
    final completer = Completer<Contact?>();

    void finish(Contact? result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    final subscription = receivedFrames.listen((frame) {
      if (frame.isEmpty || frame[0] != respCodeContact) return;
      final parsed = Contact.fromFrame(frame);
      if (parsed == null || parsed.publicKeyHex != expectedKeyHex) return;
      finish(parsed);
    });

    final timer = Timer(timeout, () => finish(null));
    try {
      await getContactByKey(pubKey);
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  /// Set path override for a contact (persists across contact refreshes)
  /// pathLen: -1 = force flood, null = auto (use device path), >= 0 = specific path
  Future<void> setPathOverride(
    Contact contact, {
    int? pathLen,
    Uint8List? pathBytes,
  }) async {
    appLogger.info(
      'setPathOverride called for ${contact.name}: pathLen=$pathLen, bytesLen=${pathBytes?.length ?? 0}',
      tag: 'Connector',
    );

    // Find contact in list
    final index = _contacts.indexWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );
    if (index == -1) {
      appLogger.warn(
        'setPathOverride: Contact not found in list: ${contact.name}',
        tag: 'Connector',
      );
      return;
    }

    appLogger.info(
      'Found contact at index $index. Current override: ${_contacts[index].pathOverride}',
      tag: 'Connector',
    );

    if (pathLen != null &&
        pathLen >= 0 &&
        !_isPathLenValidForCurrentMode(pathLen, pathBytes ?? Uint8List(0))) {
      appLogger.warn(
        'setPathOverride: invalid path for ${contact.name}: '
        'pathLen=$pathLen, bytesLen=${pathBytes?.length ?? 0}, '
        'width=$_pathHashByteWidth',
        tag: 'Connector',
      );
      return;
    }

    // Update contact with new path override
    _contacts[index] = _contacts[index].copyWith(
      pathOverride: pathLen,
      pathOverrideBytes: pathBytes,
      clearPathOverride: pathLen == null, // Clear if pathLen is null
    );

    appLogger.info(
      'Updated contact. New override: ${_contacts[index].pathOverride}, bytesLen: ${_contacts[index].pathOverrideBytes?.length}',
      tag: 'Connector',
    );

    // Save to storage
    await _contactStore.saveContacts(_contacts);
    appLogger.info('Saved contacts to storage', tag: 'Connector');

    // Update any in-flight retries so they use the new path override
    _retryService?.updatePendingContact(_contacts[index]);

    // If setting a specific path (not flood, not auto), also sync with device
    if (pathLen != null && pathLen >= 0 && pathBytes != null) {
      appLogger.info('Sending path to device...', tag: 'Connector');
      await setContactPath(contact, pathBytes, pathLen);
      appLogger.info('Path sent to device', tag: 'Connector');
    }

    debugPrint(
      'Set path override for ${contact.name}: pathLen=$pathLen, bytes=${pathBytes?.length ?? 0}',
    );
    notifyListeners();
  }

  Future<PathSelection> preparePathForContactSend(Contact contact) async {
    PathSelection? autoSelection;
    final autoRotationEnabled =
        _appSettingsService?.settings.autoRouteRotationEnabled == true;
    if (autoRotationEnabled && contact.pathOverride == null) {
      final maxRetries = _appSettingsService?.settings.maxMessageRetries ?? 5;
      autoSelection = _selectAutoPathForAttempt(
        contact.publicKeyHex,
        attemptIndex: 0,
        maxRetries: maxRetries,
      );
    }

    final resolved = resolvePathSelection(contact, selection: autoSelection);

    if (resolved.useFlood) {
      await clearContactPath(contact);
    } else {
      await setContactPath(
        contact,
        Uint8List.fromList(resolved.pathBytes),
        resolved.hopCount,
      );
    }

    return resolved;
  }

  void trackRepeaterAck({
    required Contact contact,
    required PathSelection selection,
    required String text,
    required int timestampSeconds,
    int attempt = 0,
  }) {
    final selfKey = _selfPublicKey;
    if (selfKey == null) return;
    // Use transformed text to match device's ACK hash computation
    final outboundText = prepareContactOutboundText(contact, text);
    final ackHash = MessageRetryService.computeExpectedAckHash(
      timestampSeconds,
      attempt,
      outboundText,
      selfKey,
    );
    final ackHashHex = ackHashToHex(ackHash);
    final messageBytes = utf8.encode(outboundText).length;
    _pendingRepeaterAcks[ackHashHex]?.timeout?.cancel();
    _pendingRepeaterAcks[ackHashHex] = _RepeaterAckContext(
      contactKeyHex: contact.publicKeyHex,
      selection: selection,
      pathLength: selection.useFlood ? -1 : selection.hopCount,
      messageBytes: messageBytes,
    );
  }

  void recordRepeaterPathResult(
    Contact contact,
    PathSelection selection,
    bool success,
    int? tripTimeMs,
  ) {
    _recordPathResult(contact.publicKeyHex, selection, success, tripTimeMs);
  }

  Future<bool> verifyContactPathOnDevice(
    Contact contact,
    Uint8List expectedPath, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!isConnected) return false;

    final expectedLength = expectedPath.length;
    final completer = Completer<bool>();

    void finish(bool result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    final subscription = receivedFrames.listen((frame) {
      if (frame.isEmpty || frame[0] != respCodeContact) return;
      final updated = Contact.fromFrame(frame);
      if (updated == null) return;
      if (updated.publicKeyHex != contact.publicKeyHex) return;
      final matchesLength = updated.path.length == expectedLength;
      final matchesBytes = _pathsEqual(updated.path, expectedPath);
      if (matchesLength && matchesBytes) {
        finish(true);
      }
    });

    final timer = Timer(timeout, () => finish(false));
    try {
      await getContactByKey(contact.publicKey);
      return await completer.future;
    } finally {
      await subscription.cancel();
      timer.cancel();
    }
  }

  Future<void> sendChannelMessage(
    Channel channel,
    String text, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
    String? region,
    ChannelMessage? replyTo,
  }) async {
    if (!isConnected || text.isEmpty) return;
    final sendScope = region ?? _channelSendScope(channel.index);
    // Label only: with no app scope the radio applies its own default
    // (and "no region" cannot force unscoped below ver 12).
    final radioDefaultApplies =
        sendScope.isEmpty ||
        (sendScope == kUnscopedRegion && !supportsExplicitUnscopedFlood);
    final sendRegion = radioDefaultApplies
        ? (_defaultFloodScopeName ?? '')
        : (sendScope == kUnscopedRegion ? '' : sendScope);

    // Check if this is a reaction - if so, process it immediately instead of adding as a message
    final reactionInfo = ReactionHelper.parseReaction(text);
    if (reactionInfo != null) {
      reactionInfo.senderName = selfName;
      final slot = _canonicalSlot(channel.index);
      // Check if we've already processed this reaction
      _processedChannelReactions.putIfAbsent(slot, () => {});
      final reactionIdentifier = reactionInfo.identifier();

      // Maybe we should allow resending. Recipients can drop duplicates.
      if (_processedChannelReactions[slot]!.contains(reactionIdentifier)) {
        // Already processed, don't process again
        return;
      }

      // Get the in-memory messages list (same as _addChannelMessage uses)
      _channelMessages.putIfAbsent(slot, () => []);
      final messages = _channelMessages[slot]!;

      // Process reaction locally to update the UI immediately
      appLogger.info('Adding sent channel reaction, id: $reactionIdentifier');
      final reactionApplied = _processReaction(messages, reactionInfo);
      if (reactionApplied) {
        await _saveChannelMessages(slot, messages);

        // Mark this reaction as processed
        _processedChannelReactions[slot]!.add(reactionIdentifier);

        notifyListeners();

        // Send the reaction to the device (don't add as a visible message)
        final reactionQueueId = _nextReactionSendQueueId();
        _pendingChannelSentQueue.add(reactionQueueId);
        try {
          await _runScopedChannelSend(() async {
            await _waitForRadioQuiet(lastInboundRxTime: _lastChannelMsgRxTime);
            await _sendFrameAndWaitForCommandAck(
              buildSendChannelTextMsgFrame(channel.index, text),
              channelSendQueueId: reactionQueueId,
            );
          }, region: _channelSendScope(channel.index));
        } catch (_) {
          // e.g. SET_FLOOD_SCOPE rejected or timed out: nothing was sent.
          _pendingChannelSentQueue.remove(reactionQueueId);
          rethrow;
        }
        return;
      }
      // It looks like a reaction, but we did not find its target, so
      // we continue to process it normally.
    }

    // OTP: refuse to start a second encrypted send to this channel while
    // one is already consuming pad — see the identical guard and reasoning
    // in sendMessage() above. Doubly important here: a channel pad is
    // shared-sequential (one counter every participant must agree on), so
    // corrupting its order doesn't just break this device, it desyncs
    // everyone on the channel. Also refused while a previous send to this
    // channel is still in its jitter delay (see
    // _pendingChannelJitterChannels above) — same reasoning, just an
    // earlier point in the same send.
    if (isChannelOtpEnabled(channel.index) &&
        (_pendingChannelChunkSends.containsKey(channel.index) ||
            _pendingChannelJitterChannels.contains(channel.index))) {
      appLogger.warn(
        'sendChannelMessage: still sending the previous message to '
        'channel ${channel.index}, dropping this send',
      );
      return;
    }

    // OTP: same reasoning as sendMessage() above — encrypt exactly once,
    // here, before either the locally-stored message or the outbound frame
    // is built, so both derive from the same ciphertext.
    if (isChannelOtpEnabled(channel.index)) {
      final plainBytes = Uint8List.fromList(utf8.encode(text));
      if (plainBytes.length >
          OtpService.maxPlaintextBytesForChannel(_selfName)) {
        // Chunked OTP sends are DM-only, never channel - a channel pad is
        // one shared-sequential counter every participant must agree on,
        // so a chunk transfer that stalls or loses a part (a real,
        // observed failure mode - see _sendChunkedContactMessage's DM
        // counterpart and its git history) doesn't just desync the two
        // people talking, it desyncs everyone on the channel. The
        // compose-box UI already refuses this before it reaches here
        // (see channel_chat_screen.dart's _sendMessage); this is the
        // backstop for any other caller.
        appLogger.warn(
          'sendChannelMessage: message too long for one packet on channel '
          '${channel.index} (${plainBytes.length} bytes) - refusing rather '
          'than chunking; use a DM for longer OTP messages',
        );
        return;
      }
    }

    String wireText = text;
    String? otpPlaintext;
    // Claimed pad offset for THIS ciphertext, wrapped onto the outbound
    // wire text only (see OtpChannelOffsetService) - the locally stored
    // ChannelMessage record keeps the bare, unwrapped ciphertext, same as
    // before this fix.
    int? claimedOffset;
    // Set below only for the OTP-enabled jitter path, once the bubble has
    // already been added to _channelMessages as "pending" — lets the code
    // after the delay fill in the real ciphertext on that SAME message
    // (by messageId) instead of adding a second one.
    ChannelMessage? jitterMessage;
    if (isChannelOtpEnabled(channel.index)) {
      // Phase 2 channel-collision mitigation: show the bubble right away,
      // holding only the plaintext (via otpPlaintext/displayText — see
      // ChannelMessage), but don't touch the pad or encrypt yet. Wait a
      // short random delay first, so a competing message from someone
      // else that arrives in the meantime gets to advance this channel's
      // pad offset before this device commits to one — see
      // _encryptForChannel, which always reads the pad fresh at call
      // time, and the class-level comment on _pendingChannelJitterChannels
      // for the full tradeoff vs. a full reserve/commit handshake.
      jitterMessage = ChannelMessage.outgoing(
        '',
        _selfName ?? 'Me',
        channel.index,
        originalText: originalText,
        translatedLanguageCode: translatedLanguageCode,
        translationModelId: translationModelId,
        otpPlaintext: text,
        region: sendRegion,
        replyTo: replyTo,
      );
      _addChannelMessage(channel.index, jitterMessage);
      notifyListeners();
      _pendingChannelJitterChannels.add(channel.index);
      try {
        await Future.delayed(_channelJitterDelay());
      } finally {
        _pendingChannelJitterChannels.remove(channel.index);
      }
      try {
        final encrypted = await _encryptForChannel(channel.index, text);
        wireText = encrypted.cipherHex;
        claimedOffset = encrypted.claimedOffset;
        otpPlaintext = text;
      } on OtpPadExhaustedException catch (e) {
        appLogger.warn(
          'sendChannelMessage: OTP pad exhausted for channel '
          '${channel.index}: $e',
        );
        _markPendingChannelMessageFailedById(jitterMessage.messageId);
        return;
      }
    }

    final message = jitterMessage != null
        ? jitterMessage.copyWith(text: wireText)
        : ChannelMessage.outgoing(
            wireText,
            _selfName ?? 'Me',
            channel.index,
            originalText: originalText,
            translatedLanguageCode: translatedLanguageCode,
            translationModelId: translationModelId,
            otpPlaintext: otpPlaintext,
            region: sendRegion,
            replyTo: replyTo,
          );
    if (jitterMessage != null) {
      _fillJitteredChannelMessageText(
        channel.index,
        message.messageId,
        wireText,
      );
    } else {
      _addChannelMessage(channel.index, message);
    }
    _pendingChannelSentQueue.add(message.messageId);
    notifyListeners();

    // OTP: the claimed pad offset rides on the wire text only.
    final wireTextForRadio = claimedOffset != null
        ? OtpChannelOffsetService.wrap(claimedOffset, wireText)
        : wireText;
    final outboundText = prepareChannelOutboundText(
      channel.index,
      wireTextForRadio,
    );
    // Resends reuse the timestamp, so they are the same packet: repeaters
    // that already forwarded it drop the copy and recipients see it once.
    Future<void> transmit({bool isResend = false}) =>
        _runScopedChannelSend(() async {
          await _waitForRadioQuiet(lastInboundRxTime: _lastChannelMsgRxTime);
          await _sendFrameAndWaitForCommandAck(
            buildSendChannelTextMsgFrame(
              channel.index,
              outboundText,
              timestamp: message.timestamp.millisecondsSinceEpoch ~/ 1000,
            ),
            channelSendQueueId: isResend ? null : message.messageId,
          );
        }, region: sendScope);
    try {
      await transmit();
    } catch (_) {
      // A failed or timed-out SET_FLOOD_SCOPE (or text send) means no OK/ERR
      // will resolve this message, so fail it here instead of leaving it
      // pending forever.
      _pendingChannelSentQueue.remove(message.messageId);
      _markPendingChannelMessageFailedById(message.messageId);
      rethrow;
    }

    final settings = _appSettingsService?.settings;
    if (settings != null && settings.channelMinHopsEnabled) {
      unawaited(
        _resendUntilMinHops(
          message.messageId,
          () => transmit(isResend: true),
          minHops: settings.channelMinHops,
          maxResends: settings.channelMinHopsRetries,
        ),
      );
    }
  }

  /// How long to listen for a channel message to come back through the mesh
  /// before resending it.
  static const Duration _channelHopCheckDelay = Duration(seconds: 30);

  /// Resends a channel message until one of its echoes has travelled through
  /// at least [minHops] repeaters, then gives up and marks it failed.
  Future<void> _resendUntilMinHops(
    String messageId,
    Future<void> Function() resend, {
    required int minHops,
    required int maxResends,
  }) async {
    _channelHopChecks[messageId] = (resends: 0, maxResends: maxResends);
    notifyListeners();
    var hops = 0;
    try {
      for (var attempt = 0; ; attempt++) {
        await Future<void>.delayed(_channelHopCheckDelay);
        final message = _findChannelMessageById(messageId);
        if (message == null) return;
        if (message.status == ChannelMessageStatus.failed) return;
        hops = message.pathLength ?? 0;
        // Read live so toggling the setting mid-resend takes effect.
        final countRepeaters =
            _appSettingsService?.settings.channelMinHopsCountRepeaters ?? false;
        if (channelResendSatisfied(
          message,
          minHops: minHops,
          countDistinctRepeaters: countRepeaters,
          selfPublicKey: _selfPublicKey,
        )) {
          _appDebugLogService?.info(
            hops >= minHops
                ? 'Channel message reached $hops hops after $attempt resends'
                : 'Channel message heard via ${distinctFirstHopRepeaters(message, selfPublicKey: _selfPublicKey).length} '
                      'first-hop repeaters after $attempt resends',
            tag: 'Channel resend',
          );
          return;
        }
        if (attempt >= maxResends || !isConnected) break;
        _appDebugLogService?.info(
          'Heard at $hops of $minHops hops; resending '
          '(${attempt + 1} of $maxResends)',
          tag: 'Channel resend',
        );
        _channelHopChecks[messageId] = (
          resends: attempt + 1,
          maxResends: maxResends,
        );
        notifyListeners();
        try {
          await resend();
        } catch (e) {
          _appDebugLogService?.warn(
            'Channel resend failed: $e',
            tag: 'Channel resend',
          );
          break;
        }
      }
      _appDebugLogService?.warn(
        'Channel message only heard at $hops of $minHops hops; giving up',
        tag: 'Channel resend',
      );
      // It was sent and may well have travelled further than we can hear, so
      // this is a warning, not a failure.
      _channelHopShortfalls[messageId] = (hops: hops, required: minHops);
    } finally {
      _channelHopChecks.remove(messageId);
      notifyListeners();
    }
  }

  final Map<String, ({int resends, int maxResends})> _channelHopChecks = {};
  final Map<String, ({int hops, int required})> _channelHopShortfalls = {};

  /// Set when resending gave up before hearing the message through enough
  /// repeaters. Kept for this session only.
  ({int hops, int required})? channelHopShortfall(String messageId) =>
      _channelHopShortfalls[messageId];

  /// Resend progress for a channel message still waiting to travel far
  /// enough, or null when it is not being watched.
  ({int resends, int maxResends})? channelResendProgress(String messageId) =>
      _channelHopChecks[messageId];

  ChannelMessage? _findChannelMessageById(String messageId) {
    for (final messages in _channelMessages.values) {
      for (int i = messages.length - 1; i >= 0; i--) {
        if (messages[i].messageId == messageId) return messages[i];
      }
    }
    return null;
  }

  /// Minimum companion firmware version code whose CMD_SEND_CHANNEL_DATA (62)
  /// / RESP_CODE_CHANNEL_DATA_RECV (27) layout matches ours (v1.15.0, ver 11).
  static const int _minFirmwareVerCodeForChannelData = 11;

  /// True when the connected device can send/receive GRP_DATA blobs.
  bool get supportsChannelData =>
      isConnected &&
      (_firmwareVerCode ?? 0) >= _minFirmwareVerCodeForChannelData;

  /// Sends one image's chunk [blobs] as GRP_DATA packets on [channelIndex],
  /// strictly sequentially, inside a single scoped-send scope for the whole
  /// image (the flood scope is global, so re-entering it per chunk would let
  /// another channel's send interleave mid-image).
  ///
  /// [onProgress] fires after each chunk is acked, so the UI can show
  /// "sending 2 of 3".
  ///
  /// IMPORTANT: the command ACK only proves the firmware accepted the blob and
  /// queued a packet to the radio. It says nothing about transmission or
  /// delivery — GRP_DATA is unacknowledged flood traffic, there is no
  /// PUSH_CODE_SEND_CONFIRMED for it, and a chunk may still be lost on air.
  /// That is what the XOR parity chunk is for.
  ///
  /// Returns false when the transport is unavailable (disconnected or firmware
  /// too old); throws whatever [_sendFrameAndWaitForCommandAck] throws, i.e.
  /// Exception('Command failed with error code N') where N is 1
  /// (unsupported command), 2 (bad channel index), 3 (packet pool full, worth
  /// retrying) or 6 (illegal arg — blob too long or bad data type), or a
  /// TimeoutException after _commandAckTimeout.
  Future<bool> sendImageChunks(
    List<Uint8List> blobs, {
    required int channelIndex,
    required Duration interChunkDelay,
    void Function(int sent, int total)? onProgress,
  }) => sendChannelDataBlobs(
    blobs,
    channelIndex: channelIndex,
    dataType: dataTypeAeicImage,
    interChunkDelay: interChunkDelay,
    onProgress: onProgress,
  );

  /// Sends [blobs] as GRP_DATA packets of [dataType] on [channelIndex], with
  /// the same pacing, collision avoidance and region scoping as images.
  Future<bool> sendChannelDataBlobs(
    List<Uint8List> blobs, {
    required int channelIndex,
    required int dataType,
    required Duration interChunkDelay,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (blobs.isEmpty) return false;
    if (!supportsChannelData) return false;
    // `return` inside the scoped callback only exits the callback, so a
    // disconnect mid-send used to fall through to `return true` below and the
    // caller would record a complete outgoing image and tell the user "sent"
    // after transmitting a prefix of the chunks. Track it explicitly.
    var sentAll = true;
    await _runScopedChannelSend(() async {
      for (var i = 0; i < blobs.length; i++) {
        if (!isConnected) {
          sentAll = false;
          return;
        }
        if (i > 0) await Future<void>.delayed(interChunkDelay);
        // Same collision avoidance as every other channel send. On a quiet mesh
        // this returns almost immediately; interChunkDelay is what actually
        // paces the chunks so we do not talk over our own previous packet.
        await _waitForRadioQuiet(lastInboundRxTime: _lastChannelMsgRxTime);
        await _sendFrameAndWaitForCommandAck(
          buildSendChannelDataFrame(
            channelIndex: channelIndex,
            dataType: dataType,
            payload: blobs[i],
            pathLen: outPathUnknown, // 0xFF => flood
          ),
        );
        onProgress?.call(i + 1, blobs.length);
      }
    }, region: _channelSendScope(channelIndex));
    return sentAll;
  }

  /// When the radio last reported hearing a packet (any packet, either
  /// radio), for a short listen-before-talk ahead of a burst.
  DateTime get lastRadioRxTime => _lastRadioRxTime;

  /// One GRP_DATA packet of a photo/voice burst, without the per-message
  /// collision backoff [sendChannelDataBlobs] waits out before every packet
  /// (a chat-sized pause of up to 15 s plus 3 s of silence, which made a
  /// burst take minutes): the burst is paced by its caller, and the radio
  /// still listens before it talks.
  ///
  /// [zeroHop] sends it direct with an empty path: heard by every radio in
  /// range and relayed by none, for when everyone who asked is in range.
  /// Otherwise it floods like any channel packet, in the channel's region.
  Future<void> sendChannelDataPacket({
    required int channelIndex,
    required int dataType,
    required Uint8List payload,
    bool zeroHop = false,
  }) async {
    if (!isConnected) throw StateError('Not connected');
    final frame = buildSendChannelDataFrame(
      channelIndex: channelIndex,
      dataType: dataType,
      payload: payload,
      pathLen: zeroHop ? 0 : outPathUnknown,
      path: zeroHop ? Uint8List(0) : null,
    );
    if (zeroHop) {
      await _sendFrameAndWaitForCommandAck(frame);
      return;
    }
    await _runScopedChannelSend(
      () => _sendFrameAndWaitForCommandAck(frame),
      region: _channelSendScope(channelIndex),
    );
  }

  Future<void> _runScopedChannelSend(
    Future<void> Function() action, {
    required String region,
  }) async {
    final prev = _channelScopedSendLock;
    final completer = Completer<void>();
    _channelScopedSendLock = completer.future;
    await prev;

    try {
      // Only touch the global flood scope for region-scoped channels. Plain
      // channels send exactly as before, which also stays compatible with
      // firmware that predates CMD_SET_FLOOD_SCOPE. The lock is still held so an
      // unscoped send can't interleave with (and inherit the scope of) a
      // concurrent scoped send.
      // "No region" can only override the radio's default scope on ver 12+;
      // older firmware sends it like any unscoped channel.
      final forceUnscoped =
          region == kUnscopedRegion && supportsExplicitUnscopedFlood;
      if (region.isEmpty || (region == kUnscopedRegion && !forceUnscoped)) {
        await action();
        return;
      }
      await _sendFrameAndWaitForCommandAck(
        forceUnscoped
            ? buildSetFloodScopeUnscopedFrame()
            : buildSetFloodScopeFrame(region),
      );
      try {
        await action();
      } finally {
        if (isConnected) {
          await _sendFrameAndWaitForCommandAck(buildSetFloodScopeFrame(''));
        }
      }
    } finally {
      completer.complete();
    }
  }

  // Sends [data] and resolves once the device replies to this command.
  // SET_FLOOD_SCOPE, CMD_SEND_CHANNEL_DATA and CMD_SEND_CHANNEL_TXT_MSG all
  // reply with RESP_CODE_OK or an ERR (the firmware never sends RESP_CODE_SENT
  // for channel sends). Replies are attributed through the generic-ack queue
  // (see [_handleOk] and [_handleErrorFrame]) so an OK/ERR produced by another
  // in-flight command cannot complete it.
  // Waiting for the text send's reply before the scope is reset guarantees
  // the firmware has already built the packet with the active scope.
  Future<void> _sendFrameAndWaitForCommandAck(
    Uint8List data, {
    String? channelSendQueueId,
  }) {
    return sendFrame(
      data,
      channelSendQueueId: channelSendQueueId,
      waitForGenericAck: true,
    );
  }

  Future<void> removeContact(
    Contact contact, {
    bool keepMessages = false,
  }) async {
    if (!isConnected) return;

    _handleDiscovery(
      contact,
      contact.rawPacket ?? Uint8List(0),
      noNotify: true,
    );

    await sendFrame(buildRemoveContactFrame(contact.publicKey));
    _contactsStorageFull = false;
    _contacts.removeWhere((c) => c.publicKeyHex == contact.publicKeyHex);
    _knownContactKeys.remove(contact.publicKeyHex);
    unawaited(updateKnownDiscovered());
    unawaited(_persistContacts());
    _conversations.remove(contact.publicKeyHex);
    _loadedConversationKeys.remove(contact.publicKeyHex);
    _messageStore.forgetArchive(contact.publicKeyHex);
    final removedCount = _contactUnreadCount[contact.publicKeyHex] ?? 0;
    _cachedContactsUnreadTotal = (_cachedContactsUnreadTotal - removedCount)
        .clamp(0, _cachedContactsUnreadTotal);
    _contactUnreadCount.remove(contact.publicKeyHex);
    _unreadStore.saveContactUnreadCount(
      Map<String, int>.from(_contactUnreadCount),
    );
    if (!keepMessages) _messageStore.clearMessages(contact.publicKeyHex);
    notifyListeners();
  }

  Future<void> updateKnownDiscovered() async {
    if (!isConnected) return;
    for (int i = 0; i < _discoveredContacts.length; i++) {
      _discoveredContacts[i] = _discoveredContacts[i].copyWith(
        isActive: _knownContactKeys.contains(
          _discoveredContacts[i].publicKeyHex,
        ),
      );
    }
    unawaited(_persistDiscoveredContacts());
    notifyListeners();
  }

  Future<void> removeDiscoveredContact(Contact contact) async {
    if (!isConnected) return;
    _discoveredContacts.removeWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );
    unawaited(_persistDiscoveredContacts());
    notifyListeners();
  }

  /// Broadcasts a zero-hop DISCOVER_REQ and emits each distinct node that
  /// answers with our tag until [timeout]. Repeaters reply after a random
  /// delay, and firmware rate-limits replies, so the window stays generous.
  Stream<NodeDiscoverResponse> discoverNearbyNodes({
    int typeMask = nodeDiscoverScanTypeMask,
    Duration timeout = const Duration(seconds: 12),
  }) {
    late final StreamController<NodeDiscoverResponse> controller;
    StreamSubscription<Uint8List>? subscription;
    Timer? timer;
    final seenKeys = <String>{};
    final tag = math.Random.secure().nextInt(0xFFFFFFFF) + 1;
    final selfKeyHex = selfPublicKeyHex;

    Future<void> close() async {
      timer?.cancel();
      await subscription?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<NodeDiscoverResponse>(
      onListen: () async {
        if (!isConnected || !supportsNodeDiscover) {
          await close();
          return;
        }
        subscription = receivedFrames.listen((frame) {
          final response = parseNodeDiscoverResponse(frame);
          if (response == null || response.tag != tag) return;
          final keyHex = response.publicKeyHex;
          if (selfKeyHex.isNotEmpty && selfKeyHex.startsWith(keyHex)) return;
          if (!seenKeys.add(keyHex)) return;
          if (!controller.isClosed) controller.add(response);
        });
        try {
          await sendFrame(
            buildSendControlDataFrame(
              buildDiscoveryRequestPayload(tag, typeMask: typeMask),
            ),
          );
        } catch (e) {
          if (!controller.isClosed) controller.addError(e);
          await close();
          return;
        }
        timer = Timer(timeout, () => unawaited(close()));
      },
      onCancel: close,
    );
    return controller.stream;
  }

  /// The best-known contact for a scan response: an existing contact or a
  /// discovered advert with the same key, else a placeholder built from the
  /// response (direct neighbour; firmware fills the name on its next advert).
  Contact contactForDiscoverResponse(NodeDiscoverResponse response) {
    final keyHex = response.publicKeyHex;
    for (final contact in [..._contacts, ..._discoveredContacts]) {
      if (contact.publicKeyHex.startsWith(keyHex)) return contact;
    }
    return Contact(
      publicKey: response.publicKey,
      name: keyHex.substring(0, math.min(8, keyHex.length)).toUpperCase(),
      type: response.nodeType,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime.now(),
      isActive: false,
    );
  }

  Future<bool> importDiscoveredContact(Contact contact) async {
    if (!isConnected) return false;

    // Manual saves must bypass the firmware's auto-add discovery policy.
    // CMD_IMPORT_CONTACT replays an advert and may remain discovery-only.
    final encodedPathLen = _encodePathLenForWidth(
      contact.pathLength,
      contact.path,
      contact.pathHashWidth,
    );
    if (encodedPathLen == null) return false;
    await sendFrame(
      buildUpdateContactPathFrame(
        contact.publicKey,
        contact.path,
        encodedPathLen,
        type: contact.type,
        flags: contact.flags,
        name: contact.name,
        lat: contact.latitude,
        lon: contact.longitude,
        lastAdvert: contact.lastSeen,
        lastModified: contact.lastSeen,
      ),
      waitForGenericAck: true,
    );

    // Update the discovered contact to mark it as active (imported)
    final discoveredIndex = _discoveredContacts.indexWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );
    if (discoveredIndex >= 0) {
      _discoveredContacts[discoveredIndex] =
          _discoveredContacts[discoveredIndex].copyWith(isActive: true);
    }

    _handleContactAdvert(
      Contact(
        publicKey: contact.publicKey,
        name: contact.name,
        type: contact.type,
        pathLength: contact.pathLength,
        path: contact.path,
        pathHashWidth: contact.pathHashWidth,
        latitude: contact.latitude,
        longitude: contact.longitude,
        lastSeen: contact.lastSeen,
        flags: contact.flags,
      ),
    );
    notifyListeners();
    unawaited(_persistDiscoveredContacts());
    return true;
  }

  Future<void> clearContactPath(Contact contact) async {
    // Serialize path operations to prevent interleaved async calls.
    final prev = _pathOpLock;
    final completer = Completer<void>();
    _pathOpLock = completer.future;
    await prev;
    try {
      if (!isConnected) return;

      await sendFrame(buildResetPathFrame(contact.publicKey));
      if (_activeTransport == MeshCoreTransportType.usb) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final existingIndex = _contacts.indexWhere(
        (c) => c.publicKeyHex == contact.publicKeyHex,
      );
      if (existingIndex >= 0) {
        final existing = _contacts[existingIndex];
        // Preserve pathOverride and pathOverrideBytes — only reset device path
        _contacts[existingIndex] = existing.copyWith(
          pathLength: -1,
          path: Uint8List(0),
        );
        notifyListeners();
        unawaited(_persistContacts());
      }
    } finally {
      completer.complete();
    }
  }

  void updateContactInMemory(
    String publicKeyHex, {
    Uint8List? pathBytes,
    int? pathLength,
  }) {
    final existingIndex = _contacts.indexWhere(
      (c) => c.publicKeyHex == publicKeyHex,
    );
    if (existingIndex >= 0) {
      final existing = _contacts[existingIndex];
      _contacts[existingIndex] = existing.copyWith(
        pathLength: pathLength,
        path: pathBytes,
      );
      notifyListeners();
      unawaited(_persistContacts());
    }
  }

  Future<void> syncTime() async {
    if (!isConnected) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendFrame(buildSetDeviceTimeFrame(now));
  }

  bool get _channelSyncBlocksQueue =>
      !_channelMapConfirmed ||
      _pendingInitialChannelSync ||
      _isSyncingChannels ||
      _channelSyncInFlight ||
      _channelSyncCompleter != null;

  Future<void> syncQueuedMessages({bool force = false}) async {
    if (!isConnected) return;
    if (!force && _isSyncingQueuedMessages) return;
    if (_isProcessingDeferredQueuedContactMessages) {
      _pendingQueueSync = true;
      return;
    }
    if (_awaitingSelfInfo || _isLoadingContacts) {
      _pendingQueueSync = true;
      return;
    }
    // Queued channel frames carry only a slot index, so they wait until this
    // session's slot map is confirmed and no channel sync can change it.
    if (_channelSyncBlocksQueue) {
      _pendingQueueSync = true;
      return;
    }
    _isSyncingQueuedMessages = true;
    notifyListeners();
    await _requestNextQueuedMessage();
  }

  Future<void> _requestNextQueuedMessage() async {
    if (!isConnected) {
      _isSyncingQueuedMessages = false;
      _queuedMessageSyncInFlight = false;
      _queueSyncRetries = 0;
      return;
    }
    if (_queuedMessageSyncInFlight) return;
    if (_channelSyncBlocksQueue) {
      // A channel sync started mid-queue: hold the next frame until its slot
      // map is in place. _finishChannelSync resumes the queue.
      debugPrint('[QueueSync] Paused for channel sync');
      _queueSyncTimeout?.cancel();
      _isSyncingQueuedMessages = false;
      _queueSyncRetries = 0;
      _pendingQueueSync = true;
      notifyListeners();
      return;
    }
    _queuedMessageSyncInFlight = true;

    // Cancel any existing timeout
    _queueSyncTimeout?.cancel();

    // Set up timeout for this request
    _queueSyncTimeout = Timer(Duration(milliseconds: _queueSyncTimeoutMs), () {
      _handleQueueSyncTimeout();
    });

    debugPrint(
      '[QueueSync] Requesting next message (retry: $_queueSyncRetries/$_maxQueueSyncRetries)',
    );

    try {
      await sendFrame(buildSyncNextMessageFrame());
    } catch (e) {
      debugPrint('[QueueSync] Error sending sync request: $e');
      _queuedMessageSyncInFlight = false;
      _isSyncingQueuedMessages = false;
      _queueSyncTimeout?.cancel();
      _queueSyncRetries = 0;
      notifyListeners();
      _continueAfterQueuedMessageSync();
    }
  }

  void _handleQueueSyncTimeout() {
    debugPrint(
      '[QueueSync] Timeout waiting for message (retry: $_queueSyncRetries/$_maxQueueSyncRetries)',
    );

    if (_queueSyncRetries < _maxQueueSyncRetries) {
      // Retry
      _queueSyncRetries++;
      _queuedMessageSyncInFlight = false;
      _requestNextQueuedMessage();
    } else {
      // Max retries reached, give up
      debugPrint('[QueueSync] Max retries reached, stopping sync');
      _queuedMessageSyncInFlight = false;
      _isSyncingQueuedMessages = false;
      _queueSyncRetries = 0;
      notifyListeners();
      _continueAfterQueuedMessageSync();
    }
  }

  Future<void> setNodeName(String name) async {
    if (!isConnected) return;
    await sendFrame(buildSetAdvertNameFrame(name));
  }

  Future<void> setNodeLocation({
    required double lat,
    required double lon,
  }) async {
    if (!isConnected) return;
    await sendFrame(buildSetAdvertLatLonFrame(lat, lon));
  }

  Future<void> setCustomVar(String value) async {
    if (!isConnected) return;
    await sendFrame(buildSetCustomVarFrame(value));
    final sep = value.indexOf(':');
    if (sep > 0) {
      final key = value.substring(0, sep);
      final val = value.substring(sep + 1);
      (_currentCustomVars ??= <String, String>{})[key] = val;
      notifyListeners();
    }
    if (value == 'gps:1') {
      _startGpsLocationPolling();
    } else if (value == 'gps:0') {
      _stopGpsLocationPolling();
    }
  }

  Future<void> sendSelfAdvert({bool flood = true}) async {
    if (!isConnected) return;
    await sendFrame(buildSendSelfAdvertFrame(flood: flood));
    if (!flood) {
      _lastZeroHopAdvertAt = DateTime.now();
      _lastZeroHopAdvertLatitude = _selfLatitude;
      _lastZeroHopAdvertLongitude = _selfLongitude;
    }
  }

  Future<void> rebootDevice() async {
    if (!isConnected) return;
    await sendFrame(buildRebootFrame());
  }

  Future<void> setTelemetryModeBase(
    int base,
    int location,
    int env,
    int advert,
    int multiAcks,
  ) async {
    if (!isConnected) return;
    _telemetryModeBase = base.clamp(teleModeDeny, teleModeAllowAll).toInt();
    _telemetryModeLoc = location.clamp(teleModeDeny, teleModeAllowAll).toInt();
    _telemetryModeEnv = env.clamp(teleModeDeny, teleModeAllowAll).toInt();
    _advertLocPolicy = advert.clamp(0, 1).toInt();
    _multiAcks = multiAcks.clamp(0, 2).toInt();
    await sendFrame(
      buildSetOtherParamsFrame(
        (_telemetryModeEnv << 4) |
            (_telemetryModeLoc << 2) |
            _telemetryModeBase,
        _advertLocPolicy,
        _multiAcks,
      ),
    );
    notifyListeners();
  }

  /// Syncs every channel slot from the radio. Completes once the sync has
  /// applied its slot map, so callers can persist under the new channel IDs.
  Future<void> getChannels({int? maxChannels, bool force = false}) async {
    if (!isConnected) return;
    while (_channelSyncCompleter != null) {
      final running = _channelSyncCompleter!.future;
      if (!force) {
        debugPrint('[ChannelSync] Already syncing channels, ignoring request');
        return running;
      }
      // A forced refresh follows a SET_CHANNEL the running sync may have
      // read past, so run a fresh sync once it ends.
      await running;
      if (!isConnected) return;
    }

    // Skip fetching if already loaded and not forced
    if (_hasLoadedChannels && !force) {
      debugPrint(
        '[ChannelSync] Channels already loaded, skipping fetch (use force=true to reload)',
      );
      return;
    }

    final completer = Completer<void>();
    _channelSyncCompleter = completer;
    _channelMapSyncRetries = 0;
    _isLoadingChannels = true;
    _isSyncingChannels = true;
    _hasLoadedChannels = false;
    _previousChannelsCache = List<Channel>.from(_channels);
    _channels.clear();
    _unconfirmedChannelSlots.clear();
    _channelSyncIncomplete = false;
    _nextChannelIndexToRequest = 0;
    _totalChannelsToRequest = maxChannels ?? _maxChannels;
    _channelSyncRetries = 0;
    notifyListeners();

    debugPrint(
      '[ChannelSync] Starting sync for $_totalChannelsToRequest channels',
    );

    // Start sequential sync
    await _requestNextChannel();
    return completer.future;
  }

  /// Runs another full pass after slots timed out, keeping what this pass
  /// learned as the fallback for slots that time out again.
  void _restartChannelSyncPass() {
    final known = <int, Channel>{
      for (final channel in _previousChannelsCache) channel.index: channel,
      for (final channel in _channels) channel.index: channel,
    };
    _previousChannelsCache = known.values.toList();
    _channels.clear();
    _unconfirmedChannelSlots.clear();
    _channelSyncIncomplete = false;
    _nextChannelIndexToRequest = 0;
    _channelSyncRetries = 0;
    _channelSyncInFlight = false;
    notifyListeners();
    unawaited(_requestNextChannel());
  }

  Future<void> _requestNextChannel() async {
    if (!isConnected) {
      _cleanupChannelSync(completed: false);
      return;
    }

    if (_channelSyncInFlight) return;

    // Check if we've requested all channels
    if (_nextChannelIndexToRequest >= _totalChannelsToRequest) {
      _completeChannelSync();
      return;
    }

    _channelSyncInFlight = true;
    final channelIndex = _nextChannelIndexToRequest;

    // Cancel any existing timeout
    _channelSyncTimeout?.cancel();

    // Set up timeout for this channel request
    _channelSyncTimeout = Timer(
      Duration(milliseconds: channelSyncTimeoutMs),
      () => _handleChannelSyncTimeout(channelIndex),
    );

    debugPrint(
      '[ChannelSync] Requesting channel $channelIndex/$_totalChannelsToRequest (retry: $_channelSyncRetries/$_maxChannelSyncRetries)',
    );

    try {
      await sendFrame(buildGetChannelFrame(channelIndex));
    } catch (e) {
      debugPrint('[ChannelSync] Error sending channel request: $e');
      _channelSyncInFlight = false;
      _cleanupChannelSync(completed: false);
    }
  }

  void _handleChannelSyncTimeout(int channelIndex) {
    debugPrint(
      '[ChannelSync] Timeout waiting for channel $channelIndex (retry: $_channelSyncRetries/$_maxChannelSyncRetries)',
    );

    if (_channelSyncRetries < _maxChannelSyncRetries) {
      // Retry the same channel
      _channelSyncRetries++;
      _channelSyncInFlight = false;
      unawaited(_requestNextChannel());
    } else {
      // Max retries reached for this channel, restore from cache and move to next
      debugPrint(
        '[ChannelSync] Max retries reached for channel $channelIndex, attempting cache restore',
      );
      _channelSyncIncomplete = true;

      // Try to restore this channel from cache
      try {
        final cachedChannel = _previousChannelsCache.firstWhere(
          (c) => c.index == channelIndex,
        );
        if (!cachedChannel.isEmpty) {
          _channels.add(cachedChannel);
          debugPrint(
            '[ChannelSync] Restored channel $channelIndex (${cachedChannel.name}) from cache',
          );
        }
      } catch (e) {
        // No cached copy: the slot's contents are unknown, not empty.
        _unconfirmedChannelSlots.add(channelIndex);
      }

      // Move to next channel
      _nextChannelIndexToRequest++;
      _channelSyncRetries = 0;
      _channelSyncInFlight = false;
      notifyListeners();
      unawaited(_requestNextChannel());
    }
  }

  /// The firmware answers GET_CHANNEL with ERR_NOT_FOUND only for an index
  /// past its MAX_GROUP_CHANNELS, so every later index is out of range too:
  /// finish the sync now instead of retrying each one until it times out.
  void _handleChannelSyncNotFound() {
    debugPrint(
      '[ChannelSync] Channel $_nextChannelIndexToRequest not found; '
      'device has $_nextChannelIndexToRequest channel slots',
    );
    _channelSyncTimeout?.cancel();
    _channelSyncInFlight = false;
    _totalChannelsToRequest = _nextChannelIndexToRequest;
    _completeChannelSync();
  }

  void _completeChannelSync() {
    _channelSyncTimeout?.cancel();

    debugPrint(
      '[ChannelSync] Sync complete: received ${_channels.length}/$_totalChannelsToRequest channels',
    );

    if (_channelSyncIncomplete &&
        _channelMapSyncRetries < _maxChannelMapSyncRetries &&
        isConnected) {
      _channelMapSyncRetries++;
      debugPrint(
        '[ChannelSync] Some slots did not answer; retrying the sync '
        '($_channelMapSyncRetries/$_maxChannelMapSyncRetries)',
      );
      _restartChannelSyncPass();
      return;
    }
    final complete = !_channelSyncIncomplete;

    _cleanupChannelSync(completed: true);

    // Cache channels for offline use
    _cachedChannels = List<Channel>.from(_channels);
    unawaited(_channelStore.saveChannels(_channels));
    _recalculateCachedChannelsUnreadTotal();

    // Apply ordering and notify UI
    _applyChannelOrder();
    notifyListeners();
    unawaited(_applyChannelMap(complete: complete));
  }

  /// Replaces the slot map with the one this sync read and reloads the
  /// in-memory state of every slot whose channel changed, then releases the
  /// queued messages that were waiting for it.
  Future<void> _applyChannelMap({required bool complete}) async {
    final generation = _channelSessionGeneration;
    final next = <int, String>{
      for (final channel in _channels)
        if (channel.storageId != null) channel.index: channel.storageId!,
    };
    final unconfirmed = Set<int>.of(_unconfirmedChannelSlots);
    await _channelStorageReady;
    if (generation != _channelSessionGeneration) return;

    final previous = Map<int, String>.of(_slotChannelIds);
    if (!complete) {
      for (final slot in unconfirmed) {
        final saved = previous[slot];
        if (saved != null) next[slot] = saved;
      }
      appLogger.warn(
        'Channel sync incomplete; using the saved channel map for slots '
        '$unconfirmed',
      );
    }
    _slotChannelIds
      ..clear()
      ..addAll(next);

    try {
      var orderChanged = false;
      final slots = {...previous.keys, ...next.keys}.toList()..sort();
      for (final slot in slots) {
        final before = previous[slot];
        final after = next[slot];
        if (before == after &&
            _canonicalSlotIn(previous, slot) == _canonicalSlotIn(next, slot)) {
          continue;
        }
        if (before != after) {
          appLogger.info(
            'Channel slot $slot: ${before ?? 'empty'} -> ${after ?? 'empty'}',
          );
          orderChanged |= _carryChannelOrder(before, after, next);
        }
        _dropChannelSlotState(slot, before);
        await _loadChannelSlotSettings(slot);
        if (_canonicalSlot(slot) == slot) await _loadChannelMessages(slot);
        if (generation != _channelSessionGeneration) return;
      }
      if (orderChanged) {
        _applyChannelOrder();
        await _channelOrderStore.saveChannelOrder(_channelOrder);
      }
      await _channelStore.saveSlotChannelIds(next);
    } catch (e) {
      // The map is already applied in memory; a storage failure must not
      // leave the queue blocked for the rest of the session.
      appLogger.warn('Applying the channel slot map failed: $e');
    }
    if (generation != _channelSessionGeneration) return;
    _channelMapConfirmed = true;
    notifyListeners();
    _finishChannelSync();
  }

  void _replayChannelFramesAwaitingMap() {
    if (_channelFramesAwaitingMap.isEmpty) return;
    final frames = List<Uint8List>.of(_channelFramesAwaitingMap);
    _channelFramesAwaitingMap.clear();
    for (final frame in frames) {
      if (frame[0] != respCodeChannelDataRecv) {
        _handleIncomingChannelMessage(frame);
      } else if (_appSettingsService?.settings.imageMessagesEnabled ?? false) {
        _handleIncomingChannelData(frame);
      }
    }
  }

  /// A channel whose key changed in place keeps its position in the custom
  /// order: [after] takes [before]'s place when no slot holds [before] any
  /// more. Returns true when the order changed.
  bool _carryChannelOrder(
    String? before,
    String? after,
    Map<int, String> next,
  ) {
    if (before == null || after == null) return false;
    if (next.containsValue(before) || _channelOrder.contains(after)) {
      return false;
    }
    final position = _channelOrder.indexOf(before);
    if (position < 0) return false;
    _channelOrder[position] = after;
    return true;
  }

  /// Releases queued messages after a sync failed without reading the slots,
  /// keeping the saved slot map.
  Future<void> _releaseChannelMapWithoutSync() async {
    final generation = _channelSessionGeneration;
    await _channelStorageReady;
    if (generation != _channelSessionGeneration) return;
    if (!_channelMapConfirmed) {
      appLogger.warn('Channel sync failed; using the saved channel map');
      _channelMapConfirmed = true;
    }
    _finishChannelSync();
  }

  void _finishChannelSync() {
    if (_channelMapConfirmed) _replayChannelFramesAwaitingMap();
    final completer = _channelSyncCompleter;
    _channelSyncCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    if (isConnected) _startPostChannelInitialQueuedMessageSync();
  }

  /// Forgets everything held in memory for [slot], whose channel changed.
  void _dropChannelSlotState(int slot, String? previousId) {
    _channelMessages.remove(slot);
    _processedChannelReactions.remove(slot);
    _channelSmazEnabled.remove(slot);
    _channelCyr2LatEnabled.remove(slot);
    _channelUrlImagesEnabled.remove(slot);
    _channelCyr2LatProfileId.remove(slot);
    _channelRegions.remove(slot);
    if (previousId != null && !_slotChannelIds.containsValue(previousId)) {
      _channelMessageStore.forgetArchive(previousId);
    }
    // The reassembler reports in-progress streams as failed while the store
    // can still map them to their entries, so drop it first.
    _imageTransport?.reassembler.clearChannel(slot);
    _receivedImageStore?.forgetChannelSlot(slot);
  }

  /// Runs the one-shot storage migration, then preloads this radio's channel
  /// state from the saved slot map so it shows before the channel sync ends.
  Future<void> _prepareChannelStorage() async {
    try {
      // First: the channel sync is already running and carries unread counts
      // over from these. The migration never touches the channel cache.
      await loadCachedChannels();
      await ChannelStorageMigration.migrate(
        _channelStore.publicKeyHex,
        beforeDone: (slotIds) async =>
            _receivedImageStore?.stampLegacyChannelIds(slotIds),
      );
      await _loadChannelOrder();
      final saved = await _channelStore.loadSlotChannelIds();
      _slotChannelIds
        ..clear()
        ..addAll(saved);
      await loadChannelSettings();
      await loadAllChannelMessages();
    } catch (e) {
      appLogger.warn('Loading channel storage failed: $e');
    }
  }

  void _cleanupChannelSync({required bool completed}) {
    _isSyncingChannels = false;
    _channelSyncInFlight = false;
    _isLoadingChannels = false;
    _channelSyncTimeout?.cancel();
    _channelSyncRetries = 0;
    _nextChannelIndexToRequest = 0;
    _totalChannelsToRequest = 0;

    if (completed) {
      _hasLoadedChannels = true;
      _previousChannelsCache.clear();
    } else if (_channels.isEmpty && _previousChannelsCache.isNotEmpty) {
      // A failed initial sync should not leave the UI empty/spinning forever.
      // Restore the pre-sync list so cached channels remain usable.
      _channels.addAll(_previousChannelsCache);
      _applyChannelOrder();
      _recalculateCachedChannelsUnreadTotal();
    }

    // Keep cache on failure/disconnection for future attempts
    if (!completed) {
      if (isConnected) {
        unawaited(_releaseChannelMapWithoutSync());
      } else {
        final completer = _channelSyncCompleter;
        _channelSyncCompleter = null;
        if (completer != null && !completer.isCompleted) completer.complete();
      }
      notifyListeners();
    }
  }

  void _startPostChannelInitialQueuedMessageSync() {
    if (_pendingInitialQueuedMessageSync || _pendingQueueSync) {
      // Keep a deferral already in force so its held frames still replay.
      _deferQueuedContactMessagesUntilContacts =
          _deferQueuedContactMessagesUntilContacts ||
          _pendingInitialContactsSync;
      _pendingInitialQueuedMessageSync = false;
      _pendingQueueSync = false;
      unawaited(syncQueuedMessages(force: true));
    }
  }

  Future<void> setChannel(int index, String name, Uint8List psk) async {
    if (!isConnected) return;

    await sendFrame(buildSetChannelFrame(index, name, psk));
    // Refresh channels after setting
    await getChannels(force: true);
  }

  Future<void> deleteChannel(int index) async {
    if (!isConnected) return;

    // The PSK of the channel being deleted, as the channel list shows it,
    // not the slot map, which can lag for a slot left unconfirmed.
    final channelId =
        _findChannelByIndex(index)?.storageId ?? _slotChannelIds[index];
    // Delete by setting empty name and zero PSK
    await sendFrame(buildSetChannelFrame(index, '', Uint8List(16)));
    // Another slot holding the same PSK keeps the shared history.
    final stillHeld = _channels.any(
      (channel) => channel.index != index && channel.storageId == channelId,
    );
    if (channelId != null && !stillHeld) {
      await _clearChannelStorage(channelId);
    }
    _channelMessages.remove(index);
    _processedChannelReactions.remove(index);
    // Refresh channels after deleting
    await getChannels(force: true);
  }

  /// Removes everything persisted for [channelId]: messages, settings,
  /// region, images and its place in the channel order.
  Future<void> _clearChannelStorage(String channelId) async {
    await _channelMessageStore.clearChannelMessages(channelId);
    await _channelSettingsStore.clearChannel(channelId);
    await _channelRegionStore.clearRegion(channelId);
    await _receivedImageStore?.deleteImagesForChannelId(channelId);
    if (_channelOrder.remove(channelId)) {
      await _channelOrderStore.saveChannelOrder(_channelOrder);
    }
  }

  void _handleFrame(List<int> data) {
    if (data.isEmpty) return;
    _lastRxBeforeFrame = _lastRxTime;
    _lastRxTime = DateTime.now();

    final frame = Uint8List.fromList(data);
    _receivedFramesController.add(frame);
    _bleDebugLogService?.logFrame(frame, outgoing: false);

    final code = frame[0];
    // debugPrint('RX frame: code=$code len=${frame.length}');
    final completedPendingReply = _pendingGenericAckQueue.completeReply(frame);

    switch (code) {
      case respCodeOk:
        _handleOk();
        break;
      case respCodeDeviceInfo:
        _handleDeviceInfo(frame);
        break;
      case respCodeSelfInfo:
        debugPrint('Got SELF_INFO');
        _handleSelfInfo(frame);
        break;
      case respCodeContactsStart:
        debugPrint('Got CONTACTS_START');
        if (!_preserveContactsOnRefresh) {
          _contacts.clear();
        }
        _isLoadingContacts = true;
        _contactSyncReceived = 0;
        _armContactSyncWatchdog();
        // Firmware v3+ includes total contacts after CONTACTS_START.
        // Incremental sync reports total contacts, not filtered result count.
        if (frame.length >= 5 && !_contactSyncUsesSinceFilter) {
          final reader = BufferReader(frame);
          reader.skipBytes(1);
          _contactSyncTotal = reader.readUInt32LE();
        } else if (!_contactSyncUsesSinceFilter) {
          // Older firmwares may omit the count; use the nRF node capacity as
          // a conservative progress fallback instead of hiding the progress.
          _contactSyncTotal = _defaultMaxContacts;
        } else {
          _contactSyncTotal = null;
        }
        notifyListeners();
        break;
      case pushCodeAdvert:
        // A stored contact advertised (or was just auto-added): pub key only.
        if (frame.length >= 1 + pubKeySize) {
          unawaited(
            getContactByKey(
              Uint8List.fromList(frame.sublist(1, 1 + pubKeySize)),
            ).catchError(_logTimerSendError),
          );
        }
        break;
      case pushCodeNewAdvert:
        debugPrint('Got New CONTACT');
        _handleNewAdvert(frame);
        break;
      case respCodeContact:
        debugPrint('Got CONTACT');
        _handleContact(frame, countTowardSync: !completedPendingReply);
        if (_isLoadingContacts && !completedPendingReply) {
          _armContactSyncWatchdog();
        } else if (!_isLoadingContacts) {
          unawaited(_replayUnknownSenderMessages(onlyResolvable: true));
        }
        break;
      case pushCodeContactDeleted:
        _handleContactDeleted(frame);
        break;
      case pushCodeContactsFull:
        _appDebugLogService?.warn(
          'Firmware contact storage is full; new contact not stored',
          tag: 'Connector',
        );
        _contactsStorageFull = true;
        _contactsFullController.add(null);
        notifyListeners();
        break;
      case respCodeAllowedRepeatFreq:
        _allowedRepeatFreqRanges = List.unmodifiable(
          parseAllowedRepeatFreqFrame(frame),
        );
        notifyListeners();
        break;
      case respCodeDefaultFloodScope:
        final scope = parseDefaultFloodScopeFrame(frame);
        _defaultFloodScopeName = scope?.name;
        _defaultFloodScopeKey = scope?.key;
        notifyListeners();
        break;
      case respCodeEndOfContacts:
        debugPrint('Got END_OF_CONTACTS');
        _isLoadingContacts = false;
        if (_contactsStorageFull && _contacts.length < _maxContacts) {
          _contactsStorageFull = false; // capacity freed up since the warning
        }
        _hasLoadedContacts = true;
        _preserveContactsOnRefresh = false;
        _contactSyncUsesSinceFilter = false;
        unawaited(updateKnownDiscovered());
        notifyListeners();
        unawaited(_persistContacts());
        _continueAfterContactSync();
        break;
      case respCodeContactMsgRecv:
      case respCodeContactMsgRecvV3:
        if (_shouldDeferQueuedContactMessage(frame)) {
          _deferredQueuedContactMessageFrames.add(Uint8List.fromList(frame));
          _handleQueuedMessageReceived();
        } else {
          unawaited(_handleIncomingMessage(frame));
        }
        break;
      case respCodeChannelMsgRecv ||
              respCodeChannelMsgRecvV3 ||
              respCodeChannelDataRecv
          when !_channelMapConfirmed:
        if (_isSyncingQueuedMessages) _handleQueuedMessageReceived();
        _channelFramesAwaitingMap.add(frame);
        break;
      case respCodeChannelMsgRecv:
      case respCodeChannelMsgRecvV3:
        _handleIncomingChannelMessage(frame);
        break;
      case respCodeChannelDataRecv:
        // RESP_CODE 27 (GRP_DATA received) is delivered through the firmware
        // offline queue in reply to CMD_SYNC_NEXT_MESSAGE, so the queued-message
        // sync state machine MUST be advanced here — exactly like
        // _handleIncomingChannelMessage does. Leaving code 27 unhandled stalls
        // _queueSyncTimeout (5 s) x _maxQueueSyncRetries (3) per chunk and
        // blocks every other queued message behind it. A receivedFrames
        // listener cannot do this: the sync state is private. Advance exactly
        // ONCE, before any async work.
        if (_isSyncingQueuedMessages) {
          _handleQueuedMessageReceived();
        }
        // MeshCore Open TAK: a received AI sketch (AEIC) is always kept and
        // shown, whatever this phone's own setting: the photo button offers
        // AI sketches next to VOX photos, so a receiver has to recognise one
        // without having set anything up. Its bubble says what it is, and
        // tapping it explains how to get the image model; nothing is decoded
        // (or downloaded) until then.
        _handleIncomingChannelData(frame);
        break;
      case respCodeSent:
        _handleMessageSent(frame);
        break;
      case respCodeExportContact:
        break;
      case respCodeNoMoreMessages:
        _handleNoMoreMessages();
        break;
      case pushCodeMsgWaiting:
        unawaited(syncQueuedMessages(force: true));
        break;
      case pushCodeSendConfirmed:
        _handleSendConfirmed(frame);
        break;
      case pushCodePathUpdated:
        _handlePathUpdated(frame);
        break;
      case pushCodeControlData:
        // Optional feature-specific services listen to receivedFrames directly.
        break;
      case pushCodeLoginSuccess:
        _handleLoginSuccess(frame);
        break;
      case pushCodeLoginFail:
      case pushCodeStatusResponse:
        break;
      case pushCodeLogRxData:
        _lastRadioRxTime = DateTime.now();
        _handleRxData(frame);
        _handleLogRxData(frame);
        break;
      case respCodeChannelInfo:
        _handleChannelInfo(frame);
        break;
      case respCodeAutoAddConfig:
        _handleAutoAddConfig(frame);
        _checkManualAddContacts();
        break;
      case respCodeBattAndStorage:
        _handleBatteryAndStorage(frame);
        break;
      case respCodeStats:
        _handleStatsFrame(frame);
        break;
      case respCodeCustomVars:
        _handleCustomVars(frame);
        break;
      case respCodeCliReply:
        _cliReplies.add(parseCliReplyFrame(frame));
        break;
      // RESP_CODE_ERR is a defined firmware response (code 1), not an unknown frame.
      case respCodeErr:
        _handleErrorFrame(frame);
        break;
      default:
        debugPrint('Unknown frame code: $code');
    }
  }

  void _handleErrorFrame(Uint8List frame) {
    final errCode = frame.length > 1 ? frame[1] : -1;
    _appDebugLogService?.warn(
      'Firmware responded with error code: $errCode',
      tag: 'Protocol',
    );

    final failedAck = _pendingGenericAckQueue.takeErr(errCode);
    if (failedAck != null &&
        failedAck.commandCode == cmdGetChannel &&
        errCode == _errCodeNotFound &&
        _isSyncingChannels &&
        _channelSyncInFlight) {
      _handleChannelSyncNotFound();
      return;
    }
    if (failedAck == null ||
        failedAck.commandCode != cmdSendChannelTxtMsg ||
        failedAck.channelSendQueueId == null) {
      return;
    }
    _pendingChannelSentQueue.remove(failedAck.channelSendQueueId);
    _markPendingChannelMessageFailedById(failedAck.channelSendQueueId!);
  }

  void _handlePathUpdated(Uint8List frame) {
    // Frame format: [0]=code, [1-32]=pub_key
    if (frame.length >= 33 && _pathHistoryService != null) {
      final pubKey = Uint8List.fromList(frame.sublist(1, 33));
      final contact = _contacts.cast<Contact?>().firstWhere(
        (c) => c != null && listEquals(c.publicKey, pubKey),
        orElse: () => null,
      );

      if (contact != null) {
        _pathHistoryService!.handlePathUpdated(
          contact,
          initialWeight: _initialRouteWeight,
        );
        // Refresh just this specific contact instead of all contacts.
        // This avoids race conditions with _preserveContactsOnRefresh flag
        // that can occur when using refreshContactsSinceLastmod().
        getContactByKey(pubKey);
      }
    }
  }

  void _handleSelfInfo(Uint8List frame) {
    // SELF_INFO format:
    // [0] = RESP_CODE_SELF_INFO
    // [1] = ADV_TYPE
    // [2] = tx_power_dbm
    // [3] = MAX_LORA_TX_POWER
    // [4-35] = pub_key (32 bytes)
    // [36-39] = lat (int32 LE)
    // [40-43] = lon (int32 LE)
    // [44] = multi_acks
    // [45] = advert_loc_policy
    // [46] = telemetry modes
    // [47] = manual_add_contacts
    // [48-51] = freq (uint32 LE, in Hz)
    // [52-55] = bw (uint32 LE, in Hz)
    // [56] = sf
    // [57] = cr
    // [58+] = node_name
    final wasAwaitingSelfInfo = _awaitingSelfInfo;
    final reader = BufferReader(frame);
    try {
      reader.skipBytes(2);
      _currentTxPower = reader.readInt8();
      _maxTxPower = reader.readInt8();
      _selfPublicKey = reader.readBytes(pubKeySize);
      _selfLatitude = reader.readInt32LE() / 1000000.0;
      _selfLongitude = reader.readInt32LE() / 1000000.0;
      _multiAcks = reader.readByte();
      _advertLocPolicy = reader.readByte();
      final telemetryFlag = reader.readByte();
      _telemetryModeBase = telemetryFlag & 0x03;
      _telemetryModeLoc = telemetryFlag >> 2 & 0x03;
      _telemetryModeEnv = telemetryFlag >> 4 & 0x03;

      _manualAddContacts = reader.readByte() & 0x01 == 0x00;

      _currentFreqHz = reader.readUInt32LE();
      _currentBwHz = reader.readUInt32LE();
      _currentSf = reader.readByte();
      _currentCr = reader.readByte();

      _selfName = reader.readCString();
      _notificationService.setSelfName(_selfName);

      // The local public key only exists once SELF_INFO has arrived, so the
      // image sender prefix (first 2 bytes, big-endian) is refreshed here.
      final prefix = senderPrefixFromKey(_selfPublicKey);
      if (prefix != null) {
        _imageTransport?.senderPrefix = prefix;
        _onImageSenderPrefix?.call(prefix);
      }
    } catch (e) {
      _appDebugLogService?.error(
        'Error parsing SELF_INFO frame: $e',
        tag: 'Connector',
      );
    }

    const locationChangeEpsilon = 2.25e-4; // ~25 meters in degrees.
    final lastAdvertLatitude = _lastZeroHopAdvertLatitude;
    final lastAdvertLongitude = _lastZeroHopAdvertLongitude;
    final currentLatitude = _selfLatitude;
    final currentLongitude = _selfLongitude;
    final latChanged =
        lastAdvertLatitude != null &&
        currentLatitude != null &&
        (currentLatitude - lastAdvertLatitude).abs() >= locationChangeEpsilon;
    final lonChanged =
        lastAdvertLongitude != null &&
        currentLongitude != null &&
        (currentLongitude - lastAdvertLongitude).abs() >= locationChangeEpsilon;
    final gpsSampleChanged =
        hasValidLocation(currentLatitude, currentLongitude) &&
        (!hasValidLocation(lastAdvertLatitude, lastAdvertLongitude) ||
            latChanged ||
            lonChanged);
    final effectiveGpsIntervalSeconds =
        _appSettingsService?.resolvedGpsIntervalSeconds(_currentCustomVars) ??
        0;
    final timeSinceLastZeroHopAdvert = DateTime.now().difference(
      _lastZeroHopAdvertAt,
    );
    final shouldAutoSendZeroHopAdvert =
        (gpsSampleChanged || (_clientRepeat ?? false)) &&
        _advertLocPolicy == 1 &&
        (_appSettingsService?.settings.autoSendZeroHopAdvertOnGpsUpdate ??
            false) &&
        effectiveGpsIntervalSeconds > 0 &&
        timeSinceLastZeroHopAdvert.inSeconds >= effectiveGpsIntervalSeconds;
    if (shouldAutoSendZeroHopAdvert) {
      unawaited(sendSelfAdvert(flood: false));
    }

    final selfName = _selfName?.trim();
    if (_activeTransport == MeshCoreTransportType.usb &&
        selfName != null &&
        selfName.isNotEmpty) {
      _usbManager.updateConnectedLabel(selfName);
    }

    // GPS poll responses arrive as RESP_CODE_SELF_INFO but are not the real
    // handshake — only update location and notify, skip store reloads and
    // contact sync which would clear and re-fetch contacts every minute.
    if (!wasAwaitingSelfInfo) {
      notifyListeners();
      return;
    }

    // A different radio answered (for example after a dropped BLE link):
    // drop the previous radio's history before this radio's stores load.
    if (_messageStateOwnerKey != null &&
        _messageStateOwnerKey != selfPublicKeyHex) {
      _clearSessionMessageState();
    }
    _messageStateOwnerKey = selfPublicKeyHex;

    if (_persistedStateLoadedKey == selfPublicKeyHex) {
      _awaitingSelfInfo = false;
      _selfInfoRetryTimer?.cancel();
      _selfInfoRetryTimer = null;
      _maybeRequestDeviceConfig();
      notifyListeners();
      _maybeStartInitialChannelSync();
      if (_pendingQueueSync && _hasLoadedContacts && !_isLoadingContacts) {
        _pendingQueueSync = false;
        unawaited(syncQueuedMessages(force: true));
      }
      return;
    }

    //set all the stores' public key so they can load the correct data
    _channelMessageStore.setPublicKeyHex = selfPublicKeyHex;
    _messageStore.setPublicKeyHex = selfPublicKeyHex;
    _channelOrderStore.setPublicKeyHex = selfPublicKeyHex;
    _channelSettingsStore.setPublicKeyHex = selfPublicKeyHex;
    _channelRegionStore.setPublicKeyHex = selfPublicKeyHex;
    _contactSettingsStore.setPublicKeyHex = selfPublicKeyHex;
    _otpPadStore.setPublicKeyHex = selfPublicKeyHex;
    _contactStore.setPublicKeyHex = selfPublicKeyHex;
    _channelStore.setPublicKeyHex = selfPublicKeyHex;
    _unreadStore.setPublicKeyHex = selfPublicKeyHex;
    _discoveryContactStore.setPublicKeyHex = selfPublicKeyHex;
    _pathHistoryService?.setDevicePublicKey(selfPublicKeyHex);

    // Now that we have self info, we can load all the persisted data for this node
    loadContactCache();
    // Channel data is migrated and preloaded from the saved slot map before
    // the channel sync diffs that map against the radio.
    _channelStorageReady = _prepareChannelStorage();
    loadUnreadState();
    _loadDiscoveredContactCache();
    _persistedStateLoadedKey = selfPublicKeyHex;

    _awaitingSelfInfo = false;
    _selfInfoRetryTimer?.cancel();
    _selfInfoRetryTimer = null;
    _maybeRequestDeviceConfig();
    notifyListeners();

    // Start the serialized initial sync pipeline after SELF_INFO.
    _maybeStartInitialChannelSync();

    // A queue sync deferred while this SELF_INFO was awaited (e.g. a later
    // refreshDeviceInfo) has nothing else to resume it.
    if (_pendingQueueSync && _hasLoadedContacts && !_isLoadingContacts) {
      _pendingQueueSync = false;
      unawaited(syncQueuedMessages(force: true));
    }
  }

  void _handleDeviceInfo(Uint8List frame) {
    if (frame.length < 4) return;
    if (_shouldGateInitialChannelSync) {
      _hasReceivedDeviceInfo = true;
    }
    _firmwareVerCode = frame[1];

    // Build date (bytes 8..19), manufacturer/model name (20..59) and firmware
    // version (60..79)
    String? readCString(int start, int maxLen) {
      if (frame.length < start + maxLen) return null;
      final bytes = frame.sublist(start, start + maxLen);
      final end = bytes.indexOf(0);
      final s = String.fromCharCodes(
        end >= 0 ? bytes.sublist(0, end) : bytes,
      ).trim();
      return s.isEmpty ? null : s;
    }

    _firmwareBuildDate = readCString(8, 12);
    _manufacturerName = readCString(20, 40);
    _firmwareVersionString = readCString(60, 20);

    // Parse client_repeat from firmware v9+ (byte 80)
    if (frame.length >= 81) {
      _clientRepeat = frame[80] != 0;
    }
    // Path hash mode v10+ (byte 81): width = mode + 1 byte(s) per hop
    final previousPathHashByteWidth = _pathHashByteWidth;
    if (frame.length >= 82) {
      final mode = (frame[81] & 0xFF).clamp(0, 2);
      _pathHashByteWidth = mode + 1;
    } else {
      _pathHashByteWidth = 1;
    }
    if (_pathHashByteWidth != previousPathHashByteWidth) {
      _directRepeaters.clear();
    }

    // Firmware reports MAX_CONTACTS / 2 for v3+ device info.
    final reportedContacts = frame[2];
    final reportedChannels = frame[3];
    final nextMaxContacts = reportedContacts > 0
        ? reportedContacts * 2
        : _maxContacts;
    final nextMaxChannels = reportedChannels > 0
        ? reportedChannels
        : _maxChannels;
    final previousMaxChannels = _maxChannels;
    if (nextMaxContacts != _maxContacts || nextMaxChannels != _maxChannels) {
      _maxContacts = nextMaxContacts;
      _maxChannels = nextMaxChannels;
      if (nextMaxChannels > previousMaxChannels) {
        if (isConnected &&
            _selfPublicKey != null &&
            !_pendingInitialChannelSync) {
          unawaited(getChannels(maxChannels: nextMaxChannels));
        }
      }
    }
    _maybeRequestDeviceConfig();
    notifyListeners();
    if (_shouldGateInitialChannelSync) {
      _maybeStartInitialChannelSync();
    }
  }

  void _maybeStartInitialChannelSync() {
    if (!_pendingInitialChannelSync || !isConnected) {
      return;
    }
    if (_selfPublicKey == null ||
        (_shouldGateInitialChannelSync && !_hasReceivedDeviceInfo)) {
      return;
    }

    _pendingInitialChannelSync = false;
    unawaited(getChannels(maxChannels: _maxChannels, force: true));
  }

  void _handleNoMoreMessages() {
    debugPrint('[QueueSync] No more messages, sync complete');
    _queueSyncTimeout?.cancel();
    _isSyncingQueuedMessages = false;
    _queuedMessageSyncInFlight = false;
    _queueSyncRetries = 0; // Reset retry counter on successful completion
    notifyListeners();
    _continueAfterQueuedMessageSync();
  }

  bool _shouldDeferQueuedContactMessage(Uint8List frame) {
    if (!_deferQueuedContactMessagesUntilContacts ||
        !_isSyncingQueuedMessages) {
      return false;
    }
    if (frame.isEmpty) return false;
    return frame[0] == respCodeContactMsgRecv ||
        frame[0] == respCodeContactMsgRecvV3;
  }

  void _continueAfterQueuedMessageSync() {
    if (!_deferQueuedContactMessagesUntilContacts) return;
    if (_pendingInitialContactsSync && isConnected) {
      _pendingInitialContactsSync = false;
      unawaited(getContacts());
      return;
    }
    unawaited(_processDeferredQueuedContactMessages());
  }

  Future<void> _processDeferredQueuedContactMessages() async {
    if (!_deferQueuedContactMessagesUntilContacts ||
        _isProcessingDeferredQueuedContactMessages) {
      return;
    }
    if (_deferredQueuedContactMessageFrames.isEmpty) {
      _deferQueuedContactMessagesUntilContacts = false;
      notifyListeners();
      if (_pendingQueueSync && isConnected) {
        _pendingQueueSync = false;
        unawaited(syncQueuedMessages(force: true));
      }
      return;
    }

    _isProcessingDeferredQueuedContactMessages = true;
    notifyListeners();
    try {
      // Replay direct/room queued messages only after contacts are loaded, so
      // sender prefixes can be resolved against the current contact list.
      while (_deferredQueuedContactMessageFrames.isNotEmpty) {
        final frame = _deferredQueuedContactMessageFrames.removeAt(0);
        await _handleIncomingMessage(frame, alreadyAdvancedQueueSync: true);
      }
    } finally {
      _deferQueuedContactMessagesUntilContacts = false;
      _isProcessingDeferredQueuedContactMessages = false;
      notifyListeners();
    }

    if (_pendingQueueSync && isConnected) {
      _pendingQueueSync = false;
      unawaited(syncQueuedMessages(force: true));
    }
  }

  void _handleQueuedMessageReceived() {
    if (!_isSyncingQueuedMessages) return;
    debugPrint('[QueueSync] Message received, requesting next');
    _queueSyncTimeout?.cancel(); // Cancel timeout - message arrived
    _queuedMessageSyncInFlight = false;
    _queueSyncRetries = 0; // Reset retry counter on successful message
    notifyListeners();
    unawaited(_requestNextQueuedMessage());
  }

  void _handleStatsFrame(Uint8List frame) {
    final stats = CompanionRadioStats.tryParse(frame);
    if (stats == null) return;
    final total = stats.txAirSecs + stats.rxAirSecs;
    if (total > _prevTotalAirSecs) {
      (_airtimeBumpStopwatch ??= Stopwatch()).reset();
      _airtimeBumpStopwatch!.start();
    }
    _prevTotalAirSecs = total;
    _latestRadioStats = stats;
    radioStatsNotifier.value = stats;
  }

  void _handleBatteryAndStorage(Uint8List frame) {
    // Frame format from C++:
    // [0] = RESP_CODE_BATT_AND_STORAGE
    // [1-2] = battery_mv (uint16 LE)
    // [3-6] = storage_used_kb (uint32 LE)
    // [7-10] = storage_total_kb (uint32 LE)
    try {
      final reader = BufferReader(frame);
      reader.skipBytes(1);
      _batteryMillivolts = reader.readUInt16LE();
      _storageUsedKb = reader.readUInt32LE();
      _storageTotalKb = reader.readUInt32LE();
      final volts = (_batteryMillivolts! / 1000.0).toStringAsFixed(2);
      _appDebugLogService?.info(
        'Pulled battery: $volts V ($_batteryMillivolts mV)',
        tag: 'Battery',
      );
      notifyListeners();
    } catch (e) {
      _appDebugLogService?.error(
        'Error parsing battery and storage frame: $e',
        tag: 'Connector',
      );
    }
  }

  void _checkManualAddContacts() async {
    // If manual add contacts is enabled, set auto add config and other params.
    // and disable it after
    if (_manualAddContacts) {
      await sendFrame(
        buildSetAutoAddConfigFrame(
          autoAddChat: true,
          autoAddRepeater: true,
          autoAddRoomServer: true,
          autoAddSensor: true,
          overwriteOldest: _overwriteOldest,
          maxHops: _autoAddMaxHops,
        ),
      );
      await sendFrame(
        buildSetOtherParamsFrame(
          (_telemetryModeEnv << 4) |
              (_telemetryModeLoc << 2) |
              (_telemetryModeBase),
          _advertLocPolicy,
          _multiAcks,
        ),
      );
      _manualAddContacts = false;
    }
  }

  /// Estimate single-packet airtime in ms from radio settings, or a fallback.
  int _estimateAirtimeMs(int messageBytes) {
    if (_currentFreqHz != null &&
        _currentBwHz != null &&
        _currentSf != null &&
        _currentCr != null) {
      final cr = _currentCr! <= 4 ? _currentCr! : _currentCr! - 4;
      return calculateLoRaAirtime(
        payloadBytes: messageBytes,
        spreadingFactor: _currentSf!,
        bandwidthHz: _currentBwHz!,
        codingRate: cr,
      );
    }
    return 50; // fallback: ~SF7/BW125 for 100 bytes
  }

  /// Physics-based worst-case timeout (ceiling).
  int _physicsMaxTimeout(int pathLength, int airtime) {
    if (pathLength < 0) {
      // Match firmware: SEND_TIMEOUT_BASE_MILLIS + (FLOOD_SEND_TIMEOUT_FACTOR * airtime)
      return 500 + (16 * airtime);
    } else {
      return 500 + ((airtime * 6 + 250) * (pathLength + 1));
    }
  }

  int _physicsMinTimeout(int pathLength, int airtime) {
    if (pathLength < 0) {
      // Same as max for flood — firmware uses a single formula
      return 500 + (16 * airtime);
    } else {
      // Include firmware base (500ms) and per-hop processing (6*airtime+250)
      // so ML cannot clamp below a physically plausible round-trip.
      return 500 + ((airtime * 6 + 250) * pathLength);
    }
  }

  /// Hard ceiling on any ML-derived or physics-fallback timeout (ms).
  /// Prevents the flood formula (500 + 16·airtime at SF12 ≈ 150s) and an
  /// unstable OLS model from producing multi-minute waits.
  static const int _hardMaxTimeoutMs = 45000;

  /// Calculate timeout for a message based on radio settings and path length.
  /// Returns timeout in milliseconds, considering number of hops.
  ///
  /// [deviceTimeoutMs] is the firmware's own est_timeout from RESP_CODE_SENT.
  /// When ML is absent it is used as the fallback (clamped to physicsMin).
  /// When ML is present it is used as an additional ceiling alongside physicsMax.
  int calculateTimeout({
    required int pathLength,
    int messageBytes = 100,
    String? contactKey,
    int? deviceTimeoutMs,
  }) {
    final airtime = _estimateAirtimeMs(messageBytes);
    final physicsMin = _physicsMinTimeout(pathLength, airtime);
    final physicsMax = _physicsMaxTimeout(pathLength, airtime);

    // Try ML-based prediction
    final secSinceRx = DateTime.now().difference(_lastRxTime).inSeconds;
    final mlTimeout = _timeoutPredictionService?.predictTimeout(
      contactKey: contactKey,
      pathLength: pathLength,
      messageBytes: messageBytes,
      secondsSinceLastRx: secSinceRx,
    );
    if (mlTimeout != null) {
      // Use device est_timeout as a baseline floor when available —
      // the firmware computed it from real airtime. Let the learned ML
      // estimate widen above it up to the hard cap, but never below it.
      final floor = deviceTimeoutMs != null && deviceTimeoutMs > physicsMin
          ? deviceTimeoutMs.clamp(physicsMin, _hardMaxTimeoutMs)
          : physicsMin.clamp(0, _hardMaxTimeoutMs);
      if (pathLength < 0) {
        // Flood: trust ML, only enforce firmware estimate as floor
        if (mlTimeout < floor) {
          return floor.clamp(0, _hardMaxTimeoutMs);
        }
      }
      return mlTimeout.clamp(floor, _hardMaxTimeoutMs);
    }

    // No ML data — prefer device est_timeout (it used real airtime), then physics.
    // Cap the floor to the hard maximum so slow-flood physicsMin cannot exceed
    // the upper bound and make clamp() throw.
    if (deviceTimeoutMs != null && deviceTimeoutMs > 0) {
      final floor = physicsMin.clamp(0, _hardMaxTimeoutMs);
      return deviceTimeoutMs.clamp(floor, _hardMaxTimeoutMs);
    }
    return physicsMax.clamp(0, _hardMaxTimeoutMs);
  }

  /// PUSH_CODE_NEW_ADVERT carries a contact the firmware did NOT store
  /// (type not auto-added, beyond autoadd_max_hops, or storage full;
  /// BaseChatMesh::onAdvertRecv), so it only feeds the discovered list.
  void _handleNewAdvert(Uint8List frame) {
    final contact = Contact.fromFrame(frame);
    if (contact == null || listEquals(contact.publicKey, _selfPublicKey)) {
      return;
    }
    _handleDiscovery(contact, frame);
    notifyListeners();
  }

  /// PUSH_CODE_CONTACT_DELETED: the firmware overwrote this contact to make
  /// room for a new one (auto-add overwrite-oldest).
  void _handleContactDeleted(Uint8List frame) {
    if (frame.length < 1 + pubKeySize) return;
    final keyHex = pubKeyToHex(
      Uint8List.fromList(frame.sublist(1, 1 + pubKeySize)),
    );
    _appDebugLogService?.info(
      'Firmware deleted contact ${keyHex.substring(0, 8)} to make room',
      tag: 'Connector',
    );
    _contacts.removeWhere((c) => c.publicKeyHex == keyHex);
    _knownContactKeys.remove(keyHex);
    _contactsStorageFull = false;
    unawaited(updateKnownDiscovered());
    unawaited(_persistContacts());
    notifyListeners();
  }

  void _handleContact(Uint8List frame, {bool countTowardSync = true}) {
    final contactTmp = Contact.fromFrame(frame);
    if (contactTmp != null) {
      if (countTowardSync && _isLoadingContacts) {
        _contactSyncReceived++;
      }
      if (listEquals(contactTmp.publicKey, _selfPublicKey)) {
        appLogger.info(
          'Ignoring contact with self public key: ${contactTmp.name}',
          tag: 'Connector',
        );
        notifyListeners();
        unawaited(
          removeContact(contactTmp).catchError(
            (e) => appLogger.warn(
              'Failed to remove self contact: $e',
              tag: 'Connector',
            ),
          ),
        );
        return;
      }
      final contact = getFromDiscovered(contactTmp);
      _handleDiscovery(contact, frame, noNotify: true, addActive: true);

      if (contact.type == advTypeRepeater) {
        final removedCount = _contactUnreadCount[contact.publicKeyHex] ?? 0;
        _cachedContactsUnreadTotal = (_cachedContactsUnreadTotal - removedCount)
            .clamp(0, _cachedContactsUnreadTotal);
        _contactUnreadCount.remove(contact.publicKeyHex);
        _unreadStore.saveContactUnreadCount(
          Map<String, int>.from(_contactUnreadCount),
        );
      }
      // Check if this is a new contact
      final isNewContact = !_knownContactKeys.contains(contact.publicKeyHex);
      final existingIndex = _contacts.indexWhere(
        (c) => c.publicKeyHex == contact.publicKeyHex,
      );

      if (existingIndex >= 0) {
        final existing = _contacts[existingIndex];
        final mergedLastMessageAt =
            existing.lastMessageAt.isAfter(contact.lastMessageAt)
            ? existing.lastMessageAt
            : contact.lastMessageAt;

        appLogger.info(
          'Refreshing contact ${contact.name}: devicePath=${contact.pathLength}, existingOverride=${existing.pathOverride}',
          tag: 'Connector',
        );

        // Preserve user-selected path settings and previously known GPS when
        // refreshed frames omit coordinates (lat/lon encoded as 0,0).
        _contacts[existingIndex] = contact.copyWith(
          lastMessageAt: mergedLastMessageAt,
          pathOverride: existing.pathOverride, // Preserve user's path choice
          pathOverrideBytes: existing.pathOverrideBytes,
          latitude: contact.latitude ?? existing.latitude,
          longitude: contact.longitude ?? existing.longitude,
        );

        appLogger.info(
          'After merge: pathOverride=${_contacts[existingIndex].pathOverride}, devicePath=${_contacts[existingIndex].pathLength}',
          tag: 'Connector',
        );
      } else {
        _contacts.add(contact);
        appLogger.info(
          'Added new contact ${contact.name}: pathLen=${contact.pathLength}',
          tag: 'Connector',
        );
      }
      _knownContactKeys.add(contact.publicKeyHex);
      _loadMessagesForContact(contact.publicKeyHex);

      // Add path to history if we have a valid path
      if (_pathHistoryService != null && contact.pathLength >= 0) {
        _pathHistoryService!.handlePathUpdated(
          contact,
          initialWeight: _initialRouteWeight,
        );
      }

      notifyListeners();

      // Show notification for new contact (advertisement)
      if (isNewContact && _appSettingsService != null) {
        final settings = _appSettingsService!.settings;
        if (settings.notificationsEnabled && settings.notifyOnNewAdvert) {
          _notificationService.showAdvertNotification(
            contactName: contact.name,
            contactType: contact.typeLabelRaw,
            contactId: contact.publicKeyHex,
          );
        }
      }

      if (!_isLoadingContacts) {
        unawaited(_persistContacts());
      }
    }
  }

  void _handleContactAdvert(Contact contact) {
    if (listEquals(contact.publicKey, _selfPublicKey)) {
      return;
    }

    if (contact.type == advTypeRepeater) {
      final removedCount = _contactUnreadCount[contact.publicKeyHex] ?? 0;
      _cachedContactsUnreadTotal = (_cachedContactsUnreadTotal - removedCount)
          .clamp(0, _cachedContactsUnreadTotal);
      _contactUnreadCount.remove(contact.publicKeyHex);
      _unreadStore.saveContactUnreadCount(
        Map<String, int>.from(_contactUnreadCount),
      );
    }
    // Check if this is a new contact
    final isNewContact = !_knownContactKeys.contains(contact.publicKeyHex);
    final existingIndex = _contacts.indexWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );

    if (existingIndex >= 0) {
      final existing = _contacts[existingIndex];
      final mergedLastMessageAt =
          existing.lastMessageAt.isAfter(contact.lastMessageAt)
          ? existing.lastMessageAt
          : contact.lastMessageAt;

      appLogger.info(
        'Refreshing contact ${contact.name}: devicePath=${contact.pathLength}, existingOverride=${existing.pathOverride}',
        tag: 'Connector',
      );

      // CRITICAL: Preserve user's path override when contact is refreshed from device
      _contacts[existingIndex] = contact.copyWith(
        lastMessageAt: mergedLastMessageAt,
        pathOverride: existing.pathOverride, // Preserve user's path choice
        pathOverrideBytes: existing.pathOverrideBytes,
      );

      appLogger.info(
        'After merge: pathOverride=${_contacts[existingIndex].pathOverride}, devicePath=${_contacts[existingIndex].pathLength}',
        tag: 'Connector',
      );
    } else {
      _contacts.add(contact);
      appLogger.info(
        'Added new contact ${contact.name}: pathLen=${contact.pathLength}',
        tag: 'Connector',
      );
    }
    _knownContactKeys.add(contact.publicKeyHex);
    _loadMessagesForContact(contact.publicKeyHex);

    // Add path to history if we have a valid path
    if (_pathHistoryService != null && contact.pathLength >= 0) {
      _pathHistoryService!.handlePathUpdated(
        contact,
        initialWeight: _initialRouteWeight,
      );
    }

    notifyListeners();

    // Show notification for new contact (advertisement)
    if (isNewContact && _appSettingsService != null) {
      final settings = _appSettingsService!.settings;
      if (settings.notificationsEnabled && settings.notifyOnNewAdvert) {
        _notificationService.showAdvertNotification(
          contactName: contact.name,
          contactType: contact.typeLabelRaw,
          contactId: contact.publicKeyHex,
        );
      }
    }

    if (!_isLoadingContacts) {
      unawaited(_persistContacts());
    }
  }

  Future<void> _persistContacts() async {
    await _contactStore.saveContacts(_contacts);
  }

  Future<void> _persistDiscoveredContacts() async {
    await _discoveryContactStore.saveContacts(_discoveredContacts);
  }

  int _latestContactLastmod() {
    if (_contacts.isEmpty) return 0;
    var latest = 0;
    for (final contact in _contacts) {
      // prefer lastmod per spec, fallback to lastseen
      final source = contact.lastModified ?? contact.lastSeen;
      final seconds = source.millisecondsSinceEpoch ~/ 1000;
      if (seconds > latest) {
        latest = seconds;
      }
    }
    return latest;
  }

  bool _setContactLastMessageAt(int index, DateTime timestamp) {
    final contact = _contacts[index];
    if (contact.type != advTypeChat) return false;
    if (!timestamp.isAfter(contact.lastMessageAt)) return false;
    _contacts[index] = contact.copyWith(lastMessageAt: timestamp);
    return true;
  }

  void _updateContactLastMessageAt(
    String contactKeyHex,
    DateTime timestamp, {
    bool notify = false,
  }) {
    final index = _contacts.indexWhere((c) => c.publicKeyHex == contactKeyHex);
    if (index < 0) return;
    if (!_setContactLastMessageAt(index, timestamp)) return;
    unawaited(_persistContacts());
    if (notify) {
      notifyListeners();
    }
  }

  void _updateContactLastMessageAtByName(
    String senderName,
    DateTime timestamp, {
    Uint8List? pathBytes,
    int? pathHashWidth,
    bool notify = false,
  }) {
    final normalized = senderName.trim().toLowerCase();
    final hasName = normalized.isNotEmpty && normalized != 'unknown';
    var updated = false;
    var matchedByName = false;

    if (hasName) {
      for (var i = 0; i < _contacts.length; i++) {
        final contact = _contacts[i];
        if (contact.type != advTypeChat) continue;
        if (contact.name.trim().toLowerCase() == normalized) {
          matchedByName = true;
          updated = _setContactLastMessageAt(i, timestamp) || updated;
        }
      }
    }

    if (!matchedByName && pathBytes != null && pathBytes.isNotEmpty) {
      final matches = <int>[];
      for (var i = 0; i < _contacts.length; i++) {
        final contact = _contacts[i];
        if (contact.type != advTypeChat) continue;
        if (_pathMatchesContact(
          pathBytes,
          contact.publicKey,
          pathHashWidth: pathHashWidth,
        )) {
          matches.add(i);
        }
      }
      if (matches.length == 1) {
        updated = _setContactLastMessageAt(matches.first, timestamp) || updated;
      }
    }

    if (updated) {
      unawaited(_persistContacts());
      if (notify) {
        notifyListeners();
      }
    }
  }

  bool _pathMatchesContact(
    Uint8List pathBytes,
    Uint8List publicKey, {
    int? pathHashWidth,
  }) {
    final w = pathHashWidth ?? _pathHashByteWidth;
    if (pathBytes.isEmpty || publicKey.length < w) return false;
    for (int i = 0; i + w <= pathBytes.length; i += w) {
      final prefix = pathBytes.sublist(i, i + w);
      if (_matchesPrefix(publicKey, prefix)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _handleIncomingMessage(
    Uint8List frame, {
    bool alreadyAdvancedQueueSync = false,
    bool isUnknownSenderReplay = false,
  }) async {
    if (_selfPublicKey == null) return;

    // If we're syncing the queued messages, advance the queue immediately
    // before any potentially long async work (like translation/notifications).
    if (_isSyncingQueuedMessages && !alreadyAdvancedQueueSync) {
      _handleQueuedMessageReceived();
    }

    var message = _parseContactMessage(frame);

    // Unknown sender: the firmware has already dropped this message from its
    // offline queue, so hold it until the sender's CONTACT frame arrives
    // rather than re-parsing before the refresh has delivered anything.
    if (message == null && !isUnknownSenderReplay) {
      final senderPrefix = _extractSenderPrefix(frame);
      if (senderPrefix != null &&
          !_contacts.any((c) => _matchesPrefix(c.publicKey, senderPrefix))) {
        debugPrint('Message from unknown contact; holding until contacts load');
        _holdUnknownSenderMessage(frame);
        if (!_isLoadingContacts) {
          try {
            await refreshContactsSinceLastmod();
          } catch (e) {
            appLogger.warn(
              'Contact refresh for unknown sender failed: $e',
              tag: 'Connector',
            );
          }
        }
        return;
      }
    }

    if (message != null) {
      if (!message.isOutgoing) {
        _lastContactMsgRxTime = DateTime.now();
      }
      // Ignore messages from self (device hearing its own broadcast)
      // BUT allow repeated messages (pathLength indicates it went through repeater)
      if (_selfPublicKey != null &&
          message.senderKeyHex == pubKeyToHex(_selfPublicKey!) &&
          (message.pathLength == null || message.pathLength == 0)) {
        debugPrint('Ignoring direct message from self');
        return;
      }

      // MeshCore Open TAK: control DMs (e.g. VR3 voice fetch requests) are
      // consumed here and never shown in the chat or notified.
      if (!message.isOutgoing &&
          (voxControlTextInterceptor?.call(
                message.senderKeyHex,
                message.text,
              ) ??
              false)) {
        return;
      }

      final contact = _contacts.cast<Contact?>().firstWhere(
        (c) => c?.publicKeyHex == message!.senderKeyHex,
        orElse: () => null,
      );
      if (contact != null) {
        message = message.copyWith(
          pathLength: contact.pathLength < 0 ? -1 : contact.pathLength,
          pathBytes: contact.pathLength < 0 ? Uint8List(0) : contact.path,
        );
      }
      if (contact != null) {
        _updateContactLastMessageAt(contact.publicKeyHex, message.timestamp);
      }
      if (!message.isOutgoing) {
        final existing = _conversations[message.senderKeyHex];
        final incomingTimestamp = message.timestamp.millisecondsSinceEpoch;
        if (existing != null && existing.isNotEmpty) {
          final last = existing.last;
          if (!last.isOutgoing &&
              last.timestamp.millisecondsSinceEpoch == incomingTimestamp &&
              last.text == message.text) {
            return;
          }
        }
      }
      _addMessage(message.senderKeyHex, message);
      _maybeIncrementContactUnread(message);
      notifyListeners();
      if (!message.isOutgoing && !message.isCli) {
        voxIncomingTextObserver?.call(
          message.text,
          senderKeyHex: message.senderKeyHex,
          timestamp: message.timestamp,
        );
      }

      // Show notification for new incoming message (run async with translation)
      if (!message.isOutgoing &&
          !message.isCli &&
          _appSettingsService != null) {
        final settings = _appSettingsService!.settings;
        if (settings.notificationsEnabled && settings.notifyOnNewMessage) {
          final msg = message; // capture for closure
          final c = contact; // capture contact reference
          unawaited(() async {
            final translationResult = await translateContactMessage(
              msg.senderKeyHex,
              msg,
            );
            if (c?.type == advTypeChat) {
              final resolvedText =
                  (translationResult != null &&
                      translationResult.status ==
                          MessageTranslationStatus.completed &&
                      translationResult.translatedText.trim().isNotEmpty)
                  ? translationResult.translatedText.trim()
                  : msg.text.trim();
              await _notificationService.showMessageNotification(
                contactName: c?.name ?? 'Unknown',
                message: resolvedText,
                urlImagesEnabled:
                    c != null && isContactUrlImagesEnabled(c.publicKeyHex),
                contactId: msg.senderKeyHex,
                badgeCount: getTotalUnreadCount(),
              );
            } else if (c?.type == advTypeRoom) {
              final resolvedText =
                  (translationResult != null &&
                      translationResult.status ==
                          MessageTranslationStatus.completed &&
                      translationResult.translatedText.trim().isNotEmpty)
                  ? translationResult.translatedText.trim()
                  : msg.text.trim();
              await _notificationService.showMessageNotification(
                contactName: c?.name ?? 'Unknown Room',
                message: resolvedText,
                urlImagesEnabled:
                    c != null && isContactUrlImagesEnabled(c.publicKeyHex),
                contactId: msg.senderKeyHex,
                badgeCount: getTotalUnreadCount(),
              );
            }
          }());
        }
      }
    }
  }

  Message? _parseContactMessage(Uint8List frame) {
    if (frame.isEmpty) {
      appLogger.warn('Received empty frame, ignoring');
      return null;
    }
    final reader = BufferReader(frame);

    try {
      final code = reader.readByte();
      if (code != respCodeContactMsgRecv && code != respCodeContactMsgRecvV3) {
        appLogger.warn(
          'Unexpected message code: $code, expected contact message receive codes',
        );
        return null;
      }

      // Companion radio layout:
      // [code][snr?][res?][res?][prefix x6][path_len][txt_type][timestamp x4][extra?][text...]
      // double snr = 0;
      if (code == respCodeContactMsgRecvV3) {
        // Older firmware layout with SNR as a signed byte after the code
        // snr = reader.readInt8().toDouble() * 4; // SNR in dB, scaled by 4
        reader.skipBytes(1); // Skip SNR byte
        reader.skipBytes(2); // Skip reserved bytes
      }

      final senderPrefix = reader.readBytes(6);
      final pathLength = reader.readByte();
      final txtType = reader.readByte();
      final timestampRaw = reader.readUInt32LE();
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        timestampRaw * 1000,
      );

      // Companion frames carry the raw TXT_TYPE (0..3); legacy firmware sent
      // it shifted into the upper six bits like the over-the-air flags byte.
      final type = txtType <= _txtTypeCliCommand ? txtType : txtType >> 2;
      final isSigned = type == txtTypeSigned;
      final Uint8List? roomAuthorPrefix;
      if (isSigned) {
        // Room-server pushed posts use signed/plain contact messages where this
        // 4-byte "signature" field is actually the original author's pubkey
        // prefix. Keep it as metadata; the text starts after these bytes.
        roomAuthorPrefix = reader.readBytes(4);
      } else {
        roomAuthorPrefix = null;
      }

      final msgText = reader.readCString();

      final isPlain = type == txtTypePlain || isSigned;
      // TXT_TYPE_CLI_COMMAND is a remote CLI command the firmware did not run
      // (sender lacks remote-CLI permission); show it as CLI, never as chat.
      final isCli = type == txtTypeCliData || type == _txtTypeCliCommand;
      if (!isPlain && !isCli) {
        appLogger.warn('Unknown message type received: txtType=$txtType');
        return null;
      }

      if (msgText.isEmpty) {
        appLogger.warn('Received message with empty text, ignoring');
        return null;
      }
      var decodedText = isCli
          ? msgText
          : (Smaz.tryDecodePrefixed(msgText) ?? msgText);

      final contact = _contacts.cast<Contact?>().firstWhere(
        (c) => c != null && _matchesPrefix(c.publicKey, senderPrefix),
        orElse: () => null,
      );
      if (contact == null) {
        appLogger.warn(
          'Received message from unknown contact with prefix: ${senderPrefix.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join('')}',
        );
        return null;
      }

      // OTP: decrypt (and, for a chunk piece or ack, dispatch) in place,
      // once, right here — this Message object and its `text` flow into
      // every downstream render/notification/search call site unchanged,
      // so this is the only place this needs to happen. A chunk piece or
      // ack has nothing to show yet, so the whole incoming frame is
      // suppressed (return null) rather than turned into a visible message.
      if (!isCli) {
        // Pad sync-check control messages are sent in the clear (never OTP
        // ciphertext) and must never appear as a chat bubble — checked
        // before OTP dispatch so this works even when OTP isn't (or isn't
        // yet) enabled for this contact.
        if (_maybeHandleContactNack(contact, decodedText)) return null;
        if (_maybeHandleContactSyncMessage(contact, decodedText)) return null;
        final otpResult = _dispatchOtpContact(contact, decodedText);
        if (otpResult.handled) {
          if (otpResult.displayText == null) return null;
          decodedText = otpResult.displayText!;
        }
      }

      return Message(
        senderKey: contact.publicKey,
        text: decodedText,
        timestamp: timestamp,
        receivedAt: DateTime.now(),
        isOutgoing: false,
        isCli: isCli,
        status: MessageStatus.delivered,
        pathLength: pathLength == 0xFF ? null : (pathLength & 0x3F),
        pathBytes: Uint8List(0),
        fourByteRoomContactKey: roomAuthorPrefix,
      );
    } catch (e) {
      appLogger.warn('Error parsing contact direct message: $e');
      return null;
    }
  }

  bool _matchesPrefix(Uint8List fullKey, Uint8List prefix) {
    if (fullKey.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (fullKey[i] != prefix[i]) return false;
    }
    return true;
  }

  Uint8List? _extractSenderPrefix(Uint8List frame) {
    if (frame.isEmpty) return null;
    final code = frame[0];
    if (code != respCodeContactMsgRecv && code != respCodeContactMsgRecvV3) {
      return null;
    }

    final prefixOffset = code == respCodeContactMsgRecvV3 ? 4 : 1;
    const prefixLen = 6;

    if (frame.length < prefixOffset + prefixLen) return null;

    return frame.sublist(prefixOffset, prefixOffset + prefixLen);
  }

  void _ensureContactSmazSettingLoaded(String contactKeyHex) {
    if (_contactSmazEnabled.containsKey(contactKeyHex)) return;
    _contactSettingsStore.loadSmazEnabled(contactKeyHex).then((enabled) {
      if (_contactSmazEnabled[contactKeyHex] == enabled) return;
      _contactSmazEnabled[contactKeyHex] = enabled;
      notifyListeners();
    });
  }

  void _ensureContactCyr2LatSettingLoaded(String contactKeyHex) {
    if (_contactCyr2LatEnabled.containsKey(contactKeyHex)) return;
    _contactSettingsStore.loadCyr2LatEnabled(contactKeyHex).then((enabled) {
      if (_contactCyr2LatEnabled[contactKeyHex] == enabled) return;
      _contactCyr2LatEnabled[contactKeyHex] = enabled;
      notifyListeners();
    });
  }

  void _ensureContactUrlImagesSettingLoaded(String contactKeyHex) {
    if (_contactUrlImagesEnabled.containsKey(contactKeyHex)) return;
    _contactSettingsStore.loadUrlImagesEnabled(contactKeyHex).then((enabled) {
      if (_contactUrlImagesEnabled[contactKeyHex] == enabled) return;
      _contactUrlImagesEnabled[contactKeyHex] = enabled;
      notifyListeners();
    });
  }

  void _ensureContactCyr2LatProfileLoaded(String contactKeyHex) {
    if (_contactCyr2LatProfileId.containsKey(contactKeyHex)) return;
    _contactSettingsStore.loadCyr2LatProfileId(contactKeyHex).then((profileId) {
      if (_contactCyr2LatProfileId[contactKeyHex] == profileId) return;
      _contactCyr2LatProfileId[contactKeyHex] = profileId;
      notifyListeners();
    });
  }

  void _ensureChannelCyr2LatSettingLoaded(int channelIndex) {
    if (_channelCyr2LatEnabled.containsKey(channelIndex)) return;
    final channelId = _slotChannelIds[channelIndex];
    if (channelId == null) return;
    _channelSettingsStore.loadCyr2LatEnabled(channelId).then((enabled) {
      if (_channelCyr2LatEnabled[channelIndex] == enabled) return;
      _channelCyr2LatEnabled[channelIndex] = enabled;
      notifyListeners();
    });
  }

  void _ensureChannelCyr2LatProfileLoaded(int channelIndex) {
    if (_channelCyr2LatProfileId.containsKey(channelIndex)) return;
    final channelId = _slotChannelIds[channelIndex];
    if (channelId == null) return;
    _channelSettingsStore.loadCyr2LatProfileId(channelId).then((profileId) {
      if (_channelCyr2LatProfileId[channelIndex] == profileId) return;
      _channelCyr2LatProfileId[channelIndex] = profileId;
      notifyListeners();
    });
  }

  String? getChannelCyr2LatProfileId(int channelIndex) {
    _ensureChannelCyr2LatProfileLoaded(channelIndex);
    return _channelCyr2LatProfileId[channelIndex];
  }

  Future<void> setChannelCyr2LatProfileId(
    int channelIndex,
    String? profileId,
  ) async {
    if (_channelCyr2LatProfileId[channelIndex] == profileId) return;
    for (final slot in _slotsSharingChannel(channelIndex)) {
      _channelCyr2LatProfileId[slot] = profileId;
    }
    final channelId = _channelIdForSlot(channelIndex);
    if (channelId != null) {
      await _channelSettingsStore.saveCyr2LatProfileId(channelId, profileId);
    }
    notifyListeners();
  }

  String? getContactCyr2LatProfileId(String contactKeyHex) {
    _ensureContactCyr2LatProfileLoaded(contactKeyHex);
    return _contactCyr2LatProfileId[contactKeyHex];
  }

  Future<void> setContactCyr2LatProfileId(
    String contactKeyHex,
    String? profileId,
  ) async {
    if (_contactCyr2LatProfileId[contactKeyHex] == profileId) return;
    _contactCyr2LatProfileId[contactKeyHex] = profileId;
    await _contactSettingsStore.saveCyr2LatProfileId(contactKeyHex, profileId);
    notifyListeners();
  }

  /// Prepares contact outbound text by applying SMAZ encoding if enabled.
  /// This should be used to transform text before computing ACK hashes.
  String prepareContactOutboundText(Contact contact, String text) {
    final trimmed = text.trim();
    // There's no more "OTP1|" marker to spot ciphertext by (removed so the
    // wire format matches Lua's bare-hex payloads — see otp_service.dart).
    // Since OTP encryption always runs exactly once, at compose time,
    // before this function ever sees the text (see sendMessage/
    // sendChannelMessage), a hex-looking payload for a contact that has
    // OTP enabled IS that already-computed ciphertext — never run
    // Smaz/Cyr2Lat on it, both would corrupt it, and compressing random
    // bytes never helps anyway. A plaintext message that merely happens to
    // look hex-ish only takes this branch when OTP is enabled for this
    // contact, in which case it likely NEVER reaches here un-encrypted; the
    // narrow remaining case is a reaction (which sendMessage never
    // encrypts) that coincidentally looks like hex, where skipping Smaz is
    // a harmless missed optimization, not a correctness issue.
    final isStructuredPayload =
        trimmed.startsWith('g:') ||
        trimmed.startsWith('m:') ||
        trimmed.startsWith('V1|') ||
        OtpSyncService.looksLikeSyncMessage(trimmed) ||
        (isContactOtpEnabled(contact.publicKeyHex) &&
            OtpService.looksLikeCiphertextHex(trimmed));
    if (!isStructuredPayload) {
      if (isContactSmazEnabled(contact.publicKeyHex)) {
        return Smaz.encodeIfSmaller(text);
      } else if (isContactCyr2LatEnabled(contact.publicKeyHex)) {
        final profileId = getContactCyr2LatProfileId(contact.publicKeyHex);
        final profile = profileId != null && _appSettingsService != null
            ? _appSettingsService!.getCyr2LatProfileById(profileId)
            : null;
        if (profile != null) {
          Cyr2Lat.setCharMap(profile.charMap);
        } else {
          // Use global profile
          final globalProfile = _appSettingsService
              ?.getSelectedCyr2LatProfile();
          if (globalProfile != null) {
            Cyr2Lat.setCharMap(globalProfile.charMap);
          }
        }
        return Cyr2Lat.encode(text);
      }
    }
    return text;
  }

  String prepareChannelOutboundText(int channelIndex, String text) {
    final trimmed = text.trim();
    // See the comment in prepareContactOutboundText above — same reasoning,
    // channel-side.
    final isStructuredPayload =
        trimmed.startsWith('g:') ||
        trimmed.startsWith('m:') ||
        OtpSyncService.looksLikeSyncMessage(trimmed) ||
        // z2-framed channel ciphertext (see OtpChannelOffsetService) isn't
        // pure hex any more (it has the offset + a pipe ahead of the hex),
        // so it fails looksLikeCiphertextHex below and would otherwise fall
        // through to Smaz/Cyr2Lat, which corrupts it exactly like it would
        // corrupt raw ciphertext.
        OtpChannelOffsetService.looksLikeOffsetMessage(trimmed) ||
        (isChannelOtpEnabled(channelIndex) &&
            OtpService.looksLikeCiphertextHex(trimmed));
    if (!isStructuredPayload) {
      if (isChannelSmazEnabled(channelIndex)) {
        return Smaz.encodeIfSmaller(text);
      } else if (isChannelCyr2LatEnabled(channelIndex)) {
        final profileId = getChannelCyr2LatProfileId(channelIndex);
        final profile = profileId != null && _appSettingsService != null
            ? _appSettingsService!.getCyr2LatProfileById(profileId)
            : null;
        if (profile != null) {
          Cyr2Lat.setCharMap(profile.charMap);
        } else {
          // Use global profile
          final globalProfile = _appSettingsService
              ?.getSelectedCyr2LatProfile();
          if (globalProfile != null) {
            Cyr2Lat.setCharMap(globalProfile.charMap);
          }
        }
        return Cyr2Lat.encode(text);
      }
    }
    return text;
  }

  // Falls back to the cached channel list, which stays populated while a
  // channel refresh has temporarily emptied _channels.
  String _channelDisplayName(int channelIndex) =>
      _findChannelByIndex(channelIndex)?.muteKey ?? 'Channel $channelIndex';

  void _maybeNotifyChannelMessage(
    ChannelMessage message, {
    String? channelName,
    TranslationResult? translationResult,
  }) {
    if (message.isOutgoing || _appSettingsService == null) return;
    final channelIndex = message.channelIndex;
    if (channelIndex == null) return;

    final settings = _appSettingsService!.settings;
    if (!settings.notificationsEnabled || !settings.notifyOnNewChannelMessage) {
      return;
    }

    final label = channelName ?? _channelDisplayName(channelIndex);
    if (_appSettingsService!.isChannelMuted(label)) return;

    // Reuse translation result only if completed and non-empty; else use original text
    final resolvedText =
        (translationResult != null &&
            translationResult.status == MessageTranslationStatus.completed &&
            translationResult.translatedText.trim().isNotEmpty)
        ? translationResult.translatedText.trim()
        : message.text.trim();
    unawaited(() async {
      await _notificationService.showChannelMessageNotification(
        channelName: label,
        senderName: message.senderName,
        message: resolvedText,
        urlImagesEnabled: isChannelUrlImagesEnabled(channelIndex),
        channelIndex: message.channelIndex,
        badgeCount: getTotalUnreadCount(),
      );
    }());
  }

  /// Handles RESP_CODE_CHANNEL_DATA_RECV (GRP_DATA). Frames whose dataType is
  /// not 0xAE1C — or that arrive before an [ImageChunkTransport] is installed —
  /// are ignored without disturbing any other behaviour.
  void _handleIncomingChannelData(Uint8List frame) {
    // Anchor the post-RX backoff for our own next channel send, exactly as
    // _handleIncomingChannelMessage does.
    _lastChannelMsgRxTime = DateTime.now();
    final outcome = _imageTransport?.handleFrame(frame);
    if (outcome == null) return; // Not an AEIC image chunk.
    _onImageChunk?.call(outcome);
    notifyListeners();
  }

  void _handleIncomingChannelMessage(Uint8List frame) async {
    // If we're syncing the queued messages, advance the queue immediately
    // before any potentially long async work (like translation/notifications).
    if (_isSyncingQueuedMessages) {
      _handleQueuedMessageReceived();
    }
    var parsed = ChannelMessage.fromFrame(frame);
    if (parsed != null && parsed.channelIndex != null) {
      if (_shouldDropSelfChannelMessage(
        parsed.senderName,
        parsed.pathBytes,
        channelIndex: parsed.channelIndex,
      )) {
        return;
      }
      // Pad sync-check control messages (see the note in
      // _parseContactMessage) — checked before OTP dispatch, same reasoning.
      if (_maybeHandleChannelNack(parsed.channelIndex!, parsed.text)) {
        return;
      }
      if (_maybeHandleChannelSyncMessage(
        parsed.channelIndex!,
        parsed.senderName,
        parsed.text,
      )) {
        _lastChannelMsgRxTime = DateTime.now();
        _handleQueuedMessageReceived();
        return;
      }
      // OTP: decrypt (and, for a chunk piece or ack, dispatch) in place,
      // once, right here, same reasoning as the contact-message path in
      // _parseContactMessage above. A chunk piece or ack has nothing to
      // show yet, so this whole incoming frame is suppressed.
      final otpResult = _dispatchOtpChannel(
        parsed.channelIndex!,
        parsed.senderName,
        parsed.text,
      );
      if (otpResult.handled) {
        if (otpResult.displayText == null) {
          _lastChannelMsgRxTime = DateTime.now();
          _handleQueuedMessageReceived();
          return;
        }
        parsed = parsed.copyWith(text: otpResult.displayText);
      }
      _lastChannelMsgRxTime = DateTime.now();
      final contentHash = _computeContentHash(
        parsed.channelIndex!,
        parsed.timestamp.millisecondsSinceEpoch ~/ 1000,
        '${parsed.senderName}: ${parsed.text}',
      );
      final message = parsed.copyWith(packetHash: contentHash);
      _updateContactLastMessageAtByName(
        message.senderName,
        message.timestamp,
        pathBytes: message.pathBytes,
        pathHashWidth: message.pathHashWidth,
      );
      final isNew = _addChannelMessage(message.channelIndex!, message);
      _maybeIncrementChannelUnread(message, isNew: isNew);
      notifyListeners();
      if (isNew && !message.isOutgoing) {
        voxIncomingTextObserver?.call(
          message.text,
          senderName: message.senderName,
          channelIndex: message.channelIndex,
          timestamp: message.timestamp,
        );
      }
      if (isNew && !message.isOutgoing) {
        final msg = message; // capture for closure
        unawaited(() async {
          final translationResult = await translateChannelMessage(
            msg.channelIndex!,
            msg,
          );
          _maybeNotifyChannelMessage(msg, translationResult: translationResult);
        }());
      }
    }
  }

  void _handleLogRxData(Uint8List frame) async {
    if (frame.length < 4) return;
    try {
      final reader = BufferReader(frame);
      reader.skipBytes(3); // Skip header

      final raw = reader.readRemainingBytes();
      final packet = _parseRawPacket(raw);
      if (packet == null || packet.payloadType != _payloadTypeGroupText) return;

      final payload = BufferReader(packet.payload);
      final channelHash = payload.readByte();
      final encrypted = Uint8List.fromList(payload.readRemainingBytes());

      // Use cached channels as fallback if live channels not yet loaded
      final channelsToSearch = _channels.isNotEmpty
          ? _channels
          : _cachedChannels;
      for (final channel in channelsToSearch) {
        if (channel.isEmpty) continue;
        final hash = _computeChannelHash(channel.psk);
        if (hash != channelHash) continue;
        try {
          final decryptedBytes = _decryptPayload(channel.psk, encrypted);
          if (decryptedBytes == null || decryptedBytes.length < 6) continue;
          final decrypted = BufferReader(decryptedBytes);

          final timestampRaw = decrypted.readUInt32LE();
          final txtType = decrypted.readByte();
          if ((txtType >> 2) != 0) {
            return;
          }

          final text = decrypted.readCString();
          final parsed = _splitSenderText(text);

          // Self-check MUST happen before any OTP decrypt attempt below:
          // our own outgoing channel messages can loop back through this
          // raw RX log path, and OTP decrypt is stateful (it advances the
          // pad offset) — decrypting our own echo here would double-consume
          // pad that was already spent when the message was sent, corrupting
          // sync. (This also matches how _handleIncomingChannelMessage
          // already orders its self-check before its OTP handling.)
          if (_shouldDropSelfChannelMessage(
            parsed.senderName,
            packet.pathBytes,
            channelIndex: channel.index,
          )) {
            return;
          }

          var decodedText = Smaz.tryDecodePrefixed(parsed.text) ?? parsed.text;

          // Pad sync-check control messages — same reasoning as the
          // _handleIncomingChannelMessage hook; this is the second,
          // independent channel-receive path, so it needs the same check.
          if (_maybeHandleChannelNack(channel.index, decodedText)) {
            return;
          }
          if (_maybeHandleChannelSyncMessage(
            channel.index,
            parsed.senderName,
            decodedText,
          )) {
            return;
          }

          // OTP: this is the second, independent channel-receive path (raw
          // RX log data, decoded straight from the channel PSK rather than
          // via RESP_CODE_CHANNEL_MSG_RECV) — needs the same decrypt/dispatch
          // hook as _handleIncomingChannelMessage, since either path can be
          // the one that actually delivers a given message. A chunk piece
          // or ack has nothing to show yet, so bail out without adding a
          // visible message.
          final otpResult = _dispatchOtpChannel(
            channel.index,
            parsed.senderName,
            decodedText,
          );
          if (otpResult.handled) {
            if (otpResult.displayText == null) return;
            decodedText = otpResult.displayText!;
          }

          // File the message under the channel this PSK is now in, which
          // may not be the slot the channel list says.
          final channelId = channel.storageId;
          final slot = _channelMapConfirmed && channelId != null
              ? _slotForChannelId(channelId)
              : null;
          if (slot == null) {
            debugPrint(
              '[RxLog] No confirmed slot holds channel $channelId; dropped',
            );
            return;
          }

          final pktHash = computePacketHash(packet.payloadType, packet.payload);

          final message = ChannelMessage(
            senderKey: null,
            senderName: parsed.senderName,
            text: decodedText,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestampRaw * 1000),
            receivedAt: DateTime.now(),
            isOutgoing: false,
            status: ChannelMessageStatus.sent,
            pathLength: packet.isFlood ? packet.hopCount : 0,
            pathHashWidth: packet.pathHashWidth,
            pathBytes: packet.pathBytes,
            channelIndex: slot,
            region: _resolveTransportRegion(packet),
            packetHash: pktHash,
          );

          _updateContactLastMessageAtByName(
            parsed.senderName,
            message.timestamp,
            pathBytes: message.pathBytes,
            pathHashWidth: message.pathHashWidth,
          );
          final isNew = _addChannelMessage(slot, message);
          _maybeIncrementChannelUnread(message, isNew: isNew);
          notifyListeners();
          if (isNew && !message.isOutgoing) {
            voxIncomingTextObserver?.call(
              message.text,
              senderName: message.senderName,
              channelIndex: channel.index,
              timestamp: message.timestamp,
            );
          }
          if (isNew) {
            // Run translation + notification asynchronously to avoid blocking
            unawaited(() async {
              final translationResult = await translateChannelMessage(
                slot,
                message,
              );
              _maybeNotifyChannelMessage(
                message,
                channelName: channel.muteKey,
                translationResult: translationResult,
              );
            }());
          }
          return;
        } catch (e) {
          appLogger.warn('Decryption failed for channel ${channel.index}: $e');
        }
      }
    } catch (e) {
      appLogger.warn('Error handling log RX data frame: $e');
    }
  }

  void _handleMessageSent(Uint8List frame) {
    // Frame format from C++:
    // [0] = RESP_CODE_SENT
    // [1] = is_flood (1 or 0)
    // [2-5] = expected_ack_hash (uint32)
    // [6-9] = estimated_timeout_ms (uint32)

    try {
      final reader = BufferReader(frame);
      reader.skipBytes(2); //Skip code and is_flood
      final ackHash = reader.readUInt32LE();
      final timeoutMs = reader.readUInt32LE();

      if (_handleRepeaterCommandSent(ackHash, timeoutMs)) {
        return;
      }

      final retryService = _retryService;
      if (retryService != null &&
          retryService.updateMessageFromSent(ackHash, timeoutMs)) {
        return;
      }
    } catch (e) {
      appLogger.warn('Error handling message sent frame: $e');
      // Fallback to old behavior
      for (var messages in _conversations.values) {
        for (int i = messages.length - 1; i >= 0; i--) {
          if (messages[i].isOutgoing &&
              messages[i].status == MessageStatus.pending) {
            messages[i] = messages[i].copyWith(status: MessageStatus.sent);
            notifyListeners();
            return;
          }
        }
      }
    }
  }

  /// Fills in the real ciphertext (and any other passed fields) on a
  /// channel message that was shown as a bubble before it was actually
  /// encrypted — see the channel-send jitter delay in sendChannelMessage.
  /// Unlike _markPendingChannelMessageSentById, this doesn't require the
  /// message to still be `pending` (it always is at this point, but this
  /// helper's job is narrower: just the text swap, not a status change).
  bool _fillJitteredChannelMessageText(
    int channelIndex,
    String messageId,
    String cipherHex,
  ) {
    final channelMessages = _channelMessages[channelIndex];
    if (channelMessages == null) return false;
    for (int i = channelMessages.length - 1; i >= 0; i--) {
      final message = channelMessages[i];
      if (message.messageId != messageId) continue;
      channelMessages[i] = message.copyWith(text: cipherHex);
      unawaited(_saveChannelMessages(channelIndex, channelMessages));
      notifyListeners();
      return true;
    }
    return false;
  }

  bool _markPendingChannelMessageSentById(String messageId) {
    for (final entry in _channelMessages.entries) {
      final channelMessages = entry.value;
      for (int i = channelMessages.length - 1; i >= 0; i--) {
        final message = channelMessages[i];
        if (message.messageId != messageId) {
          continue;
        }
        if (!message.isOutgoing ||
            message.status != ChannelMessageStatus.pending) {
          return false;
        }
        channelMessages[i] = message.copyWith(
          status: ChannelMessageStatus.sent,
        );
        _pendingChannelSentQueue.remove(messageId);
        unawaited(_saveChannelMessages(entry.key, channelMessages));
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void _markPendingChannelMessageFailedById(String messageId) {
    for (final entry in _channelMessages.entries) {
      final channelMessages = entry.value;
      for (int i = channelMessages.length - 1; i >= 0; i--) {
        final message = channelMessages[i];
        if (message.messageId != messageId) {
          continue;
        }
        if (!message.isOutgoing ||
            message.status != ChannelMessageStatus.pending) {
          return;
        }
        channelMessages[i] = message.copyWith(
          status: ChannelMessageStatus.failed,
        );
        unawaited(_saveChannelMessages(entry.key, channelMessages));
        notifyListeners();
        return;
      }
    }
  }

  void _handleOk() {
    final pendingAck = _pendingGenericAckQueue.takeOk();
    if (pendingAck == null ||
        pendingAck.commandCode != cmdSendChannelTxtMsg ||
        pendingAck.channelSendQueueId == null) {
      return;
    }

    final queueId = pendingAck.channelSendQueueId!;
    _pendingChannelSentQueue.remove(queueId);
    if (_isReactionSendQueueId(queueId)) {
      return;
    }
    _markPendingChannelMessageSentById(queueId);
  }

  void _handleSendConfirmed(Uint8List frame) {
    // Frame format from C++:
    // [0] = PUSH_CODE_SEND_CONFIRMED
    // [1-4] = ack_hash (uint32)
    // [5-8] = trip_time_ms (uint32)

    try {
      final reader = BufferReader(frame);
      reader.skipBytes(1); // Skip code
      final ackHash = reader.readUInt32LE();
      final tripTimeMs = reader.readUInt32LE();

      if (_handleRepeaterCommandAck(ackHash, tripTimeMs)) {
        return;
      }

      // Handle ACK in retry service
      if (_retryService != null) {
        _retryService!.handleAckReceived(ackHash, tripTimeMs);
      }
    } catch (e) {
      appLogger.warn('Error handling send confirmed frame: $e');
      // Fallback to old behavior
      for (var messages in _conversations.values) {
        for (int i = messages.length - 1; i >= 0; i--) {
          if (messages[i].isOutgoing &&
              messages[i].status == MessageStatus.sent) {
            messages[i] = messages[i].copyWith(status: MessageStatus.delivered);
            notifyListeners();
            return;
          }
        }
      }
    }
  }

  bool _handleRepeaterCommandSent(int ackHash, int timeoutMs) {
    final ackHashHex = ackHashToHex(ackHash);
    final entry = _pendingRepeaterAcks[ackHashHex];
    if (entry == null) return false;

    entry.timeout?.cancel();
    final effectiveTimeoutMs = timeoutMs > 0
        ? timeoutMs
        : calculateTimeout(
            pathLength: entry.pathLength,
            messageBytes: entry.messageBytes,
          );
    entry.timeout = Timer(Duration(milliseconds: effectiveTimeoutMs), () {
      _recordPathResult(entry.contactKeyHex, entry.selection, false, null);
      _pendingRepeaterAcks.remove(ackHashHex);
    });
    return true;
  }

  bool _handleRepeaterCommandAck(int ackHash, int tripTimeMs) {
    final ackHashHex = ackHashToHex(ackHash);
    final entry = _pendingRepeaterAcks.remove(ackHashHex);
    if (entry == null) return false;
    entry.timeout?.cancel();
    _recordPathResult(entry.contactKeyHex, entry.selection, true, tripTimeMs);
    return true;
  }

  void _handleChannelInfo(Uint8List frame) {
    final channel = Channel.fromFrame(frame);
    if (channel == null) return;
    _unconfirmedChannelSlots.remove(channel.index);

    debugPrint(
      '[ChannelSync] Received channel ${channel.index}: ${channel.isEmpty ? "empty" : channel.name}',
    );

    // Preserve unread count from the cached copy of the same channel (same
    // PSK), wherever it sat; a reused slot starts with no unread.
    final cachedChannel =
        _cachedChannels.cast<Channel?>().firstWhere(
          (c) => c?.index == channel.index && listEquals(c?.psk, channel.psk),
          orElse: () => null,
        ) ??
        _cachedChannels.cast<Channel?>().firstWhere(
          (c) => listEquals(c?.psk, channel.psk),
          orElse: () => null,
        );
    if (cachedChannel != null) {
      channel.unreadCount = cachedChannel.unreadCount;
    }

    // If we're syncing and this is the channel we're waiting for
    if (_isSyncingChannels && _channelSyncInFlight) {
      if (channel.index == _nextChannelIndexToRequest) {
        // Expected channel arrived
        _channelSyncTimeout?.cancel();
        _channelSyncInFlight = false;
        _channelSyncRetries = 0; // Reset retry counter on success

        // Only add non-empty channels
        if (!channel.isEmpty) {
          _channels.add(channel);
        }

        // Move to next channel
        _nextChannelIndexToRequest++;
        notifyListeners();
        unawaited(_requestNextChannel());
        return;
      } else {
        // Received a channel but not the one we're waiting for
        // This can happen if device sends unsolicited updates
        debugPrint(
          '[ChannelSync] Received unexpected channel ${channel.index}, expected $_nextChannelIndexToRequest',
        );
        // Add it anyway but don't advance sync
        if (!channel.isEmpty &&
            !_channels.any((c) => c.index == channel.index)) {
          _channels.add(channel);
        }
        return;
      }
    }

    // Not syncing, or received unsolicited update - handle normally
    if (!channel.isEmpty) {
      // Update or add channel
      final existingIndex = _channels.indexWhere(
        (c) => c.index == channel.index,
      );
      if (existingIndex >= 0) {
        // Preserve unread count from the existing channel if unchanged
        if (listEquals(_channels[existingIndex].psk, channel.psk)) {
          channel.unreadCount = _channels[existingIndex].unreadCount;
        }
        _channels[existingIndex] = channel;
      } else {
        _channels.add(channel);
      }
    }

    // Only notify if not in loading state
    if (!_isLoadingChannels) {
      _applyChannelOrder();
      notifyListeners();
    }
  }

  void _applyChannelOrder() {
    if (_channelOrder.isEmpty) {
      _channels.sort((a, b) => a.index.compareTo(b.index));
      return;
    }

    final orderIndex = <String, int>{};
    for (int i = 0; i < _channelOrder.length; i++) {
      orderIndex.putIfAbsent(_channelOrder[i], () => i);
    }

    _channels.sort((a, b) {
      final aPos = orderIndex[a.storageId];
      final bPos = orderIndex[b.storageId];
      if (aPos != null && bPos != null) return aPos.compareTo(bPos);
      if (aPos != null) return -1;
      if (bPos != null) return 1;
      return a.index.compareTo(b.index);
    });
  }

  /// Saves the channel order given as slot indexes; it is stored by channel
  /// ID so it follows channels that move between slots.
  Future<void> setChannelOrder(List<int> order) async {
    final ids = <String>[];
    for (final slot in order) {
      final id = _findChannelByIndex(slot)?.storageId;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    _channelOrder = ids;
    _applyChannelOrder();
    notifyListeners();
    await _channelOrderStore.saveChannelOrder(_channelOrder);
  }

  bool _shouldTrackUnreadForContactKey(String contactKeyHex) {
    final contact = _contacts.cast<Contact?>().firstWhere(
      (c) => c?.publicKeyHex == contactKeyHex,
      orElse: () => null,
    );
    if (contact == null) return true;
    return contact.type != advTypeRepeater;
  }

  Channel? _findChannelByIndex(int index) {
    return _channels.cast<Channel?>().firstWhere(
          (c) => c?.index == index,
          orElse: () => null,
        ) ??
        _cachedChannels.cast<Channel?>().firstWhere(
          (c) => c?.index == index,
          orElse: () => null,
        );
  }

  void _maybeIncrementChannelUnread(
    ChannelMessage message, {
    required bool isNew,
  }) {
    if (!isNew || message.isOutgoing) {
      _appDebugLogService?.info(
        'Skip unread increment: isNew=$isNew, isOutgoing=${message.isOutgoing}',
        tag: 'Unread',
      );
      return;
    }
    final channelIndex = message.channelIndex;
    if (channelIndex == null) {
      _appDebugLogService?.info(
        'Skip unread increment: channelIndex is null',
        tag: 'Unread',
      );
      return;
    }
    // Don't increment if user is viewing this channel
    if (_activeChannelIndex == channelIndex) {
      _appDebugLogService?.info(
        'Skip unread increment: channel $channelIndex is active',
        tag: 'Unread',
      );
      return;
    }

    final channel = _findChannelByIndex(channelIndex);
    if (channel != null) {
      channel.unreadCount++;
      _cachedChannelsUnreadTotal++;
      _appDebugLogService?.info(
        'Channel ${channel.name.isNotEmpty ? channel.name : channelIndex} unread count incremented to ${channel.unreadCount}',
        tag: 'Unread',
      );
      unawaited(
        _channelStore.saveChannels(
          _channels.isNotEmpty ? _channels : _cachedChannels,
        ),
      );
    } else {
      _appDebugLogService?.info(
        'Channel $channelIndex not found in _channels (${_channels.length}) or _cachedChannels (${_cachedChannels.length})',
        tag: 'Unread',
      );
    }
  }

  void _maybeIncrementContactUnread(Message message) {
    if (message.isOutgoing || message.isCli) {
      _appDebugLogService?.info(
        'Skip contact unread increment: isOutgoing=${message.isOutgoing}, isCli=${message.isCli}',
        tag: 'Unread',
      );
      return;
    }
    final contactKey = message.senderKeyHex;
    if (!_shouldTrackUnreadForContactKey(contactKey)) {
      _appDebugLogService?.info(
        'Skip contact unread increment: should not track for $contactKey',
        tag: 'Unread',
      );
      return;
    }
    // Don't increment if user is viewing this contact
    if (_activeContactKey == contactKey) {
      _appDebugLogService?.info(
        'Skip contact unread increment: contact $contactKey is active',
        tag: 'Unread',
      );
      return;
    }

    final currentCount = _contactUnreadCount[contactKey] ?? 0;
    _contactUnreadCount[contactKey] = currentCount + 1;
    _cachedContactsUnreadTotal++;
    _appDebugLogService?.info(
      'Contact $contactKey unread count incremented to ${currentCount + 1}',
      tag: 'Unread',
    );
    _unreadStore.saveContactUnreadCount(
      Map<String, int>.from(_contactUnreadCount),
    );
  }

  void _addMessage(String pubKeyHex, Message message) {
    _conversations.putIfAbsent(pubKeyHex, () => []);
    final messages = _conversations[pubKeyHex]!;

    // Parse reaction info
    final reactionInfo = Message.parseReaction(message.text);
    if (reactionInfo != null) {
      // Check if we've already processed this exact reaction
      _processedContactReactions.putIfAbsent(pubKeyHex, () => {});
      reactionInfo.senderName = _resolveContactSenderName(message, null, false);
      final reactionIdentifier = reactionInfo.identifier();
      final isDuplicate = _processedContactReactions[pubKeyHex]!.contains(
        reactionIdentifier,
      );
      if (isDuplicate) return;

      // New reaction - process it
      // For hashing and dup checking, we use null for sender names in
      // normal 1:1 chats. This way if we and they have different ideas
      // about what their name is, reactions still work. But for reaction
      // reports, we want to know who sent what, rather than infer it later,
      // so we'll add it to the reactionInfo before storing it.
      reactionInfo.senderName ??= message.isOutgoing
          ? selfName
          : getContactByPubKeyHex(pubKeyHex)?.name ?? '???';
      final reactionApplied = _processContactReaction(
        messages,
        reactionInfo,
        pubKeyHex,
      );
      if (reactionApplied) {
        appLogger.info('Adding reaction, id: $reactionIdentifier');
        _messageStore.saveMessages(pubKeyHex, messages);

        // Mark as processed
        _processedContactReactions[pubKeyHex]!.add(reactionIdentifier);

        notifyListeners();
        return; // Don't add reaction as a visible message
      }

      // Looks like a reaction, but didn't match any message we have.
      // for reactions matching our own format, because those are not very
      // informative on their own, but the MC1 format is useful even if
      // in raw form, so we'll let those through.
      appLogger.info('No match for reaction, id: $reactionIdentifier');
      if (reactionInfo.hashType == HashType.ours) return;
    }

    messages.add(message);
    if (messages.length > _messageWindowSize) {
      final trimCount = messages.length - _messageWindowSize;
      _messageStore.archive(pubKeyHex, messages.sublist(0, trimCount));
      messages.removeRange(0, trimCount);
    }
    _messageStore.saveMessages(pubKeyHex, messages);
    notifyListeners();
  }

  bool _processContactReaction(
    List<Message> messages,
    ReactionInfo reactionInfo,
    String contactPubKeyHex,
  ) {
    final contact = getContactByPubKeyHex(contactPubKeyHex);
    final isRoomServer = contact?.type == advTypeRoom;

    return ReactionHelper.applyReaction<Message>(
      messages: messages,
      reactionInfo: reactionInfo,
      // Incoming reactions in 1:1: match against outgoing messages only
      shouldSkip: (msg) => isRoomServer != true && !msg.isOutgoing,
      getTimestampSecs: (msg) => msg.timestamp.millisecondsSinceEpoch ~/ 1000,
      getSenderName: (msg) =>
          _resolveContactSenderName(msg, contact, isRoomServer == true),
      getMessageText: (msg) => msg.text,
      getReactions: (msg) => msg.reactions,
      updateMessage: (i, reactions) {
        messages[i] = messages[i].copyWith(reactions: reactions);
      },
    );
  }

  void _processOutgoingContactReaction(
    List<Message> messages,
    ReactionInfo reactionInfo,
    Contact contact,
  ) {
    final isRoomServer = contact.type == advTypeRoom;

    ReactionHelper.applyReaction<Message>(
      messages: messages,
      reactionInfo: reactionInfo,
      // Outgoing reactions in 1:1: match against incoming messages
      shouldSkip: (msg) => !isRoomServer && msg.isOutgoing,
      getTimestampSecs: (msg) => msg.timestamp.millisecondsSinceEpoch ~/ 1000,
      getSenderName: (msg) =>
          _resolveContactSenderName(msg, contact, isRoomServer),
      getMessageText: (msg) => msg.text,
      getReactions: (msg) => msg.reactions,
      updateMessage: (i, reactions) {
        messages[i] = messages[i].copyWith(reactions: reactions);
      },
    );
  }

  void _setReactionStatus(
    String pubKeyHex,
    ReactionInfo reactionInfo,
    MessageStatus status,
  ) {
    final messages = _conversations[pubKeyHex];
    if (messages == null) return;
    final contact = getContactByPubKeyHex(pubKeyHex);
    final isRoomServer = contact?.type == advTypeRoom;
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      final timestampSecs = msg.timestamp.millisecondsSinceEpoch ~/ 1000;
      final msgHash = ReactionHelper.computeReactionHash(
        timestampSecs,
        _resolveContactSenderName(msg, contact, isRoomServer == true),
        msg.text,
      );
      if (msgHash == reactionInfo.targetHash) {
        final statuses = Map<String, MessageStatus>.from(msg.reactionStatuses);
        statuses[reactionInfo.emoji] = status;
        messages[i] = msg.copyWith(reactionStatuses: statuses);
        break;
      }
    }
  }

  String? _resolveContactSenderName(
    Message msg,
    Contact? contact,
    bool isRoomServer,
  ) {
    if (!isRoomServer) return null;
    if (!msg.isOutgoing) {
      // Saved contacts first, then discovery-only nodes, so reaction matching
      // resolves the author's name even when they haven't been saved.
      final senderContact = allContactsUnfiltered.cast<Contact?>().firstWhere(
        (c) =>
            c != null &&
            _matchesPrefix(c.publicKey, msg.fourByteRoomContactKey),
        orElse: () => null,
      );
      return senderContact?.name;
    }
    return selfName;
  }

  _RawPacket? _parseRawPacket(Uint8List raw) {
    try {
      final reader = BufferReader(raw);
      final header = reader.readByte();
      final routeType = header & _phRouteMask;
      final hasTransport =
          routeType == _routeTransportFlood ||
          routeType == _routeTransportDirect;
      final transportCodes = hasTransport ? reader.readBytes(4) : null;
      final pathLenRaw = reader.readByte();
      final pathByteLen = decodePathByteLen(pathLenRaw);
      final pathBytes = reader.readBytes(pathByteLen);
      final payload = reader.readBytes(reader.remaining);

      return _RawPacket(
        header: header,
        routeType: routeType,
        payloadType: (header >> _phTypeShift) & _phTypeMask,
        payloadVer: (header >> _phVerShift) & _phVerMask,
        pathLenRaw: pathLenRaw,
        transportCodes: transportCodes,
        pathBytes: pathBytes,
        payload: payload,
      );
    } catch (e) {
      appLogger.warn('Error parsing raw packet: $e');
      return null;
    }
  }

  int? _slotForChannelId(String channelId) =>
      _lowestSlotFor(_slotChannelIds, channelId);

  int _computeChannelHash(Uint8List psk) {
    final digest = crypto.sha256.convert(psk).bytes;
    return digest[0];
  }

  String? _resolveTransportRegion(_RawPacket packet) {
    if (packet.routeType != _routeTransportFlood ||
        packet.transportCodes == null) {
      return null;
    }

    // `foo` and `#foo` share a scope key, so dedupe without the prefix or a
    // region listed both ways would always look ambiguous.
    final names = <String>{
      for (final region in [
        ...RegionStore().loadRegions(),
        ..._channelRegions.values,
        _defaultRegion,
      ])
        region.startsWith('#') ? region.substring(1) : region,
    }.where((region) => region.trim().isNotEmpty && region != kUnscopedRegion);
    final keys = <String, Uint8List>{
      for (final name in names) name: floodScopeKeyForRegion(name),
    };
    // The radio's default scope key may not be derived from its name (another
    // client may have set it), so match on the stored key itself.
    final radioDefaultName = _defaultFloodScopeName;
    final radioDefaultKey = _defaultFloodScopeKey;
    if (radioDefaultName != null && radioDefaultKey != null) {
      final name = radioDefaultName.startsWith('#')
          ? radioDefaultName.substring(1)
          : radioDefaultName;
      final derived = keys[name];
      if (derived == null || !_pathsEqual(derived, radioDefaultKey)) {
        keys[name] = radioDefaultKey;
      }
    }
    final candidates = keys.keys.toList()..sort();
    String? match;
    for (final region in candidates) {
      final code = floodTransportCode(
        scopeKey: keys[region]!,
        payloadType: packet.payloadType,
        payload: packet.payload,
      );
      if (!_pathsEqual(code, packet.transportCodes!.sublist(0, 2))) continue;
      if (match != null) return null;
      match = region;
    }
    return match;
  }

  /// Content-based dedup hash for sync queue messages (no raw payload available).
  /// Prefixed with 'c:' to avoid collisions with packet hashes.
  String _computeContentHash(
    int channelIdx,
    int timestampSecs,
    String fullText,
  ) {
    final textBytes = utf8.encode(fullText);
    final input = Uint8List(5 + textBytes.length);
    input[0] = channelIdx;
    input[1] = timestampSecs & 0xFF;
    input[2] = (timestampSecs >> 8) & 0xFF;
    input[3] = (timestampSecs >> 16) & 0xFF;
    input[4] = (timestampSecs >> 24) & 0xFF;
    input.setRange(5, 5 + textBytes.length, textBytes);
    final digest = crypto.sha256.convert(input).bytes;
    return 'c:${digest.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Uint8List? _decryptPayload(Uint8List psk, Uint8List encrypted) {
    if (encrypted.length <= _cipherMacSize) return null;
    final mac = encrypted.sublist(0, _cipherMacSize);
    final cipherText = encrypted.sublist(_cipherMacSize);

    final key32 = Uint8List(32);
    final copyLen = psk.length < 32 ? psk.length : 32;
    key32.setRange(0, copyLen, psk);

    final hmac = crypto.Hmac(crypto.sha256, key32).convert(cipherText).bytes;
    if (hmac[0] != mac[0] || hmac[1] != mac[1]) {
      return null;
    }

    if (cipherText.isEmpty || cipherText.length % 16 != 0) return null;
    final key16 = Uint8List(16);
    final keyLen = psk.length < 16 ? psk.length : 16;
    key16.setRange(0, keyLen, psk);

    final cipher = ECBBlockCipher(AESEngine());
    cipher.init(false, KeyParameter(key16));
    final out = Uint8List(cipherText.length);
    for (var i = 0; i < cipherText.length; i += 16) {
      cipher.processBlock(cipherText, i, out, i);
    }
    return out;
  }

  _ParsedText _splitSenderText(String text) {
    final colonIndex = text.indexOf(':');
    if (colonIndex > 0 && colonIndex < text.length - 1 && colonIndex < 50) {
      final potentialSender = text.substring(0, colonIndex);
      if (RegExp(r'[:\[\]]').hasMatch(potentialSender)) {
        return _ParsedText(senderName: 'Unknown', text: text);
      }
      final offset =
          (colonIndex + 1 < text.length && text[colonIndex + 1] == ' ')
          ? colonIndex + 2
          : colonIndex + 1;
      return _ParsedText(
        senderName: potentialSender,
        text: text.substring(offset),
      );
    }
    return _ParsedText(senderName: 'Unknown', text: text);
  }

  bool _addChannelMessage(int slot, ChannelMessage message) {
    final channelIndex = _canonicalSlot(slot);
    _channelMessages.putIfAbsent(channelIndex, () => []);
    final messages = _channelMessages[channelIndex]!;

    // Parse reaction info
    final reactionInfo = message.parseReaction();
    if (reactionInfo != null) {
      // Check if we've already processed this exact reaction
      _processedChannelReactions.putIfAbsent(channelIndex, () => {});
      final reactionIdentifier = reactionInfo.identifier();

      final isDuplicate = _processedChannelReactions[channelIndex]!.contains(
        reactionIdentifier,
      );

      if (isDuplicate) return false;

      // New reaction - process it
      final reactionApplied = _processReaction(messages, reactionInfo);
      if (reactionApplied) {
        appLogger.info('Adding channel reaction, id: $reactionIdentifier');
        // Save updated messages
        _saveChannelMessages(channelIndex, messages);

        // Mark as processed
        _processedChannelReactions[channelIndex]!.add(reactionIdentifier);
        return false; // Don't add reaction as a visible message
      }
      // Looks like a reaction, but didn't match any message we have.
      // Old behavior is to silently drop these. We'll continue doing that
      // for reactions matching our own format, because those are not very
      // informative on their own, but the MC1 format is useful even if
      // in raw form, so we'll let those through.
      appLogger.info('No match for reaction, id: $reactionIdentifier');
      if (reactionInfo.hashType == HashType.ours) return false;
    }

    // Parse reply info from message text
    final replyInfo = ChannelMessage.parseReplyMention(message.text);
    ChannelMessage processedMessage = message;

    if (replyInfo != null) {
      // Outgoing replies already carry the selected target. The wire format
      // only names the sender, so incoming replies fall back to that
      // sender's most recent message.
      final hasReplyTarget = message.replyToMessageId != null;
      final originalMessage = hasReplyTarget
          ? null
          : _findMessageBySender(messages, replyInfo.mentionedNode);

      if (hasReplyTarget || originalMessage != null) {
        // Create new message with reply metadata
        processedMessage = ChannelMessage(
          senderKey: message.senderKey,
          senderName: message.senderName,
          text: replyInfo.actualMessage,
          originalText: message.originalText,
          translatedText: message.translatedText,
          translatedLanguageCode: message.translatedLanguageCode,
          translationStatus: message.translationStatus,
          translationModelId: message.translationModelId,
          timestamp: message.timestamp,
          receivedAt: message.receivedAt,
          isOutgoing: message.isOutgoing,
          status: message.status,
          repeats: message.repeats,
          repeatCount: message.repeatCount,
          pathLength: message.pathLength,
          pathHashWidth: message.pathHashWidth,
          pathBytes: message.pathBytes,
          pathVariants: message.pathVariants,
          channelIndex: message.channelIndex,
          region: message.region,
          messageId: message.messageId,
          replyToMessageId:
              message.replyToMessageId ?? originalMessage!.messageId,
          replyToSenderName:
              message.replyToSenderName ?? originalMessage!.senderName,
          replyToText: message.replyToText ?? originalMessage!.text,
        );
      }
    }

    final existingIndex = _findChannelRepeatIndex(messages, processedMessage);
    var isNew = true;
    if (existingIndex >= 0) {
      isNew = false;
      final existing = messages[existingIndex];
      final mergedPathBytes = _selectPreferredPathBytes(
        existing.pathBytes,
        processedMessage.pathBytes,
      );
      final mergedPathVariants = _mergePathVariants(
        existing.pathVariants,
        processedMessage.pathVariants,
      );
      final hashWidth =
          (existing.pathHashWidth ?? processedMessage.pathHashWidth ?? 1)
              .clamp(1, 3)
              .toInt();
      final mergedPathLength = _mergePathLength(
        existing.pathLength,
        processedMessage.pathLength,
        mergedPathBytes.length ~/ hashWidth,
      );
      final newRepeatCount = existing.repeatCount + 1;
      final promotedFromPending =
          newRepeatCount == 1 &&
          existing.status == ChannelMessageStatus.pending;
      messages[existingIndex] = existing.copyWith(
        repeatCount: newRepeatCount,
        pathLength: mergedPathLength,
        pathHashWidth: existing.pathHashWidth ?? processedMessage.pathHashWidth,
        pathBytes: mergedPathBytes,
        pathVariants: mergedPathVariants,
        region: existing.region ?? processedMessage.region,
        packetHash: existing.packetHash ?? processedMessage.packetHash,
        // Mark as sent when first repeat is heard
        status: promotedFromPending
            ? ChannelMessageStatus.sent
            : existing.status,
      );
      if (promotedFromPending) {
        _pendingChannelSentQueue.remove(existing.messageId);
      }
    } else {
      messages.add(processedMessage);
    }

    // Save to persistent storage
    _saveChannelMessages(channelIndex, messages);
    return isNew;
  }

  ChannelMessage? _findMessageBySender(
    List<ChannelMessage> messages,
    String mentionedNode,
  ) {
    // Search backwards for most recent message from this sender
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].senderName == mentionedNode && !messages[i].isOutgoing) {
        return messages[i];
      }
    }
    return null;
  }

  bool _processReaction(
    List<ChannelMessage> messages,
    ReactionInfo reactionInfo,
  ) {
    return ReactionHelper.applyReaction<ChannelMessage>(
      messages: messages,
      reactionInfo: reactionInfo,
      shouldSkip: (_) => false,
      getTimestampSecs: (msg) => msg.timestamp.millisecondsSinceEpoch ~/ 1000,
      getSenderName: (msg) => msg.senderName,
      getMessageText: (msg) => msg.text,
      getReactions: (msg) => msg.reactions,
      updateMessage: (i, reactions) {
        messages[i] = messages[i].copyWith(reactions: reactions);
        notifyListeners();
      },
    );
  }

  int _findChannelRepeatIndex(
    List<ChannelMessage> messages,
    ChannelMessage incoming,
  ) {
    // First pass: match by packet hash (exact dedup)
    final incomingHash = incoming.packetHash;
    if (incomingHash != null) {
      for (int i = messages.length - 1; i >= 0; i--) {
        final existingHash = messages[i].packetHash;
        if (existingHash != null && existingHash == incomingHash) {
          return i;
        }
      }
    }
    // Second pass: heuristic fallback (outgoing echo, old messages without hash)
    int? selfEchoFallback;
    for (int i = messages.length - 1; i >= 0; i--) {
      final existing = messages[i];
      if (!_isChannelRepeat(existing, incoming)) continue;
      if (!existing.isOutgoing) return i;
      // Our messages sent within one second share a timestamp. Skip any
      // already tied to a different packet, and prefer the one whose text
      // matches; the text can differ (reply prefix, cyr2lat), so otherwise
      // fall back to the newest.
      final existingHash = existing.packetHash;
      if (existingHash != null &&
          incomingHash != null &&
          existingHash != incomingHash) {
        continue;
      }
      if (_sameChannelText(existing.text, incoming.text)) return i;
      selfEchoFallback ??= i;
    }
    return selfEchoFallback ?? -1;
  }

  bool _sameChannelText(String a, String b) {
    String strip(String text) =>
        ChannelMessage.parseReplyMention(text)?.actualMessage ?? text;
    return a == b || strip(a) == strip(b);
  }

  bool _isChannelRepeat(ChannelMessage existing, ChannelMessage incoming) {
    // A message we are sending is always new, even if its text matches an
    // earlier one.
    if (incoming.isOutgoing) return false;

    // Every copy of one packet carries the sender's timestamp, and for our own
    // messages that timestamp is the one we put in the send frame. Separate
    // sends of the same text therefore differ here, while true repeats match.
    final sameSecond =
        existing.timestamp.millisecondsSinceEpoch ~/ 1000 ==
        incoming.timestamp.millisecondsSinceEpoch ~/ 1000;
    if (!sameSecond) return false;

    // Our own echo can read differently from what we stored (a reply keeps its
    // @[name] prefix, cyr2lat transliterates), so the timestamp decides.
    if (existing.isOutgoing) {
      return incoming.senderName == (_selfName ?? 'Me');
    }
    return existing.senderName == incoming.senderName &&
        existing.text == incoming.text;
  }

  bool _shouldDropSelfChannelMessage(
    String senderName,
    Uint8List pathBytes, {
    int? channelIndex,
  }) {
    final trimmed = senderName.trim();
    if (trimmed.isEmpty) return false;

    final selfName = _selfName?.trim();
    if (selfName == null || selfName.isEmpty) return false;

    // If sender name doesn't match, keep the message
    if (trimmed != selfName) return false;

    // Name matches - this is from self.
    //
    // For an OTP-enabled channel, always drop it, hop count or not. A
    // self-echo repeated back through another node still carries the exact
    // ciphertext we already burned pad on when we sent it; letting it reach
    // _dispatchOtpChannel would consume ANOTHER slice of the (forward-only,
    // shared-sequential) channel pad against our own message, permanently
    // desyncing us from every other participant even though nothing is
    // actually wrong. There's no legitimate reason two different senders on
    // the same OTP channel would share our exact self-name, so this can't
    // drop someone else's real message.
    if (channelIndex != null &&
        getChannelOtpPad(channelIndex)?.enabled == true) {
      return true;
    }

    // Plaintext channel: keep the old, non-OTP behavior. Drop only if
    // pathBytes is empty (direct broadcast); keep it if pathBytes has data
    // (repeated through another node), since that's useful confirmation the
    // message actually propagated.
    return pathBytes.isEmpty;
  }

  Uint8List _selectPreferredPathBytes(Uint8List existing, Uint8List incoming) {
    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;
    if (incoming.length > existing.length) return incoming;
    return existing;
  }

  int? _mergePathLength(int? existing, int? incoming, int observedLength) {
    if (existing == null) {
      if (incoming == null) return observedLength > 0 ? observedLength : null;
      return incoming >= observedLength ? incoming : observedLength;
    }
    if (incoming == null) {
      return existing >= observedLength ? existing : observedLength;
    }
    final merged = existing >= incoming ? existing : incoming;
    return merged >= observedLength ? merged : observedLength;
  }

  List<Uint8List> _mergePathVariants(
    List<Uint8List> existing,
    List<Uint8List> incoming,
  ) {
    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;

    final merged = <Uint8List>[...existing];
    for (final candidate in incoming) {
      var already = false;
      for (final current in merged) {
        if (_pathsEqual(current, candidate)) {
          already = true;
          break;
        }
      }
      if (!already && candidate.isNotEmpty) {
        merged.add(candidate);
      }
    }
    return merged;
  }

  bool _pathsEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _handleDisconnection() {
    _resetLinkSessionState();

    _notifySubscription?.cancel();
    _notifySubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;

    _device = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    // Preserve deviceId and displayName for UI display during reconnection
    // They're only cleared on manual disconnect via disconnect() method.
    // Conversations are kept for an auto-reconnect to the same radio;
    // _handleSelfInfo drops them if a different radio answers.

    _setState(MeshCoreConnectionState.disconnected);
    _scheduleReconnect();
  }

  /// Per-link state shared by a full disconnect and a dropped BLE link:
  /// polling timers, radio stats, battery and pending protocol replies.
  void _resetLinkSessionState() {
    _persistedStateLoadedKey = null;
    _defaultFloodScopeName = null;
    _defaultFloodScopeKey = null;
    _stopBatteryPolling();
    _stopOtpAutoSyncPolling();
    _stopWaitingQueueTicker();
    _stopGpsLocationPolling();
    _stopRadioStatsPolling();
    _latestRadioStats = null;
    radioStatsNotifier.value = null;
    _prevTotalAirSecs = 0;
    _airtimeBumpStopwatch?.stop();
    _airtimeBumpStopwatch = null;

    for (final entry in _pendingRepeaterAcks.values) {
      entry.timeout?.cancel();
    }
    _pendingRepeaterAcks.clear();

    _selfPublicKey = null;
    _awaitingSelfInfo = false;
    _selfInfoRetryTimer?.cancel();
    _selfInfoRetryTimer = null;
    _hasReceivedDeviceInfo = false;
    _batteryMillivolts = null;
    _batteryRequested = false;
    _pathHashByteWidth = 1;
    _maxContacts = _defaultMaxContacts;
    _maxChannels = _defaultMaxChannels;
    _resetSyncProgressState();
    _pendingChannelSentQueue.clear();
    _pendingGenericAckQueue.clear();
    _reactionSendQueueSequence = 0;
    _retryService?.failAllPending();
  }

  /// Drops the conversation and channel history held in memory, so a
  /// different radio never shows or persists another radio's messages.
  void _clearSessionMessageState() {
    _conversations.clear();
    _loadedConversationKeys.clear();
    _channelMessages.clear();
    _processedChannelReactions.clear();
    _processedContactReactions.clear();
    _channelHopChecks.clear();
    _channelHopShortfalls.clear();
    _messageStore.forgetArchive();
    _channelMessageStore.forgetArchive();
    _slotChannelIds.clear();
    _channelMapConfirmed = false;
    _messageStateOwnerKey = null;
    _persistedStateLoadedKey = null;
  }

  String _nextReactionSendQueueId() {
    _reactionSendQueueSequence++;
    return '$_reactionSendQueuePrefix$_reactionSendQueueSequence';
  }

  bool _isReactionSendQueueId(String queueId) {
    return queueId.startsWith(_reactionSendQueuePrefix);
  }

  Map<String, String> _parseKeyValueString(String input) {
    final result = <String, String>{};

    // Split on commas first – empty entries are ignored.
    for (final pair in input.split(',')) {
      final trimmedPair = pair.trim();
      if (trimmedPair.isEmpty) continue;

      // Each pair must contain exactly one ':'.
      final separatorIndex = trimmedPair.indexOf(':');
      if (separatorIndex == -1) continue; // malformed, skip

      final key = trimmedPair.substring(0, separatorIndex).trim();
      final value = trimmedPair.substring(separatorIndex + 1).trim();

      if (key.isNotEmpty) {
        result[key] = value;
      }
    }

    return result;
  }

  /// Parse PUSH_CODE_LOGIN_SUCCESS (0x85) frame and stash the repeater's
  /// reported clock. Frame layout (firmware companion_radio/MyMesh.cpp:678+):
  ///   [0]=0x85, [1]=permissions, [2..7]=pubkey prefix (6 bytes),
  ///   [8..11]=repeater RTC unix seconds (LE), [12]=ACL perms, [13]=fw level
  /// The timestamp is only present in the v7+ "new login response" — older
  /// firmware emits a shorter frame that we silently skip.
  void _handleLoginSuccess(Uint8List frame) {
    if (frame.length < 12) return;
    final prefix = pubKeyToHex(frame.sublist(2, 8));
    final ts = ByteData.sublistView(frame, 8, 12).getUint32(0, Endian.little);
    if (ts == 0) return;
    _repeaterLoginClocks[prefix] = DateTime.fromMillisecondsSinceEpoch(
      ts * 1000,
      isUtc: true,
    );
    notifyListeners();
  }

  void _handleCustomVars(Uint8List frame) {
    final buf = BufferReader(frame.sublist(1));
    try {
      _currentCustomVars = _parseKeyValueString(buf.readCString());
      // Reflect current GPS state in the polling timer (handles initial
      // device state on connect as well as external CLI/USB toggles).
      if (_currentCustomVars?['gps'] == '1') {
        _startGpsLocationPolling();
      } else {
        _stopGpsLocationPolling();
      }
    } catch (e) {
      appLogger.warn('Malformed custom vars frame: $e', tag: 'Connector');
    }
  }

  void _setState(MeshCoreConnectionState newState) {
    if (_disposed) return;
    if (_state != newState) {
      _state = newState;
      if (newState == MeshCoreConnectionState.connected) {
        if (_appSettingsService?.settings.notificationsEnabled ?? false) {
          unawaited(_notificationService.requestPermissionsOnce());
        }
      }
      notifyListeners();
    }
  }

  void markNotifyDirty() {
    if (_disposed) return;
    if (_notifyListenersDirty && _notifyListenersTimer != null) {
      return;
    }

    _notifyListenersDirty = true;
    _notifyListenersTimer ??= Timer(
      _notifyListenersDebounce,
      _flushBatchedNotify,
    );
  }

  void _flushBatchedNotify() {
    _notifyListenersTimer = null;
    if (!_notifyListenersDirty) {
      return;
    }

    _notifyListenersDirty = false;
    super.notifyListeners();

    if (_notifyListenersDirty && _notifyListenersTimer == null) {
      _notifyListenersTimer = Timer(
        _notifyListenersDebounce,
        _flushBatchedNotify,
      );
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    markNotifyDirty();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _connectionSubscription?.cancel();
    _usbFrameSubscription?.cancel();
    _notifySubscription?.cancel();
    _notificationReplySubscription?.cancel();
    _notificationService.releaseReplyPort();
    _notifyListenersTimer?.cancel();
    _reconnectTimer?.cancel();
    _batteryPollTimer?.cancel();
    _otpAutoSyncPollTimer?.cancel();
    _waitingQueueTickTimer?.cancel();
    _gpsLocationPollTimer?.cancel();
    _radioStatsPollTimer?.cancel();
    for (final timer in _otpSyncTimeoutTimers.values) {
      timer.cancel();
    }
    for (final timer in _otpResyncTimers.values) {
      timer.cancel();
    }
    for (final timer in _otpBackoffTimers.values) {
      timer.cancel();
    }
    radioStatsNotifier.dispose();
    _receivedFramesController.close();
    _contactsFullController.close();
    _usbManager.dispose();
    _tcpConnector.dispose();
    _reviewFrameSubscription?.cancel();
    _reviewRadio?.dispose();

    // Flush pending unread writes before disposal
    _unreadStore.flush();

    super.dispose();
  }

  void _handleRxData(Uint8List frame) {
    final packet = BufferReader(frame);
    try {
      packet.skipBytes(1); // Skip frame type byte
      final snr = packet.readInt8() / 4.0;
      packet.skipBytes(1); // Skip RSSI byte
      //final rssi = packet.readByte();
      final header = packet.readByte();
      final routeType = header & 0x03;
      final payloadType = (header >> 2) & 0x0F;
      if (routeType == _routeTransportFlood ||
          routeType == _routeTransportDirect) {
        packet.skipBytes(4); // Skip transport-specific bytes
      }
      //final payloadVer = (header >> 6) & 0x03;
      final pathLenRaw = packet.readByte();
      final pathByteLen = decodePathByteLen(pathLenRaw);
      final pathHashWidth = decodePathHashWidth(pathLenRaw);
      final pathBytes = packet.readBytes(pathByteLen);
      final payload = packet.readBytes(packet.remaining);

      final rawPacket = frame.sublist(3);
      switch (payloadType) {
        case payloadTypeADVERT:
          _handlePayloadAdvertReceived(
            rawPacket,
            payload,
            pathBytes,
            pathHashWidth,
            routeType,
            snr,
          );
          break;
        default:
      }
    } catch (e) {
      appLogger.warn('Malformed RX frame: $e', tag: 'Connector');
      return;
    }
  }

  void importContact(Uint8List frame) {
    final packet = BufferReader(frame);
    int payloadType = 0;
    Uint8List pathBytes = Uint8List(0);
    int pathHashWidth = 1;
    try {
      packet.skipBytes(1); // Skip frame type byte
      packet.skipBytes(1); // Skip SNR byte
      packet.skipBytes(1); // Skip RSSI byte
      final header = packet.readByte();
      final routeType = header & 0x03;
      payloadType = (header >> 2) & 0x0F;
      if (routeType == _routeTransportFlood ||
          routeType == _routeTransportDirect) {
        packet.skipBytes(4); // Skip transport-specific bytes
      }
      //final payloadVer = (header >> 6) & 0x03;
      final pathLenRaw = packet.readByte();
      final pathByteLen = decodePathByteLen(pathLenRaw);
      pathHashWidth = decodePathHashWidth(pathLenRaw);
      pathBytes = packet.readBytes(pathByteLen);
    } catch (e) {
      appLogger.warn('Malformed RX frame: $e', tag: 'Connector');
      return;
    }
    double? latitude;
    double? longitude;
    String name = '';
    Uint8List publicKey = Uint8List(0);
    int type = 0;
    int timestamp = 0;
    bool hasLocation = false;
    bool hasName = false;
    if (payloadType != payloadTypeADVERT) {
      appLogger.warn('Unexpected payload type: $payloadType', tag: 'Connector');
      return;
    }
    try {
      publicKey = packet.readBytes(32);
      timestamp = packet.readInt32LE();
      //TODO add signature verification
      packet.skipBytes(64); // Skip signature for now
      final flags = packet.readByte();
      type = flags & 0x0F;
      hasLocation = (flags & 0x10) != 0;
      // For future use:
      //final hasFeature1 = (flags & 0x20) != 0;
      //final hasFeature2 = (flags & 0x40) != 0;
      hasName = (flags & 0x80) != 0;
      if (hasLocation && packet.remaining >= 8) {
        latitude = packet.readInt32LE() / 1e6;
        longitude = packet.readInt32LE() / 1e6;
      }
      if (hasName && packet.remaining > 0) {
        name = packet.readCString();
      }
    } catch (e) {
      appLogger.warn('Malformed advert frame: $e', tag: 'Connector');
      return;
    }

    importDiscoveredContact(
      Contact(
        rawPacket: frame,
        publicKey: publicKey,
        name: name,
        type: type,
        pathLength: pathBytes.isEmpty
            ? -1
            : (pathBytes.length ~/ pathHashWidth),
        // Store hop order reversed for easier outgoing messages; keep bytes
        // inside each multi-byte hop in their original order.
        path: _reversePathByHop(pathBytes, pathHashWidth),
        pathHashWidth: pathHashWidth,
        latitude: latitude,
        longitude: longitude,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      ),
    );
  }

  bool hasValidLocation(double? latitude, double? longitude) {
    const double epsilon = 1e-6;
    final lat = latitude ?? 0.0;
    final lon = longitude ?? 0.0;
    return (lat.abs() > epsilon || lon.abs() > epsilon) &&
        lat >= -90.0 &&
        lat <= 90.0 &&
        lon >= -180.0 &&
        lon <= 180.0;
  }

  void _handlePayloadAdvertReceived(
    Uint8List rawPacket,
    Uint8List payload,
    Uint8List path,
    int pathHashWidth,
    int routeType,
    double snr,
  ) {
    final advert = BufferReader(payload);
    double? latitude;
    double? longitude;
    String name = '';
    String contactKeyHex = '';
    Uint8List publicKey = Uint8List(0);
    int type = 0;
    int timestamp = 0;
    bool hasLocation = false;
    bool hasName = false;
    try {
      publicKey = advert.readBytes(32);
      contactKeyHex = publicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      timestamp = advert.readInt32LE();
      //TODO add signature verification
      advert.skipBytes(64); // Skip signature for now
      final flags = advert.readByte();
      type = flags & 0x0F;
      hasLocation = (flags & 0x10) != 0;
      // For future use:
      //final hasFeature1 = (flags & 0x20) != 0;
      //final hasFeature2 = (flags & 0x40) != 0;
      hasName = (flags & 0x80) != 0;
      if (hasLocation && advert.remaining >= 8) {
        latitude = advert.readInt32LE() / 1e6;
        longitude = advert.readInt32LE() / 1e6;
      }
      // Validate location values if present
      hasLocation = hasValidLocation(latitude, longitude);

      if (hasName && advert.remaining > 0) {
        name = advert.readCString();
      }
    } catch (e) {
      appLogger.warn('Malformed advert frame: $e', tag: 'Connector');
      return;
    }

    //We ignore our own adverts
    if (listEquals(publicKey, _selfPublicKey)) {
      return;
    }

    // Check if this is a new contact
    final isNewContact = !_knownContactKeys.contains(contactKeyHex);

    if (isNewContact) {
      final newContact = Contact(
        rawPacket: rawPacket,
        publicKey: publicKey,
        name: name,
        type: type,
        pathLength: path.isEmpty ? -1 : (path.length ~/ pathHashWidth),
        // Store hop order reversed for easier outgoing messages; keep bytes
        // inside each multi-byte hop in their original order.
        path: _reversePathByHop(path, pathHashWidth),
        pathHashWidth: pathHashWidth,
        latitude: latitude,
        longitude: longitude,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      );
      // The firmware decides whether to store it: PUSH_CODE_ADVERT (then
      // GET_CONTACT_BY_KEY) adds it to _contacts and notifies.
      final mayAutoAdd =
          (_autoAddUsers && type == advTypeChat) ||
          (_autoAddRepeaters && type == advTypeRepeater) ||
          (_autoAddRoomServers && type == advTypeRoom) ||
          (_autoAddSensors && type == advTypeSensor);
      _handleDiscovery(newContact, rawPacket, noNotify: mayAutoAdd);
      _updateDirectRepeater(
        newContact,
        snr,
        path,
        pathHashWidth: pathHashWidth,
      );
      return;
    }

    final existingIndex = _contacts.indexWhere(
      (c) => c.publicKeyHex == contactKeyHex,
    );

    if (existingIndex >= 0) {
      final existing = _contacts[existingIndex];
      final mergedLastMessageAt = existing.lastMessageAt.isAfter(DateTime.now())
          ? DateTime.now()
          : existing.lastMessageAt;

      appLogger.info(
        'Refreshing contact ${existing.name}: devicePath=${existing.pathLength}, existingOverride=${existing.pathOverride}',
        tag: 'Connector',
      );

      // CRITICAL: Preserve user's path override when contact is refreshed from device
      _contacts[existingIndex] = existing.copyWith(
        latitude: hasLocation ? latitude : existing.latitude,
        longitude: hasLocation ? longitude : existing.longitude,
        name: hasName ? name : existing.name,
        path: _reversePathByHop(path, pathHashWidth),
        pathHashWidth: pathHashWidth,
        pathLength: path.isEmpty ? -1 : (path.length ~/ pathHashWidth),
        lastMessageAt: mergedLastMessageAt,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
        pathOverride: existing.pathOverride, // Preserve user's path choice
        pathOverrideBytes: existing.pathOverrideBytes,
      );

      // Add path to history if we have a valid path
      if (_pathHistoryService != null &&
          _contacts[existingIndex].pathLength >= 0) {
        _pathHistoryService!.handlePathUpdated(
          _contacts[existingIndex],
          initialWeight: _initialRouteWeight,
        );
      }

      _updateDirectRepeater(
        _contacts[existingIndex],
        snr,
        path,
        pathHashWidth: pathHashWidth,
      );

      appLogger.info(
        'After merge: pathOverride=${_contacts[existingIndex].pathOverride}, devicePath=${_contacts[existingIndex].pathLength}',
        tag: 'Connector',
      );
    }
  }

  void _updateDirectRepeater(
    Contact contact,
    double snr,
    Uint8List path, {
    required int pathHashWidth,
  }) {
    final hashWidth = pathHashWidth.clamp(1, 4).toInt();
    if (path.isNotEmpty && path.length < hashWidth) {
      return;
    }
    final pathStartIndex = path.isNotEmpty ? path.length - hashWidth : 0;
    final publicKeyPrefixEnd = math
        .min(hashWidth, contact.publicKey.length)
        .toInt();
    final pubkeyPrefix = path.isNotEmpty
        ? path.sublist(pathStartIndex)
        : contact.publicKey.sublist(0, publicKeyPrefixEnd);
    final contactKeyHex = _resolveDirectRepeaterContactKeyHex(
      contact,
      pubkeyPrefix,
      path.isEmpty,
    );
    final knownRepeaters = contactKeyHex == null
        ? _directRepeaters
              .where(
                (r) =>
                    r.contactKeyHex != null &&
                    _contactKeyMatchesPrefix(r.contactKeyHex!, pubkeyPrefix),
              )
              .toList()
        : const <DirectRepeater>[];
    final knownRepeater = knownRepeaters.length == 1
        ? knownRepeaters.first
        : null;
    final effectiveContactKeyHex =
        contactKeyHex ?? knownRepeater?.contactKeyHex;

    _directRepeaters.removeWhere((r) => r.isStale());

    //We can use adverts from chat and sensor nodes, but only if the advert has a path to get the last hop.
    if ((contact.type == advTypeChat || contact.type == advTypeSensor) &&
        path.isEmpty) {
      notifyListeners();
      return;
    }

    final isTracked = _directRepeaters.where((r) {
      if (knownRepeater != null) {
        return identical(r, knownRepeater);
      }
      if (effectiveContactKeyHex != null) {
        return r.contactKeyHex == effectiveContactKeyHex ||
            (r.contactKeyHex == null &&
                _contactKeyMatchesPrefix(
                  effectiveContactKeyHex,
                  r.pubkeyPrefix,
                ));
      }
      if (r.contactKeyHex == null &&
          r.pathHashWidth == hashWidth &&
          r.matchesPrefix(pubkeyPrefix)) {
        return true;
      }
      return false;
    }).toList();

    final sortedRepeaters = List<DirectRepeater>.from(_directRepeaters)
      ..sort((a, b) => b.snr.compareTo(a.snr));
    final weakestRepeater = sortedRepeaters.isNotEmpty
        ? sortedRepeaters.last
        : null;

    if (_directRepeaters.length >= 5 &&
        weakestRepeater != null &&
        isTracked.isEmpty) {
      _directRepeaters.remove(weakestRepeater);
    }

    if (isTracked.isNotEmpty) {
      final repeater = isTracked.first;
      repeater.update(
        snr,
        pubkeyPrefix: pubkeyPrefix,
        pathHashWidth: hashWidth,
        contactKeyHex: effectiveContactKeyHex,
      );
      if (effectiveContactKeyHex != null) {
        _directRepeaters.removeWhere(
          (r) =>
              !identical(r, repeater) &&
              (r.contactKeyHex == effectiveContactKeyHex ||
                  (r.contactKeyHex == null &&
                      _contactKeyMatchesPrefix(
                        effectiveContactKeyHex,
                        r.pubkeyPrefix,
                      ))),
        );
      }
    } else if (_directRepeaters.length < 5) {
      _directRepeaters.add(
        DirectRepeater(
          pubkeyPrefix: pubkeyPrefix,
          pathHashWidth: hashWidth,
          contactKeyHex: effectiveContactKeyHex,
          snr: snr,
        ),
      );
    }
    notifyListeners();
  }

  String? _resolveDirectRepeaterContactKeyHex(
    Contact contact,
    List<int> pubkeyPrefix,
    bool pathIsEmpty,
  ) {
    if (pathIsEmpty &&
        (contact.type == advTypeRepeater || contact.type == advTypeRoom)) {
      return contact.publicKeyHex;
    }

    final prefixMatches = allContacts
        .where(
          (c) =>
              (c.type == advTypeRepeater || c.type == advTypeRoom) &&
              _contactKeyMatchesPrefix(c.publicKeyHex, pubkeyPrefix),
        )
        .toList();
    if (prefixMatches.length == 1) {
      return prefixMatches.first.publicKeyHex;
    }

    return null;
  }

  bool _contactKeyMatchesPrefix(String contactKeyHex, List<int> pubkeyPrefix) {
    // Normalize both sides to upper-case hex to avoid case-sensitive mismatches.
    final normalizedPrefixHex = pubkeyPrefix
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final normalizedContactKeyHex = contactKeyHex.toUpperCase();
    return normalizedContactKeyHex.startsWith(normalizedPrefixHex);
  }

  void _handleAutoAddConfig(Uint8List frame) {
    final reader = BufferReader(frame);
    try {
      reader.skipBytes(1); // Skip the response code byte
      final flags = reader.readByte();
      _autoAddUsers = (flags & autoAddChatFlag) != 0;
      _autoAddRepeaters = (flags & autoAddRepeaterFlag) != 0;
      _autoAddRoomServers = (flags & autoAddRoomServerFlag) != 0;
      _autoAddSensors = (flags & autoAddSensorFlag) != 0;
      _overwriteOldest = (flags & autoAddOverwriteOldestFlag) != 0;
      _autoAddMaxHops = frame.length > 2 ? frame[2] : null;
    } catch (e) {
      appLogger.error('Failed to parse auto-add config: $e', tag: 'Connector');
    }
  }

  void _handleDiscovery(
    Contact contact,
    Uint8List rawPacket, {
    bool noNotify = false,
    bool addActive = false,
  }) {
    appLogger.info('Discovered new contact: ${contact.name}', tag: 'Connector');

    final existingIndex = _discoveredContacts.indexWhere(
      (c) => c.publicKeyHex == contact.publicKeyHex,
    );

    // Update existing contact
    if (existingIndex >= 0) {
      _discoveredContacts[existingIndex] = _discoveredContacts[existingIndex]
          .copyWith(
            rawPacket: rawPacket,
            name: contact.name,
            type: contact.type,
            pathLength: contact.pathLength,
            path: contact.path,
            pathHashWidth: contact.pathHashWidth,
            latitude: contact.latitude,
            longitude: contact.longitude,
            lastSeen: contact.lastSeen,
            flags: 0,
            isActive: addActive,
          );
      notifyListeners();
      unawaited(_persistDiscoveredContacts());
      return;
    }

    final disContact = Contact(
      rawPacket: rawPacket,
      publicKey: contact.publicKey,
      name: contact.name,
      type: contact.type,
      pathLength: contact.pathLength,
      path: contact.path,
      pathHashWidth: contact.pathHashWidth,
      latitude: contact.latitude,
      longitude: contact.longitude,
      lastSeen: contact.lastSeen,
      lastMessageAt: contact.lastMessageAt,
      isActive: addActive,
      flags: 0,
    );

    if (_evictDiscoveredContactsEnabled) {
      while (_discoveredContacts.length >= maxDiscoveredContacts) {
        _evictStalestDiscoveredContact();
      }
    }
    _discoveredContacts.add(disContact);

    unawaited(_persistDiscoveredContacts());

    // Show notification for new contact (advertisement)
    if (_appSettingsService != null && !noNotify) {
      final settings = _appSettingsService!.settings;
      if (settings.notificationsEnabled && settings.notifyOnNewAdvert) {
        _notificationService.showAdvertNotification(
          contactName: contact.name,
          contactType: contact.typeLabelRaw,
          contactId: contact.publicKeyHex,
        );
      }
    }
  }

  void _evictStalestDiscoveredContact() {
    if (_discoveredContacts.isEmpty) return;
    var stalestIndex = 0;
    for (int i = 1; i < _discoveredContacts.length; i++) {
      if (_discoveredContacts[i].lastSeen.isBefore(
        _discoveredContacts[stalestIndex].lastSeen,
      )) {
        stalestIndex = i;
      }
    }
    _discoveredContacts.removeAt(stalestIndex);
  }

  void removeAllDiscoveredContacts() {
    _discoveredContacts.clear();
    unawaited(_persistDiscoveredContacts());
    notifyListeners();
  }

  void clearMessagesForContact(Contact contact) {
    final contactKeyHex = contact.publicKeyHex;
    final messages = _conversations[contactKeyHex];
    if (messages == null) return;
    messages.clear();
    // Clear storage too, not just the in-memory window.
    unawaited(_messageStore.clearMessages(contactKeyHex));
    markContactRead(contactKeyHex);
    notifyListeners();
  }

  void clearMessagesForChannel(int channelIndex) {
    _channelMessages[_canonicalSlot(channelIndex)]?.clear();
    // Clear storage too, even when nothing of it is in memory.
    final channelId = _channelIdForSlot(channelIndex);
    if (channelId != null) {
      unawaited(_channelMessageStore.clearChannelMessages(channelId));
    }
    markChannelRead(channelIndex);
    notifyListeners();
  }

  void deleteAllPaths() {
    _pathHistoryService?.clearAllHistories();
  }
}

const int _phRouteMask = 0x03;
const int _phTypeShift = 2;
const int _phTypeMask = 0x0F;
const int _phVerShift = 6;
const int _phVerMask = 0x03;

const int _routeTransportFlood = 0x00;
const int _routeFlood = 0x01;
const int _routeTransportDirect = 0x03;

const int _payloadTypeGroupText = 0x05;
const int _cipherMacSize = 2;

bool _isPathLenValidForMode(
  int pathLen,
  List<int> pathBytes,
  int pathHashWidth,
) {
  if (pathLen < 0 || pathLen > 0x3F) return false;
  if (pathHashWidth < 1 || pathHashWidth > 3) return false;
  final width = pathHashWidth;
  final maxHopCountByBytes = maxPathSize ~/ width;
  if (pathLen > maxHopCountByBytes) return false;
  return pathBytes.length <= maxPathSize && pathBytes.length == pathLen * width;
}

Uint8List _reversePathByHop(Uint8List pathBytes, int pathHashWidth) {
  if (pathBytes.isEmpty) return Uint8List(0);
  final width = pathHashWidth.clamp(1, maxPathHashWidth).toInt();
  final reversed = <int>[];
  for (var i = pathBytes.length; i > 0; i -= width) {
    final start = (i - width).clamp(0, pathBytes.length).toInt();
    reversed.addAll(pathBytes.sublist(start, i));
  }
  return Uint8List.fromList(reversed);
}

class _RawPacket {
  final int header;
  final int routeType;
  final int payloadType;
  final int payloadVer;
  final int pathLenRaw;
  final Uint8List? transportCodes;
  final Uint8List pathBytes;
  final Uint8List payload;

  _RawPacket({
    required this.header,
    required this.routeType,
    required this.payloadType,
    required this.payloadVer,
    required this.pathLenRaw,
    required this.transportCodes,
    required this.pathBytes,
    required this.payload,
  });

  bool get isFlood =>
      routeType == _routeFlood || routeType == _routeTransportFlood;

  int get hopCount => pathLenRaw & 63;
  int get pathHashWidth => ((pathLenRaw >> 6) & 0x03) + 1;
}

class _ParsedText {
  final String senderName;
  final String text;

  _ParsedText({required this.senderName, required this.text});
}

class _RepeaterAckContext {
  final String contactKeyHex;
  final PathSelection selection;
  final int pathLength;
  final int messageBytes;
  Timer? timeout;

  _RepeaterAckContext({
    required this.contactKeyHex,
    required this.selection,
    required this.pathLength,
    required this.messageBytes,
  });
}

/// Inbound reassembly state for one chunked OTP transfer (one `tid`) from
/// one contact or on one channel. Chunks may arrive out of order or be
/// redelivered (see the two-independent-channel-receive-paths note near
/// the top of this file) — storing by index and only reassembling once
/// every index 0..totCh-1 is present makes both of those harmless.
class _OtpChunkReassembly {
  final int totCh;
  final Map<int, Uint8List> chunks = {};
  DateTime lastActivity = DateTime.now();

  _OtpChunkReassembly(this.totCh);

  bool get isComplete => chunks.length >= totCh;

  Uint8List? tryJoin() {
    if (!isComplete) return null;
    final ordered = <Uint8List>[];
    for (var i = 0; i < totCh; i++) {
      final part = chunks[i];
      if (part == null) return null; // shouldn't happen given isComplete
      ordered.add(part);
    }
    return OtpChunkService.joinOrderedChunks(ordered);
  }
}

/// Base outbound chunked-send state shared by the contact and channel
/// variants below. One in-flight chunked send at a time per contact / per
/// channel (mirrors Lua's single global `psend`).
abstract class _OtpChunkSend {
  final int tid;
  final List<Uint8List> chunks;
  final String localMessageId;

  /// Index of the next chunk to send — Lua's `psend.sctr`.
  int sctr = 0;

  /// The already-computed ciphertext hex for chunk [sctr]. Must be reused
  /// verbatim on every retry — never recomputed — exactly like this app's
  /// existing single-shot "encrypt exactly once at compose time" rule,
  /// extended to the chunk case.
  String? currentCipherHex;

  int retryCount = 0;
  Timer? retryTimer;

  /// Wall-clock time of the last real transmit attempt for the current
  /// chunk. Used by MeshCoreConnector.resumeStalledOtpChunkSends to tell
  /// a retry that's genuinely overdue from one that's simply early —
  /// retryTimer alone can't answer that after the app has been
  /// backgrounded, since Android can suspend a plain Dart Timer for far
  /// longer than its nominal duration (Doze / background execution
  /// limits), silently leaving this transfer (and the send guard that
  /// blocks anything else to this contact/channel while it's in flight)
  /// stuck long past whatever its real retry budget should have been.
  DateTime? lastAttemptAt;

  _OtpChunkSend({
    required this.tid,
    required this.chunks,
    required this.localMessageId,
  });

  void cancelRetryTimer() {
    retryTimer?.cancel();
    retryTimer = null;
  }
}

class _OtpContactChunkSend extends _OtpChunkSend {
  final Contact contact;

  /// Fires exactly once, when this whole chunked transfer finishes
  /// (success or not). An ordinary chunked text message has nothing left
  /// to do once `_finishContactChunkSend` has updated its status, so this
  /// is null for one — only an OTP DM image send sets it, to register the
  /// completed transfer with `ReceivedImageStore` and swap the placeholder
  /// bubble text for the real image sentinel, which can only happen once
  /// transmission is confirmed (see `_sendChunkedContactImage`).
  Future<void> Function(bool success)? onSendCompleted;

  _OtpContactChunkSend({
    required this.contact,
    required super.tid,
    required super.chunks,
    required super.localMessageId,
  });
}

class _OtpChannelChunkSend extends _OtpChunkSend {
  final Channel channel;

  _OtpChannelChunkSend({
    required this.channel,
    required super.tid,
    required super.chunks,
    required super.localMessageId,
  });
}
