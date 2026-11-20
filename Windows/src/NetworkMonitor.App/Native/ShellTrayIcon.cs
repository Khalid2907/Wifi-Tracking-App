using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace NetworkMonitor.App.Native;

/// <summary>Small Shell_NotifyIcon bridge; sampling remains in the shared app service.</summary>
internal sealed class ShellTrayIcon : IDisposable
{
    private const uint WmApp = 0x8000;
    private const uint WmLeftDoubleClick = 0x0203;
    private const uint WmLeftButtonUp = 0x0202;
    private const uint WmRightButtonUp = 0x0205;
    private const uint WmPowerBroadcast = 0x0218;
    private const uint NimAdd = 0;
    private const uint NimDelete = 2;
    private const uint NimSetVersion = 4;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint NifGuid = 0x20;
    private const uint NiifGuid = 1;
    private const uint TpmRightButton = 2;
    private const uint TpmReturnCommand = 0x0100;
    private const uint MfString = 0;
    private const int SwShow = 5;
    private const int SwHide = 0;
    private readonly IntPtr _window;
    private readonly Action _show;
    private readonly Action _exit;
    private readonly Action<bool> _powerTransition;
    private readonly SubclassProc _subclass;
    private readonly uint _callbackMessage = WmApp + 33;
    private readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private readonly Guid _id = new("a0d1b4c3-f82e-4f73-a772-a94d93de6e28");
    private bool _disposed;

    public ShellTrayIcon(Window window, Action show, Action exit, Action<bool> powerTransition)
    {
        _window = WindowNative.GetWindowHandle(window);
        _show = show;
        _exit = exit;
        _powerTransition = powerTransition;
        _subclass = WindowSubclass;
        if (!SetWindowSubclass(_window, _subclass, (UIntPtr)1, UIntPtr.Zero))
            throw new InvalidOperationException("Could not install the system tray window callback.");
        AddIcon();
    }

    public void HideWindow() => ShowWindow(_window, SwHide);

    public void ShowWindow()
    {
        ShowWindow(_window, SwShow);
        SetForegroundWindow(_window);
        _show();
    }

    private void AddIcon()
    {
        var data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = _window,
            Id = 1,
            Flags = NifMessage | NifIcon | NifTip | NifGuid,
            CallbackMessage = _callbackMessage,
            Icon = LoadIcon(IntPtr.Zero, (IntPtr)32512),
            Tip = "Network Monitor — open dashboard",
            Info = string.Empty,
            InfoTitle = string.Empty,
            Guid = _id,
            Version = 4
        };
        if (!Shell_NotifyIcon(NimAdd, ref data)) throw new InvalidOperationException("Windows could not create the tray icon.");
        data.Flags = NifGuid;
        Shell_NotifyIcon(NimSetVersion, ref data);
    }

    private IntPtr WindowSubclass(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam, UIntPtr subclassId, UIntPtr referenceData)
    {
        if (message == WmPowerBroadcast)
        {
            var powerEvent = wParam.ToUInt64();
            if (powerEvent == 4) _powerTransition(false);
            else if (powerEvent is 7 or 0x12) _powerTransition(true);
        }
        else if (_taskbarCreated != 0 && message == _taskbarCreated) AddIcon();
        else if (message == _callbackMessage)
        {
            // Notification icon version 4 packs the event identifier into the low word of lParam.
            var notification = unchecked((uint)lParam.ToInt64()) & 0xffff;
            if (notification == WmLeftButtonUp || notification == WmLeftDoubleClick) ShowWindow();
            else if (notification == WmRightButtonUp) ShowMenu();
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        SetForegroundWindow(_window);
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        try
        {
            AppendMenu(menu, MfString, (UIntPtr)1, "Open Network Monitor");
            AppendMenu(menu, MfString, (UIntPtr)2, "Exit");
            GetCursorPos(out var point);
            var command = TrackPopupMenu(menu, TpmRightButton | TpmReturnCommand, point.X, point.Y, 0, _window, IntPtr.Zero);
            if (command == 1) ShowWindow();
            else if (command == 2) _exit();
            PostMessage(_window, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally { DestroyMenu(menu); }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        var data = new NotifyIconData { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = _window, Id = 1, Flags = NifGuid, Tip = string.Empty, Info = string.Empty, InfoTitle = string.Empty, Guid = _id };
        Shell_NotifyIcon(NimDelete, ref data);
        RemoveWindowSubclass(_window, _subclass, (UIntPtr)1);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public IntPtr BalloonIcon;
        public uint Version { readonly get => TimeoutOrVersion; set => TimeoutOrVersion = value; }
    }

    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X; public int Y; }
    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam, UIntPtr subclassId, UIntPtr referenceData);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", EntryPoint = "LoadIconW", SetLastError = true)] private static extern IntPtr LoadIcon(IntPtr instance, IntPtr name);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr window, IntPtr rect);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool SetWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId, UIntPtr referenceData);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProc callback, UIntPtr subclassId);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
}
