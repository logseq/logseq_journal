import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:journal_lui_native/journal_lui_native.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'application_host_adapter.dart';
import 'journal_extension_registry.dart';

Future<void> main() async {
  JournalStartupTimeline.mark(JournalStartupMilestone.dartEntrypointStarted);
  WidgetsFlutterBinding.ensureInitialized();
  await launchJournalApplication();
}

Future<void> launchJournalApplication() async {
  final amplifyReady = JournalAmplify.configure().then((_) {
    JournalStartupTimeline.mark(
      JournalStartupMilestone.amplifyConfigurationComplete,
    );
  });
  final runtimeOwner = JournalRuntimeOwner();
  final adapter = createJournalHostAdapter(
    amplifyReady: amplifyReady,
    authenticationFailureBuilder: () =>
        const _ConfigurationFailureApplication(),
    prepareToTerminate: runtimeOwner.shutdown,
  );
  runApp(JournalApplicationHost(adapter: adapter, runtimeOwner: runtimeOwner));
}

final class _ConfigurationFailureApplication extends StatelessWidget {
  const _ConfigurationFailureApplication();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Logseq Journal',
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unable to configure authentication'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => unawaited(launchJournalApplication()),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Owns the OCaml bridge + `LUIFlutterBackend` pair for the app lifetime:
/// applies patch batches from the patch callback, forwards `LUIEvent`s into
/// `lui_ocaml_*`/`journal_ocaml_*` entries, schedules `journal_ocaml_pump`
/// off the wakeup callback, and bridges the LJP2 platform channel both ways.
final class JournalRuntimeOwner {
  JournalOcamlBridge? _bridge;
  LUIFlutterBackend? _backend;
  JournalPlatformServices? _platform;
  StreamSubscription<Uint8List>? _platformEvents;
  Future<void>? _shutdown;

  static int get _platformCode => Platform.isMacOS
      ? 1
      : Platform.isIOS
      ? 2
      : Platform.isAndroid
      ? 3
      : Platform.isLinux
      ? 4
      : 5;

  LUIFlutterBackend start({
    required Uint8List payload,
    required JournalPlatformServices platform,
  }) {
    if (_shutdown != null) {
      throw StateError('The journal runtime is shutting down');
    }
    _platform = platform;
    late final LUIFlutterBackend backend;
    backend = LUIFlutterBackend(
      onEvent: _handleEvent,
      extensionRegistry: journalExtensionRegistry(
        (nodeID) => backend.widget(node: nodeID),
      ),
    );
    _backend = backend;
    final bridge = JournalOcamlBridge(
      onPatch: (source) {
        backend.applyJson(source);
        generation.value = backend.generation;
      },
    );
    _bridge = bridge;
    // `journal_ml_wakeup` may fire off the UI thread; the listener callable
    // hops back to this isolate, then the pump drains queued work + patches.
    bridge.installWakeupCallback(() {
      scheduleMicrotask(() => _bridge?.pump());
    });
    bridge.installPlatformRequestCallback((bytes) {
      final current = _bridge;
      if (current == null) return;
      unawaited(
        platform.handleRequest(bytes).then((response) {
          if (response != null) current.platformResponse(response);
        }),
      );
    });
    _platformEvents = platform.events.listen(bridge.platformEvent);
    bridge.start(platform: _platformCode, payload: payload);
    JournalStartupTimeline.mark(JournalStartupMilestone.runtimeStarted);
    return backend;
  }

  /// Bumped per patch batch so hosts can wait for the root node to appear.
  final ValueNotifier<int> generation = ValueNotifier(0);

  int? get rootNode {
    final bridge = _bridge;
    if (bridge == null) return null;
    try {
      return bridge.rootNode;
    } on StateError {
      return null;
    }
  }

