/// Serial line parameters (desktop native only).
enum SerialParity { none, even, odd, mark, space }

enum SerialFlowControl { none, xonXoff, rtsCts, dtrDsr }

class SerialPortConfig {
  const SerialPortConfig({
    required this.name,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.parity = SerialParity.none,
    this.stopBits = 1,
    this.flowControl = SerialFlowControl.none,
  });

  final String name;
  final int baudRate;
  final int dataBits;
  final SerialParity parity;
  final int stopBits;
  final SerialFlowControl flowControl;

  String get subtitle => '$name@$baudRate';

  Map<String, Object?> toJson() => {
        'name': name,
        'baudRate': baudRate,
        'dataBits': dataBits,
        'parity': parity.name,
        'stopBits': stopBits,
        'flowControl': flowControl.name,
      };

  factory SerialPortConfig.fromJson(Map<String, Object?> j) {
    return SerialPortConfig(
      name: j['name']?.toString() ?? '',
      baudRate: (j['baudRate'] as num?)?.toInt() ?? 115200,
      dataBits: (j['dataBits'] as num?)?.toInt() ?? 8,
      parity: SerialParity.values.firstWhere(
        (e) => e.name == j['parity']?.toString(),
        orElse: () => SerialParity.none,
      ),
      stopBits: (j['stopBits'] as num?)?.toInt() ?? 1,
      flowControl: SerialFlowControl.values.firstWhere(
        (e) => e.name == j['flowControl']?.toString(),
        orElse: () => SerialFlowControl.none,
      ),
    );
  }

  SerialPortConfig copyWith({
    String? name,
    int? baudRate,
    int? dataBits,
    SerialParity? parity,
    int? stopBits,
    SerialFlowControl? flowControl,
  }) {
    return SerialPortConfig(
      name: name ?? this.name,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      parity: parity ?? this.parity,
      stopBits: stopBits ?? this.stopBits,
      flowControl: flowControl ?? this.flowControl,
    );
  }
}
