import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'release_notes_preview.dart';

/// GitHub Releases API client for [adhyc520/EasyTerm].
///
/// Release assets from CI use tag [GITHUB_REF_NAME], e.g.
/// `easyterm-v0.0.3-windows-x64.zip`, `easyterm-v0.0.3-macos-arm64.zip`.
final class GithubReleaseClient {
  GithubReleaseClient({
    http.Client? client,
    String? assetSuffixForTests,
  }) : _client = client ?? http.Client(),
       _assetSuffixOverride = assetSuffixForTests;

  static const owner = 'adhyc520';
  static const repo = 'EasyTerm';

  final http.Client _client;
  final String? _assetSuffixOverride;

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

    final rawBody = (json['body'] as String? ?? '').trim();
    final body = await _resolveReleaseNotes(tag: tag, body: rawBody);

    return GithubRelease(
      tagName: tag,
      version: version,
      name: json['name'] as String? ?? tag,
      body: body,
      htmlUrl: json['html_url'] as String? ?? '',
      assetName: match['name'] as String? ?? suffix,
      downloadUrl: url,
      sizeBytes: (match['size'] as num?)?.toInt(),
    );
  }

  /// Prefer authored notes; when GitHub only left a compare link, pull commit
  /// subjects so the update dialog can preview roughly what changed.
  Future<String> _resolveReleaseNotes({
    required String tag,
    required String body,
  }) async {
    if (!ReleaseNotesPreview.needsEnrichment(body)) {
      return ReleaseNotesPreview.sanitizeAuthoredBody(body);
    }

    final range =
        ReleaseNotesPreview.parseCompareRange(body) ??
        await _inferCompareRange(tag);
    if (range == null) {
      return ReleaseNotesPreview.sanitizeAuthoredBody(body);
    }

    try {
      final subjects = await _fetchCompareSubjects(range.$1, range.$2);
      final preview = ReleaseNotesPreview.formatCommitSummaries(subjects);
      if (preview.isNotEmpty) return preview;
    } catch (_) {
      // Fall through to original body / empty.
    }
    return ReleaseNotesPreview.sanitizeAuthoredBody(body);
  }

  Future<(String base, String head)?> _inferCompareRange(String tag) async {
    final response = await _client.get(
      Uri.parse(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=2',
      ),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'EasyTerm-Updater',
      },
    );
    if (response.statusCode != 200) return null;
    final list = jsonDecode(response.body);
    if (list is! List || list.length < 2) return null;
    final latest = list[0] as Map<String, dynamic>;
    final previous = list[1] as Map<String, dynamic>;
    final latestTag = latest['tag_name'] as String? ?? '';
    final previousTag = previous['tag_name'] as String? ?? '';
    if (latestTag != tag || previousTag.isEmpty) return null;
    return (previousTag, latestTag);
  }

  Future<List<String>> _fetchCompareSubjects(String base, String head) async {
    final response = await _client.get(
      Uri.parse(
        'https://api.github.com/repos/$owner/$repo/compare/'
        '${Uri.encodeComponent(base)}...${Uri.encodeComponent(head)}',
      ),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'EasyTerm-Updater',
      },
    );
    if (response.statusCode != 200) {
      throw GithubReleaseException(
        'GitHub compare API ${response.statusCode}: ${response.reasonPhrase}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final commits = json['commits'] as List<dynamic>? ?? const [];
    final subjects = <String>[];
    for (final raw in commits) {
      final commit = raw as Map<String, dynamic>;
      final detail = commit['commit'] as Map<String, dynamic>? ?? const {};
      final message = detail['message'] as String? ?? '';
      if (message.isNotEmpty) subjects.add(message);
    }
    return subjects;
  }

  String? _assetSuffixForPlatform() {
    if (_assetSuffixOverride != null) return _assetSuffixOverride;
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
