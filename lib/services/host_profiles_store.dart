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

  Future<void> upsert({
    required String label,
    required String host,
    required int port,
    required String username,
    String? keyPath,
    String? password,
  }) async {
    if (kIsWeb) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = profiles.indexWhere((p) => p.host == host && p.port == port && p.username == username);
    final trimmedKey = keyPath?.trim();
    final kp = (trimmedKey == null || trimmedKey.isEmpty) ? null : trimmedKey;
    final pwdTrim = password?.trim();
    final pwd = (pwdTrim == null || pwdTrim.isEmpty) ? null : pwdTrim;

    if (existing >= 0) {
      final old = profiles[existing];
      profiles[existing] = SavedHostProfile(
        id: old.id,
        label: label.trim().isEmpty ? old.label : label.trim(),
        host: host.trim(),
        port: port,
        username: username.trim(),
        keyPath: kp,
        password: pwd ?? old.password,
        updatedAtMs: now,
      );
    } else {
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
    }
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
