import 'dart:convert';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const BonsaiFlutterHost());
}

final class BonsaiFlutterHost extends StatelessWidget {
  const BonsaiFlutterHost({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'logseq_journal',
    home: BonsaiFlutterRoot(
      config: Uint8List.fromList(utf8.encode('logseq_journal')),
    ),
  );
}
