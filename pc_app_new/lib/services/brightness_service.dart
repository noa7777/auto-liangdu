import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

void _logBrightness(String msg) {
  if (kDebugMode) {
    debugPrint('[Brightness] $msg');
  }
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData != null) {
      final file = File('$appData\\AutoLiangDu\\brightness.log');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
        flush: true,
      );
    }
  } catch (_) {}
}

class BrightnessService {
  static BrightnessService? _instance;
  factory BrightnessService() {
    _instance ??= BrightnessService._internal();
    return _instance!;
  }

  int _currentBrightness = 50;
  int get currentBrightness => _currentBrightness;

  String? _lastError;
  String? get lastError => _lastError;

  final _brightnessController = StreamController<int>.broadcast();
  Stream<int> get brightnessStream => _brightnessController.stream;

  bool _scriptsReady = false;
  String? _brightScriptPath;

  Timer? _pendingSetTimer;
  int? _pendingLevel;
  bool _isSetting = false;

  BrightnessService._internal();

  // 合并的 DDC 脚本：set 与 get 共享同一个类型 DDCService
  // 避免 PowerShell 5.1 的 StartupProfileData 缓存把同名类型"卡死"
  static const String _ddcBrightnessScript = r'''
param([string]$Action = "set", [int]$Level = 50)

$source = @"
using System;
using System.Runtime.InteropServices;
public class DDCService {
  [DllImport("dxva2.dll", SetLastError=true)]
  public static extern bool SetMonitorBrightness(IntPtr hMonitor, uint dwNewBrightness);
  [DllImport("dxva2.dll", SetLastError=true)]
  public static extern bool GetMonitorBrightness(IntPtr hMonitor, out uint pdwMinimumBrightness, out uint pdwCurrentBrightness, out uint pdwMaximumBrightness);
  [DllImport("user32.dll")]
  public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
  [DllImport("dxva2.dll")]
  public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);
  public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PHYSICAL_MONITOR {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
    public string szPhysicalMonitorDescription;
    public IntPtr hPhysicalMonitor;
  }
}
"@

if (-not ("DDCService" -as [type])) {
  Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing
}

$script:setOk = $false
$script:setErr = 0
$script:cur = -1
$script:getOk = $false
$script:getErr = 0

$enumCallback = [DDCService+MonitorEnumProc] {
  param($hMonitor, $hdcMonitor, [ref]$lprcMonitor, $dwData)
  $physArr = New-Object 'DDCService+PHYSICAL_MONITOR[]' 1
  $ok = [DDCService]::GetPhysicalMonitorsFromHMONITOR($hMonitor, 1, $physArr)
  if ($ok) {
    $hPhys = $physArr[0].hPhysicalMonitor
    if ($Action -eq "set") {
      $script:setOk = [DDCService]::SetMonitorBrightness($hPhys, [uint32]$Level)
      $script:setErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    } else {
      $min=0; $cur=0; $max=0
      $script:getOk = [DDCService]::GetMonitorBrightness($hPhys, [ref]$min, [ref]$cur, [ref]$max)
      $script:getErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
      $script:cur = [int]$cur
    }
  }
  return $true
}

[void][DDCService]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $enumCallback, [IntPtr]::Zero)

if ($Action -eq "set") {
  if ($script:setOk) { Write-Output "OK" } else { Write-Output ("FAIL:" + $script:setErr) }
} else {
  if ($script:getOk -and $script:cur -ge 0) { Write-Output ("CUR:" + $script:cur) } else { Write-Output ("FAIL:" + $script:getErr) }
}
''';

