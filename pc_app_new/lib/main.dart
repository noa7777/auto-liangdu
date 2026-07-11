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
import 'services/sun_calculator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.white,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
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
  List<MappingEntry> _mappingTableNight = [];
  bool _activeTableIsNight = false;
  int? _selectedRow;

  StreamSubscription<int>? _luxSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  late TextEditingController _brightnessController;

  // 时间戳与定时器
  DateTime? _tManual;
  DateTime? _tTable;
  Timer? _manualTimer;
  Timer? _debounceTimer;

  // 最近 9 秒的环境光环状缓存（9 个位置，每秒写入一个值）
  final List<int?> _luxBuffer = List.filled(9, null);
  int _luxBufferIndex = 0;
  Timer? _luxBufferTimer;

  // 日出日落相关
  late TextEditingController _latController;
  late TextEditingController _lonController;
  late FocusNode _latFocusNode;
  late FocusNode _lonFocusNode;
  String _sunriseText = '--:--';
  String _sunsetText = '--:--';
  SunCalculator? _sunCalc;
  Timer? _sunTimer;

  @override
  void initState() {
    super.initState();
    _brightnessController = TextEditingController(text: '$_currentBrightness');
    _latController = TextEditingController(text: '39.9042');
    _lonController = TextEditingController(text: '116.4074');
    _latFocusNode = FocusNode();
    _lonFocusNode = FocusNode();
    _latFocusNode.addListener(_onLatLonSubmitted);
    _lonFocusNode.addListener(_onLatLonSubmitted);
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
      _mappingTableNight = List.from(_storageService.nightMappingTable);
    });

    _currentBrightness = await _brightnessService.getBrightness();
    _brightnessController.text = '$_currentBrightness';
    setState(() {});
    _updateTrayTooltip();

    // 加载经纬度，初始化日出日落计算
    _latController.text = _storageService.latitude.toStringAsFixed(4);
    _lonController.text = _storageService.longitude.toStringAsFixed(4);
    _calcAndDisplaySunTimes();

    await _udpService.startServer(port: 8888);

    _luxSubscription = _udpService.luxStream.listen((lux) {
      _onLuxReceived(lux);
    });

    _connectionSubscription = _udpService.connectionStream.listen((connected) {
      setState(() {
        _isConnected = connected;
      });
    });

    // 每秒写入一次当前 Lux 到环状缓存
    _luxBufferTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pushLuxToBuffer(_currentLux);
    });

    // 每天午夜自动刷新日出日落时间
    _scheduleNextSunUpdate();
  }

  // ESP8266 来数据处理（中途触发）
  void _onLuxReceived(int lux) {
    setState(() {
      _currentLux = lux;
    });

    final now = DateTime.now();
    final isManualActive =
        _tManual != null && now.difference(_tManual!).inSeconds < 5;

    if (!isManualActive) {
      _applyTableBrightness();
    }
  }

  // 把当前 Lux 写入最近 9 秒的环状缓存（每秒调用一次）
  void _pushLuxToBuffer(int lux) {
    _luxBuffer[_luxBufferIndex] = lux;
    _luxBufferIndex = (_luxBufferIndex + 1) % _luxBuffer.length;
  }

  // 取缓存中的中位数（向下取整，未填满时忽略 null）
  int _getMedianLuxFromBuffer() {
    final valid = _luxBuffer.whereType<int>().toList()..sort();
    if (valid.isEmpty) return _currentLux;
    return valid[valid.length ~/ 2];
  }

  // 手动调节时清空 Lux 缓存，避免历史高 Lux 在手动期间继续触发表格逻辑
  void _clearLuxBuffer() {
    for (int i = 0; i < _luxBuffer.length; i++) {
      _luxBuffer[i] = null;
    }
    _luxBufferIndex = 0;
  }

  // 返回当前 UI 正在编辑的激活表（白天 or 黑夜）
  List<MappingEntry> get _activeTable =>
      _activeTableIsNight ? _mappingTableNight : _mappingTable;

  // 根据当前时间自动选择应使用的映射表
  List<MappingEntry> _getTableForCurrentTime() {
    if (_sunCalc == null) return _mappingTable; // 无日出日落数据时默认白天表
    final isDay = _sunCalc!.isDaytime(DateTime.now());
    // null=极昼夜用白天表, true=白天表, false=黑夜表
    return isDay == false ? _mappingTableNight : _mappingTable;
  }

  // 保存当前 UI 激活的表到持久层
  Future<void> _saveActiveTable() async {
    if (_activeTableIsNight) {
      await _storageService.updateNightMappingTable(_mappingTableNight);
    } else {
      await _storageService.updateMappingTable(_mappingTable);
    }
  }

  // 查表应用亮度（按当前时间自动选择白天表或黑夜表）
  Future<void> _applyTableBrightness() async {
    final table = _getTableForCurrentTime();
    if (table.isEmpty) {
      _tTable = null;
      return;
    }

    // 取最近 9 秒内的中位数 Lux 来查表，平滑小幅波动
    final luxForLookup = _getMedianLuxFromBuffer();

    // 非插值区间匹配：取当前 Lux 所在区间的前一个档位
    int targetBrightness = table[0].brightness;
    for (int i = 0; i < table.length; i++) {
      if (luxForLookup >= table[i].lux) {
        targetBrightness = table[i].brightness;
      } else {
        break;
      }
    }

    targetBrightness = targetBrightness.clamp(2, 100);

    // 只在亮度值实际变化时才执行 DDC 调用，避免每秒无意义的 IO
    if (targetBrightness == _currentBrightness) return;

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
    _clearLuxBuffer();
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
    _clearLuxBuffer();
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

  // ---- 日出日落 ----

  // 计算并显示日出日落时间
  void _calcAndDisplaySunTimes() {
    final lat = double.tryParse(_latController.text);
    final lon = double.tryParse(_lonController.text);
    if (lat == null || lon == null) {
      setState(() {
        _sunriseText = '无效经纬度';
        _sunsetText = '无效经纬度';
        _sunCalc = null;
      });
      return;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      setState(() {
        _sunriseText = '范围错误';
        _sunsetText = '范围错误';
        _sunCalc = null;
      });
      return;
    }

    _sunCalc = SunCalculator(latitude: lat, longitude: lon);
    final today = DateTime.now();
    final sunrise = _sunCalc!.getSunrise(today);
    final sunset = _sunCalc!.getSunset(today);

    setState(() {
      _sunriseText = sunrise != null
          ? '${_pad(sunrise.hour)}:${_pad(sunrise.minute)}'
          : '极夜/无日出';
      _sunsetText = sunset != null
          ? '${_pad(sunset.hour)}:${_pad(sunset.minute)}'
          : '极昼/无日落';
    });
  }

  // 每天的午夜定时刷新日出日落
  void _scheduleNextSunUpdate() {
    _sunTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    final duration = nextMidnight.difference(now);
    _sunTimer = Timer(duration, () {
      _calcAndDisplaySunTimes();
      _scheduleNextSunUpdate(); // 递归安排下一次
    });
  }

  // 经纬度输入确认后（回车/失焦）更新显示并保存
  void _onLatLonSubmitted() {
    final lat = double.tryParse(_latController.text);
    final lon = double.tryParse(_lonController.text);
    if (lat != null && lon != null) {
      _storageService.setLatitude(lat);
      _storageService.setLongitude(lon);
    }
    _calcAndDisplaySunTimes();
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  // 表格编辑后触发
  void _onTableEdited() {
    setState(() {});
    _saveActiveTable();
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
        final active = _activeTable;
        final existingIndex =
            active.indexWhere((e) => e.lux == result.lux);
        if (existingIndex >= 0) {
          // 相同 Lux 已存在：新亮度覆盖旧亮度
          active[existingIndex].brightness =
              result.brightness.clamp(2, 100);
        } else {
          active.add(MappingEntry(
            lux: result.lux,
            brightness: result.brightness.clamp(2, 100),
          ));
        }
        active.sort((a, b) => a.lux.compareTo(b.lux));
      });
      await _saveActiveTable();
      _onTableEdited();
    }
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
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
    _luxBufferTimer?.cancel();
    _luxSubscription?.cancel();
    _connectionSubscription?.cancel();
    _sunTimer?.cancel();
    _latFocusNode.removeListener(_onLatLonSubmitted);
    _lonFocusNode.removeListener(_onLatLonSubmitted);
    _latFocusNode.dispose();
    _lonFocusNode.dispose();
    _udpService.dispose();
    _brightnessService.dispose();
    _brightnessController.dispose();
    _latController.dispose();
    _lonController.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: DragToMoveArea(
          child: Container(
            color: Colors.transparent,
            height: kToolbarHeight,
            alignment: Alignment.centerLeft,
            child: const Text('AutoLiangDu PC 新版客户端'),
          ),
        ),
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
              await windowManager.hide();
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
            _buildSunSection(),
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

  Widget _buildSunSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('【日出日落】',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('纬度: ', style: TextStyle(fontSize: 13)),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _latController,
                  focusNode: _latFocusNode,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _onLatLonSubmitted(),
                ),
              ),
              const SizedBox(width: 16),
              const Text('经度: ', style: TextStyle(fontSize: 13)),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _lonController,
                  focusNode: _lonFocusNode,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _onLatLonSubmitted(),
                ),
              ),
              const SizedBox(width: 8),
              const Text('(北京: 39.9, 116.4)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('今日日出: ', style: TextStyle(fontSize: 13)),
              Text(_sunriseText,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange)),
              const SizedBox(width: 24),
              const Text('今日日落: ', style: TextStyle(fontSize: 13)),
              Text(_sunsetText,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Row(
      children: [
        const Text('WebSocket连接状态: ',
            style: TextStyle(fontWeight: FontWeight.bold)),
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
        const Text('实时采集环境光(Lux): ',
            style: TextStyle(fontWeight: FontWeight.bold)),
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
            const Text('当前屏幕亮度: ',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '$_currentBrightness',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                  _debounceTimer = Timer(
                      const Duration(seconds: 1), () => _onManualSubmit(value));
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
    final activeTable = _activeTable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '【自定义亮度映射表】',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Spacer(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('白天表')),
                ButtonSegment(value: true, label: Text('黑夜表')),
              ],
              selected: {_activeTableIsNight},
              onSelectionChanged: (selected) {
                setState(() {
                  _activeTableIsNight = selected.first;
                  _selectedRow = null;
                });
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DataTable(
          columns: const [
            DataColumn(label: Text('环境光Lux值')),
            DataColumn(label: Text('对应屏幕亮度')),
          ],
          rows: activeTable.asMap().entries.map((entry) {
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
                          final duplicateIndex = activeTable.indexWhere(
                            (e) => e.lux == lux && e != mapping,
                          );
                          if (duplicateIndex >= 0) {
                            // 相同 Lux 已存在：当前行亮度覆盖旧行亮度，并删除当前行
                            activeTable[duplicateIndex].brightness =
                                mapping.brightness;
                            activeTable.remove(mapping);
                          } else {
                            mapping.lux = lux;
                          }
                          activeTable.sort((a, b) => a.lux.compareTo(b.lux));
                        });
                        _onTableEdited();
                      }
                    },
                  ),
                ),
                DataCell(
                  TextField(
                    controller:
                        TextEditingController(text: '${mapping.brightness}'),
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
          onPressed: _showAddRowDialog, // 改为弹窗
          child: const Text('添加行'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedRow != null
              ? () {
                  setState(() {
                    _activeTable.removeAt(_selectedRow!);
                    _selectedRow = null;
                  });
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
                _mappingTableNight = List.from(_storageService.nightMappingTable);
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
          Text('白天/黑夜各有一张独立映射表，系统根据当前时间自动选表', style: TextStyle(fontSize: 12)),
          Text('表格为空时，自动亮度功能关闭，不调节屏幕', style: TextStyle(fontSize: 12)),
          Text('亮度强制限制：最低2，最高100，无法设置低于2的值', style: TextStyle(fontSize: 12)),
          Text('手动调节5秒后按表格恢复（ESP8266连接时）', style: TextStyle(fontSize: 12)),
          Text('底层兼容策略：WMI背光调节(优先) → Gamma曲线模拟(兜底，全Win10 LTSC21H2兼容)',
              style: TextStyle(fontSize: 12)),
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
                onPressed: () =>
                    setState(() => _lux = (_lux - 1).clamp(0, 99999)),
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
                onPressed: () => setState(
                    () => _brightness = (_brightness - 1).clamp(2, 100)),
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
                onPressed: () => setState(
                    () => _brightness = (_brightness + 1).clamp(2, 100)),
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
