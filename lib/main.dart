import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'l10n/app_localizations.dart';
import 'l10n/l10n.dart';
import 'package:provider/provider.dart';

import 'review_mode/review_mode_storage.dart';
import 'screens/chrome_required_screen.dart';
import 'team/drone_detector.dart';
import 'team/map_highlights.dart';
import 'services/media_mesh_nearby.dart';
import 'services/media_lockdown.dart';
import 'utils/platform_info.dart';

import 'connector/meshcore_connector.dart';
import 'models/image_codec_support.dart';
import 'screens/scanner_screen.dart';
import 'services/image_chunk_transport.dart';
import 'services/image_codec_service.dart';
import 'services/image_codec_settings_store.dart';
import 'services/received_image_blob_store_factory.dart';
import 'services/received_image_store.dart';
import 'services/storage_service.dart';
import 'services/message_retry_service.dart';
import 'services/path_history_service.dart';
import 'services/app_settings_service.dart';
import 'services/network_map/network_map_upload_service.dart';
import 'services/notification_service.dart';
import 'services/ble_debug_log_service.dart';
import 'services/app_debug_log_service.dart';
import 'services/background_service.dart';
import 'services/map_tile_cache_service.dart';
import 'services/chat_text_scale_service.dart';
import 'services/translation_service.dart';
import 'services/ui_view_state_service.dart';
import 'services/timeout_prediction_service.dart';
import 'storage/prefs_manager.dart';
import 'theme/mesh_theme.dart';
import 'utils/app_logger.dart';
import 'widgets/image_send_codec_binding.dart';
import 'services/app_update_service.dart';
import 'team/tak/atak_plugin_bridge.dart';
import 'team/tak/tak_service.dart';
import 'team/team_alert_host.dart';
import 'widgets/app_update_ui.dart';
import 'team/team_service.dart';
import 'team/watch_feed.dart';
import 'vox/aeic_hd_service.dart';
import 'vox/voice_service.dart';
import 'vox/walkie_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _catchUncaughtErrors();

  // On desktop, debugPrint is not suppressed in release builds and every
  // call is a synchronous stdout write. The connector logs heavily on hot
  // paths (frame handling, queue/channel sync), which shows up as syscall
  // overhead on low-end Linux machines (issue #202). The in-app debug log
  // screens are unaffected — they store entries themselves.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Android 15+ forces edge-to-edge for apps targeting SDK 35; opt Android
  // 10-14 in too so they lay out the same way under the bars. Flutter ignores
  // this mode before Android 10, where the old layout remains.
  if (PlatformInfo.isAndroid) {
    await _startupStep(
      'SystemChrome.setEnabledSystemUIMode',
      () => SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    );
  }

  // Initialize SharedPreferences cache
  await _startupStep('PrefsManager.initialize', () => PrefsManager.initialize());

  // Android: look for a newer build on the GitHub "Latest build" release.
  unawaited(AppUpdateService.instance.start());

  // Initialize services
  final storage = StorageService();
  final connector = MeshCoreConnector();
  final pathHistoryService = PathHistoryService(storage);
  final retryService = MessageRetryService();
  final appSettingsService = AppSettingsService();
  final bleDebugLogService = BleDebugLogService();
  final appDebugLogService = AppDebugLogService();
  final backgroundService = BackgroundService();
  final mapTileCacheService = MapTileCacheService(
    appSettingsService: appSettingsService,
  );
  final chatTextScaleService = ChatTextScaleService();
  final translationService = TranslationService(appSettingsService);
  final uiViewStateService = UiViewStateService();
  final timeoutPredictionService = TimeoutPredictionService(storage);

  // Load settings before anything reads them. The image stack below takes its
  // model registry and its "process automatically" default straight off
  // `appSettingsService.settings`, so this cannot stay where it used to be
  // (after the constructions) without those two starting out wrong.
  await _startupStep('appSettingsService.loadSettings', () => appSettingsService.loadSettings());
  // Undo a review-mode session the app was killed in before it could exit.
  await _startupStep('endReviewModeSession', () => endReviewModeSession(appSettingsService));
  await _startupStep('mediaMeshNearby.load', () => MediaMeshNearby.instance.load());
  await _startupStep('mapHighlights.load', () => MapHighlights.instance.load());
  MediaMeshNearby.instance.attach(connector);

  // ---- image messages (AEIC over GRP_DATA) --------------------------------
  // The codec owns the ONNX decoder; the store owns received-image state and
  // the decode queue; the reassembler/transport pair is the receive path the
  // connector feeds raw frames into.
  final imageCodecService = ImageCodecService(
    appSettingsService,
    settingsStore: AppSettingsImageCodecStore(appSettingsService),
  );
  final receivedImageStore = ReceivedImageStore(
    // Without a file-backed store this silently falls back to memory and every
    // received image — sidecar included — is gone at the next launch.
    blobs: createReceivedImageBlobStore(),
    decoder: AeicHdRoutingDecoder(ImageCodecServiceDecoder(imageCodecService)),
    processAutomatically: appSettingsService.settings.imageProcessAutomatically,
  );
  // A decode peaks around 2.16 GiB, so the setting is the user's consent to
  // spend it. Mirrored on every settings change; the store applies it to
  // future arrivals only, so turning it on does not decode a backlog.
  appSettingsService.addListener(() {
    receivedImageStore.processAutomatically =
        appSettingsService.settings.imageProcessAutomatically;
  });
  // Availability/isBusy changes are the only thing that un-parks a decode
  // queue that stopped because the codec was unusable or busy.
  imageCodecService.addListener(receivedImageStore.notifyDecoderChanged);
  final imageReassembler = ImageStreamReassembler(
    store: receivedImageStore,
    channelIdForSlot: connector.channelIdForSlot,
  );
  final imageTransport = ImageChunkTransport(
    reassembler: imageReassembler,
    // The UI sends whole chunk sets through connector.sendImageChunks so it
    // gets real inter-chunk pacing and per-chunk progress; this closure only
    // keeps ImageChunkTransport.sendImage() usable on its own.
    send: (blob, channelIndex) => connector.sendImageChunks(
      <Uint8List>[blob],
      channelIndex: channelIndex,
      interChunkDelay: Duration.zero,
    ),
    // Overwritten by onImageSenderPrefix as soon as SELF_INFO lands.
    senderPrefix: 0,
  );

  // Initialize app logger
  appLogger.initialize(
    appDebugLogService,
    enabled: appSettingsService.settings.appDebugLogEnabled,
  );

  // Initialize notification service
  final notificationService = NotificationService();
  await _startupStep('notificationService.initialize', () => notificationService.initialize());
  await _startupStep('backgroundService.initialize', () => backgroundService.initialize());
  backgroundService.setLanguageOverrideProvider(
    () => appSettingsService.settings.languageOverride,
  );
  _registerThirdPartyLicenses();

  await _startupStep('chatTextScaleService.initialize', () => chatTextScaleService.initialize());
  await _startupStep('translationService.refreshDownloadedModels', () => translationService.refreshDownloadedModels());
  await _startupStep('imageCodecService.refreshDownloadedModels', () => imageCodecService.refreshDownloadedModels());
  await _startupStep('receivedImageStore.load', () => receivedImageStore.load());
  await _startupStep('mediaLockdown.load', MediaLockdown.load);
  await _startupStep('uiViewStateService.initialize', () => uiViewStateService.initialize());
  await _startupStep('timeoutPredictionService.initialize', () => timeoutPredictionService.initialize());

  // Wire up connector with services
  connector.initialize(
    retryService: retryService,
    pathHistoryService: pathHistoryService,
    appSettingsService: appSettingsService,
    translationService: translationService,
    bleDebugLogService: bleDebugLogService,
    appDebugLogService: appDebugLogService,
    backgroundService: backgroundService,
    timeoutPredictionService: timeoutPredictionService,
    imageCodecService: imageCodecService,
    imageTransport: imageTransport,
    receivedImageStore: receivedImageStore,
    // ImageStreamReassembler.addChunk already forwards every outcome to the
    // store together with the channel index (which ImageChunkOutcome itself
    // does not carry), so onImageChunk would be a second, channel-blind path.
    onImageSenderPrefix: (prefix) => imageReassembler.selfPrefix = prefix,
  );

  // MeshCore Open TAK: on-demand Codec2 voice messages (VE3).
  final voxVoiceService = VoxVoiceService(connector);

  final networkMapUploadService = NetworkMapUploadService(
    connector: connector,
    settings: appSettingsService,
  );

  await _startupStep('connector.loadContactCache', () => connector.loadContactCache());
  await _startupStep('connector.loadCachedChannels', () => connector.loadCachedChannels());
  await _startupStep('connector.loadUnreadState', () => connector.loadUnreadState());

  runApp(
    MeshCoreApp(
      connector: connector,
      retryService: retryService,
      pathHistoryService: pathHistoryService,
      storage: storage,
      appSettingsService: appSettingsService,
      bleDebugLogService: bleDebugLogService,
      appDebugLogService: appDebugLogService,
      mapTileCacheService: mapTileCacheService,
      chatTextScaleService: chatTextScaleService,
      translationService: translationService,
      uiViewStateService: uiViewStateService,
      timeoutPredictionService: timeoutPredictionService,
      imageCodecService: imageCodecService,
      receivedImageStore: receivedImageStore,
      imageReassembler: imageReassembler,
      voxVoiceService: voxVoiceService,
      networkMapUploadService: networkMapUploadService,
    ),
  );
  _reportStartupStalls();
}

