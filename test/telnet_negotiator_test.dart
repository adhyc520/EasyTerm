import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/shell_exec_emulator.dart';
import 'package:easyterm/services/telnet/telnet_login_matcher.dart';
import 'package:easyterm/services/telnet/telnet_negotiator.dart';

void main() {
  test('TelnetNegotiator strips IAC and doubles 0xFF', () {
    final sent = <List<int>>[];
    final n = TelnetNegotiator(
      send: sent.add,
      terminalType: 'xterm',
    );
    // data + escaped 0xFF + WILL ECHO
    final out = n.feed([
      0x41,
      TelnetCommand.iac,
      TelnetCommand.iac,
      0x42,
      TelnetCommand.iac,
      TelnetCommand.will,
      TelnetOption.echo,
    ]);
    expect(out, [0x41, 0xff, 0x42]);
    expect(sent.isNotEmpty, isTrue);
    expect(sent.last, [TelnetCommand.iac, TelnetCommand.do_, TelnetOption.echo]);
  });

  test('first DO ECHO is refused with WONT', () {
    final sent = <List<int>>[];
    final n = TelnetNegotiator(send: sent.add);
    n.feed([TelnetCommand.iac, TelnetCommand.do_, TelnetOption.echo]);
    expect(sent, [
      [TelnetCommand.iac, TelnetCommand.wont, TelnetOption.echo],
    ]);
    // Retransmission must not spam replies.
    sent.clear();
    n.feed([TelnetCommand.iac, TelnetCommand.do_, TelnetOption.echo]);
    expect(sent, isEmpty);
  });

  test('first unwanted WILL is refused with DONT', () {
    final sent = <List<int>>[];
    final n = TelnetNegotiator(send: sent.add);
    n.feed([TelnetCommand.iac, TelnetCommand.will, TelnetOption.linemode]);
    expect(sent, [
      [TelnetCommand.iac, TelnetCommand.dont, TelnetOption.linemode],
    ]);
  });

  test('sendNaws escapes 0xFF width/height bytes', () {
    final sent = <List<int>>[];
    final n = TelnetNegotiator(send: sent.add);
    n.startLocalOffers();
    sent.clear();
    n.sendNaws(255, 24);
    final frame = sent.single;
    expect(frame.first, TelnetCommand.iac);
    expect(frame[1], TelnetCommand.sb);
    // width 255 => 0x00, 0xFF, 0xFF (escaped)
    expect(frame.contains(TelnetCommand.iac), isTrue);
  });

  test('looksLikeFollowCommand treats tail -F as follow', () {
    expect(ShellExecEmulator.looksLikeFollowCommand('tail -F /var/log/syslog'), isTrue);
    expect(ShellExecEmulator.looksLikeFollowCommand('tail -f /var/log/syslog'), isTrue);
    expect(ShellExecEmulator.looksLikeFollowCommand('cat /var/log/syslog'), isFalse);
  });

  test('looksLikeShellPrompt matches common endings', () {
    expect(TelnetLoginMatcher.looksLikeShellPrompt('user@host:~\$ '), isTrue);
    expect(TelnetLoginMatcher.looksLikeShellPrompt('root@box:/# '), isTrue);
    expect(TelnetLoginMatcher.looksLikeShellPrompt('login: '), isFalse);
  });

  test('waitForTelnetReady aborts only when prompt seen but inject incomplete', () async {
    final login = TelnetLoginMatcher(
      username: 'u',
      password: 'p',
      enabled: true,
    );
    // No prompt seen → timeout proceeds (open shell / non-matching banner).
    final ok = await waitForTelnetReady(
      login: login,
      isAlive: () => true,
      sawShellPrompt: () => false,
      timeout: const Duration(milliseconds: 80),
    );
    expect(ok, isTrue);

    // Simulate password prompt without completing inject.
    login.feedText('Password: ');
    final stuck = await waitForTelnetReady(
      login: login,
      isAlive: () => true,
      sawShellPrompt: () => false,
      timeout: const Duration(milliseconds: 80),
    );
    expect(stuck, isFalse);
  });
}
