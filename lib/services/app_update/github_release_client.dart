import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'app_version.dart';

/// GitHub Releases API client for [adhyc520/EasyTerm].
///
/// Release assets from CI use tag [GITHUB_REF_NAME], e.g.
/// `easyterm-v0.0.3-windows-x64.zip`, `easyterm-v0.0.3-macos-arm64.zip`.
final class GithubReleaseClient {
  GithubReleaseClient({http.Client? client})
    : _client = client ?? http.Client();

  static const owner = 'adhyc520';
  static const repo = 'EasyTerm';

  final http.Client _client;

  Uri get _latestUri =>
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  Future<GithubRelease?> fetchLatestRelease() async {
    final response = await _client.get(
      _latestUri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'EasyTerm-Updater',
      },
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw GithubReleaseException(
        'GitHub API ${response.statusCode}: ${response.reasonPhrase}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null) {
      throw GithubReleaseException('Invalid release tag: $tag');
    }
    final assets = json['assets'] as List<dynamic>? ?? const [];
    final suffix = _assetSuffixForPlatform();
    if (suffix == null) return null;

    Map<String, dynamic>? match;
    for (final raw in assets) {
      final asset = raw as Map<String, dynamic>;
      final name = asset['name'] as String? ?? '';
      if (name.endsWith(suffix)) {
        match = asset;
        break;
      }
    }
    if (match == null) {
      throw GithubReleaseException(
        'No release asset for this platform ($suffix)',
      );
    }

    final url = match['browser_download_url'] as String?;
    if (url == null || url.isEmpty) {
      throw GithubReleaseException('Missing download URL for $suffix');
    }

    return GithubRelease(
      tagName: tag,
      version: version,
      name: json['name'] as String? ?? tag,
      body: (json['body'] as String? ?? '').trim(),
      htmlUrl: json['html_url'] as String? ?? '',
      assetName: match['name'] as String? ?? suffix,
      downloadUrl: url,
      sizeBytes: (match['size'] as num?)?.toInt(),
    );
  }

  static String? _assetSuffixForPlatform() {
    if (Platform.isWindows) return '-windows-x64.zip';
    if (Platform.isMacOS) return '-macos-arm64.zip';
    return null;
  }

  void close() => _client.close();
}

final class GithubRelease {
  const GithubRelease({
    required this.tagName,
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.assetName,
    required this.downloadUrl,
    this.sizeBytes,
  });

  final String tagName;
  final AppVersion version;
  final String name;
  final String body;
  final String htmlUrl;
  final String assetName;
  final String downloadUrl;
  final int? sizeBytes;
}

final class GithubReleaseException implements Exception {
  GithubReleaseException(this.message);
  final String message;
  @override
  String toString() => message;
}