  void _ensureScripts() {
    if (_scriptsReady) return;
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) {
        _logBrightness('无 APPDATA 环境变量');
        return;
      }
      final dir = Directory('$appData\\AutoLiangDu');
      dir.createSync(recursive: true);
      _brightScriptPath = '${dir.path}\\ddc.ps1';
      File(_brightScriptPath!).writeAsStringSync(_ddcBrightnessScript, flush: true);
      _logBrightness('已写入 DDC 脚本: $_brightScriptPath');
      _scriptsReady = true;
    } catch (e) {
      _logBrightness('写脚本失败: $e');
    }
  }

  Future<int> getBrightness() async {
    _ensureScripts();
    // 优先 DDC/CI
    final ddcCur = await _getBrightnessDDC();
    if (ddcCur >= 0) {
      _currentBrightness = ddcCur;
      _lastError = 'DDC 读取成功';
      return _currentBrightness;
    }
    // 兜底: WMI
    try {
      final result = await Process.run('powershell', [
        '-Command',
        '(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness'
      ]);
      _logBrightness('WMI get exit=${result.exitCode} stdout=${result.stdout}');
      if (result.exitCode == 0) {
        final value = int.tryParse(result.stdout.toString().trim());
        if (value != null && value >= 2 && value <= 100) {
          _currentBrightness = value;
          _lastError = 'WMI 读取成功';
          return _currentBrightness;
        }
      }
    } catch (e) {
      _logBrightness('WMI get 异常: $e');
    }
    return _currentBrightness;
  }

  Future<bool> setBrightness(int level) async {
    level = level.clamp(2, 100);
    _ensureScripts();

    // 立即更新目标亮度并重启防抖定时器，合并连续点击
    _pendingSetTimer?.cancel();
    _pendingLevel = level;

    if (_isSetting) {
      // 当前正在执行 DDC，等完成后由 _applyPendingSet 自动处理最新值
      return true;
    }

    _pendingSetTimer = Timer(const Duration(milliseconds: 200), _applyPendingSet);
    return true; // UI 立即反馈，无需等待 PowerShell
  }

  Future<void> _applyPendingSet() async {
    if (_isSetting) {
      // 仍在执行中，稍后重试
      _pendingSetTimer = Timer(const Duration(milliseconds: 100), _applyPendingSet);
      return;
    }
    final target = _pendingLevel;
    if (target == null) return;

    _isSetting = true;
    try {
      final ok = await _setBrightnessDDC(target);
      if (ok) {
        _currentBrightness = target;
        _lastError = 'DDC 设置成功';
        _brightnessController.add(_currentBrightness);
      } else {
        // 立即读取实际亮度，看是否已生效（有些显示器延迟生效）
        final actual = await _getBrightnessDDC();
        if (actual == target) {
          _currentBrightness = target;
          _lastError = 'DDC 设置成功(延迟生效)';
          _brightnessController.add(_currentBrightness);
        } else {
          _lastError = 'DDC 设置失败 (显示器响应异常，请重试)';
        }
      }
    } catch (e) {
      _lastError = 'DDC 设置异常: $e';
      _logBrightness(_lastError!);
    } finally {
      _isSetting = false;
      _pendingLevel = null;
    }
  }

  Future<bool> _setBrightnessDDC(int level) async {
    if (_brightScriptPath == null) return false;
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', _brightScriptPath!,
        '-Action', 'set',
        '-Level', level.toString(),
      ]);
      final out = result.stdout.toString().trim();
      _logBrightness('DDC set exit=${result.exitCode} stdout=${out} stderr=${result.stderr}');
      return out == 'OK';
    } catch (e) {
      _logBrightness('DDC set 异常: $e');
      return false;
    }
  }

  Future<int> _getBrightnessDDC() async {
    if (_brightScriptPath == null) return -1;
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', _brightScriptPath!,
        '-Action', 'get',
      ]);
      final out = result.stdout.toString().trim();
      _logBrightness('DDC get exit=${result.exitCode} stdout=${out} stderr=${result.stderr}');
      if (out.startsWith('CUR:')) {
        final cur = int.tryParse(out.substring(4));
        if (cur != null && cur >= 0) return cur;
      }
    } catch (e) {
      _logBrightness('DDC get 异常: $e');
    }
    return -1;
  }

  Future<void> adjustBrightness(int delta) async {
    int newBrightness = _currentBrightness + delta;
    newBrightness = newBrightness.clamp(2, 100);
    await setBrightness(newBrightness);
  }

  void dispose() {
    _pendingSetTimer?.cancel();
    _brightnessController.close();
  }
}
