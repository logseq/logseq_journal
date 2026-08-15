import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

enum RuntimeFlowFixtureMode { normal, persistenceFailure }

final class RuntimeFlowFixture {
  const RuntimeFlowFixture({
    required this.supportRoot,
    required this.snapshotToken,
    required this.graphDirectory,
    required this.ownsSupportRoot,
  });

  final Directory supportRoot;
  final String snapshotToken;
  final Directory graphDirectory;
  final bool ownsSupportRoot;

  static var _normalFixtureIndex = 0;
  static var _failureFixtureIndex = 0;

  static Future<RuntimeFlowFixture> create(
    WidgetTester tester, {
    RuntimeFlowFixtureMode mode = RuntimeFlowFixtureMode.normal,
  }) async {
    final configured = _configuredFixture(mode);
    if (configured != null) return configured;
    final supportRoot = await tester.runAsync(
      () => Directory.systemTemp.createTemp('logseq-runtime-flow-'),
    );
    expect(supportRoot, isNotNull);
    final executable = _fixtureGenerator();
    expect(
      executable.existsSync(),
      isTrue,
      reason:
          'Build logseq_db_worker/tool/generate_fixtures.exe before Flutter integration tests.',
    );
    final command = switch (mode) {
      RuntimeFlowFixtureMode.normal => 'runtime-flow',
      RuntimeFlowFixtureMode.persistenceFailure => 'runtime-flow-failure',
    };
    final result = await tester.runAsync(
      () => Process.run(executable.path, [
        command,
        '--support-root',
        supportRoot!.path,
      ]),
    );
    expect(result, isNotNull);
    expect(result!.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    expect(json['formatVersion'], 1);
    return RuntimeFlowFixture(
      supportRoot: supportRoot!,
      snapshotToken: json['snapshotToken']! as String,
      graphDirectory: Directory(json['graphDir']! as String),
      ownsSupportRoot: true,
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    if (ownsSupportRoot && supportRoot.existsSync()) {
      await tester.runAsync(() => supportRoot.delete(recursive: true));
    }
  }

  static RuntimeFlowFixture? _configuredFixture(RuntimeFlowFixtureMode mode) {
    final encoded =
        Platform.environment['LOGSEQ_DB_WORKER_RUNTIME_FIXTURES_JSON'];
    if (encoded == null) return null;
    final document = jsonDecode(encoded) as Map<String, dynamic>;
    final key = switch (mode) {
      RuntimeFlowFixtureMode.normal => 'normal',
      RuntimeFlowFixtureMode.persistenceFailure => 'persistenceFailure',
    };
    final fixtures = document[key]! as List<dynamic>;
    final index = switch (mode) {
      RuntimeFlowFixtureMode.normal => _normalFixtureIndex++,
      RuntimeFlowFixtureMode.persistenceFailure => _failureFixtureIndex++,
    };
    if (index >= fixtures.length) {
      throw StateError('No configured $key runtime fixture remains.');
    }
    final json = fixtures[index]! as Map<String, dynamic>;
    return RuntimeFlowFixture(
      supportRoot: Directory(json['supportRoot']! as String),
      snapshotToken: json['snapshotToken']! as String,
      graphDirectory: Directory(json['graphDir']! as String),
      ownsSupportRoot: false,
    );
  }
}

File _fixtureGenerator() {
  final configured = Platform.environment['LOGSEQ_DB_WORKER_FIXTURE_GENERATOR'];
  if (configured != null) return File(configured);
  var directory = Directory.current.absolute;
  while (true) {
    final candidate = File(
      '${directory.path}/_build/default/logseq_db_worker/tool/generate_fixtures.exe',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) return candidate;
    directory = parent;
  }
}
