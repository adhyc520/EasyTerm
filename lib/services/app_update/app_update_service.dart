import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'github_release_client.dart';

enum AppUpdatePhase { idle, checking, downloading, installing }

/// Desktop auto-update via GitHub Releases (macOS arm64, Windows x64).
final class AppUpdateService {
  AppUpdateService({GithubReleaseClient? client})
    : _client = client ?? GithubReleaseClient();

  static const _kSkipVersion = 'wb_skip_update_version';

  final GithubReleaseClient _client;

  AppUpdatePhase phase = AppUpdatePhase.idle;
  double downloadProgress = 0;

  static bool get isSupportedPlatform => Platform.isMacOS || Platform.isWindows;

  /// Auto/manual update checks are disabled in debug runs (`flutter run`).
  static bool get isUpdateEnabled => isSupportedPlatform && !kDebugMode;

  Future<PackageInfo> packageInfo() => PackageInfo.fromPlatform();

  Future<AppVersion> currentVersion() async {
    final info = await packageInfo();
    return AppVersion.tryParse(info.version) ??
        AppVersion.tryParse('${info.version}+${info.buildNumber}') ??
        const AppVersion(major: 0, minor: 0, patch: 0);
  }

  /// Matches GitHub tag style (`v0.0.2`) for UI and release comparison hints.
  Future<String> currentVersionTagLabel() async {
    final info = await packageInfo();
    return AppVersion.formatTagLabel(info.version);
  }

