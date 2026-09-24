import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

import 'ocaml_artifact.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final packageName = input.packageName;
    final requireOcamlBackend = _requireOcamlBackend(input);
    final target = _ocamlTarget(input);
    final nativeArtifactRoot = input.userDefines.path('native_artifact_root');
    File? ocamlObject;
    if (target == null) {
      if (requireOcamlBackend) {
        throw StateError(
          'require_ocaml_backend is enabled, but '
          '${input.config.code.targetOS} is not an Apple target.',
        );
      }
    } else {
      final variant = nativeArtifactRoot == null && !requireOcamlBackend
          ? null
          : _artifactVariant(input, target, nativeArtifactRoot);
      ocamlObject = await OcamlArtifactResolver().resolve(
        nativeArtifactRoot: nativeArtifactRoot,
        requireOcamlBackend: requireOcamlBackend,
        target: target,
        variant: variant,
      );
    }
    final embedOcaml = ocamlObject != null;
    final exportList = input.packageRoot.resolve(
      'src/journal_lui_exports.txt',
    );
    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: [
        if (!embedOcaml) 'src/$packageName.c',
        if (ocamlObject != null) ocamlObject.path,
        if (input.config.code.targetOS == OS.iOS)
          'src/journal_lui_ios_process_stubs.c',
      ],
      includes: ['src'],
      flags: [
        if (input.config.code.targetOS == OS.macOS ||
            input.config.code.targetOS == OS.iOS) ...[
          '-Wl,-dead_strip',
          '-Wl,-exported_symbols_list,${exportList.toFilePath()}',
        ],
        if (input.config.code.targetOS == OS.iOS) ...['-framework', 'Security'],
        if (input.config.code.targetOS == OS.iOS)
          ...iOSDeploymentTargetFlagsForTesting(
            input.config.code.iOS.targetVersion,
            input.userDefines['ios_deployment_target'],
          ),
        if (input.config.code.targetOS == OS.macOS)
          ...macOSDeploymentTargetFlags(
            input.userDefines['macos_deployment_target'],
          ),
        ...systemLinkFlagsForTesting(
          input.config.code.targetOS,
          input.userDefines['link_system_sqlite3'],
        ),
      ],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        ..onRecord.listen((record) => stderr.writeln(record.message)),
    );
    output.dependencies.add(exportList);
  });
}

bool _requireOcamlBackend(BuildInput input) {
  return _booleanUserDefine(input, 'require_ocaml_backend');
}

/// `native_artifact_profile` selects the artifact variant explicitly; without
/// it, pick the first variant directory that actually contains the object so
/// `flutter test`/`build` work without toolchain-injected defines.
OcamlArtifactVariant _artifactVariant(
  BuildInput input,
  OcamlArtifactTarget target,
  Uri? nativeArtifactRoot,
) {
  final profile = _artifactProfile(input);
  if (profile != null) return OcamlArtifactVariant.fromProfileName(profile);
  if (nativeArtifactRoot != null) {
    for (final variant in OcamlArtifactVariant.values) {
      if (File.fromUri(
        nativeArtifactRoot.resolve(target.artifactPathFor(variant: variant)),
      ).existsSync()) {
        return variant;
      }
    }
  }
  return OcamlArtifactVariant.debug;
}

String? _artifactProfile(BuildInput input) {
  final value = input.userDefines['native_artifact_profile'];
  if (value == null || value is String) return value as String?;
  throw FormatException(
    'native_artifact_profile must be debug, profile, or release; '
    'found $value.',
  );
}

bool _booleanUserDefine(BuildInput input, String name) {
  return _booleanValue(name, input.userDefines[name]);
}

bool _booleanValue(String name, Object? value) {
  return switch (value) {
    null => false,
    true || 'true' => true,
    false || 'false' => false,
    _ => throw FormatException('$name must be true or false, found $value.'),
  };
}

List<String> systemLinkFlagsForTesting(OS targetOS, Object? userDefine) {
  final enabled = _booleanValue('link_system_sqlite3', userDefine);
  if (!enabled) return const [];
  return switch (targetOS) {
    OS.macOS || OS.iOS => const ['-lsqlite3'],
    _ => const [],
  };
}

String iOSMinimumVersionForTesting(
  int nativeAssetsTargetVersion,
  Object? userDefine,
) {
  if (userDefine == null) return '$nativeAssetsTargetVersion.0';
  if (userDefine case final String value
      when RegExp(r'^[1-9][0-9]*[.][0-9]+$').hasMatch(value)) {
    return value;
  }
  throw FormatException(
    'ios_deployment_target must be a quoted major.minor version, '
    'found $userDefine.',
  );
}

List<String> iOSDeploymentTargetFlagsForTesting(
  int nativeAssetsTargetVersion,
  Object? userDefine,
) {
  if (userDefine == null) return const [];
  final minimumVersion = iOSMinimumVersionForTesting(
    nativeAssetsTargetVersion,
    userDefine,
  );
  return ['-mios-version-min=$minimumVersion'];
}

String macOSMinimumVersion(Object? userDefine) {
  if (userDefine case final String value
      when RegExp(r'^[1-9][0-9]*[.][0-9]+$').hasMatch(value)) {
    return value;
  }
  throw FormatException(
    'macos_deployment_target must be a quoted major.minor version, '
    'found $userDefine.',
  );
}

List<String> macOSDeploymentTargetFlags(Object? userDefine) => [
  '-mmacosx-version-min=${macOSMinimumVersion(userDefine)}',
];

OcamlArtifactTarget? _ocamlTarget(BuildInput input) {
  final config = input.config.code;
  if (config.targetOS == OS.macOS) {
    if (config.targetArchitecture == Architecture.x64) {
      throw StateError(
        'Unsupported macOS architecture x86_64; '
        'journal_lui_native supports arm64 only.',
      );
    }
    if (config.targetArchitecture != Architecture.arm64) return null;
    return OcamlArtifactTarget(
      operatingSystem: OcamlTargetOperatingSystem.macOS,
      architecture: OcamlTargetArchitecture.arm64,
      appleSdk: OcamlAppleSdk.macOS,
      minimumVersion: macOSMinimumVersion(
        input.userDefines['macos_deployment_target'],
      ),
    );
  }
  if (config.targetOS == OS.iOS) {
    final sdk = switch (config.iOS.targetSdk) {
      IOSSdk.iPhoneOS => OcamlAppleSdk.iPhoneOS,
      IOSSdk.iPhoneSimulator => throw StateError(
        'iOS Simulator is unsupported; use a physical iPhone.',
      ),
      _ => throw StateError('Unsupported iOS SDK ${config.iOS.targetSdk}.'),
    };
    if (config.targetArchitecture != Architecture.arm64) {
      throw StateError(
        'Unsupported iPhoneOS architecture ${config.targetArchitecture}; '
        'journal_lui_native supports arm64 only.',
      );
    }
    return OcamlArtifactTarget(
      operatingSystem: OcamlTargetOperatingSystem.iOS,
      architecture: OcamlTargetArchitecture.arm64,
      appleSdk: sdk,
      minimumVersion: iOSMinimumVersionForTesting(
        config.iOS.targetVersion,
        input.userDefines['ios_deployment_target'],
      ),
    );
  }
  return null;
}
