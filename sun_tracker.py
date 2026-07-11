"""
SunTracker - 轻量级日出日落时间计算封装类

依赖: suntime (pip install suntime)
特性: 体积极小，无外部依赖，自动处理时区转换，捕获极昼/极夜异常。
"""

from datetime import date, datetime, timedelta, timezone
import math

try:
    from suntime import Sun, SunTimeException
except ImportError:
    raise ImportError(
        "请先安装 suntime: pip install suntime\n"
        "该库体积极小(~8KB)，无任何外部依赖，仅依赖 Python 标准库。"
    )


class SunTracker:
    """基于经纬度的日出日落时间追踪器。

    用法:
        tracker = SunTracker(lat=39.9042, lon=116.4074)  # 北京
        sunrise = tracker.get_sunrise(date.today())
        sunset  = tracker.get_sunset(date.today())
    """

    def __init__(self, lat: float, lon: float):
        """初始化。

        Args:
            lat: 纬度，北正南负 (-90 ~ 90)
            lon: 经度，东正西负 (-180 ~ 180)
        """
        self._lat = lat
        self._lon = lon
        self._sun = Sun(lat, lon)

        # 预先计算时区偏移（东经正、西经负）
        # 用经度估算 UTC 偏移小时数，四舍五入到半小时精度
        tz_hours = round(lon / 15.0 * 2) / 2.0
        self._tz_offset = timedelta(hours=tz_hours)

    # ---- 公开方法 ----

    def get_sunrise(self, d: date) -> datetime | None:
        """获取指定日期的日出本地时间。

        Args:
            d: 日期对象

        Returns:
            本地化的 datetime 对象，若该日为极昼/极夜则返回 None
        """
        try:
            utc_dt = self._sun.get_sunrise_time(d)
            return utc_dt.replace(tzinfo=timezone.utc) + self._tz_offset
        except SunTimeException:
            return None

    def get_sunset(self, d: date) -> datetime | None:
        """获取指定日期的日落本地时间。

        Args:
            d: 日期对象

        Returns:
            本地化的 datetime 对象，若该日为极昼/极夜则返回 None
        """
        try:
            utc_dt = self._sun.get_sunset_time(d)
            return utc_dt.replace(tzinfo=timezone.utc) + self._tz_offset
        except SunTimeException:
            return None

    def is_daytime(self, dt: datetime | None = None) -> bool | None:
        """判断给定时间是否为白天（日出 <= 时间 < 日落）。

        Args:
            dt: 要判断的时间。None 表示当前时间。

        Returns:
            True=白天, False=黑夜, None=该日存在极昼/极夜无法判断
        """
        if dt is None:
            dt = datetime.now()
        d = dt.date()
        sunrise = self.get_sunrise(d)
        sunset = self.get_sunset(d)

        # 极昼: 只有日出(或只有日落)都不正常，均属异常
        if sunrise is None and sunset is None:
            return None
        if sunrise is None:
            # 只有日落 → 极夜（一整天黑夜）
            return False
        if sunset is None:
            # 只有日出 → 极昼（一整天白天）
            return True

        return sunrise <= dt < sunset

    def __repr__(self) -> str:
        return f"SunTracker(lat={self._lat}, lon={self._lon})"


# =============================================
# 使用示例（可直接运行）
# =============================================
if __name__ == "__main__":
    from datetime import date

    # 北京
    tracker = SunTracker(lat=39.9042, lon=116.4074)

    today = date.today()
    sunrise = tracker.get_sunrise(today)
    sunset = tracker.get_sunset(today)

    print(f"日期: {today}")
    print(f"日出: {sunrise}")
    print(f"日落: {sunset}")
    print(f"当前是否为白天: {tracker.is_daytime()}")

    # 测试极区（夏季的北极圈内 → 极昼）
    arctic = SunTracker(lat=78.2, lon=15.6)
    print(f"\n北极夏季日出: {arctic.get_sunrise(today)}")   # 应为 None
    print(f"北极夏季日落: {arctic.get_sunset(today)}")      # 应为 None

    # 测试南极（冬季的南极圈内 → 极夜）
    antarctic = SunTracker(lat=-78.2, lon=15.6)
    print(f"\n南极冬季日出: {antarctic.get_sunrise(today)}")  # 应为 None
    print(f"南极冬季日落: {antarctic.get_sunset(today)}")     # 应为 None
