import 'dart:io';

enum OcamlTargetOperatingSystem { macOS, iOS }

enum OcamlTargetArchitecture { arm64 }

enum OcamlAppleSdk { macOS, iPhoneOS }

enum OcamlMachOPlatform { macOS, iOS }

enum OcamlArtifactVariant {
  debug,
  profile,
  release;

  static OcamlArtifactVariant fromProfileName(String? profile) {
    return switch (profile) {
      'debug' => debug,
      'profile' => OcamlArtifactVariant.profile,
      'release' => release,
      _ => throw FormatException(
        'native_artifact_profile must be debug, profile, or release; '
        'found $profile.',
      ),
    };
  }
}

final class OcamlArtifactTarget {
  final OcamlTargetOperatingSystem operatingSystem;
  final OcamlTargetArchitecture architecture;
  final OcamlAppleSdk appleSdk;
  final String minimumVersion;

  const OcamlArtifactTarget({
    required this.operatingSystem,
    required this.architecture,
    required this.appleSdk,
    required this.minimumVersion,
  });

  String get artifactPath {
    return artifactPathFor();
  }

  String artifactPathFor({OcamlArtifactVariant? variant}) {
    final architectureDirectory = architecture.name;
    final variantDirectory = variant == null ? '' : '${variant.name}/';
    return switch (appleSdk) {
      OcamlAppleSdk.macOS =>
        'macos/$architectureDirectory/'
            '${variantDirectory}native_embed.exe.o',
      OcamlAppleSdk.iPhoneOS =>
        'ios/iphoneos/$architectureDirectory/'
            '${variantDirectory}native_embed.exe.o',
    };
  }

  String get description =>
      '${_operatingSystemLabel(operatingSystem)} '
      '${architecture.name} ${_sdkLabel(appleSdk)} minimum $minimumVersion';
}

final class OcamlArtifactMetadata {
  final OcamlMachOPlatform platform;
  final OcamlTargetArchitecture architecture;
  final OcamlAppleSdk appleSdk;
  final String minimumVersion;

  const OcamlArtifactMetadata({
    required this.platform,
    required this.architecture,
    required this.appleSdk,
    required this.minimumVersion,
  });
}

typedef OcamlArtifactInspector =
    Future<OcamlArtifactMetadata> Function(File object);

final class OcamlArtifactResolver {
  final OcamlArtifactInspector inspect;

  OcamlArtifactResolver({OcamlArtifactInspector? inspect})
    : inspect = inspect ?? inspectOcamlArtifact;

  Future<File?> resolve({
    required Uri? nativeArtifactRoot,
    required bool requireOcamlBackend,
    required OcamlArtifactTarget target,
    OcamlArtifactVariant? variant,
  }) async {
    if (nativeArtifactRoot == null) {
      if (requireOcamlBackend) {
        throw StateError(
          'require_ocaml_backend is enabled, but native_artifact_root is '
          'missing for ${target.description}.',
        );
      }
      return null;
    }

    final object = File.fromUri(
      nativeArtifactRoot.resolve(target.artifactPathFor(variant: variant)),
    );
    if (!object.existsSync()) {
      throw StateError(
        'Required OCaml complete object is missing for '
        '${target.description}. Expected ${object.path}.',
      );
    }

    final metadata = await inspect(object);
    final expectedPlatform = switch (target.appleSdk) {
      OcamlAppleSdk.macOS => OcamlMachOPlatform.macOS,
      OcamlAppleSdk.iPhoneOS => OcamlMachOPlatform.iOS,
    };
    if (metadata.platform != expectedPlatform) {
      throw StateError(
        'OCaml object platform mismatch for ${target.description}: '
        'found ${metadata.platform.name} at ${object.path}.',
      );
    }
    if (metadata.architecture != target.architecture) {
      throw StateError(
        'OCaml object architecture mismatch for ${target.description}: '
        'found ${metadata.architecture.name} at ${object.path}.',
      );
    }
    if (metadata.appleSdk != target.appleSdk) {
      throw StateError(
        'OCaml object SDK mismatch for ${target.description}: '
        'found ${_sdkLabel(metadata.appleSdk)} at ${object.path}.',
      );
    }
    if (metadata.minimumVersion != target.minimumVersion) {
      throw StateError(
        'OCaml object minimum version mismatch for ${target.description}: '
        'found ${metadata.minimumVersion} at ${object.path}.',
      );
    }
    return object;
  }
}

Future<OcamlArtifactMetadata> inspectOcamlArtifact(File object) async {
  final fileOutput = await _run('file', [object.path]);
  final architecture = switch (fileOutput) {
    final output when output.contains('arm64') => OcamlTargetArchitecture.arm64,
    _ => throw StateError(
      'Unsupported Mach-O architecture for ${object.path}: $fileOutput',
    ),
  };

  final architectures = (await _run('xcrun', [
    'lipo',
    '-archs',
    object.path,
  ])).trim();
  if (architectures != architecture.name) {
    throw StateError(
      'OCaml object must contain exactly ${architecture.name}; '
      'found "$architectures" at ${object.path}.',
    );
  }

  final build = await _run('xcrun', ['vtool', '-show-build', object.path]);
  final platformMatch = RegExp(
    r'^\s*platform\s+(\S+)\s*$',
    multiLine: true,
  ).firstMatch(build);
  final minimumMatch = RegExp(
    r'^\s*minos\s+(\S+)\s*$',
    multiLine: true,
  ).firstMatch(build);
  if (platformMatch == null || minimumMatch == null) {
    throw StateError(
      'OCaml object has no complete LC_BUILD_VERSION at ${object.path}.',
    );
  }

  final (platform, sdk) = switch (platformMatch.group(1)) {
    'MACOS' => (OcamlMachOPlatform.macOS, OcamlAppleSdk.macOS),
    'IOS' => (OcamlMachOPlatform.iOS, OcamlAppleSdk.iPhoneOS),
    final value => throw StateError(
      'Unsupported Mach-O platform $value at ${object.path}.',
    ),
  };

  final loadCommands = await _run('xcrun', ['otool', '-l', object.path]);
  if (RegExp(r'\b__LLVM\b').hasMatch(loadCommands)) {
    throw StateError('Bitcode segment __LLVM is prohibited at ${object.path}.');
  }

  return OcamlArtifactMetadata(
    platform: platform,
    architecture: architecture,
    appleSdk: sdk,
    minimumVersion: minimumMatch.group(1)!,
  );
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed with exit code '
      '${result.exitCode}: ${result.stderr}',
    );
  }
  return result.stdout as String;
}

String _operatingSystemLabel(OcamlTargetOperatingSystem operatingSystem) =>
    switch (operatingSystem) {
      OcamlTargetOperatingSystem.macOS => 'macOS',
      OcamlTargetOperatingSystem.iOS => 'iOS',
    };

String _sdkLabel(OcamlAppleSdk sdk) => switch (sdk) {
  OcamlAppleSdk.macOS => 'macOS',
  OcamlAppleSdk.iPhoneOS => 'iPhoneOS',
};