/// [ReceivedImageDecoder] over [ImageCodecService].
///
/// Pure delegation. It exists so `received_image_store.dart` never imports
/// `image_codec_service.dart` (and so the store stays testable without an
/// 872 MB ONNX graph).
class ImageCodecServiceDecoder implements ReceivedImageDecoder {
  final ImageCodecService service;

  const ImageCodecServiceDecoder(this.service);

  @override
  ImageCodecAvailability get availability => service.availability;

  @override
  bool get isBusy => service.isBusy;

  @override
  Future<ImageCodecResult?> decodeBitstream({
    required Uint8List bitstream,
    required AeicRatePoint ratePoint,
    required int resolution,
  }) => service.decodeBitstream(
    bitstream: bitstream,
    ratePoint: ratePoint,
    resolution: resolution,
  );

  @override
  void cancelCodecJob() => service.cancelCodecJob();
}

/// [ImageCodecSettingsStore] backed by [AppSettingsService].
///
/// Replaces `PrefsImageCodecSettingsStore` now that the five `imageCodec*`
/// fields live on [AppSettings]; the JSON keys were already the same, so a
/// user upgrading keeps their model registry only if it was written through
/// this adapter — the old standalone `image_codec_settings` blob is not
/// migrated, because a placeholder-URL build cannot have produced one.
class AppSettingsImageCodecStore implements ImageCodecSettingsStore {
  final AppSettingsService _service;

