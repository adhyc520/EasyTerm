import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Keyboard copy-mode state machine (tmux/vi-style) over terminal buffer coords.
class TerminalCopyMode {
  TerminalCopyMode(this.terminal);

  Terminal terminal;

  bool _active = false;
  int _cursorRow = 0;
  int _cursorCol = 0;
  int _selRow = -1;
  int _selCol = -1;
  bool _visual = false;

  bool get active => _active;
  bool get visualMode => _visual;
  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;

  CellOffset get cursor => CellOffset(_cursorCol, _cursorRow);

  /// Inclusive selection range when in visual mode; otherwise null.
  (CellOffset start, CellOffset end)? get selection {
    if (!_visual || _selRow < 0) return null;
    final a = CellOffset(_selCol, _selRow);
    final b = CellOffset(_cursorCol, _cursorRow);
    final aFirst = a.y < b.y || (a.y == b.y && a.x <= b.x);
    return aFirst ? (a, b) : (b, a);
  }

  void enter() {
    final buf = terminal.buffer;
    _active = true;
    _visual = false;
    _selRow = -1;
    _selCol = -1;
    final maxRow = (buf.height - 1).clamp(0, 1 << 20);
    final maxCol = (buf.viewWidth - 1).clamp(0, 1 << 20);
    _cursorRow = buf.absoluteCursorY.clamp(0, maxRow);
    _cursorCol = buf.cursorX.clamp(0, maxCol);
  }

  void exit() {
    _active = false;
    _visual = false;
    _selRow = -1;
    _selCol = -1;
  }

  void moveCursor(int dRow, int dCol) {
    if (!_active) return;
    final buf = terminal.buffer;
    final maxRow = (buf.height - 1).clamp(0, 1 << 20);
    final maxCol = (buf.viewWidth - 1).clamp(0, 1 << 20);
    _cursorRow = (_cursorRow + dRow).clamp(0, maxRow);
    _cursorCol = (_cursorCol + dCol).clamp(0, maxCol);
  }

  void toggleVisual() {
    if (!_active) return;
    if (_visual) {
      _visual = false;
      _selRow = -1;
      _selCol = -1;
    } else {
      _visual = true;
      _selRow = _cursorRow;
      _selCol = _cursorCol;
    }
  }

  /// Returns selected text (or empty). Does not exit copy mode.
  String yankText() {
    final sel = selection;
    if (sel == null) {
      // Yank current cell / line start — empty if nothing selected.
      return '';
    }
    final (begin, end) = sel;
    final range = BufferRangeLine(begin, end);
    return terminal.buffer.getText(range);
  }

  /// Handle a key while copy mode is active. Returns true if consumed.
  bool handleKey(LogicalKeyboardKey key, {String? character}) {
    if (!_active) return false;

    if (key == LogicalKeyboardKey.escape) {
      exit();
      return true;
    }
    if (key == LogicalKeyboardKey.keyV || character == 'v') {
      toggleVisual();
      return true;
    }
    if (key == LogicalKeyboardKey.keyY || character == 'y') {
      // Caller copies clipboard; we only compute.
      return true;
    }
    if (key == LogicalKeyboardKey.keyH ||
        key == LogicalKeyboardKey.arrowLeft ||
        character == 'h') {
      moveCursor(0, -1);
      return true;
    }
    if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.arrowRight ||
        character == 'l') {
      moveCursor(0, 1);
      return true;
    }
    if (key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.arrowUp ||
        character == 'k') {
      moveCursor(-1, 0);
      return true;
    }
    if (key == LogicalKeyboardKey.keyJ ||
        key == LogicalKeyboardKey.arrowDown ||
        character == 'j') {
      moveCursor(1, 0);
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 || character == '0') {
      _cursorCol = 0;
      return true;
    }
    if ((key == LogicalKeyboardKey.digit4 &&
            HardwareKeyboard.instance.isShiftPressed) ||
        character == '\$') {
      _cursorCol = (terminal.buffer.viewWidth - 1).clamp(0, 1 << 20);
      return true;
    }
    if (character == 'G' ||
        (key == LogicalKeyboardKey.keyG &&
            HardwareKeyboard.instance.isShiftPressed)) {
      _cursorRow = (terminal.buffer.height - 1).clamp(0, 1 << 20);
      return true;
    }
    if (character == 'g' || key == LogicalKeyboardKey.keyG) {
      _cursorRow = 0;
      return true;
    }
    if (character == 'w') {
      moveCursor(0, 4);
      return true;
    }
    if (character == 'b') {
      moveCursor(0, -4);
      return true;
    }
    // Swallow other keys so they don't reach the PTY.
    return true;
  }
}
