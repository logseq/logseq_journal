import 'dart:convert';

import 'package:logseq_journal_host/application_host_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed startup rejects credentials and non-origin URLs', () {
    expect(
      () => LogseqDbWorkerStartupEnvelope(
        applicationSupportDirectory: '/tmp/support',
        baseUrl: Uri.parse('https://user@example.test/path'),
      ).encode(),
      throwsFormatException,
    );
    final payload = LogseqDbWorkerStartupEnvelope(
      applicationSupportDirectory: '/tmp/support',
      baseUrl: Uri.parse('https://api.example.test'),
    ).encode();
    final json = utf8.decode(payload.sublist(8));
    expect(json, contains('"kind":"managedSync"'));
    expect(json, isNot(contains('token')));
  });
}
