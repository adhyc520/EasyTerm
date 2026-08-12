import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../io/host_profiles_disk.dart';
import '../models/connection_protocol.dart';
import '../models/host_group.dart';
import '../models/host_tag.dart';
import '../models/proxy_config.dart';
import '../models/saved_host_profile.dart';
import '../models/serial_port_config.dart';
import 'terminal_charset.dart';

/// 持久化「设备」连接模板；可选保存 [SavedHostProfile.password] 以便免二次输入。
///
/// 磁盘格式为 `{profiles, groups, tags}`；旧版纯数组仍可加载（仅 profiles）。
class HostProfilesStore extends ChangeNotifier {
  HostProfilesStore();

  final List<SavedHostProfile> profiles = [];
  final List<HostGroup> groups = [];
  final List<HostTag> tags = [];
  bool _loaded = false;
  Future<void>? _diskLoadFuture;

  /// 从磁盘读出一次；未完成前 mutator 会在此等待，避免与 [profiles.clear] 交错抹掉刚写入的条目。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _diskLoadFuture ??= _loadProfilesFromDisk();
    await _diskLoadFuture;
    _loaded = true;
    _diskLoadFuture = null;
  }

  Future<void> _loadProfilesFromDisk() async {
    if (kIsWeb) {
      notifyListeners();
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final path = '${dir.path}/easyterm_host_profiles.json';
      final raw = await readUtf8IfExists(path);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        profiles.clear();
        groups.clear();
        tags.clear();
        if (decoded is List) {
          profiles.addAll(
            decoded.map(
              (e) => SavedHostProfile.fromJson(
                Map<String, Object?>.from(e as Map),
              ),
            ),
          );
        } else if (decoded is Map) {
          final map = Map<String, Object?>.from(decoded);
          final plist = map['profiles'];
          if (plist is List) {
            profiles.addAll(
              plist.map(
                (e) => SavedHostProfile.fromJson(
                  Map<String, Object?>.from(e as Map),
                ),
              ),
            );
          }
          final glist = map['groups'];
          if (glist is List) {
            groups.addAll(
              glist.map(
                (e) => HostGroup.fromJson(Map<String, Object?>.from(e as Map)),
              ),
            );
          }
          final tlist = map['tags'];
          if (tlist is List) {
            tags.addAll(
              tlist.map(
                (e) => HostTag.fromJson(Map<String, Object?>.from(e as Map)),
              ),
            );
          }
        }
        profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      }
    } catch (e, st) {
      debugPrint('HostProfilesStore load: $e\n$st');
    }
    notifyListeners();
  }

  Future<String> _profilesPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/easyterm_host_profiles.json';
  }

  Future<void> _persist() async {
    if (kIsWeb) return;
    final path = await _profilesPath();
    final payload = <String, Object?>{
      'profiles': profiles.map((p) => p.toJson()).toList(),
      'groups': groups.map((g) => g.toJson()).toList(),
      'tags': tags.map((t) => t.toJson()).toList(),
    };
    await writeUtf8EnsureParent(
      path,
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  /// 始终新增一条已保存连接（不因 host/port/user 与已有条目相同而合并）。
  /// Web 上无持久化时返回 `null`。
  Future<String?> add({
    required String label,
    required String host,
    required int port,
    required String username,
    String? keyPath,
    String? password,
    List<String>? tags,
    ProxyConfig? proxyConfig,
    ConnectionProtocol protocol = ConnectionProtocol.ssh,
    SerialPortConfig? serialConfig,
    TerminalEncoding? encoding,
    bool autoInjectCredentials = true,
  }) async {
    await ensureLoaded();
    if (kIsWeb) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = now.toString();
    final trimmedKey = keyPath?.trim();
    final kp = (trimmedKey == null || trimmedKey.isEmpty) ? null : trimmedKey;
    final pwdTrim = password?.trim();
    final pwd = (pwdTrim == null || pwdTrim.isEmpty) ? null : pwdTrim;

    profiles.add(
      SavedHostProfile(
        id: id,
        label: label.trim().isEmpty ? '$username@$host' : label.trim(),
        host: host.trim(),
        port: port,
        username: username.trim(),
        keyPath: kp,
        password: pwd,
        updatedAtMs: now,
        tags: tags,
        proxyConfig: proxyConfig,
        protocol: protocol,
        serialConfig: serialConfig,
        encoding: encoding,
        autoInjectCredentials: autoInjectCredentials,
      ),
    );
    profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _persist();
    notifyListeners();
    return id;
  }

  /// 按 [id] 更新已保存连接。[password] 为 `null` 表示不修改已存口令；非 null 则写入（含空字符串表示清除本地保存的口令）。
  ///
  /// [proxyConfig] 为 `null` 且 [clearProxyConfig] 为 false 时保留原跳板配置。
  Future<void> updateById({
    required String id,
    required String label,
    required String host,
    required int port,
    required String username,
    String? keyPath,
    String? password,
    List<String>? tags,
    ProxyConfig? proxyConfig,
    bool clearProxyConfig = false,
    ConnectionProtocol? protocol,
    SerialPortConfig? serialConfig,
    bool clearSerialConfig = false,
    TerminalEncoding? encoding,
    bool clearEncoding = false,
    bool? autoInjectCredentials,
  }) async {
    await ensureLoaded();
    if (kIsWeb) return;
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final old = profiles[i];
    final trimmedKey = keyPath?.trim();
    final kp = (trimmedKey == null || trimmedKey.isEmpty) ? null : trimmedKey;
    final String? pwd = password == null
        ? old.password
        : (password.isEmpty ? null : password);

    profiles[i] = SavedHostProfile(
      id: old.id,
      label: label.trim().isEmpty ? old.label : label.trim(),
      host: host.trim(),
      port: port,
      username: username.trim(),
      keyPath: kp,
      password: pwd,
      updatedAtMs: now,
      tags: tags ?? old.tags,
      proxyConfig: clearProxyConfig
          ? null
          : (proxyConfig ?? old.proxyConfig),
      protocol: protocol ?? old.protocol,
      serialConfig: clearSerialConfig
          ? null
          : (serialConfig ?? old.serialConfig),
      encoding: clearEncoding ? null : (encoding ?? old.encoding),
      autoInjectCredentials:
          autoInjectCredentials ?? old.autoInjectCredentials,
    );
    profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    profiles.removeWhere((p) => p.id == id);
    for (final g in groups) {
      g.profileIds.removeWhere((pid) => pid == id);
    }
    if (!kIsWeb) {
      await _persist();
    }
    notifyListeners();
  }

  Future<String?> createGroup(String name, {String? icon, String? color}) async {
    await ensureLoaded();
    if (kIsWeb) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'g_$now';
    groups.add(
      HostGroup(
        id: id,
        name: trimmed,
        icon: icon,
        color: color,
        createdAtMs: now,
      ),
    );
    await _persist();
    notifyListeners();
    return id;
  }

  Future<void> renameGroup(String id, String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final i = groups.indexWhere((g) => g.id == id);
    if (i < 0) return;
    groups[i] = groups[i].copyWith(name: trimmed);
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  Future<void> deleteGroup(String id) async {
    await ensureLoaded();
    groups.removeWhere((g) => g.id == id);
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  Future<void> setGroupExpanded(String id, bool expanded) async {
    await ensureLoaded();
    final i = groups.indexWhere((g) => g.id == id);
    if (i < 0) return;
    groups[i].expanded = expanded;
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  Future<void> addToGroup(String profileId, String groupId) async {
    await ensureLoaded();
    HostGroup? g;
    for (final e in groups) {
      if (e.id == groupId) {
        g = e;
        break;
      }
    }
    if (g == null) return;
    if (!profiles.any((p) => p.id == profileId)) return;
    if (!g.profileIds.contains(profileId)) {
      g.profileIds.add(profileId);
      if (!kIsWeb) await _persist();
      notifyListeners();
    }
  }

  Future<void> removeFromGroup(String profileId, String groupId) async {
    await ensureLoaded();
    HostGroup? g;
    for (final e in groups) {
      if (e.id == groupId) {
        g = e;
        break;
      }
    }
    if (g == null) return;
    final removed = g.profileIds.remove(profileId);
    if (removed) {
      if (!kIsWeb) await _persist();
      notifyListeners();
    }
  }

  Future<String?> createTag(String name, {String? color}) async {
    await ensureLoaded();
    if (kIsWeb) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final id = 't_${DateTime.now().millisecondsSinceEpoch}';
    tags.add(HostTag(id: id, name: trimmed, color: color));
    await _persist();
    notifyListeners();
    return id;
  }

  Future<void> deleteTag(String id) async {
    await ensureLoaded();
    tags.removeWhere((t) => t.id == id);
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      if (p.tags.contains(id)) {
        profiles[i] = p.copyWith(
          tags: p.tags.where((t) => t != id).toList(),
        );
      }
    }
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  Future<void> addTag(String profileId, String tagId) async {
    await ensureLoaded();
    if (!tags.any((t) => t.id == tagId)) return;
    final i = profiles.indexWhere((p) => p.id == profileId);
    if (i < 0) return;
    final p = profiles[i];
    if (p.tags.contains(tagId)) return;
    profiles[i] = p.copyWith(tags: [...p.tags, tagId]);
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  Future<void> removeTag(String profileId, String tagId) async {
    await ensureLoaded();
    final i = profiles.indexWhere((p) => p.id == profileId);
    if (i < 0) return;
    final p = profiles[i];
    if (!p.tags.contains(tagId)) return;
    profiles[i] = p.copyWith(
      tags: p.tags.where((t) => t != tagId).toList(),
    );
    if (!kIsWeb) await _persist();
    notifyListeners();
  }

  /// 搜索 label / host / username / 标签名。
  List<SavedHostProfile> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List<SavedHostProfile>.from(profiles);
    final tagNameById = {for (final t in tags) t.id: t.name.toLowerCase()};
    return profiles.where((p) {
      if (p.label.toLowerCase().contains(q)) return true;
      if (p.host.toLowerCase().contains(q)) return true;
      if (p.username.toLowerCase().contains(q)) return true;
      if (p.subtitle.toLowerCase().contains(q)) return true;
      for (final tid in p.tags) {
        final name = tagNameById[tid];
        if (name != null && name.contains(q)) return true;
      }
      return false;
    }).toList();
  }

  /// 未归入任何分组的主机。
  List<SavedHostProfile> ungroupedProfiles({List<SavedHostProfile>? from}) {
    final source = from ?? profiles;
    final grouped = <String>{};
    for (final g in groups) {
      grouped.addAll(g.profileIds);
    }
    return source.where((p) => !grouped.contains(p.id)).toList();
  }

  SavedHostProfile? profileById(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }
}
