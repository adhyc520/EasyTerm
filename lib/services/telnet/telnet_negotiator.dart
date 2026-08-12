import 'dart:typed_data';

/// Telnet command bytes (RFC 854).
class TelnetCommand {
  static const int iac = 255;
  static const int dont = 254;
  static const int do_ = 253;
  static const int wont = 252;
  static const int will = 251;
  static const int sb = 250;
  static const int se = 240;
  static const int goAhead = 249;
  static const int nop = 241;
}

/// Common Telnet options.
class TelnetOption {
  static const int echo = 1;
  static const int suppressGoAhead = 3;
  static const int status = 5;
  static const int terminalType = 24;
  static const int naws = 31;
  static const int terminalSpeed = 32;
  static const int linemode = 34;
  static const int newEnviron = 39;
}

typedef TelnetSendBytes = void Function(List<int> bytes);

/// RFC 854 IAC negotiator: strips commands from the byte stream and replies.
class TelnetNegotiator {
  TelnetNegotiator({
    required this.send,
    this.terminalType = 'xterm-256color',
    this.debugLog,
  });

  final TelnetSendBytes send;
  final String terminalType;
  final void Function(String message)? debugLog;

  int _cols = 80;
  int _rows = 24;
  bool _nawsEnabled = false;

  /// Remote (him) option enabled — RFC 1143 style; only reply on change.
  final Map<int, bool> _him = {};

  /// Local (us) option enabled.
  final Map<int, bool> _us = {};

  // Parser state
  static const int _stData = 0;
  static const int _stIac = 1;
  static const int _stWill = 2;
  static const int _stWont = 3;
  static const int _stDo = 4;
  static const int _stDont = 5;
  static const int _stSb = 6;
  static const int _stSbIac = 7;

  int _state = _stData;
  final List<int> _sb = [];

  /// Feed raw socket bytes; returns display payload with IAC sequences removed.
  List<int> feed(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    final out = <int>[];
    for (final b in bytes) {
      switch (_state) {
        case _stData:
          if (b == TelnetCommand.iac) {
            _state = _stIac;
          } else {
            out.add(b);
          }
        case _stIac:
          if (b == TelnetCommand.iac) {
            // Escaped 0xFF
            out.add(TelnetCommand.iac);
            _state = _stData;
          } else if (b == TelnetCommand.will) {
            _state = _stWill;
          } else if (b == TelnetCommand.wont) {
            _state = _stWont;
          } else if (b == TelnetCommand.do_) {
            _state = _stDo;
          } else if (b == TelnetCommand.dont) {
            _state = _stDont;
          } else if (b == TelnetCommand.sb) {
            _sb.clear();
            _state = _stSb;
          } else if (b == TelnetCommand.nop ||
              b == TelnetCommand.goAhead ||
              b == TelnetCommand.se) {
            _state = _stData;
          } else {
            // Unknown 2-byte command — ignore.
            _state = _stData;
          }
        case _stWill:
          _onWill(b);
          _state = _stData;
        case _stWont:
          _onWont(b);
          _state = _stData;
        case _stDo:
          _onDo(b);
          _state = _stData;
        case _stDont:
          _onDont(b);
          _state = _stData;
        case _stSb:
          if (b == TelnetCommand.iac) {
            _state = _stSbIac;
          } else {
            _sb.add(b);
          }
        case _stSbIac:
          if (b == TelnetCommand.se) {
            _onSubnegotiation(List<int>.from(_sb));
            _sb.clear();
            _state = _stData;
          } else if (b == TelnetCommand.iac) {
            _sb.add(TelnetCommand.iac);
            _state = _stSb;
          } else {
            _sb.add(TelnetCommand.iac);
            _sb.add(b);
            _state = _stSb;
          }
      }
    }
    return out;
  }

  void _log(String m) => debugLog?.call(m);

  void _sendCommand(int cmd, int opt) {
    send([TelnetCommand.iac, cmd, opt]);
  }

  bool _wantHim(int opt) {
    return opt == TelnetOption.echo || opt == TelnetOption.suppressGoAhead;
  }

  bool _wantUs(int opt) {
    return opt == TelnetOption.suppressGoAhead ||
        opt == TelnetOption.terminalType ||
        opt == TelnetOption.naws;
  }