  const AppSettingsImageCodecStore(this._service);

  @override
  ImageCodecPreferences get preferences => _service.settings.imageCodec;

  @override
  Future<void> load() async {
    // AppSettingsService.loadSettings() already ran in main().
  }

  @override
  Future<void> save(ImageCodecPreferences preferences) =>
      _service.setImageCodecPreferences(preferences);
}

/// An [ImageReassembler] that (a) learns the local sender prefix after
/// SELF_INFO and (b) forwards every outcome to [ReceivedImageStore] together
/// with the channel index and the channel ID that slot holds.
///
/// Both exist because of upstream shapes this file cannot change:
///  * `ImageReassembler.selfPrefix` is `final`, but the local public key does
///    not exist until `RESP_CODE_SELF_INFO`, so a reassembler built here would
///    start with a null prefix and never be able to drop our own flood echo.
///    Overriding the getter is the smallest fix that does not touch the
///    transport; see the report's "needs from others".
///  * `ImageChunkOutcome` carries no channel index, so the connector's
///    `onImageChunk` callback cannot call `handleOutcome`, which requires one.
///    Intercepting `addChunk` — the only place the index is in scope — can.
class ImageStreamReassembler extends ImageReassembler {
  final ReceivedImageStore store;

  /// Resolves the radio slot a chunk arrived on to its [Channel.storageId].
  final String? Function(int channelIndex)? channelIdForSlot;

