import 'dart:convert';

import 'package:easyterm/services/app_update/github_release_client.dart';
import 'package:easyterm/services/app_update/release_notes_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ReleaseNotesPreview', () {
    test('needsEnrichment for empty / Full Changelog-only bodies', () {
      expect(ReleaseNotesPreview.needsEnrichment(''), isTrue);
      expect(
        ReleaseNotesPreview.needsEnrichment(
          '**Full Changelog**: https://github.com/adhyc520/EasyTerm/compare/v0.0.8...v0.0.9',
        ),
        isTrue,
      );
      expect(
        ReleaseNotesPreview.needsEnrichment('''
## What's new

**Full Changelog**: https://github.com/adhyc520/EasyTerm/compare/v0.0.8...v0.0.9
'''),
        isTrue,
      );
    });

    test('keeps authored bullet notes', () {
      const body = '''
## What's new

- Fix SFTP drag drop
- Improve update dialog

**Full Changelog**: https://github.com/a/b/compare/v1...v2
''';
      expect(ReleaseNotesPreview.needsEnrichment(body), isFalse);
      final sanitized = ReleaseNotesPreview.sanitizeAuthoredBody(body);
      expect(sanitized, contains('Fix SFTP drag drop'));
      expect(sanitized, isNot(contains('Full Changelog')));
    });

    test('parseCompareRange extracts base/head', () {
      final range = ReleaseNotesPreview.parseCompareRange(
        '**Full Changelog**: https://github.com/adhyc520/EasyTerm/compare/v0.0.8...v0.0.9',
      );
      expect(range, isNotNull);
      expect(range!.$1, 'v0.0.8');
      expect(range.$2, 'v0.0.9');
    });

    test('formatCommitSummaries builds bullets and drops merges', () {
      final text = ReleaseNotesPreview.formatCommitSummaries([
        'feat: add preview\n\nlonger body',
        'Merge pull request #1',
        'feat: add preview',
        'fix(ui): polish dialog',
      ]);
      expect(text, '• add preview\n• polish dialog');
    });
  });

  group('GithubReleaseClient notes enrichment', () {
    test('replaces link-only notes with compare commit subjects', () async {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/releases/latest')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'v0.0.9',
              'name': 'v0.0.9',
              'body':
                  '**Full Changelog**: https://github.com/adhyc520/EasyTerm/compare/v0.0.8...v0.0.9',
              'html_url': 'https://github.com/adhyc520/EasyTerm/releases/tag/v0.0.9',
              'assets': [
                {
                  'name': 'easyterm-v0.0.9-macos-arm64.zip',
                  'browser_download_url':
                      'https://example.com/easyterm-v0.0.9-macos-arm64.zip',
                  'size': 12,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.contains('/compare/')) {
          return http.Response(
            jsonEncode({
              'commits': [
                {
                  'commit': {'message': '增强更新预览\n\ndetails'},
                },
                {
                  'commit': {'message': '修复发版说明为空'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      final client = GithubReleaseClient(
        client: mock,
        assetSuffixForTests: '-macos-arm64.zip',
      );
      final release = await client.fetchLatestRelease();
      expect(release, isNotNull);
      expect(release!.body, '• 增强更新预览\n• 修复发版说明为空');
      client.close();
    });

    test('keeps authored notes without calling compare', () async {
      var compareCalled = false;
      final mock = MockClient((request) async {
        if (request.url.path.contains('/compare/')) {
          compareCalled = true;
          return http.Response('{}', 200);
        }
        return http.Response(
          jsonEncode({
            'tag_name': 'v0.0.9',
            'name': 'v0.0.9',
            'body': '- Real note item\n- Another item',
            'html_url': 'https://github.com/adhyc520/EasyTerm/releases/tag/v0.0.9',
            'assets': [
              {
                'name': 'easyterm-v0.0.9-macos-arm64.zip',
                'browser_download_url':
                    'https://example.com/easyterm-v0.0.9-macos-arm64.zip',
                'size': 12,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = GithubReleaseClient(
        client: mock,
        assetSuffixForTests: '-macos-arm64.zip',
      );
      final release = await client.fetchLatestRelease();
      expect(release!.body, contains('Real note item'));
      expect(compareCalled, isFalse);
      client.close();
    });
  });
}
