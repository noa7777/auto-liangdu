import 'dart:async';
import 'dart:io';

class UdpService {
  static final UdpService _instance = UdpService._internal();
  factory UdpService() => _instance;
  UdpService._internal();

  RawDatagramSocket? _socket;
  bool _isRunning = false;

  final _luxController = StreamController<int>.broadcast();
  Stream<int> get luxStream => _luxController.stream;

  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  Timer? _timeoutTimer;
  bool _isConnected = false;

  Future<bool> startServer({int port = 8888}) async {
    if (_isRunning) return true;

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _isRunning = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            try {
              final dataStr = String.fromCharCodes(datagram.data);
              final lux = int.parse(dataStr.trim());
              _luxController.add(lux);
              _updateConnection(true);
              _resetTimeoutTimer();
            } catch (e) {
              print('解析 UDP 数据失败：$e');
            }
          }
        }
      });

      print('UDP 服务器启动在端口 $port');
      return true;
    } catch (e) {
      print('UDP 服务器启动失败：$e');
      _isRunning = false;
      return false;
    }
  }

  void _resetTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 3), () {
      _updateConnection(false);
    });
  }

  void _updateConnection(bool connected) {
    if (_isConnected != connected) {
      _isConnected = connected;
      _connectionController.add(connected);
    }
  }

  Future<void> stopServer() async {
    _timeoutTimer?.cancel();
    _socket?.close();
    _socket = null;
    _isRunning = false;
    _updateConnection(false);
  }

  void dispose() {
    stopServer();
    _luxController.close();
    _connectionController.close();
  }
}