  int? _selfPrefix;

  ImageStreamReassembler({required this.store, this.channelIdForSlot})
    : super(onFailed: ((failure) => unawaited(store.handleFailure(failure))));

  @override
  int? get selfPrefix => _selfPrefix;

  set selfPrefix(int? value) => _selfPrefix = value;

  @override
  ImageChunkOutcome addChunk(
    Uint8List blob, {
    int channelIndex = 0,
    DateTime? now,
    int? via,
  }) {
    final outcome = super.addChunk(blob, channelIndex: channelIndex, now: now);
    unawaited(
      store.handleOutcome(
        outcome,
        channelIndex: channelIndex,
        channelId: channelIdForSlot?.call(channelIndex),
        via: via,
      ),
    );
    return outcome;
  }
}

void _registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      <String>['Mimi (Kyutai)'],
      '''
VOX voice messages can use the Mimi neural audio codec by Kyutai,
downloaded on demand and converted to ONNX for on-device use.

https://huggingface.co/kyutai/mimi
Licensed under Creative Commons Attribution 4.0 International (CC BY 4.0)
https://creativecommons.org/licenses/by/4.0/
''',
    );
  });
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      <String>['Open-Meteo Elevation API Data'],
      '''
Data used by LOS elevation lookups is provided by Open-Meteo.

Open-Meteo terms and attribution:
https://open-meteo.com/en/terms

Elevation API:
https://open-meteo.com/en/docs/elevation-api

Attribution license reference:
Creative Commons Attribution 4.0 International (CC BY 4.0)
https://creativecommons.org/licenses/by/4.0/
''',
    );
  });
}

class MeshCoreApp extends StatefulWidget {
  final MeshCoreConnector connector;
  final MessageRetryService retryService;
  final PathHistoryService pathHistoryService;
  final StorageService storage;
  final AppSettingsService appSettingsService;
  final BleDebugLogService bleDebugLogService;
  final AppDebugLogService appDebugLogService;
  final MapTileCacheService mapTileCacheService;
  final ChatTextScaleService chatTextScaleService;
  final TranslationService translationService;
  final UiViewStateService uiViewStateService;
  final TimeoutPredictionService timeoutPredictionService;
  final ImageCodecService imageCodecService;
  final ReceivedImageStore receivedImageStore;
  final ImageStreamReassembler imageReassembler;
  final VoxVoiceService? voxVoiceService;
  final NetworkMapUploadService networkMapUploadService;

  const MeshCoreApp({
    super.key,
    required this.connector,
    required this.retryService,
    required this.pathHistoryService,
    required this.storage,
    required this.appSettingsService,
    required this.bleDebugLogService,
    required this.appDebugLogService,
    required this.mapTileCacheService,
    required this.chatTextScaleService,
    required this.translationService,
    required this.uiViewStateService,
    required this.timeoutPredictionService,
    required this.imageCodecService,
    required this.receivedImageStore,
    required this.imageReassembler,
    this.voxVoiceService,
    required this.networkMapUploadService,
  });

  @override
  State<MeshCoreApp> createState() => _MeshCoreAppState();
}

/// How often abandoned image streams are swept.
///
/// `ImageReassembler.evictExpired` otherwise only runs from `addChunk`, so a
/// sender that stops mid-image would leave its bubble stuck on "2 of 3
/// packets" until some unrelated image arrived.
const Duration _kImageSweepInterval = Duration(seconds: 5);

