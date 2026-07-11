import 'dart:math';

/// 基于 NOAA 太阳位置算法计算日出日落时间。
/// 纯 Dart 实现，零外部依赖，只使用 dart:math。
///
/// 返回的时间为**本地太阳时**（基于经度的真太阳时），
/// 不依赖任何时区数据库，体积极小，适合资源受限场景。
class SunCalculator {
  final double latitude; // 纬度，北正南负 (-90 ~ 90)
  final double longitude; // 经度，东正西负 (-180 ~ 180)

  SunCalculator({required this.latitude, required this.longitude});

  /// 获取指定日期的日出本地时间，极夜返回 null
  DateTime? getSunrise(DateTime date) => _calc(date, isSunrise: true);

  /// 获取指定日期的日落本地时间，极昼返回 null
  DateTime? getSunset(DateTime date) => _calc(date, isSunrise: false);

  /// 判断指定时间是否为白天（日出 <= 时间 < 日落）
  bool? isDaytime(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final sunrise = getSunrise(d);
    final sunset = getSunset(d);

    if (sunrise == null && sunset == null) return null; // 极昼夜
    if (sunrise == null) return false; // 极夜
    if (sunset == null) return true; // 极昼

    return !dt.isBefore(sunrise) && dt.isBefore(sunset);
  }

  DateTime? _calc(DateTime date, {required bool isSunrise}) {
    final n = _dayOfYear(date); // 1-365/366
    final latRad = _rad(latitude);

    // ---- 轨道计算 ----
    final t = n.toDouble();
    final M = 0.9856 * t - 3.289; // 平近点角 (°)
    final mRad = _rad(M);
    var L = M + 1.916 * sin(mRad) + 0.020 * sin(2 * mRad) + 282.634; // 真黄经 (°)
    L %= 360;
    if (L < 0) L += 360;
    final lRad = _rad(L);

    // ---- 赤经 ----
    var ra = _deg(atan(0.91764 * tan(lRad))); // (°)
    ra += (L / 90).floor() * 90 - (ra / 90).floor() * 90; // 象限校正
    ra %= 360;
    if (ra < 0) ra += 360;

    // ---- 赤纬 ----
    final sinDec = 0.39782 * sin(lRad);
    final decRad = asin(sinDec);

    // ---- 时角 ----
    // 90.833° = 太阳视圆面中心到地平线的天顶距 (90° + 平均折射 0.567° + 视半径 0.267°)
    final cosH =
        (cos(_rad(90.833)) - sinDec * sin(latRad)) / (cos(decRad) * cos(latRad));

    if (cosH < -1) return null; // 极昼
    if (cosH > 1) return null; // 极夜

    final H = _deg(acos(cosH)); // 时角 (°)
    final hHr = H / 15.0; // 时角 (小时)

    // ---- 本地太阳时 ----
    // 正午在 0.5 个小数日（12:00），日出在正午前 H 小时，日落在正午后 H 小时
    final eventFrac = isSunrise ? 0.5 - hHr / 24.0 : 0.5 + hHr / 24.0;

    final totalHours = eventFrac * 24;
    final hour = totalHours.floor();
    final minute = ((totalHours - hour) * 60).floor();
    final second =
        (((totalHours - hour) * 60 - minute) * 60).round().clamp(0, 59);

    return DateTime(date.year, date.month, date.day,
        hour.clamp(0, 23), minute.clamp(0, 59), second);
  }

  /// 计算一年中的第几天（1 月 1 日 = 1）
  int _dayOfYear(DateTime date) {
    final start = DateTime(date.year, 1, 1);
    return date.difference(start).inDays + 1;
  }

  static double _rad(double deg) => deg * pi / 180.0;
  static double _deg(double rad) => rad * 180.0 / pi;
}
