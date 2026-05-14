import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../io/host_profiles_disk.dart';
import '../models/saved_host_profile.dart';

/// 持久化「设备」连接模板；可选保存 [SavedHostProfile.password] 以便免二次输入。
class HostProfilesStore extends ChangeNotifier {
  HostProfilesStore();

  final List<SavedHostProfile> profiles = [];
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    if (kIsWeb) {
      notifyListeners();
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final path = '${dir.path}/terminall_host_profiles.json';
      final raw = await readUtf8IfExists(path);
      if (raw != null && raw.trim().isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        profiles
          ..clear()
          ..addAll(
            list.map((e) => SavedHostProfile.fromJson(Map<String, Object?>.from(e as Map))),
          );
        profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      }
    } catch (e, st) {
      debugPrint('HostProfilesStore load: $e\n$st');
    }
    notifyListeners();
  }

  Future<String> _profilesPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/terminall_host_profiles.json';
  }

  Future<void> _persist() async {
    if (kIsWeb) return;
    final path = await _profilesPath();
    final list = profiles.map((p) => p.toJson()).toList();
    await writeUtf8EnsureParent(path, const JsonEncoder.withIndent('  ').convert(list));
  }

  /// 始终新增一条已保存连接（不因 host/port/user 与已有条目相同而合并）。
  Future<void> add({
    required String label,
    required String host,
    required int port,
    required String username,
    String? keyPath,
    String? password,
  }) async {
    if (kIsWeb) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final trimmedKey = keyPath?.trim();
    final kp = (trimmedKey == null || trimmedKey.isEmpty) ? null : trimmedKey;
    final pwdTrim = password?.trim();
    final pwd = (pwdTrim == null || pwdTrim.isEmpty) ? null : pwdTrim;

    profiles.add(
      SavedHostProfile(
        id: now.toString(),
        label: label.trim().isEmpty ? '$username@$host' : label.trim(),
        host: host.trim(),
        port: port,
        username: username.trim(),
        keyPath: kp,
        password: pwd,
        updatedAtMs: now,
      ),
    );
    profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _persist();
    notifyListeners();
  }

  /// 按 [id] 更新已保存连接。[password] 为 `null` 表示不修改已存口令；非 null 则写入（含空字符串表示清除本地保存的口令）。
  Future<void> updateById({
    required String id,
    required String label,
    required String host,
    required int port,
    required String username,
    String? keyPath,
    String? password,
  }) async {
    if (kIsWeb) return;
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final old = profiles[i];
    final trimmedKey = keyPath?.trim();
    final kp = (trimmedKey == null || trimmedKey.isEmpty) ? null : trimmedKey;
    final String? pwd = password == null ? old.password : (password.isEmpty ? null : password);

    profiles[i] = SavedHostProfile(
      id: old.id,
      label: label.trim().isEmpty ? old.label : label.trim(),
      host: host.trim(),
      port: port,
      username: username.trim(),
      keyPath: kp,
      password: pwd,
      updatedAtMs: now,
    );
    profiles.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    profiles.removeWhere((p) => p.id == id);
    if (!kIsWeb) {
      await _persist();
    }
    notifyListeners();
  }
}
