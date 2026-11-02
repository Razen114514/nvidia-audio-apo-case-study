using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AudioModeTray
{
    internal static class Program
    {
        private static Mutex instanceMutex;

        [STAThread]
        private static void Main()
        {
            bool createdNew;
            instanceMutex = new Mutex(true, "Local\\RazenAudioModeTray", out createdNew);
            if (!createdNew)
            {
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
    }

    internal sealed class TrayContext : ApplicationContext
    {
        private const string BaseDirectory = @"C:\ProgramData\AudioMode";
        private const string StateFile = @"C:\ProgramData\AudioMode\current-mode.txt";
        private const string TrayLog = @"C:\ProgramData\AudioMode\audio-mode-tray.log";

        private readonly Control dispatcher;
        private readonly NotifyIcon notifyIcon;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem speakerItem;
        private readonly ToolStripMenuItem headsetItem;
        private readonly ToolStripMenuItem desktopItem;
        private readonly ToolStripMenuItem statusItem;
        private readonly System.Threading.Timer deviceDebounceTimer;
        private readonly HotkeyWindow hotkeyWindow;

        private ManagementEventWatcher deviceWatcher;
        private string currentMode;
        private volatile bool applying;
        private DateTime suppressDeviceEventsUntil;
        private DateTime lastHotkeyUtc;

        public TrayContext()
        {
            dispatcher = new Control();
            dispatcher.CreateControl();

            currentMode = ReadCurrentMode();

            menu = new ContextMenuStrip();
            speakerItem = new ToolStripMenuItem("扬声器模式\tCtrl+Win+Shift+PageUp");
            headsetItem = new ToolStripMenuItem("G9 耳机模式\tCtrl+Win+Shift+PageDown");
            desktopItem = new ToolStripMenuItem("桌面麦克风模式");
            statusItem = new ToolStripMenuItem("状态");

            speakerItem.Click += delegate { ApplyMode("Speaker", true); };
            headsetItem.Click += delegate { ApplyMode("Headset", true); };
            desktopItem.Click += delegate { ApplyMode("Desktop", true); };

            menu.Items.Add(speakerItem);
            menu.Items.Add(headsetItem);
            menu.Items.Add(desktopItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(statusItem);

            ToolStripMenuItem openLogsItem = new ToolStripMenuItem("打开日志文件夹");
            openLogsItem.Click += delegate
            {
                try
                {
                    Process.Start("explorer.exe", BaseDirectory);
                }
                catch (Exception ex)
                {
                    ShowError("无法打开日志目录", ex.Message);
                }
            };
            menu.Items.Add(openLogsItem);

            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem exitItem = new ToolStripMenuItem("退出托盘");
            exitItem.Click += delegate { ExitTray(); };
            menu.Items.Add(exitItem);

            notifyIcon = new NotifyIcon();
            try
            {
                notifyIcon.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch
            {
                notifyIcon.Icon = SystemIcons.Application;
            }
            notifyIcon.Text = "音频模式切换";
            notifyIcon.Visible = true;
            notifyIcon.ContextMenuStrip = menu;
            notifyIcon.DoubleClick += delegate { menu.Show(Cursor.Position); };

            deviceDebounceTimer = new System.Threading.Timer(
                OnDeviceChangeDebounced,
                null,
                Timeout.Infinite,
                Timeout.Infinite
            );

            UpdateModeIndicators();
            StartDeviceWatcher();

            hotkeyWindow = new HotkeyWindow(delegate(int id)
            {
                if ((DateTime.UtcNow - lastHotkeyUtc).TotalMilliseconds < 800)
                {
                    return;
                }
                lastHotkeyUtc = DateTime.UtcNow;
                ApplyMode(id == HotkeyWindow.SpeakerHotkeyId ? "Speaker" : "Headset", false);
            });
            bool speakerHotkeyRegistered = hotkeyWindow.Register(
                HotkeyWindow.SpeakerHotkeyId,
                HotkeyWindow.ModControl | HotkeyWindow.ModShift | HotkeyWindow.ModWin,
                HotkeyWindow.VkPageUp);
            if (!speakerHotkeyRegistered)
            {
                Log("Failed to register PageUp hotkey.");
                ShowMessage("快捷键注册失败", "Ctrl+Win+Shift+PageUp 已被其他程序占用。", ToolTipIcon.Warning);
            }
            else
            {
                Log("Registered PageUp speaker hotkey.");
            }
            bool headsetHotkeyRegistered = hotkeyWindow.Register(
                HotkeyWindow.HeadsetHotkeyId,
                HotkeyWindow.ModControl | HotkeyWindow.ModShift | HotkeyWindow.ModWin,
                HotkeyWindow.VkPageDown);
            if (!headsetHotkeyRegistered)
            {
                Log("Failed to register PageDown hotkey.");
                ShowMessage("快捷键注册失败", "Ctrl+Win+Shift+PageDown 已被其他程序占用。", ToolTipIcon.Warning);
            }
            else
            {
                Log("Registered PageDown headset hotkey.");
            }

            Log("Tray started. Current mode: " + currentMode);
            ApplyMode(currentMode, true);
        }

        private string ReadCurrentMode()
        {
            try
            {
                if (File.Exists(StateFile))
                {
                    string value = File.ReadAllText(StateFile).Trim();
                    if (value == "Speaker" || value == "Headset" || value == "Desktop")
                    {
                        return value;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Read state failed: " + ex.Message);
            }
            return "Speaker";
        }

        private void ApplyMode(string targetMode, bool announce)
        {
            if (applying)
            {
                if (announce)
                {
                    ShowMessage("正在切换", "音频设备正在切换，请稍候。", ToolTipIcon.Info);
                }
                return;
            }

            applying = true;
            statusItem.Text = "正在应用：" + DisplayName(targetMode);
            Log("Applying mode: " + targetMode);

            Task.Run(delegate
            {
                SwitchResult result = RunSwitch(targetMode);
                bool success = result.ExitCode == 0;

                if (success)
                {
                    currentMode = targetMode;
                    try
                    {
                        File.WriteAllText(StateFile, targetMode);
                    }
                    catch (Exception ex)
                    {
                        Log("Write state failed: " + ex.Message);
                    }
                    Log("Mode applied: " + targetMode);
                }
                else
                {
                    Log("Mode failed: " + targetMode + " ExitCode=" + result.ExitCode);
                    Log("STDOUT: " + result.Output);
                    Log("STDERR: " + result.Error);
                }

                suppressDeviceEventsUntil = DateTime.UtcNow.AddSeconds(6);
                applying = false;

                InvokeUi(delegate
                {
                    UpdateModeIndicators();
                    if (success)
                    {
                        if (announce)
                        {
                            ShowMessage(
                                "音频模式已切换",
                                DisplayName(currentMode) + " 已生效。",
                                ToolTipIcon.Info
                            );
                        }
                    }
                    else
                    {
                        ShowMessage(
                            "音频模式切换失败",
                            FirstUsefulLine(result.Error, result.Output),
                            ToolTipIcon.Error
                        );
                    }
                });
            });
        }

        private SwitchResult RunSwitch(string targetMode)
        {
            return AudioSwitchEngine.Apply(targetMode, BaseDirectory);
        }

        private void StartDeviceWatcher()
        {
            try
            {
                WqlEventQuery query = new WqlEventQuery("SELECT * FROM Win32_DeviceChangeEvent");
                deviceWatcher = new ManagementEventWatcher(query);
                deviceWatcher.EventArrived += delegate
                {
                    if (applying || DateTime.UtcNow < suppressDeviceEventsUntil)
                    {
                        return;
                    }
                    deviceDebounceTimer.Change(2000, Timeout.Infinite);
                };
                deviceWatcher.Start();
                Log("Device watcher started.");
            }
            catch (Exception ex)
            {
                Log("Device watcher failed: " + ex.Message);
            }
        }

        private void OnDeviceChangeDebounced(object state)
        {
            if (applying || DateTime.UtcNow < suppressDeviceEventsUntil)
            {
                return;
            }

            Log("Device change detected. Reapplying mode: " + currentMode);
            ApplyMode(currentMode, false);
        }

        private void UpdateModeIndicators()
        {
            speakerItem.Checked = currentMode == "Speaker";
            headsetItem.Checked = currentMode == "Headset";
            desktopItem.Checked = currentMode == "Desktop";
            statusItem.Text = "当前：" + DisplayName(currentMode);
            notifyIcon.Text = "音频模式：" + DisplayName(currentMode);
        }

        private static string DisplayName(string mode)
        {
            if (mode == "Headset")
            {
                return "G9 耳机";
            }
            if (mode == "Desktop")
            {
                return "桌面麦克风";
            }
            return "扬声器";
        }

        private static string FirstUsefulLine(string primary, string secondary)
        {
            string text = !string.IsNullOrWhiteSpace(primary) ? primary : secondary;
            if (string.IsNullOrWhiteSpace(text))
            {
                return "请查看音频模式日志。";
            }

            string[] lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            return lines.Length > 0 ? lines[0].Trim() : text.Trim();
        }

        private void InvokeUi(Action action)
        {
            if (dispatcher.IsDisposed)
            {
                return;
            }

            try
            {
                dispatcher.BeginInvoke(action);
            }
            catch
            {
            }
        }

        private void ShowMessage(string title, string text, ToolTipIcon icon)
        {
            notifyIcon.BalloonTipTitle = title;
            notifyIcon.BalloonTipText = text;
            notifyIcon.BalloonTipIcon = icon;
            notifyIcon.ShowBalloonTip(3500);
        }

        private void ShowError(string title, string text)
        {
            ShowMessage(title, FirstUsefulLine(text, ""), ToolTipIcon.Error);
        }

        private static void Log(string message)
        {
            try
            {
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message;
                File.AppendAllText(TrayLog, line + Environment.NewLine);
            }
            catch
            {
            }
        }

        private void ExitTray()
        {
            Log("Tray exit requested.");
            notifyIcon.Visible = false;
            notifyIcon.Dispose();
            deviceDebounceTimer.Dispose();
            hotkeyWindow.Dispose();
            if (deviceWatcher != null)
            {
                deviceWatcher.Stop();
                deviceWatcher.Dispose();
            }
            dispatcher.Dispose();
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (deviceWatcher != null)
                {
                    try
                    {
                        deviceWatcher.Stop();
                    }
                    catch
                    {
                    }
                    deviceWatcher.Dispose();
                }
                deviceDebounceTimer.Dispose();
                hotkeyWindow.Dispose();
                notifyIcon.Dispose();
                dispatcher.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    internal sealed class SwitchResult
    {
        public int ExitCode;
        public string Output;
        public string Error;
    }

    internal sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        public const int SpeakerHotkeyId = 0x5101;
        public const int HeadsetHotkeyId = 0x5102;
        public const uint ModControl = 0x0002;
        public const uint ModShift = 0x0004;
        public const uint ModWin = 0x0008;
        public const uint VkPageUp = 0x21;
        public const uint VkPageDown = 0x22;

        private const int WmHotkey = 0x0312;
        private readonly Action<int> callback;

        [DllImport("user32.dll")]
        private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr window, int id);

        public HotkeyWindow(Action<int> callback)
        {
            this.callback = callback;
            CreateParams parameters = new CreateParams();
            parameters.Caption = "AudioModeHotkeys";
            CreateHandle(parameters);
        }

        public bool Register(int id, uint modifiers, uint virtualKey)
        {
            return RegisterHotKey(Handle, id, modifiers, virtualKey);
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotkey)
            {
                callback(message.WParam.ToInt32());
                return;
            }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            UnregisterHotKey(Handle, SpeakerHotkeyId);
            UnregisterHotKey(Handle, HeadsetHotkeyId);
            DestroyHandle();
        }
    }
}
