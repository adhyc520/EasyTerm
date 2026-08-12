/// 主机分组。
class HostGroup {
  HostGroup({
    required this.id,
    required this.name,
    this.icon,
    this.color,
    List<String>? profileIds,
    this.expanded = true,
    required this.createdAtMs,
  }) : profileIds = List<String>.from(profileIds ?? const []);

  final String id;
  final String name;
  final String? icon;
  final String? color;
  final List<String> profileIds;
  bool expanded;
  final int createdAtMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'color': color,
    'profileIds': profileIds,
    'expanded': expanded,
    'createdAtMs': createdAtMs,
  };

  factory HostGroup.fromJson(Map<String, Object?> j) {
    final rawIds = j['profileIds'];
    final ids = <String>[];
    if (rawIds is List) {
      for (final e in rawIds) {
        if (e is String && e.isNotEmpty) ids.add(e);
      }
    }
    return HostGroup(
      id: j['id']! as String,
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? (j['name'] as String).trim()
          : 'Group',
      icon: j['icon'] as String?,
      color: j['color'] as String?,
      profileIds: ids,
      expanded: j['expanded'] as bool? ?? true,
      createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  HostGroup copyWith({
    String? name,
    String? icon,
    String? color,
    List<String>? profileIds,
    bool? expanded,
  }) {
    return HostGroup(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      profileIds: profileIds ?? this.profileIds,
      expanded: expanded ?? this.expanded,
      createdAtMs: createdAtMs,
    );
  }
}