  Future<String?> skippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSkipVersion);
  }

  Future<void> skipVersion(String versionLabel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkipVersion, versionLabel);
  }

  Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSkipVersion);
  }

  /// Returns available release when newer than installed; null if up to date.
  Future<AppUpdateCheckResult> checkForUpdates({
    bool respectSkipped = true,
  }) async {
    if (!isUpdateEnabled) {
      if (!isSupportedPlatform) {
        return AppUpdateCheckResult.unsupported();
      }
      final installed = await currentVersion();
      return AppUpdateCheckResult.upToDate(installed: installed);
    }
    phase = AppUpdatePhase.checking;
    try {
      final installed = await currentVersion();
      final release = await _client.fetchLatestRelease();
      if (release == null) {
        return AppUpdateCheckResult.error('No published release found.');
      }
      if (!release.version.isNewerThan(installed)) {
        return AppUpdateCheckResult.upToDate(installed: installed);
      }
      if (respectSkipped) {
        final skip = await skippedVersion();
        if (skip == release.tagName || skip == release.version.toString()) {
          return AppUpdateCheckResult.upToDate(installed: installed);
        }
      }
      return AppUpdateCheckResult.available(
        installed: installed,
        release: release,
      );
    } on GithubReleaseException catch (e) {
      return AppUpdateCheckResult.error(e.message);
    } catch (e) {
      return AppUpdateCheckResult.error(e.toString());
    } finally {
      phase = AppUpdatePhase.idle;
    }
  }

  /// Downloads the release asset, extracts it, and launches a platform updater.
  Future<void> downloadAndInstall(
    GithubRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    if (!isSupportedPlatform) {
      throw StateError('Updates are only supported on macOS and Windows.');
    }
    phase = AppUpdatePhase.downloading;
    downloadProgress = 0;
    onProgress?.call(0);

    final tempRoot = await getTemporaryDirectory();
    final workDir = Directory(
      p.join(tempRoot.path, 'easyterm-update', release.tagName),
    );
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
    await workDir.create(recursive: true);

    final zipPath = p.join(workDir.path, release.assetName);
    try {
      await _downloadFile(
        release.downloadUrl,
        zipPath,
        expectedBytes: release.sizeBytes,
        onProgress: (v) {
          downloadProgress = v;
          onProgress?.call(v);
        },
      );

      phase = AppUpdatePhase.installing;
      onProgress?.call(1);

      final staging = Directory(p.join(workDir.path, 'staging'));
      await staging.create(recursive: true);
      await _extractZip(zipPath, staging.path);

      if (Platform.isMacOS) {
        await _installMacos(staging.path);
      } else if (Platform.isWindows) {
        await _installWindows(staging.path);
      }
    } finally {
      phase = AppUpdatePhase.idle;
      downloadProgress = 0;
    }
  }

  Future<void> _downloadFile(
    String url,
    String destPath, {
    int? expectedBytes,
    required void Function(double progress) onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'EasyTerm-Updater';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw GithubReleaseException(
          'Download failed (${response.statusCode})',
        );
      }
      final total = response.contentLength ?? expectedBytes ?? 0;
      final file = File(destPath);
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.close();
      onProgress(1);
    } finally {
      client.close();
    }
  }

  Future<void> _extractZip(String zipPath, String destDir) async {
    await extractFileToDisk(zipPath, destDir);
  }

  Future<void> _installMacos(String stagingDir) async {
    final bundle = await _findMacosAppBundle(Directory(stagingDir));
    if (bundle == null) {
      throw GithubReleaseException('EasyTerm.app not found in update package.');
    }
    final target = _macosAppBundlePath();
    if (target == null) {
      throw GithubReleaseException('Could not locate the running application.');
    }

    final scriptPath = p.join(
      (await getTemporaryDirectory()).path,
      'easyterm-update-${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    final script =
        '''
#!/bin/bash
set -e
sleep 2
TARGET=${_shellQuote(target)}
SOURCE=${_shellQuote(bundle.path)}
BACKUP="\${TARGET}.bak"
rm -rf "\$BACKUP"
if [ -d "\$TARGET" ]; then
  mv "\$TARGET" "\$BACKUP"
fi
ditto "\$SOURCE" "\$TARGET"
rm -rf "\$BACKUP"
open "\$TARGET"
''';
    await File(scriptPath).writeAsString(script);
    await Process.start('/bin/chmod', ['+x', scriptPath]);
    await Process.start('/bin/bash', [
      scriptPath,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _installWindows(String stagingDir) async {
    final installDir = _windowsInstallDirectory();
    if (installDir == null) {
      throw GithubReleaseException('Could not locate install directory.');
    }
    final exeName = p.basename(Platform.resolvedExecutable);
    final scriptPath = p.join(
      (await getTemporaryDirectory()).path,
      'easyterm-update-${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    final script =
        '''
Start-Sleep -Seconds 2
\$src = ${_psQuote(stagingDir)}
\$dst = ${_psQuote(installDir)}
Copy-Item -Path (Join-Path \$src '*') -Destination \$dst -Recurse -Force
Start-Process (Join-Path \$dst ${_psQuote(exeName)})
''';
    await File(scriptPath).writeAsString(script, encoding: utf8);
    await Process.start('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  static Future<Directory?> _findMacosAppBundle(Directory root) async {
    if (p.basename(root.path).endsWith('.app')) return root;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory && entity.path.endsWith('.app')) {
        return entity;
      }
    }
    return null;
  }

  static String? _macosAppBundlePath() {
    var path = Platform.resolvedExecutable;
    for (var i = 0; i < 3; i++) {
      path = p.dirname(path);
    }
    if (path.endsWith('.app')) return path;
    return null;
  }

  static String? _windowsInstallDirectory() =>
      p.dirname(Platform.resolvedExecutable);

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  void dispose() => _client.close();
}

final class AppUpdateCheckResult {
  const AppUpdateCheckResult._({
    required this.kind,
    this.installed,
    this.release,
    this.errorMessage,
  });

  factory AppUpdateCheckResult.available({
    required AppVersion installed,
    required GithubRelease release,
  }) => AppUpdateCheckResult._(
    kind: AppUpdateCheckKind.updateAvailable,
    installed: installed,
    release: release,
  );

  factory AppUpdateCheckResult.upToDate({required AppVersion installed}) =>
      AppUpdateCheckResult._(
        kind: AppUpdateCheckKind.upToDate,
        installed: installed,
      );

  factory AppUpdateCheckResult.error(String message) => AppUpdateCheckResult._(
    kind: AppUpdateCheckKind.error,
    errorMessage: message,
  );

  factory AppUpdateCheckResult.unsupported() =>
      const AppUpdateCheckResult._(kind: AppUpdateCheckKind.unsupported);

  final AppUpdateCheckKind kind;
  final AppVersion? installed;
  final GithubRelease? release;
  final String? errorMessage;

  bool get hasUpdate => kind == AppUpdateCheckKind.updateAvailable;
}

enum AppUpdateCheckKind { updateAvailable, upToDate, error, unsupported }
