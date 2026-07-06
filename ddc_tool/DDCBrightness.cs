using System;
using System.Runtime.InteropServices;

class DDCBrightness
{
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetMonitorBrightness(IntPtr hMonitor, uint dwNewBrightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetMonitorBrightness(IntPtr hMonitor, out uint pdwMinimumBrightness, out uint pdwCurrentBrightness, out uint pdwMaximumBrightness);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("dxva2.dll")]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll")]
    static extern bool DestroyPhysicalMonitors(uint dwPhysicalMonitorArraySize, [In] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct PHYSICAL_MONITOR
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
        public IntPtr hPhysicalMonitor;
    }

    static IntPtr _hPhysicalMonitor = IntPtr.Zero;
    static bool _found = false;

    static bool EnumCallback(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData)
    {
        PHYSICAL_MONITOR[] physArr = new PHYSICAL_MONITOR[1];
        bool ok = GetPhysicalMonitorsFromHMONITOR(hMonitor, 1, physArr);
        if (ok)
        {
            _hPhysicalMonitor = physArr[0].hPhysicalMonitor;
            _found = true;
            return false; // 找到第一个显示器就停止
        }
        return true;
    }

    static void Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.WriteLine("Usage: DDCBrightness.exe set <level> | get");
            return;
        }

        // 获取物理显示器句柄
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, EnumCallback, IntPtr.Zero);

        if (!_found)
        {
            Console.WriteLine("FAIL:NoMonitor");
            return;
        }

        try
        {
            if (args[0] == "set" && args.Length >= 2)
            {
                uint level;
                if (!uint.TryParse(args[1], out level))
                {
                    Console.WriteLine("FAIL:0");
                    return;
                }

                if (SetMonitorBrightness(_hPhysicalMonitor, level))
                {
                    Console.WriteLine("OK:" + level);
                }
                else
                {
                    int err = Marshal.GetLastWin32Error();
                    Console.WriteLine("FAIL:" + err);
                }
            }
            else if (args[0] == "get")
            {
                uint min, cur, max;
                if (GetMonitorBrightness(_hPhysicalMonitor, out min, out cur, out max))
                {
                    Console.WriteLine("CUR:" + cur);
                }
                else
                {
                    int err = Marshal.GetLastWin32Error();
                    Console.WriteLine("FAIL:" + err);
                }
            }
            else
            {
                Console.WriteLine("FAIL:0");
            }
        }
        finally
        {
            if (_found)
            {
                // 释放物理显示器句柄
                PHYSICAL_MONITOR[] physArr = new PHYSICAL_MONITOR[1];
                physArr[0].hPhysicalMonitor = _hPhysicalMonitor;
                DestroyPhysicalMonitors(1, physArr);
            }
        }
    }
}