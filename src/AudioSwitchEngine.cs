using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AudioModeTray
{
    internal sealed class AudioEndpointInfo
    {
        public string Flow;
        public string Id;
        public string InstanceId;
        public string AdapterName;
        public string Description;
        public string ParentInstanceId;
        public bool Active;
    }

    internal static class AudioSwitchEngine
    {
        private const string AudioRoot =
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio";
        private const string AdapterNameKey =
            "{b3f8fa53-0004-438e-9003-51a46e139bfc},6";
        private const string DescriptionKey =
            "{a45c254e-df1c-4efd-8020-67d146a850e0},2";
        private const string ParentKey =
            "{b3f8fa53-0004-438e-9003-51a46e139bfc},2";

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        private static extern int CM_Locate_DevNodeW(
            out uint deviceInstance,
            string deviceId,
            uint flags
        );

        [DllImport("cfgmgr32.dll")]
        private static extern int CM_Get_DevNode_Status(
            out uint status,
            out uint problem,
            uint deviceInstance,
            uint flags
        );

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PROPERTYKEY
        {
            public Guid fmtid;
            public uint pid;
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PROPVARIANT
        {
            [FieldOffset(0)] public ushort vt;
            [FieldOffset(8)] public uint ulVal;
        }

        [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
        private class CPolicyConfigClient { }

        [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPolicyConfig
        {
            [PreserveSig]
            int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
            [PreserveSig]
            int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr format);
            [PreserveSig]
            int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig]
            int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
            [PreserveSig]
            int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr defaultPeriod, IntPtr minimumPeriod);
            [PreserveSig]
            int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
            [PreserveSig]
            int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
            [PreserveSig]
            int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
            [PreserveSig]
            int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool fxStore, ref PROPERTYKEY key, out PROPVARIANT value);
            [PreserveSig]
            int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool fxStore, ref PROPERTYKEY key, ref PROPVARIANT value);
            [PreserveSig]
            int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
            [PreserveSig]
            int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
        }

        public static SwitchResult Apply(string mode, string baseDirectory)
        {
            Stopwatch timer = Stopwatch.StartNew();
            string logPath = Path.Combine(baseDirectory, "audio-mode.log");

            try
            {
                bool changingMode = mode != "Status";
                Log(logPath, "Native mode requested: " + mode);
                List<AudioEndpointInfo> endpoints = GetEndpoints();

                if (mode == "Headset")
                {
                    EnsureMediaDevice(endpoints, "MCHOSE G9");
                    EnsureMediaDevice(endpoints, "Realtek High Definition Audio");
                    endpoints = GetEndpoints();
                    AudioEndpointInfo headsetRender = FindPrimaryRender(endpoints, "MCHOSE G9");
                    if (headsetRender == null)
                    {
                        throw new InvalidOperationException("MCHOSE G9 render endpoint is unavailable.");
                    }
                    AudioEndpointInfo headsetCapture = EnableCaptureEndpoint(
                        endpoints,
                        "MCHOSE G9",
                        CachePath(baseDirectory, "g9-capture")
                    );
                    endpoints = GetEndpoints();
                    headsetRender = FindPrimaryRender(endpoints, "MCHOSE G9");
                    SetDisableSysFx(headsetRender.Id);
                    if (headsetCapture.Active)
                    {
                        SetDisableSysFx(headsetCapture.Id);
                    }
                    SetDefaultForAllRoles(headsetRender.Id);
                    SetDefaultForAllRoles(headsetCapture.Id);
                    DisableCaptureEndpoint(
                        endpoints,
                        "Realtek High Definition Audio",
                        CachePath(baseDirectory, "realtek-capture")
                    );
                    SaveCache(CachePath(baseDirectory, "g9-render"), headsetRender.Id);
                }
                else if (mode == "Speaker" || mode == "Desktop")
                {
                    EnsureMediaDevice(endpoints, "Realtek High Definition Audio");
                    EnsureMediaDevice(endpoints, "MCHOSE G9");
                    endpoints = GetEndpoints();
                    AudioEndpointInfo desktopRender = FindPrimaryRender(endpoints, "Realtek High Definition Audio");
                    if (desktopRender == null)
                    {
                        throw new InvalidOperationException("Realtek render endpoint is unavailable.");
                    }

                    foreach (AudioEndpointInfo endpoint in endpoints.Where(
                        item => item.Active && item.AdapterName.IndexOf(
                            "MCHOSE G9",
                            StringComparison.OrdinalIgnoreCase
                        ) >= 0))
                    {
                        SetDisableSysFx(endpoint.Id);
                    }

                    SetDefaultForAllRoles(desktopRender.Id);
                    SaveCache(CachePath(baseDirectory, "realtek-render"), desktopRender.Id);

                    AudioEndpointInfo desktopCapture = FindActiveCapture(
                        endpoints,
                        "Realtek High Definition Audio"
                    );
                    if (desktopCapture != null)
                    {
                        SetDefaultForAllRoles(desktopCapture.Id);
                        SaveCache(CachePath(baseDirectory, "realtek-capture"), desktopCapture.Id);
                    }
                    else if (mode == "Desktop")
                    {
                        throw new InvalidOperationException(
                            "Realtek microphone endpoint is unavailable. Plug the microphone into the motherboard 3.5 mm jack."
                        );
                    }

                    DisableCaptureEndpoint(
                        endpoints,
                        "MCHOSE G9",
                        CachePath(baseDirectory, "g9-capture")
                    );
                }

                if (changingMode)
                {
                    File.WriteAllText(
                        Path.Combine(baseDirectory, "current-mode.txt"),
                        mode
                    );
                }
                string summary = BuildSummary(baseDirectory);
                timer.Stop();
                Log(logPath, string.Format(
                    "Native mode completed: {0} in {1:F3} seconds",
                    mode,
                    timer.Elapsed.TotalSeconds
                ));

                SwitchResult result = new SwitchResult();
                result.ExitCode = 0;
                result.Output = summary;
                result.Error = "";
                return result;
            }
            catch (Exception ex)
            {
                timer.Stop();
                Log(logPath, "NATIVE ERROR " + ex.Message);
                SwitchResult result = new SwitchResult();
                result.ExitCode = 1;
                result.Output = "";
                result.Error = ex.Message;
                return result;
            }
        }

        private static List<AudioEndpointInfo> GetEndpoints()
        {
            List<AudioEndpointInfo> items = new List<AudioEndpointInfo>();
            using (RegistryKey audioKey = Registry.LocalMachine.OpenSubKey(AudioRoot))
            {
                if (audioKey == null)
                {
                    throw new InvalidOperationException(
                        "MMDevices audio registry key is unavailable."
                    );
                }

                AddEndpoints(items, audioKey, "Render");
                AddEndpoints(items, audioKey, "Capture");
            }
            return items;
        }

        private static void AddEndpoints(
            List<AudioEndpointInfo> items,
            RegistryKey audioKey,
            string flow
        )
        {
            using (RegistryKey flowKey = audioKey.OpenSubKey(flow))
            {
                if (flowKey == null)
                {
                    return;
                }

                foreach (string guid in flowKey.GetSubKeyNames())
                {
                    using (RegistryKey endpointKey = flowKey.OpenSubKey(guid))
                    using (RegistryKey propertiesKey = endpointKey == null
                        ? null
                        : endpointKey.OpenSubKey("Properties"))
                    {
                        if (propertiesKey == null)
                        {
                            continue;
                        }

                        string adapterName = Convert.ToString(
                            propertiesKey.GetValue(AdapterNameKey, "")
                        );
                        if (string.IsNullOrWhiteSpace(adapterName))
                        {
                            continue;
                        }

                        bool relevant =
                            adapterName.IndexOf(
                                "MCHOSE G9",
                                StringComparison.OrdinalIgnoreCase
                            ) >= 0 ||
                            adapterName.IndexOf(
                                "Realtek High Definition Audio",
                                StringComparison.OrdinalIgnoreCase
                            ) >= 0;

                        string prefix = flow == "Render"
                            ? "{0.0.0.00000000}."
                            : "{0.0.1.00000000}.";
                        string id = prefix + guid.ToLowerInvariant();
                        string instanceId = @"SWD\MMDEVAPI\" + id;
                        string parentRaw = Convert.ToString(
                            propertiesKey.GetValue(ParentKey, "")
                        );

                        AudioEndpointInfo endpoint = new AudioEndpointInfo();
                        endpoint.Flow = flow;
                        endpoint.Id = id;
                        endpoint.InstanceId = instanceId;
                        endpoint.AdapterName = adapterName;
                        endpoint.Description = Convert.ToString(
                            propertiesKey.GetValue(DescriptionKey, "")
                        );
                        endpoint.ParentInstanceId =
                            parentRaw.StartsWith("{1}.")
                                ? parentRaw.Substring(4)
                                : parentRaw;
                        endpoint.Active =
                            relevant && IsDeviceStarted(instanceId);
                        items.Add(endpoint);
                    }
                }
            }
        }

        private static bool IsDeviceStarted(string instanceId)
        {
            uint instance;
            int locateResult = CM_Locate_DevNodeW(out instance, instanceId, 0);
            if (locateResult != 0)
            {
                return false;
            }

            uint status;
            uint problem;
            int statusResult = CM_Get_DevNode_Status(
                out status,
                out problem,
                instance,
                0
            );
            return statusResult == 0 && problem == 0;
        }

        private static void EnsureMediaDevice(
            List<AudioEndpointInfo> endpoints,
            string adapterPattern
        )
        {
            if (endpoints.Any(item =>
                item.Active &&
                item.AdapterName.IndexOf(
                    adapterPattern,
                    StringComparison.OrdinalIgnoreCase
                ) >= 0))
            {
                return;
            }

            AudioEndpointInfo sample = endpoints.FirstOrDefault(item =>
                item.AdapterName.IndexOf(
                    adapterPattern,
                    StringComparison.OrdinalIgnoreCase
                ) >= 0 &&
                !string.IsNullOrWhiteSpace(item.ParentInstanceId));
            if (sample == null)
            {
                throw new InvalidOperationException(
                    "Audio device is unavailable: " + adapterPattern
                );
            }

            RunPnPUtil("enable-device", sample.ParentInstanceId);
            WaitFor(
                delegate
                {
                    return GetEndpoints().Any(item =>
                        item.Active &&
                        item.AdapterName.IndexOf(
                            adapterPattern,
                            StringComparison.OrdinalIgnoreCase
                        ) >= 0);
                },
                3000
            );
        }

        private static AudioEndpointInfo FindPrimaryRender(
            List<AudioEndpointInfo> endpoints,
            string adapterPattern
        )
        {
            List<AudioEndpointInfo> candidates = endpoints.Where(item =>
                item.Flow == "Render" &&
                item.Active &&
                item.AdapterName.IndexOf(
                    adapterPattern,
                    StringComparison.OrdinalIgnoreCase
                ) >= 0
            ).ToList();
            if (candidates.Count == 0)
            {
                return null;
            }

            AudioEndpointInfo preferred = candidates.FirstOrDefault(item =>
                item.Description.IndexOf("2nd output", StringComparison.OrdinalIgnoreCase) < 0 &&
                !item.Description.StartsWith("2-")
            );
            return preferred ?? candidates[0];
        }

        private static AudioEndpointInfo FindActiveCapture(
            List<AudioEndpointInfo> endpoints,
            string adapterPattern
        )
        {
            return endpoints.FirstOrDefault(item =>
                item.Flow == "Capture" &&
                item.Active &&
                item.AdapterName.IndexOf(
                    adapterPattern,
                    StringComparison.OrdinalIgnoreCase
                ) >= 0
            );
        }

        private static AudioEndpointInfo EnableCaptureEndpoint(
            List<AudioEndpointInfo> endpoints,
            string adapterPattern,
            string cachePath
        )
        {
            AudioEndpointInfo active = FindActiveCapture(endpoints, adapterPattern);
            if (active != null)
            {
                SaveCache(cachePath, active.Id);
                return active;
            }

            string cachedId = ReadCache(cachePath);
            if (string.IsNullOrWhiteSpace(cachedId))
            {
                throw new InvalidOperationException(
                    "No capture endpoint is available for " + adapterPattern + "."
                );
            }

            RunPnPUtil("enable-device", @"SWD\MMDEVAPI\" + cachedId);
            AudioEndpointInfo enabled = null;
            WaitFor(
                delegate
                {
                    enabled = GetEndpoints().FirstOrDefault(item =>
                        item.Active && item.Id == cachedId
                    );
                    return enabled != null;
                },
                3000
            );
            SaveCache(cachePath, enabled.Id);
            return enabled;
        }

        private static void DisableCaptureEndpoint(
            List<AudioEndpointInfo> endpoints,
            string adapterPattern,
            string cachePath
        )
        {
            AudioEndpointInfo active = FindActiveCapture(endpoints, adapterPattern);
            if (active == null)
            {
                return;
            }

            SaveCache(cachePath, active.Id);
            RunPnPUtil("disable-device", active.InstanceId);
            WaitFor(
                delegate
                {
                    return !GetEndpoints().Any(item =>
                        item.Active && item.Id == active.Id
                    );
                },
                3000
            );
        }

        private static void SetDefaultForAllRoles(string endpointId)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(
                typeof(CPolicyConfigClient)
            );
            for (int role = 0; role < 3; role++)
            {
                int hr = policy.SetDefaultEndpoint(endpointId, role);
                if (hr != 0)
                {
                    throw new InvalidOperationException(
                        string.Format(
                            "SetDefaultEndpoint failed with HRESULT 0x{0:X8}",
                            hr
                        )
                    );
                }
            }
        }

        private static void SetDisableSysFx(string endpointId)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(
                typeof(CPolicyConfigClient)
            );
            PROPERTYKEY key = new PROPERTYKEY();
            key.fmtid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
            key.pid = 5;
            PROPVARIANT value = new PROPVARIANT();
            value.vt = 19;
            value.ulVal = 1;
            int hr = policy.SetPropertyValue(endpointId, true, ref key, ref value);
            if (hr != 0)
            {
                throw new InvalidOperationException(
                    string.Format(
                        "SetPropertyValue(Disable_SysFx) failed with HRESULT 0x{0:X8}",
                        hr
                    )
                );
            }
        }

        private static void RunPnPUtil(string action, string instanceId)
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = "pnputil.exe";
            startInfo.Arguments = string.Format(
                "/{0} \"{1}\"",
                action,
                instanceId
            );
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            using (Process process = Process.Start(startInfo))
            {
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(string.Format(
                        "pnputil /{0}-device failed: {1} {2}",
                        action,
                        output,
                        error
                    ));
                }
            }
        }

        private static void WaitFor(Func<bool> condition, int timeoutMs)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMs)
            {
                if (condition())
                {
                    return;
                }
                System.Threading.Thread.Sleep(75);
            }
            throw new TimeoutException("Audio endpoint state did not update in time.");
        }

        private static string CachePath(string baseDirectory, string name)
        {
            return Path.Combine(baseDirectory, "cache-" + name + ".txt");
        }

        private static string ReadCache(string path)
        {
            try
            {
                return File.Exists(path) ? File.ReadAllText(path).Trim() : "";
            }
            catch
            {
                return "";
            }
        }

        private static void SaveCache(string path, string endpointId)
        {
            try
            {
                File.WriteAllText(path, endpointId);
            }
            catch
            {
            }
        }

        private static string BuildSummary(string baseDirectory)
        {
            List<AudioEndpointInfo> endpoints = GetEndpoints();
            // The tray only needs a compact status line; detailed state remains in the log.
            AudioEndpointInfo render = FindPrimaryRender(endpoints, "Realtek High Definition Audio");
            AudioEndpointInfo g9 = FindPrimaryRender(endpoints, "MCHOSE G9");
            if (render == null && g9 == null)
            {
                return "No managed render endpoint.";
            }

            string current = File.Exists(Path.Combine(baseDirectory, "current-mode.txt"))
                ? File.ReadAllText(Path.Combine(baseDirectory, "current-mode.txt")).Trim()
                : "Unknown";
            return "Mode=" + current +
                "; Realtek=" + (render != null ? "ready" : "missing") +
                "; G9=" + (g9 != null ? "ready" : "missing");
        }

        private static void Log(string path, string message)
        {
            try
            {
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") +
                    " " + message + Environment.NewLine;
                File.AppendAllText(path, line);
            }
            catch
            {
            }
        }
    }
}
