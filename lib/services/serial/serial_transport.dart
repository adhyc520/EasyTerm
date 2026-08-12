import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart' as sp;

import '../../models/serial_port_config.dart';

/// Serial port facade over `flutter_libserialport`.
class SerialTransport {
  SerialTransport();

  sp.SerialPort? _port;
  sp.SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _sub;
  final _controller = StreamController<Uint8List>.broadcast();
  bool _open = false;

  bool get isOpen => _open;
  Stream<Uint8List> get input => _controller.stream;

  static Future<List<String>> availablePorts() async {
    if (kIsWeb) return const [];
    try {
      return List<String>.from(sp.SerialPort.availablePorts);
    } catch (e) {
      debugPrint('SerialTransport.availablePorts: $e');
      return const [];
    }
  }

  Future<void> open(SerialPortConfig cfg) async {
    if (kIsWeb) {
      throw UnsupportedError('串口在 Web 上不可用');
    }
    await close();
    final name = cfg.name.trim();
    if (name.isEmpty) {
      throw ArgumentError('串口名不能为空');
    }
    final port = sp.SerialPort(name);
    if (!port.openReadWrite()) {
      final err = sp.SerialPort.lastError;
      throw StateError('无法打开串口 $name：${err?.message ?? 'unknown'}');
    }
    final config = sp.SerialPortConfig();
    config.baudRate = cfg.baudRate;
    config.bits = cfg.dataBits;
    config.stopBits = cfg.stopBits;
    config.parity = switch (cfg.parity) {
      SerialParity.none => sp.SerialPortParity.none,
      SerialParity.even => sp.SerialPortParity.even,
      SerialParity.odd => sp.SerialPortParity.odd,
      SerialParity.mark => sp.SerialPortParity.mark,
      SerialParity.space => sp.SerialPortParity.space,
    };
    config.setFlowControl(switch (cfg.flowControl) {
      SerialFlowControl.none => sp.SerialPortFlowControl.none,
      SerialFlowControl.xonXoff => sp.SerialPortFlowControl.xonXoff,
      SerialFlowControl.rtsCts => sp.SerialPortFlowControl.rtsCts,
      SerialFlowControl.dtrDsr => sp.SerialPortFlowControl.dtrDsr,
    });
    port.config = config;
    config.dispose();

    final reader = sp.SerialPortReader(port);
    _port = port;
    _reader = reader;
    _sub = reader.stream.listen(
      (data) {
        if (!_controller.isClosed) _controller.add(data);
      },
      onError: (Object e) {
        if (!_controller.isClosed) _controller.addError(e);
      },
    );
    _open = true;
  }

  void add(List<int> bytes) {
    final port = _port;
    if (!_open || port == null || bytes.isEmpty) return;
    try {
      port.write(Uint8List.fromList(bytes));
    } catch (e) {
      debugPrint('Serial write failed: $e');
    }
  }

  Future<void> close() async {
    _open = false;
    await _sub?.cancel();
    _sub = null;
    try {
      _reader?.close();
    } catch (_) {}
    _reader = null;
    try {
      _port?.close();
    } catch (_) {}
    try {
      _port?.dispose();
    } catch (_) {}
    _port = null;
  }

  Future<void> dispose() async {
    await close();
    if (!_controller.isClosed) await _controller.close();
  }
}
