import 'dart:convert';

import 'package:charset/charset.dart' as cs;

/// Character encodings for Telnet / Serial (SSH remains UTF-8).
enum TerminalEncoding {
  utf8,
  gbk,
  big5,
  latin1,
  shiftJis;

  String get displayName => switch (this) {
        TerminalEncoding.utf8 => 'UTF-8',
        TerminalEncoding.gbk => 'GBK',
        TerminalEncoding.big5 => 'Big5',
        TerminalEncoding.latin1 => 'Latin-1',
        TerminalEncoding.shiftJis => 'Shift-JIS',
      };

  static TerminalEncoding fromName(String? name) {
    switch (name?.trim().toLowerCase()) {
      case 'gbk':
        return TerminalEncoding.gbk;
      case 'big5':
      case 'big-5':
      case 'cn-big5':
        return TerminalEncoding.big5;
      case 'latin1':
      case 'iso-8859-1':
        return TerminalEncoding.latin1;
      case 'shiftjis':
      case 'shift_jis':
      case 'shift-jis':
        return TerminalEncoding.shiftJis;
      default:
        return TerminalEncoding.utf8;
    }
  }

  /// Codec for encode/decode. UTF-8 allows malformed input.
  Encoding get codec {
    switch (this) {
      case TerminalEncoding.utf8:
        return const Utf8Codec(allowMalformed: true);
      case TerminalEncoding.gbk:
        return cs.gbk;
      case TerminalEncoding.big5:
        final e = cs.Charset.getByName('big5');
        if (e is Encoding) return e;
        return const Latin1Codec(allowInvalid: true);
      case TerminalEncoding.latin1:
        return const Latin1Codec(allowInvalid: true);
      case TerminalEncoding.shiftJis:
        return cs.shiftJis;
    }
  }
}
