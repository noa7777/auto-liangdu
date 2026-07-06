# AutoLiangDu

本项目包含 AutoLiangDu 自动亮度调节系统的 PC 客户端与 ESP8266 采集端源码。

## 目录结构

- `pc_app_new/` — Flutter Windows 客户端
  - 通过 UDP 接收 ESP8266 上传的环境光数据
  - 支持 DDC/CI、WMI、Gamma 曲线方式调节显示器亮度
  - 提供手动调节、亮度映射表、系统托盘等功能
- `auto_brightness_mcu/` — ESP8266 固件
  - 每秒读取 BH1750 光照传感器
  - 通过 UDP 广播当前 Lux 值到 `255.255.255.255:8888`

## 技术栈

| 项目 | 框架/平台 | 主要依赖 |
|------|-----------|----------|
| PC 客户端 | Flutter 3.x (Windows) | window_manager, tray_manager, file_picker, win32, ffi |
| 采集端 | Arduino + ESP8266 | BH1750, ESP8266WiFi, WiFiUdp |

## 构建入口

- PC 客户端：`flutter build windows --release`
- ESP8266 固件：`pio run --target upload --upload-port COM3`

## 隐私说明

ESP8266 固件源码 `auto_brightness_mcu/src/main.cpp` 中包含 WiFi SSID 与密码，提交到版本控制前请替换为占位符或移入未跟踪的配置文件。

## 桌面端功能说明

- 实时显示 ESP8266 上传的环境光强度（Lux）。
- 手动调节显示器亮度：支持 +/- 按钮和数值输入，连续点击会自动合并为一次 DDC 调用。
- 亮度映射表：根据 Lux 自动匹配并应用对应的显示器亮度。
- 手动模式优先级：手动调节后 5 秒内，映射表不会覆盖当前亮度。
- 系统托盘：关闭窗口时最小化到托盘，点击托盘图标恢复窗口，右键托盘图标选择“退出”关闭软件。
- 开机自启：可选随 Windows 启动。
- 配置持久化：亮度映射表、托盘和自启设置自动保存，支持导入/导出。
- 窗口控制：隐藏原生标题栏，仅保留 AppBar 作为唯一标题栏。
