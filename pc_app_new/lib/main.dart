import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'models/mapping_entry.dart';
import 'services/brightness_service.dart';
import 'services/udp_service.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.white,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setTitle('AutoLiangDu PC 新版客户端');
    await windowManager.hide();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AutoLiangDu PC 新版客户端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener, TrayListener {
  late BrightnessService _brightnessService;
  late UdpService _udpService;
  late StorageService _storageService;

  int _currentLux = 0;
  int _currentBrightness = 50;
  bool _isConnected = false;
  bool _minimizeToTray = false;
  bool _autoStart = false;

  List<MappingEntry> _mappingTable = [];
  int? _selectedRow;

  StreamSubscription<int>? _luxSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  late TextEditingController _brightnessController;

  // 时间戳与定时器
  DateTime? _tManual;
  DateTime? _tTable;
  Timer? _manualTimer;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _brightnessController = TextEditingController(text: '$_currentBrightness');
    _brightnessService = BrightnessService();
    _udpService = UdpService();
    _storageService = StorageService();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initServices();
    _initSystemTray();
  }

  Future<void> _initServices() async {
    await _storageService.initialize();

    setState(() {
      _minimizeToTray = _storageService.minimizeToTray;
      _autoStart = _storageService.autoStart;
      _mappingTable = List.from(_storageService.mappingTable);
    });

    _currentBrightness = await _brightnessService.getBrightness();
    _brightnessController.text = '$_currentBrightness';
    setState(() {});
    _updateTrayTooltip();

    await _udpService.startServer(port: 8888);

    _luxSubscription = _udpService.luxStream.listen((lux) {
      _onLuxReceived(lux);
    });

    _connectionSubscription = _udpService.connectionStream.listen((connected) {
      setState(() {
        _isConnected = connected;
      });
    });
  }

  // ESP8266 来数据处理（中途触发）
  void _onLuxReceived(int lux) {
    setState(() {
      _currentLux = lux;
    });

    final now = DateTime.now();
    final isManualActive = _tManual != null && now.difference(_tManual!).inSeconds < 5;

    if (!isManualActive) {
      _applyTableBrightness();
    }
  }

  // 查表应用亮度
  Future<void> _applyTableBrightness() async {
    if (_mappingTable.isEmpty) {
      _tTable = null;
      return;
    }

    int targetBrightness = _mappingTable[0].brightness;
    for (int i = 0; i < _mappingTable.length; i++) {
      if (_currentLux <= _mappingTable[i].lux) {
        targetBrightness = _mappingTable[i].brightness;
        break;
      }
      if (i == _mappingTable.length - 1) {
        targetBrightness = _mappingTable[i].brightness;
      }
    }

    targetBrightness = targetBrightness.clamp(2, 100);
    await _brightnessService.setBrightness(targetBrightness);
    setState(() {
      _currentBrightness = targetBrightness;
      _brightnessController.text = '$_currentBrightness';
    });
    _updateTrayTooltip();
    _tTable = DateTime.now();
    _manualTimer?.cancel();
  }

  // 手动调节：点击 +/-
  Future<void> _onManualAdjust(int delta) async {
    int newBrightness = (_currentBrightness + delta).clamp(2, 100);
    final success = await _brightnessService.setBrightness(newBrightness);
    setState(() {
      _currentBrightness = newBrightness;
      _brightnessController.text = '$_currentBrightness';
    });
    _updateTrayTooltip();
    _tManual = DateTime.now();
    _startManualTimer();
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('亮度设置失败：${_brightnessService.lastError ?? "未知错误"}'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // 手动调节：输入框回车
  Future<void> _onManualSubmit(String value) async {
    final brightness = int.tryParse(value);
    if (brightness == null) {
      _brightnessController.text = '$_currentBrightness';
      return;
    }
    final clamped = brightness.clamp(2, 100);
    final success = await _brightnessService.setBrightness(clamped);
    setState(() {
      _currentBrightness = clamped;
      _brightnessController.text = '$clamped';
    });
    _updateTrayTooltip();
    _tManual = DateTime.now();
    _startManualTimer();
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('亮度设置失败：${_brightnessService.lastError ?? "未知错误"}'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // 启动 5 秒倒计时
  void _startManualTimer() {
    _manualTimer?.cancel();
    _manualTimer = Timer(const Duration(seconds: 5), _onManualTimerEnd);
  }

  // 5 秒倒计时结束
  void _onManualTimerEnd() {
    if (_isConnected) {
      _applyTableBrightness();
    } else {
      // 再来一次手动值
      _tManual = DateTime.now();
      _startManualTimer();
    }
  }

  // 表格编辑后触发
  void _onTableEdited() {
    setState(() {});
    _applyTableBrightness();
  }

  Future<void> _initSystemTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('显示器亮度: $_currentBrightness');

      final Menu menu = Menu(items: [
        MenuItem(
          label: '显示窗口',
          onClick: (menuItem) => _showWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          label: '退出',
          onClick: (menuItem) => exit(0),
        ),
      ]);

      await trayManager.setContextMenu(menu);
    } catch (e) {
      print('托盘初始化失败：$e');
    }
  }

  // 同步托盘悬浮提示为当前亮度
  Future<void> _updateTrayTooltip() async {
    try {
      await trayManager.setToolTip('显示器亮度: $_currentBrightness');
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // 弹出添加行 Dialog
  Future<void> _showAddRowDialog() async {
    final result = await showDialog<_AddRowResult>(
      context: context,
      builder: (ctx) => _AddRowDialog(
        initialLux: _currentLux,
        initialBrightness: _currentBrightness,
      ),
    );

    if (result != null) {
      setState(() {
        _mappingTable.add(MappingEntry(
          lux: result.lux,
          brightness: result.brightness.clamp(2, 100),
        ));
        _mappingTable.sort((a, b) => a.lux.compareTo(b.lux));
      });
      await _storageService.updateMappingTable(_mappingTable);
      _onTableEdited();
    }
  }

  @override
  void onWindowClose() async {
    if (_minimizeToTray) {
      await windowManager.hide();
    } else {
      exit(0);
    }
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void dispose() {
    _manualTimer?.cancel();
    _luxSubscription?.cancel();
    _connectionSubscription?.cancel();
    _udpService.dispose();
    _brightnessService.dispose();
    _brightnessController.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AutoLiangDu PC 新版客户端'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.minimize),
            onPressed: () async {
              await windowManager.minimize();
            },
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              if (_minimizeToTray) {
                await windowManager.hide();
              } else {
                exit(0);
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopControls(),
            const SizedBox(height: 16),
            const Divider(),
            _buildConnectionStatus(),
            const SizedBox(height: 16),
            _buildLuxDisplay(),
            const SizedBox(height: 16),
            _buildBrightnessControl(),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            _buildMappingTable(),
            const SizedBox(height: 16),
            _buildTableButtons(),
            const SizedBox(height: 16),
            _buildNotes(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopControls() {
    return Row(
      children: [
        const Text('[系统托盘]', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Checkbox(
          value: _minimizeToTray,
          onChanged: (value) async {
            setState(() {
              _minimizeToTray = value ?? false;
            });
            await _storageService.setMinimizeToTray(_minimizeToTray);
          },
        ),
        const Text('关闭时最小化到托盘'),
        const SizedBox(width: 24),
        Checkbox(
          value: _autoStart,
          onChanged: (value) async {
            setState(() {
              _autoStart = value ?? false;
            });
            await _storageService.setAutoStart(_autoStart);
          },
        ),
        const Text('开机自启'),
      ],
    );
  }

  Widget _buildConnectionStatus() {
    return Row(
      children: [
        const Text('WebSocket连接状态: ', style: TextStyle(fontWeight: FontWeight.bold)),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: _isConnected ? Colors.green : Colors.grey,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(_isConnected ? '已连接ESP8266' : '未连接'),
      ],
    );
  }

  Widget _buildLuxDisplay() {
    return Row(
      children: [
        const Text('实时采集环境光(Lux): ', style: TextStyle(fontWeight: FontWeight.bold)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.blue),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '$_currentLux',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  // 手动亮度区：拆成两行
  Widget _buildBrightnessControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一行：实时显示
        Row(
          children: [
            const Text('当前屏幕亮度: ', style: TextStyle(fontWeight: FontWeight.bold)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$_currentBrightness',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 第二行：调节按钮
        Row(
          children: [
            const Text('调节: ', style: TextStyle(fontWeight: FontWeight.bold)),
            ElevatedButton(
              onPressed: () => _onManualAdjust(-1),
              child: const Text('-'),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _brightnessController,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onSubmitted: _onManualSubmit,
                onChanged: (value) {
                  _debounceTimer?.cancel();
                  _debounceTimer = Timer(const Duration(seconds: 1), () => _onManualSubmit(value));
                },
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _onManualAdjust(1),
              child: const Text('+'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMappingTable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '【自定义亮度映射表】(自动按环境光升序排列)',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        DataTable(
          columns: const [
            DataColumn(label: Text('环境光Lux值')),
            DataColumn(label: Text('对应屏幕亮度')),
          ],
          rows: _mappingTable.asMap().entries.map((entry) {
            final index = entry.key;
            final mapping = entry.value;
            return DataRow(
              selected: _selectedRow == index,
              onSelectChanged: (selected) {
                setState(() {
                  _selectedRow = selected == true ? index : null;
                });
              },
              cells: [
                DataCell(
                  TextField(
                    controller: TextEditingController(text: '${mapping.lux}'),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (value) {
                      final lux = int.tryParse(value);
                      if (lux != null) {
                        setState(() {
                          mapping.lux = lux;
                          _mappingTable.sort((a, b) => a.lux.compareTo(b.lux));
                        });
                        _storageService.updateMappingTable(_mappingTable);
                        _onTableEdited();
                      }
                    },
                  ),
                ),
                DataCell(
                  TextField(
                    controller: TextEditingController(text: '${mapping.brightness}'),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (value) {
                      final brightness = int.tryParse(value);
                      if (brightness != null) {
                        setState(() {
                          mapping.brightness = brightness.clamp(2, 100);
                        });
                        _storageService.updateMappingTable(_mappingTable);
                        _onTableEdited();
                      }
                    },
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildTableButtons() {
    return Row(
      children: [
        ElevatedButton(
          onPressed: _showAddRowDialog,  // 改为弹窗
          child: const Text('添加行'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedRow != null
              ? () {
                  setState(() {
                    _mappingTable.removeAt(_selectedRow!);
                    _selectedRow = null;
                  });
                  _storageService.updateMappingTable(_mappingTable);
                  _onTableEdited();
                }
              : null,
          child: const Text('删除选中行'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () async {
            final filePath = await FilePicker.platform.saveFile(
              dialogTitle: '导出配置',
              fileName: 'autoliangdu_config.json',
              type: FileType.custom,
              allowedExtensions: ['json'],
            );
            if (filePath != null) {
              await _storageService.exportConfig(filePath);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配置导出成功')),
                );
              }
            }
          },
          child: const Text('导出配置'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () async {
            final result = await FilePicker.platform.pickFiles(
              dialogTitle: '导入配置',
              type: FileType.custom,
              allowedExtensions: ['json'],
            );
            if (result != null && result.files.single.path != null) {
              await _storageService.importConfig(result.files.single.path!);
              setState(() {
                _mappingTable = List.from(_storageService.mappingTable);
                _minimizeToTray = _storageService.minimizeToTray;
                _autoStart = _storageService.autoStart;
              });
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配置导入成功')),
                );
              }
            }
          },
          child: const Text('导入配置'),
        ),
      ],
    );
  }

  Widget _buildNotes() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('匹配规则说明：无插值，区间取前一档亮度', style: TextStyle(fontSize: 12)),
          Text('表格为空时，自动亮度功能关闭，不调节屏幕', style: TextStyle(fontSize: 12)),
          Text('亮度强制限制：最低2，最高100，无法设置低于2的值', style: TextStyle(fontSize: 12)),
          Text('手动调节5秒后按表格恢复（ESP8266连接时）', style: TextStyle(fontSize: 12)),
          Text('底层兼容策略：WMI背光调节(优先) → Gamma曲线模拟(兜底，全Win10 LTSC21H2兼容)', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// 添加行结果
class _AddRowResult {
  final int lux;
  final int brightness;
  _AddRowResult({required this.lux, required this.brightness});
}

// 添加行弹窗
class _AddRowDialog extends StatefulWidget {
  final int initialLux;
  final int initialBrightness;

  const _AddRowDialog({
    required this.initialLux,
    required this.initialBrightness,
  });

  @override
  State<_AddRowDialog> createState() => _AddRowDialogState();
}

class _AddRowDialogState extends State<_AddRowDialog> {
  late int _lux;
  late int _brightness;

  @override
  void initState() {
    super.initState();
    _lux = widget.initialLux;
    _brightness = widget.initialBrightness;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加映射行'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 环境光
          Row(
            children: [
              const Text('环境光 Lux: '),
              IconButton(
                onPressed: () => setState(() => _lux = (_lux - 1).clamp(0, 99999)),
                icon: const Text('-', style: TextStyle(fontSize: 20)),
              ),
              Container(
                width: 80,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('$_lux', textAlign: TextAlign.center),
              ),
              IconButton(
                onPressed: () => setState(() => _lux = _lux + 1),
                icon: const Text('+', style: TextStyle(fontSize: 20)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 屏幕亮度
          Row(
            children: [
              const Text('屏幕亮度:  '),
              IconButton(
                onPressed: () => setState(() => _brightness = (_brightness - 1).clamp(2, 100)),
                icon: const Text('-', style: TextStyle(fontSize: 20)),
              ),
              Container(
                width: 80,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('$_brightness', textAlign: TextAlign.center),
              ),
              IconButton(
                onPressed: () => setState(() => _brightness = (_brightness + 1).clamp(2, 100)),
                icon: const Text('+', style: TextStyle(fontSize: 20)),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(
            _AddRowResult(lux: _lux, brightness: _brightness),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