class _MeshCoreAppState extends State<MeshCoreApp> with WidgetsBindingObserver {
  Timer? _imageSweepTimer;
  late final VoxVoiceService _voxVoiceService =
      widget.voxVoiceService ?? VoxVoiceService(widget.connector);
  late final WalkieService _walkie = WalkieService(
    widget.connector,
    _voxVoiceService,
  );
  late final TeamService _teamService = TeamService(widget.connector);
  late final TakService _takService = TakService(_teamService);
  late final WatchFeedService _watchFeed = WatchFeedService(widget.connector);
  late final DroneDetectorService _drones = DroneDetectorService(
    widget.connector,
    _watchFeed,
  );
  late final AtakPluginBridge _atakBridge;

  @override
  void initState() {
    super.initState();
    _atakBridge = AtakPluginBridge(
      widget.connector,
      _teamService,
      _voxVoiceService,
    );
    MapHighlights.instance.attach(_teamService, _watchFeed);
    WidgetsBinding.instance.addObserver(this);
    _imageSweepTimer = Timer.periodic(
      _kImageSweepInterval,
      (_) => widget.imageReassembler.evictExpired(),
    );
  }

  @override
  void dispose() {
    _atakBridge.dispose();
    _imageSweepTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // `inactive` is still on screen (iOS Control Center, a call banner, a Face
    // ID prompt), so it must not cancel a decode and mark the image corrupt.
    widget.receivedImageStore.setForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
    if (state == AppLifecycleState.resumed) {
      // See MeshCoreConnector.resumeStalledOtpChunkSends: a backgrounded
      // app can have its OTP chunk-send retry Timers suspended well past
      // their nominal 12s, leaving a transfer (and the send guard for
      // that contact/channel) stuck until this runs.
      widget.connector.resumeStalledOtpChunkSends();
    }
    // ~2.7 GiB resident in a backgrounded app is a low-memory-killer kill, so
    // unlike the translation stack the graph is dropped on background rather
    // than held until the radio disconnects. The store keeps its queue: the
    // cancelled decode goes back on it and resumes when the app returns. Only
    // a real memory warning (didHaveMemoryPressure) parks everything.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.imageCodecService.handleMemoryPressure());
    }
    if (state == AppLifecycleState.resumed) {
      widget.connector.syncAppBadge();
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    unawaited(widget.imageCodecService.handleMemoryPressure());
    unawaited(widget.receivedImageStore.handleMemoryPressure());
  }

