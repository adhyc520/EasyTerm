import 'dart:async';
import 'dart:convert';

import 'package:easyterm/models/proxy_config.dart';
import 'package:easyterm/services/llm_openai_chat_service.dart';
import 'package:easyterm/services/llm_tool_executor.dart';
import 'package:easyterm/services/shell_exec_emulator.dart';
import 'package:easyterm/services/ssh_config_importer.dart';
import 'package:easyterm/services/telnet/telnet_login_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProxyConfig persistence', () {
    test('toJson omits privateKeyPem and keeps keyPath', () {
      final cfg = ProxyConfig(
        type: ProxyType.sshJump,
        host: 'jump.example',
        port: 22,
        username: 'jump',
        password: 'secret',
        keyPath: '/home/u/.ssh/id_ed25519',
        privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\nxxx\n',
      );
      final json = cfg.toJson();
      expect(json.containsKey('privateKeyPem'), isFalse);
      expect(json['keyPath'], '/home/u/.ssh/id_ed25519');
      expect(json['password'], 'secret');

      final loaded = ProxyConfig.fromJson({
        ...json,
        'privateKeyPem': '-----BEGIN SHOULD BE IGNORED-----\n',
      });
      expect(loaded.privateKeyPem, isNull);
      expect(loaded.keyPath, '/home/u/.ssh/id_ed25519');
    });
  });

  group('SshConfigImporter ProxyJump', () {
    test('resolves Host alias to HostName/User/IdentityFile', () {
      const text = '''
Host bastion
  HostName 10.0.0.1
  User jump
  Port 2222
  IdentityFile ~/.ssh/bastion_key

Host app
  HostName 10.0.0.2
  User deploy
  ProxyJump bastion
''';
      final importer = SshConfigImporter();
      final entries = importer.parseConfigText(text);
      final profiles = importer.toProfiles(entries);
      final app = profiles.firstWhere((p) => p.label == 'app');
      final proxy = app.proxyConfig!;
      expect(proxy.host, '10.0.0.1');
      expect(proxy.port, 2222);
      expect(proxy.username, 'jump');
      expect(proxy.keyPath, endsWith('bastion_key'));
      expect(proxy.privateKeyPem, isNull);
    });

    test('user@host form still parses and can fill IdentityFile from alias', () {
      const text = '''
Host jumpbox
  HostName jump.internal
  User ops
  IdentityFile /tmp/jump.pem

Host target
  HostName target.internal
  User root
  ProxyJump other@jumpbox:2200
''';
      final importer = SshConfigImporter();
      final profiles = importer.toProfiles(importer.parseConfigText(text));
      final target = profiles.firstWhere((p) => p.label == 'target');
      final proxy = target.proxyConfig!;
      expect(proxy.host, 'jump.internal');
      expect(proxy.port, 2200);
      expect(proxy.username, 'other');
      expect(proxy.keyPath, '/tmp/jump.pem');
    });
  });

  group('ShellExecEmulator exit code', () {
    test('captures non-zero exit from sentinel', () async {
      final backend = _ScriptedBackend();
      final emu = ShellExecEmulator(backend);
      // Respond after script is written.
      backend.onWrite = (bytes) {
        final script = utf8.decode(bytes);
        final begin =
            RegExp(r"printf '%s' '([^']+)'").firstMatch(script)?.group(1);
        final end = RegExp(
          r"printf '\\n%s:%s\\n' '([^']+)'",
        ).firstMatch(script)?.group(1);
        if (begin == null || end == null) return;
        scheduleMicrotask(() {
          backend.emit(utf8.encode('$begin\nfail-output\n$end:1\n'));
        });
      };

      final out = await emu.run('false', timeout: const Duration(seconds: 2));
      expect(out, contains('fail-output'));
      expect(emu.lastExitCode, 1);
      await emu.dispose();
    });

    test('captures zero exit', () async {
      final backend = _ScriptedBackend();
      final emu = ShellExecEmulator(backend);
      backend.onWrite = (bytes) {
        final script = utf8.decode(bytes);
        final begin = RegExp(r"printf '%s' '([^']+)'").firstMatch(script)?.group(1);
        final end = RegExp(
          r"printf '\\n%s:%s\\n' '([^']+)'",
        ).firstMatch(script)?.group(1);
        if (begin == null || end == null) return;
        scheduleMicrotask(() {
          backend.emit(utf8.encode('${begin}ok$end:0\n'));
        });
      };
      final out = await emu.run('true', timeout: const Duration(seconds: 2));
      expect(out, 'ok');
      expect(emu.lastExitCode, 0);
      await emu.dispose();
    });
  });

  group('TelnetLoginMatcher prompts', () {
    test('ignores password mention inside MOTD', () {
      final m = TelnetLoginMatcher(username: '', password: 'secret');
      final out = m.feedText(
        'Welcome!\nPlease change your password: see /etc/motd\n',
      );
      expect(out, isEmpty);
      expect(m.sawCredentialPrompt, isFalse);
    });

    test('injects on real password prompt line', () {
      final m = TelnetLoginMatcher(username: '', password: 'secret');
      final out = m.feedText('Password: ');
      expect(utf8.decode(out), 'secret\r');
      expect(m.injectComplete, isTrue);
    });

    test('login then password', () {
      final m = TelnetLoginMatcher(username: 'alice', password: 'pw');
      expect(m.feedText('login: '), utf8.encode('alice\r'));
      expect(m.feedText('\nPassword:'), utf8.encode('pw\r'));
      expect(m.injectComplete, isTrue);
    });

    test('accepts prefixed and ANSI-colored prompts', () {
      final m = TelnetLoginMatcher(username: 'bob', password: 's3cret');
      expect(
        m.feedText('Please login: '),
        utf8.encode('bob\r'),
      );
      expect(
        m.feedText('\n\x1b[1mroot\'s password: \x1b[0m'),
        utf8.encode('s3cret\r'),
      );
      expect(m.injectComplete, isTrue);
    });

    test('accepts Username prompt used by network gear', () {
      final m = TelnetLoginMatcher(username: 'admin', password: 'x');
      expect(m.feedText('Username: '), utf8.encode('admin\r'));
      expect(m.feedText('\nPassword: '), utf8.encode('x\r'));
    });

    test('matches chunked password prompt', () {
      final m = TelnetLoginMatcher(username: '', password: 'p');
      expect(m.feedText('Pass'), isEmpty);
      expect(utf8.decode(m.feedText('word: ')), 'p\r');
    });
  });

  group('LLM tool arg helpers', () {
    test('parseToolArgs accepts non-string values via map', () {
      final args = parseToolArgs({'path': 123, 'content': true});
      expect(args['path'], 123);
      // LlmOpenAiChatService._argString is private; FileWrite uses registry which
      // uses _argString — verify truncateToolOutput / toolJson helpers still work.
      expect(toolJsonOk({'n': 1}), contains('"ok":true'));
    });

    test('messagesForApiRequest keeps tool_call_id', () {
      final out = LlmOpenAiChatService.messagesForApiRequest([
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': '{"ok":false}',
          '_ui_tool': {'name': 'file_write', 'status': 'failure'},
        },
      ]);
      expect(out.single['tool_call_id'], 'call_1');
      expect(out.single.containsKey('_ui_tool'), isFalse);
    });
  });
}

class _ScriptedBackend implements ShellBackend {
  final _ctrl = StreamController<List<int>>.broadcast();
  void Function(List<int> bytes)? onWrite;

  @override
  Stream<List<int>> get output => _ctrl.stream;

  @override
  void write(List<int> bytes) => onWrite?.call(bytes);

  void emit(List<int> bytes) {
    if (!_ctrl.isClosed) _ctrl.add(bytes);
  }
}
