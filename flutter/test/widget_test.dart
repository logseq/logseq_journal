import 'package:logseq_journal_host/application_host_adapter.dart'
    as application;
import 'package:logseq_journal_host/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('custom host can be constructed', () {
    expect(
      JournalApplicationHost(
        adapter: application.createJournalHostAdapter(),
        runtimeOwner: JournalRuntimeOwner(),
      ),
      isNotNull,
    );
  });
}