  void _handleEvent(LUIEvent event) {
    final bridge = _bridge;
    if (bridge == null) return;
    switch (event) {
      case LUIAppearEvent e:
        bridge.appear(e.node);
      case LUIPressEvent e:
        bridge.press(e.node);
      case LUILongPressEvent e:
        bridge.longPress(e.node);
      case LUIDoublePressEvent e:
        bridge.doublePress(e.node);
      case LUIDismissEvent e:
        bridge.dismiss(e.node);
      case LUISubmitEvent e:
        bridge.submit(e.node);
      case LUITextChangedEvent e:
        bridge.textChanged(e.node, e.text);
      case LUIToggleChangedEvent e:
        bridge.toggleChanged(e.node, e.checked);
      case LUIChangeEvent e:
        bridge.radioChanged(e.node);
      case LUIValueChangedEvent e:
        bridge.sliderChanged(e.node, e.value);
      case LUIExtensionComponentEvent e:
        bridge.extensionEvent(e.node, e.name, jsonEncode(e.values));
    }
  }

  void pushEnvironment(Uint8List envelope) => _bridge?.platformEvent(envelope);

  Future<void> shutdown() => _shutdown ??= _shutdownOnce();

  Future<void> _shutdownOnce() async {
    await _platformEvents?.cancel();
    final platform = _platform;
    if (platform is JournalApplicationPlatform) platform.dispose();
    _bridge?.close();
    _backend?.dispose();
  }
}

final class JournalApplicationHost extends StatefulWidget {
  const JournalApplicationHost({
    required this.adapter,
    required this.runtimeOwner,
    super.key,
  });

  final JournalHostAdapter adapter;
  final JournalRuntimeOwner runtimeOwner;

  @override
  State<JournalApplicationHost> createState() => _JournalApplicationHostState();
}

final class _PreparedRuntime {
  const _PreparedRuntime({
    required this.applicationPayload,
    required this.applicationPlatform,
  });

  final Uint8List applicationPayload;
  final JournalApplicationPlatform? applicationPlatform;
}

/// Stand-in `JournalPlatformServices` for host adapters that expose no
/// platform (e.g. tests) — accepts requests silently, pushes nothing.
final class _NullJournalPlatformServices implements JournalPlatformServices {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  Future<Uint8List?> handleRequest(Uint8List request) async => null;
}

final class _JournalApplicationHostState extends State<JournalApplicationHost> {
  late final Future<_PreparedRuntime> _preparedRuntime = _prepareRuntime();
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  final Map<String, Completer<String>> _pendingNotices = {};
  LUIFlutterBackend? _backend;

  Future<_PreparedRuntime> _prepareRuntime() async {
    final applicationPayload = await widget.adapter.createApplicationPayload();
    return _PreparedRuntime(
      applicationPayload: applicationPayload,
      applicationPlatform: widget.adapter.createApplicationPlatform(),
    );
  }

  Future<String> _showNotice({
    required String token,
    required String message,
    required String? actionLabel,
    required int durationMs,
  }) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return Future.value('dismiss');
    final completer = Completer<String>();
    _pendingNotices[token] = completer;
    messenger
        .showSnackBar(
          SnackBar(
            content: Text(message),
            duration: Duration(milliseconds: durationMs),
            action: actionLabel == null
                ? null
                : SnackBarAction(label: actionLabel, onPressed: () {}),
          ),
        )
        .closed
        .then((reason) {
          final result = switch (reason) {
            SnackBarClosedReason.action => 'action',
            SnackBarClosedReason.swipe => 'swipe',
            SnackBarClosedReason.timeout => 'timeout',
            _ => 'dismiss',
          };
          final pending = _pendingNotices.remove(token);
          if (pending != null && !pending.isCompleted) {
            pending.complete(result);
          }
        });
    return completer.future;
  }