  void _onWill(int opt) {
    _log('WILL $opt');
    final accept = _wantHim(opt);
    // Tri-state: unset must still get an explicit DO/DONT (RFC 854).
    final current = _him[opt];
    if (current == accept) return;
    _him[opt] = accept;
    _sendCommand(accept ? TelnetCommand.do_ : TelnetCommand.dont, opt);
  }

  void _onWont(int opt) {
    _log('WONT $opt');
    final current = _him[opt];
    if (current != true) {
      _him[opt] = false;
      return;
    }
    _him[opt] = false;
    _sendCommand(TelnetCommand.dont, opt);
  }

  void _onDo(int opt) {
    _log('DO $opt');
    final accept = _wantUs(opt);
    // Echo: server asks us to echo — refuse (server should echo).
    final effectiveAccept = opt == TelnetOption.echo ? false : accept;
    final current = _us[opt];
    if (current == effectiveAccept) {
      if (effectiveAccept && opt == TelnetOption.naws) {
        _nawsEnabled = true;
        sendNaws(_cols, _rows);
      }
      return;
    }
    _us[opt] = effectiveAccept;
    if (effectiveAccept) {
      _sendCommand(TelnetCommand.will, opt);
      if (opt == TelnetOption.naws) {
        _nawsEnabled = true;
        sendNaws(_cols, _rows);
      }
    } else {
      if (opt == TelnetOption.naws) _nawsEnabled = false;
      _sendCommand(TelnetCommand.wont, opt);
    }
  }

  void _onDont(int opt) {
    _log('DONT $opt');
    final already = _us[opt] == true;
    if (!already) {
      _us[opt] = false;
      if (opt == TelnetOption.naws) _nawsEnabled = false;
      return;
    }
    _us[opt] = false;
    if (opt == TelnetOption.naws) _nawsEnabled = false;
    _sendCommand(TelnetCommand.wont, opt);
  }

  void _onSubnegotiation(List<int> data) {
    if (data.isEmpty) return;
    final opt = data[0];
    if (opt == TelnetOption.terminalType && data.length >= 2 && data[1] == 1) {
      // SB TERMINAL-TYPE SEND
      final typeBytes = terminalType.codeUnits;
      final reply = <int>[
        TelnetCommand.iac,
        TelnetCommand.sb,
        TelnetOption.terminalType,
        0, // IS
        ...typeBytes,
        TelnetCommand.iac,
        TelnetCommand.se,
      ];
      send(reply);
    }
  }

  /// Announce WILL SUPPRESS-GO-AHEAD and WILL NAWS after connect.
  void startLocalOffers() {
    _us[TelnetOption.suppressGoAhead] = true;
    _sendCommand(TelnetCommand.will, TelnetOption.suppressGoAhead);
    _us[TelnetOption.naws] = true;
    _nawsEnabled = true;
    _sendCommand(TelnetCommand.will, TelnetOption.naws);
    sendNaws(_cols, _rows);
  }

  /// Send NAWS subnegotiation (width/height as 16-bit big-endian, 0xFF doubled).
  void sendNaws(int width, int height) {
    _cols = width.clamp(1, 0xffff);
    _rows = height.clamp(1, 0xffff);
    if (!_nawsEnabled) return;
    final w = _cols;
    final h = _rows;
    final body = <int>[
      TelnetOption.naws,
      (w >> 8) & 0xff,
      w & 0xff,
      (h >> 8) & 0xff,
      h & 0xff,
    ];
    final escaped = <int>[TelnetCommand.iac, TelnetCommand.sb];
    for (final b in body) {
      escaped.add(b);
      if (b == TelnetCommand.iac) escaped.add(TelnetCommand.iac);
    }
    escaped.add(TelnetCommand.iac);
    escaped.add(TelnetCommand.se);
    send(escaped);
  }

  /// Escape 0xFF bytes for raw payload that must pass through Telnet (e.g. ZMODEM).
  static Uint8List escapeIac(List<int> raw) {
    var need = false;
    for (final b in raw) {
      if (b == TelnetCommand.iac) {
        need = true;
        break;
      }
    }
    if (!need) return Uint8List.fromList(raw);
    final out = <int>[];
    for (final b in raw) {
      out.add(b);
      if (b == TelnetCommand.iac) out.add(TelnetCommand.iac);
    }
    return Uint8List.fromList(out);
  }
}
