import 'dart:convert';
import 'dart:io';
import '../models/mapping_entry.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  String? _appDataPath;
  List<MappingEntry> _mappingTable = [];
  List<MappingEntry> _nightMappingTable = [];
  bool _minimizeToTray = false;
  bool _autoStart = false;
  double _latitude = 39.9042; // 北京默认
  double _longitude = 116.4074;

  List<MappingEntry> get mappingTable => List.unmodifiable(_mappingTable);
  List<MappingEntry> get nightMappingTable => List.unmodifiable(_nightMappingTable);
  bool get minimizeToTray => _minimizeToTray;
  bool get autoStart => _autoStart;
  double get latitude => _latitude;
  double get longitude => _longitude;

  Future<void> initialize() async {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        _appDataPath = '$appData\\AutoLiangDu';
        final dir = Directory(_appDataPath!);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        await _loadData();
        // 如果开启了自启，自动校验注册表路径是否正确（软件换位置时自动更新）
        if (_autoStart) {
          await _updateAutoStartRegistry(true);
        }
      }
    } catch (e) {
      print('存储初始化失败: $e');
    }
  }

  Future<void> _loadData() async {
    try {
      final configFile = File('$_appDataPath\\config.json');
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final json = jsonDecode(content);
        _minimizeToTray = json['minimizeToTray'] ?? false;
        _autoStart = json['autoStart'] ?? false;
        _latitude = (json['latitude'] as num?)?.toDouble() ?? 39.9042;
        _longitude = (json['longitude'] as num?)?.toDouble() ?? 116.4074;
        _mappingTable = (json['mappingTable'] as List?)
                ?.map((e) => MappingEntry.fromJson(e))
                .toList() ??
            [];
        _nightMappingTable = (json['nightMappingTable'] as List?)
                ?.map((e) => MappingEntry.fromJson(e))
                .toList() ??
            [];
      }
    } catch (e) {
      print('加载配置失败: $e');
    }
  }

  Future<void> _saveData() async {
    try {
      final configFile = File('$_appDataPath\\config.json');
      final json = {
        'minimizeToTray': _minimizeToTray,
        'autoStart': _autoStart,
        'latitude': _latitude,
        'longitude': _longitude,
        'mappingTable': _mappingTable.map((e) => e.toJson()).toList(),
        'nightMappingTable': _nightMappingTable.map((e) => e.toJson()).toList(),
      };
      await configFile.writeAsString(jsonEncode(json));
    } catch (e) {
      print('保存配置失败: $e');
    }
  }

  Future<void> setMinimizeToTray(bool value) async {
    _minimizeToTray = value;
    await _saveData();
  }

  Future<void> setAutoStart(bool value) async {
    _autoStart = value;
    await _saveData();
    await _updateAutoStartRegistry(value);
  }

  Future<void> setLatitude(double value) async {
    _latitude = value;
    await _saveData();
  }

  Future<void> setLongitude(double value) async {
    _longitude = value;
    await _saveData();
  }

  Future<void> _updateAutoStartRegistry(bool enable) async {
    try {
      final exePath = Platform.resolvedExecutable;
      if (enable) {
        await Process.run('reg', [
          'add',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'AutoLiangDu',
          '/t',
          'REG_SZ',
          '/d',
          '"$exePath"',
          '/f'
        ]);
      } else {
        await Process.run('reg', [
          'delete',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'AutoLiangDu',
          '/f'
        ]);
      }
    } catch (e) {
      print('更新注册表失败: $e');
    }
  }

  Future<void> updateMappingTable(List<MappingEntry> entries) async {
    _mappingTable = List.from(entries);
    _mappingTable.sort((a, b) => a.lux.compareTo(b.lux));
    _dedupeMappingTable();
    await _saveData();
  }

  Future<void> updateNightMappingTable(List<MappingEntry> entries) async {
    _nightMappingTable = List.from(entries);
    _nightMappingTable.sort((a, b) => a.lux.compareTo(b.lux));
    _dedupeNightMappingTable();
    await _saveData();
  }

  // 相同 Lux 只保留最后一项（后导入/后编辑的亮度覆盖前者）
  void _dedupeMappingTable() {
    final seen = <int>{};
    for (int i = _mappingTable.length - 1; i >= 0; i--) {
      if (seen.contains(_mappingTable[i].lux)) {
        _mappingTable.removeAt(i);
      } else {
        seen.add(_mappingTable[i].lux);
      }
    }
  }

  void _dedupeNightMappingTable() {
    final seen = <int>{};
    for (int i = _nightMappingTable.length - 1; i >= 0; i--) {
      if (seen.contains(_nightMappingTable[i].lux)) {
        _nightMappingTable.removeAt(i);
      } else {
        seen.add(_nightMappingTable[i].lux);
      }
    }
  }

  Future<void> addMappingEntry(MappingEntry entry) async {
    _mappingTable.add(entry);
    _mappingTable.sort((a, b) => a.lux.compareTo(b.lux));
    await _saveData();
  }

  Future<void> removeMappingEntry(int index) async {
    if (index >= 0 && index < _mappingTable.length) {
      _mappingTable.removeAt(index);
      await _saveData();
    }
  }

  Future<void> exportConfig(String filePath) async {
    try {
      final json = {
        'minimizeToTray': _minimizeToTray,
        'autoStart': _autoStart,
        'latitude': _latitude,
        'longitude': _longitude,
        'mappingTable': _mappingTable.map((e) => e.toJson()).toList(),
        'nightMappingTable': _nightMappingTable.map((e) => e.toJson()).toList(),
      };
      final file = File(filePath);
      await file.writeAsString(jsonEncode(json));
    } catch (e) {
      print('导出配置失败: $e');
    }
  }

  Future<void> importConfig(String filePath) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      final json = jsonDecode(content);
      _minimizeToTray = json['minimizeToTray'] ?? false;
      _autoStart = json['autoStart'] ?? false;
      _latitude = (json['latitude'] as num?)?.toDouble() ?? 39.9042;
      _longitude = (json['longitude'] as num?)?.toDouble() ?? 116.4074;
      _mappingTable = (json['mappingTable'] as List?)
              ?.map((e) => MappingEntry.fromJson(e))
              .toList() ??
          [];
      _mappingTable.sort((a, b) => a.lux.compareTo(b.lux));
      _dedupeMappingTable();
      _nightMappingTable = (json['nightMappingTable'] as List?)
              ?.map((e) => MappingEntry.fromJson(e))
              .toList() ??
          [];
      _nightMappingTable.sort((a, b) => a.lux.compareTo(b.lux));
      _dedupeNightMappingTable();
      await _saveData();
    } catch (e) {
      print('导入配置失败: $e');
    }
  }
}
