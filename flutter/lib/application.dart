import 'dart:async';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/material.dart';

import 'application_host_adapter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await launchJournalApplication();
}

Future<void> launchJournalApplication() async {
  try {
    await JournalAmplify.configure();
  } catch (_) {
    runApp(const _ConfigurationFailureApplication());
    return;
  }
  final runtimeOwner = JournalRuntimeOwner();
  final adapter = createBonsaiFlutterHostAdapter(
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

final class JournalRuntimeOwner {
  RuntimeSession? _runtime;
  Future<void>? _shutdown;

  Future<RuntimeSession> start(Uint8List config) async {
    if (_shutdown != null) {
      throw StateError('The journal runtime is shutting down');
    }
    final runtime = await RuntimeClient.start(config: config);
    if (_shutdown != null) {
      await runtime.dispose();
      throw StateError('The journal runtime shut down during startup');
    }
    _runtime = runtime;
    return runtime;
  }

  Future<void> shutdown() => _shutdown ??= _shutdownOnce();

  Future<void> _shutdownOnce() async {
    final runtime = _runtime;
    if (runtime != null) await runtime.dispose();
  }
}

final class JournalApplicationHost extends StatefulWidget {
  const JournalApplicationHost({
    required this.adapter,
    required this.runtimeOwner,
    super.key,
  });

  final BonsaiFlutterHostAdapter adapter;
  final JournalRuntimeOwner runtimeOwner;

  @override
  State<JournalApplicationHost> createState() => _JournalApplicationHostState();
}

final class _PreparedRuntime {
  const _PreparedRuntime({
    required this.runtimeConfig,
    required this.applicationPlatform,
  });

  final Uint8List runtimeConfig;
  final BonsaiFlutterApplicationPlatform? applicationPlatform;
}

final class _JournalApplicationHostState extends State<JournalApplicationHost> {
  late final Future<_PreparedRuntime> _preparedRuntime = _prepareRuntime();

  Future<_PreparedRuntime> _prepareRuntime() async {
    final applicationPayload = await widget.adapter.createApplicationPayload();
    return _PreparedRuntime(
      runtimeConfig: RuntimeBootstrapConfig(
        entrypoint: 'logseq_journal',
        launchPolicy: RuntimeLaunchPolicy.replaceExisting,
        applicationPayload: applicationPayload,
      ).encode(),
      applicationPlatform: widget.adapter.createApplicationPlatform(),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_PreparedRuntime>(
    future: _preparedRuntime,
    builder: (context, snapshot) {
      final prepared = snapshot.data;
      final Widget home;
      if (snapshot.error case final error?) {
        home = Center(child: Text('Unable to prepare application: $error'));
      } else if (prepared == null) {
        home = const Center(child: CircularProgressIndicator());
      } else {
        home = BonsaiFlutterRoot(
          config: prepared.runtimeConfig,
          runtimeStarter: widget.runtimeOwner.start,
          applicationPlatform: prepared.applicationPlatform,
        );
      }
      return widget.adapter.buildHost(
        context: context,
        child: MaterialApp(title: 'Logseq Journal', home: home),
      );
    },
  );
}
