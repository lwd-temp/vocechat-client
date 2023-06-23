// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/dao.dart';
import 'package:vocechat_client/dao/init_dao/properties_models/user_settings/user_settings.dart';

class UserSettingsM with M {
  String _settings = "";

  UserSettingsM();

  UserSettingsM.item(this._settings, String id, int createdAt) {
    super.id = id;
    super.createdAt = createdAt;
  }

  UserSettingsM.fromUserSettings(UserSettings data) {
    _settings = json.encode(data.toJson());
  }

  UserSettings get settings => UserSettings.fromJson(json.decode(_settings));

  static UserSettingsM fromMap(Map<String, dynamic> map) {
    UserSettingsM m = UserSettingsM();
    if (map.containsKey(M.ID)) {
      m.id = map[M.ID];
    }
    if (map.containsKey(F_settings)) {
      m._settings = map[F_settings];
    }
    if (map.containsKey(F_createdAt)) {
      m.createdAt = map[F_createdAt];
    }

    return m;
  }

  static const F_tableName = 'user_settings';
  static const F_settings = 'settings';
  static const F_createdAt = 'created_at';

  @override
  Map<String, Object> get values => {
        UserSettingsM.F_settings: _settings,
        UserSettingsM.F_createdAt: createdAt
      };

  static MMeta meta = MMeta.fromType(UserSettingsM, UserSettingsM.fromMap)
    ..tableName = F_tableName;
}

class UserSettingsDao extends Dao<UserSettingsM> {
  UserSettingsDao() {
    UserSettingsM.meta;
  }

  Future<UserSettingsM> addOrUpdate(UserSettingsM m) async {
    final old = await super.first();
    if (old != null) {
      m.id = old.id;
      await super.update(m);
      App.logger.info("UserSettings updated. ${m.values}");
    } else {
      await super.add(m);
      App.logger.info("UserSettings added. ${m.values}");
    }
    return m;
  }

  Future<UserSettings?> getSettings() async {
    final m = await super.first();
    if (m != null) {
      return UserSettings.fromJson(json.decode(m._settings));
    }
    return null;
  }

  Future<GroupSettings?> getGroupSettings(int gid) async {
    final m = await super.first();
    if (m != null) {
      final settings = UserSettings.fromJson(json.decode(m._settings));

      // Burn after read
      final burnAfterReadsGroups = settings.burnAfterReadingGroups;
      final muteGroups = settings.muteGroups;
      final pinnedGroups = settings.pinnedGroups;
      final readIndexGroups = settings.readIndexGroups;

      final burnAfterReadSecond = burnAfterReadsGroups?[gid] ?? 0;
      final muteExpiredAt = muteGroups?[gid] ?? 0;
      final pinned = pinnedGroups?.contains(gid) ?? false;
      final readIndex = readIndexGroups?[gid] ?? 0;

      return GroupSettings(
          burnAfterReadSecond: burnAfterReadSecond,
          enableMute: muteExpiredAt > 0,
          pinned: pinned,
          readIndex: readIndex);
    }
    return null;
  }

  /// Updates group settings by [gid].
  ///
  /// If no local settings, returns null.
  Future<UserSettings?> updateGroupSettings(int gid,
      {int? burnAfterReadSecond,
      int? muteExpiredAt,
      bool? pinned,
      int? readIndex}) async {
    final m = await super.first();
    if (m != null) {
      final settings = UserSettings.fromJson(json.decode(m._settings));

      if (burnAfterReadSecond != null) {
        settings.burnAfterReadingGroups?[gid] = burnAfterReadSecond;
      }

      if (muteExpiredAt != null) {
        if (muteExpiredAt > 0) {
          settings.muteGroups?[gid] = muteExpiredAt;
        } else {
          settings.muteGroups?.remove(gid);
        }
      }

      if (pinned != null) {
        if (pinned) {
          settings.pinnedGroups?.add(gid);
        } else {
          settings.pinnedGroups?.remove(gid);
        }
      }

      if (readIndex != null) {
        settings.readIndexGroups?[gid] = readIndex;
      }

      m._settings = json.encode(settings.toJson());
      await super.update(m);
      return m.settings;
    }
    return null;
  }

  /// Updates dm settings by [dmUid].
  ///
  /// If no local settings, returns null.
  Future<UserSettings?> updateDmSettings(int dmUid,
      {int? burnAfterReadSecond,
      int? muteExpiredAt,
      bool? pinned,
      int? readIndex}) async {
    final m = await super.first();
    if (m != null) {
      final settings = UserSettings.fromJson(json.decode(m._settings));

      if (burnAfterReadSecond != null) {
        settings.burnAfterReadingUsers?[dmUid] = burnAfterReadSecond;
      }

      if (muteExpiredAt != null) {
        if (muteExpiredAt > 0) {
          settings.muteUsers?[dmUid] = muteExpiredAt;
        } else {
          settings.muteUsers?.remove(dmUid);
        }
      }

      if (pinned != null) {
        if (pinned) {
          settings.pinnedUsers?.add(dmUid);
        } else {
          settings.pinnedUsers?.remove(dmUid);
        }
      }

      if (readIndex != null) {
        settings.readIndexUsers?[dmUid] = readIndex;
      }

      m._settings = json.encode(settings.toJson());
      await super.update(m);
      return m.settings;
    }
    return null;
  }
}

class GroupSettings {
  final int burnAfterReadSecond; // in seconds. <=0 means disabled.
  final bool enableMute;
  final bool pinned;
  final int readIndex;

  GroupSettings({
    required this.burnAfterReadSecond,
    required this.enableMute,
    required this.pinned,
    required this.readIndex,
  });

  static GroupSettings fromUserSettings(UserSettings settings, int gid) {
    final burnAfterReadsGroups = settings.burnAfterReadingGroups;
    final muteGroups = settings.muteGroups;
    final pinnedGroups = settings.pinnedGroups;
    final readIndexGroups = settings.readIndexGroups;

    final burnAfterReadSecond = burnAfterReadsGroups?[gid] ?? 0;
    final muteExpiredAt = muteGroups?[gid] ?? 0;
    final pinned = pinnedGroups?.contains(gid) ?? false;
    final readIndex = readIndexGroups?[gid] ?? 0;

    return GroupSettings(
        burnAfterReadSecond: burnAfterReadSecond,
        enableMute: muteExpiredAt > 0,
        pinned: pinned,
        readIndex: readIndex);
  }
}