  @override
  Widget build(BuildContext context) {
    final connector = widget.connector;
    final storage = widget.storage;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: connector),
        ChangeNotifierProvider.value(value: widget.retryService),
        ChangeNotifierProvider.value(value: widget.pathHistoryService),
        ChangeNotifierProvider.value(value: widget.appSettingsService),
        ChangeNotifierProvider.value(value: widget.bleDebugLogService),
        ChangeNotifierProvider.value(value: widget.appDebugLogService),
        ChangeNotifierProvider.value(value: widget.chatTextScaleService),
        ChangeNotifierProvider.value(value: widget.translationService),
        ChangeNotifierProvider.value(value: widget.uiViewStateService),
        Provider.value(value: storage),
        ChangeNotifierProvider.value(value: widget.mapTileCacheService),
        ChangeNotifierProvider.value(value: widget.timeoutPredictionService),
        ChangeNotifierProvider.value(value: widget.imageCodecService),
        ChangeNotifierProvider.value(value: widget.receivedImageStore),
        ChangeNotifierProvider<VoxVoiceService>.value(value: _voxVoiceService),
        ChangeNotifierProvider<WalkieService>.value(value: _walkie),
        ChangeNotifierProvider<TeamService>.value(value: _teamService),
        ChangeNotifierProvider<TakService>.value(value: _takService),
        ChangeNotifierProvider<WatchFeedService>.value(value: _watchFeed),
        ChangeNotifierProvider<DroneDetectorService>.value(value: _drones),
        Provider<AtakPluginBridge>.value(value: _atakBridge),
        ChangeNotifierProvider.value(value: widget.networkMapUploadService),
      ],
      child: Consumer<AppSettingsService>(
        builder: (context, settingsService, child) {
          return MaterialApp(
            title: 'MeshCore Open TAK',
            navigatorKey: appNavigatorKey,
            debugShowCheckedModeBanner: false,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: _localeFromSetting(
              settingsService.settings.languageOverride,
            ),
            theme: MeshTheme.light(),
            darkTheme: MeshTheme.dark(),
            themeMode: _themeModeFromSetting(
              settingsService.settings.themeMode,
            ),
            builder: (context, child) {
              // Update notification service with resolved locale
              final locale = Localizations.localeOf(context);
              NotificationService().setLocale(locale);
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: _systemUiOverlayStyle(context),
                child: TeamAlertHost(
                  child: AppUpdateBanner(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              );
            },
            home: (PlatformInfo.isWeb && !PlatformInfo.isChrome)
                ? const ChromeRequiredScreen()
                : const ScannerScreen(),
          );
        },
      ),
    );
  }

  ThemeMode _themeModeFromSetting(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  SystemUiOverlayStyle _systemUiOverlayStyle(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;

    // The app draws edge-to-edge, so both system bars stay transparent and
    // their icon brightness follows the resolved Flutter theme. Contrast
    // enforcement keeps a scrim behind three-button navigation in case a
    // route paints a dark surface under light-theme icons; dark full-screen
    // routes also set light icons themselves.
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: iconBrightness,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: iconBrightness,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: true,
    );
  }

  Locale? _localeFromSetting(String? languageCode) {
    if (languageCode == null) return null;
    return Locale(languageCode);
  }
}

// ---- startup guard -----------------------------------------------------------
// Every awaited step before the first screen gets a time limit. One that hangs
// (a plugin whose platform call never answers) or throws used to leave the app
// on the splash screen for good; now the app opens anyway and says which step
// it gave up on.
final List<String> _startupStalls = [];

Future<void> _startupStep(
  String name,
  Future<void> Function() body, {
  Duration limit = const Duration(seconds: 10),
}) async {
  try {
    await body().timeout(limit);
  } on TimeoutException {
    _startupStalls.add('$name (no answer in ${limit.inSeconds} s)');
  } catch (e) {
    _startupStalls.add('$name ($e)');
  }
}

void _reportStartupStalls() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // The CI smoke test (scripts/ci/android_smoke.sh) waits for this line: the
    // release build got past the splash screen. print, not debugPrint, which is
    // silenced in release builds.
    // ignore: avoid_print
    print('MeshCoreOpen: first frame');
    if (_startupStalls.isEmpty) return;
    final steps = _startupStalls.join('; ');
    appLogger.warn('Startup steps that did not finish: $steps', tag: 'Startup');
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 30),
        content: Text(context.l10n.startup_stalled(steps)),
      ),
    );
  });
}

/// Errors nothing awaited: a failed platform call in a fire-and-forget future,
/// an exception in a callback. Before the first frame they are kept with the
/// startup report (the app opens and says so); after it they go to the app log.
/// Either way they are printed once for the smoke test and adb logcat.
var _firstFrameShown = false;

void _catchUncaughtErrors() {
  void record(Object error) {
    final line = '$error'.split('\n').first;
    // ignore: avoid_print
    print('MeshCoreOpen: uncaught error: $line');
    if (!_firstFrameShown) {
      _startupStalls.add(line);
    } else {
      appLogger.error(line, tag: 'Uncaught');
    }
  }

  PlatformDispatcher.instance.onError = (error, stack) {
    record(error);
    return true;
  };
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    record(details.exception);
    previous?.call(details);
  };
  WidgetsBinding.instance.addPostFrameCallback((_) => _firstFrameShown = true);
}