  void _cancelNotice(String token) {
    final pending = _pendingNotices.remove(token);
    pending?.complete('dismiss');
    _messengerKey.currentState?.hideCurrentSnackBar();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_PreparedRuntime>(
    future: _preparedRuntime,
    builder: (context, snapshot) {
      final prepared = snapshot.data;
      final Widget home;
      if (snapshot.error case final error?) {
        home = Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Text('Unable to prepare application: $error')),
        );
      } else if (prepared == null) {
        home = const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: CircularProgressIndicator()),
        );
      } else {
        final platform =
            prepared.applicationPlatform ?? _NullJournalPlatformServices();
        if (platform is JournalApplicationPlatform) {
          platform.installNoticeSink(
            showNotice: _showNotice,
            cancelNotice: _cancelNotice,
          );
        }
        final backend = _backend ??= widget.runtimeOwner.start(
          payload: prepared.applicationPayload,
          platform: platform,
        );
        home = ScaffoldMessenger(
          key: _messengerKey,
          child: _EnvironmentPusher(
            onSnapshot: widget.runtimeOwner.pushEnvironment,
            child: ValueListenableBuilder<int>(
              valueListenable: widget.runtimeOwner.generation,
              builder: (context, _, child) {
                final root = widget.runtimeOwner.rootNode;
                return root == null
                    ? const Center(child: CircularProgressIndicator())
                    : backend.widget(node: root);
              },
            ),
          ),
        );
      }
      return widget.adapter.buildHost(context: context, child: home);
    },
  );
}

/// Pushes LJP2 tag-24 environment snapshots at startup and on every
/// environment change (metrics, brightness, text scale, locale).
final class _EnvironmentPusher extends StatefulWidget {
  const _EnvironmentPusher({required this.onSnapshot, required this.child});

  final void Function(Uint8List envelope) onSnapshot;
  final Widget child;

  @override
  State<_EnvironmentPusher> createState() => _EnvironmentPusherState();
}

class _EnvironmentPusherState extends State<_EnvironmentPusher>
    with WidgetsBindingObserver {
  String? _lastJson;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => _push();
  @override
  void didChangePlatformBrightness() => _push();
  @override
  void didChangeTextScaleFactor() => _push();
  @override
  void didChangeLocales(List<Locale>? locales) => _push();
  @override
  void didChangeAccessibilityFeatures() => _push();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _push();
  }

  void _push() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSnapshot(
        JournalPlatformCodec.encodeJson(
          JournalPlatformTag.environmentEvent,
          _snapshot(),
        ),
      );
    });
  }

  Map<String, Object?> _snapshot() {
    final media = MediaQuery.of(context);
    final dispatcher = View.of(context).platformDispatcher;
    final safeArea = media.padding;
    final keyboard = media.viewInsets;
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.windows => 'windows',
      _ => 'unknown',
    };
    // Host capability mask, not an inventory of connected input devices —
    // mirrors the Swift host: touch-primary platforms 0x0f, desktop 0x0e.
    final pointerKinds = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.android => 0x0f,
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => 0x0e,
      _ => 0,
    };
    Map<String, Object?> insets(EdgeInsets value) => <String, Object?>{
      'left': value.left,
      'top': value.top,
      'right': value.right,
      'bottom': value.bottom,
    };
    final snapshot = <String, Object?>{
      'viewportWidth': media.size.width,
      'viewportHeight': media.size.height,
      'devicePixelRatio': media.devicePixelRatio,
      'textScale': media.textScaler.scale(1),
      'brightness': media.platformBrightness == Brightness.dark
          ? 'dark'
          : 'light',
      'platform': platform,
      'locale': dispatcher.locale.toLanguageTag(),
      'safeArea': insets(safeArea),
      'keyboardInsets': insets(keyboard),
      'accessibleNavigation': media.accessibleNavigation,
      'boldText': media.boldText,
      'invertColors': media.invertColors,
      'disableAnimations': media.disableAnimations,
      'reducedMotion': media.disableAnimations,
      'highContrast': media.highContrast,
      'orientation': media.size.width > media.size.height
          ? 'landscape'
          : 'portrait',
      'pointerKinds': pointerKinds,
    };
    // Skip redundant pushes: the wire is per-snapshot, not per-change-source.
    final encoded = jsonEncode(snapshot);
    if (encoded == _lastJson) return const {};
    _lastJson = encoded;
    return snapshot;
  }

  @override
  Widget build(BuildContext context) {
    _push();
    return widget.child;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
