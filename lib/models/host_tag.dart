/// 主机标签。
class HostTag {
  HostTag({required this.id, required this.name, this.color});

  final String id;
  final String name;
  final String? color;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'color': color};

  factory HostTag.fromJson(Map<String, Object?> j) {
    return HostTag(
      id: j['id']! as String,
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? (j['name'] as String).trim()
          : 'Tag',
      color: j['color'] as String?,
    );
  }
}
