param(
    [ValidateSet('Headset', 'Speaker', 'Desktop', 'Status')]
    [string]$Mode = 'Status'
)

$ErrorActionPreference = 'Stop'
$AudioRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$StatePath = Join-Path $PSScriptRoot 'current-mode.txt'
$LogPath = Join-Path $PSScriptRoot 'audio-mode.log'

function Write-ModeLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Mode -ne 'Status' -and -not (Test-IsAdmin)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-Mode', $Mode
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

if (-not ('FastAudio.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace FastAudio
{
    public enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    public enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public uint ulVal;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig]
        int OpenPropertyStore(int access, out IntPtr props);
        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig]
        int GetState(out int state);
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    internal class CPolicyConfigClient { }

    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
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

    public static class Native
    {
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        private static extern int CM_Locate_DevNodeW(out uint deviceInstance, string deviceId, uint flags);

        [DllImport("cfgmgr32.dll")]
        private static extern int CM_Get_DevNode_Status(out uint status, out uint problem, uint deviceInstance, uint flags);

        public static bool IsDeviceStarted(string deviceId)
        {
            uint instance;
            int locateResult = CM_Locate_DevNodeW(out instance, deviceId, 0);
            if (locateResult != 0)
            {
                return false;
            }

            uint status;
            uint problem;
            int statusResult = CM_Get_DevNode_Status(out status, out problem, instance, 0);
            if (statusResult != 0)
            {
                return false;
            }

            return problem == 0;
        }

        public static int SetDefault(string id, int role)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(typeof(CPolicyConfigClient));
            return policy.SetDefaultEndpoint(id, role);
        }

        public static int SetDisableSysFx(string id, uint value)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(typeof(CPolicyConfigClient));
            var key = new PROPERTYKEY();
            key.fmtid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
            key.pid = 5;
            var prop = new PROPVARIANT();
            prop.vt = 19;
            prop.ulVal = value;
            return policy.SetPropertyValue(id, true, ref key, ref prop);
        }

        public static string[] GetDefaults()
        {
            var type = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
            var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(type);
            var results = new string[6];
            int index = 0;
            foreach (EDataFlow flow in new[] { EDataFlow.eRender, EDataFlow.eCapture })
            {
                foreach (ERole role in new[] { ERole.eConsole, ERole.eMultimedia, ERole.eCommunications })
                {
                    IMMDevice device;
                    int hr = enumerator.GetDefaultAudioEndpoint(flow, role, out device);
                    string id = string.Empty;
                    if (hr == 0)
                    {
                        device.GetId(out id);
                    }
                    results[index++] = string.Format("{0}:{1}:{2}:{3}", flow, role, hr, id);
                }
            }
            return results;
        }
    }
}
'@
}

function Get-RegistryValue {
    param(
        [Microsoft.Win32.RegistryKey]$Key,
        [string]$Name
    )
    if (-not $Key) { return $null }
    return $Key.GetValue($Name, $null)
}

function Get-AudioEndpoints {
    $items = @()
    $audioKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($AudioRoot)
    if (-not $audioKey) {
        throw 'MMDevices audio registry key is unavailable.'
    }

    try {
        foreach ($flow in @('Render', 'Capture')) {
            $flowKey = $audioKey.OpenSubKey($flow)
            if (-not $flowKey) { continue }
            try {
                foreach ($guid in $flowKey.GetSubKeyNames()) {
                    $endpointKey = $flowKey.OpenSubKey($guid)
                    if (-not $endpointKey) { continue }
                    try {
                        $state = [int](Get-RegistryValue $endpointKey 'DeviceState')
                        $propertiesKey = $endpointKey.OpenSubKey('Properties')
                        if (-not $propertiesKey) { continue }
                        try {
                            $adapterName = [string](Get-RegistryValue $propertiesKey '{b3f8fa53-0004-438e-9003-51a46e139bfc},6')
                            $description = [string](Get-RegistryValue $propertiesKey '{a45c254e-df1c-4efd-8020-67d146a850e0},2')
                            $parentRaw = [string](Get-RegistryValue $propertiesKey '{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
                            $parent = $parentRaw -replace '^\{1\}\.', ''
                            if (-not $adapterName) { continue }
                            $prefix = if ($flow -eq 'Render') { '{0.0.0.00000000}.' } else { '{0.0.1.00000000}.' }
                            $id = ($prefix + $guid.ToLowerInvariant())
                            $instanceId = "SWD\MMDEVAPI\$id"
                            $active = [FastAudio.Native]::IsDeviceStarted($instanceId)
                            $items += [pscustomobject]@{
                                Flow = $flow
                                Id = $id
                                InstanceId = $instanceId
                                Guid = $guid.ToLowerInvariant()
                                State = $state
                                Active = $active
                                AdapterName = $adapterName
                                Description = $description
                                ParentInstanceId = $parent
                            }
                        }
                        finally {
                            $propertiesKey.Dispose()
                        }
                    }
                    finally {
                        $endpointKey.Dispose()
                    }
                }
            }
            finally {
                $flowKey.Dispose()
            }
        }
    }
    finally {
        $audioKey.Dispose()
    }
    return $items
}

function Save-EndpointCache {
    param(
        [string]$Name,
        [object]$Endpoint
    )
    if ($Endpoint) {
        Set-Content -LiteralPath (Join-Path $PSScriptRoot "cache-$Name.txt") -Value $Endpoint.Id -Encoding ASCII
    }
}

function Read-EndpointCache {
    param([string]$Name)
    $path = Join-Path $PSScriptRoot "cache-$Name.txt"
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw).Trim()
    }
    return $null
}

function Invoke-PnPUtil {
    param(
        [string]$Action,
        [string]$InstanceId
    )
    $output = & pnputil.exe "/$Action-device" $InstanceId 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pnputil $Action failed for ${InstanceId}: $($output -join ' ')"
    }
}

function Wait-EndpointActive {
    param(
        [string]$EndpointId,
        [int]$TimeoutMilliseconds = 3000
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $endpoint = Get-AudioEndpoints | Where-Object { $_.Id -eq $EndpointId -and $_.Active } | Select-Object -First 1
        if ($endpoint) { return $endpoint }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-EndpointInactive {
    param(
        [string]$EndpointId,
        [int]$TimeoutMilliseconds = 3000
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $endpoint = Get-AudioEndpoints | Where-Object { $_.Id -eq $EndpointId -and $_.Active } | Select-Object -First 1
        if (-not $endpoint) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Find-PrimaryRender {
    param(
        [object[]]$Endpoints,
        [string]$AdapterPattern
    )
    $candidates = @($Endpoints | Where-Object {
        $_.Flow -eq 'Render' -and $_.Active -and $_.AdapterName -match $AdapterPattern
    })
    if ($candidates.Count -eq 0) { return $null }
    $preferred = @($candidates | Where-Object {
        $_.Description -notmatch '2nd output|^2-'
    })
    if ($preferred.Count -gt 0) { return $preferred[0] }
    return $candidates[0]
}

function Find-ActiveCapture {
    param(
        [object[]]$Endpoints,
        [string]$AdapterPattern
    )
    $candidates = @($Endpoints | Where-Object {
        $_.Flow -eq 'Capture' -and $_.Active -and $_.AdapterName -match $AdapterPattern
    })
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Ensure-MediaDevice {
    param(
        [object[]]$Endpoints,
        [string]$AdapterPattern
    )
    if (@($Endpoints | Where-Object { $_.Active -and $_.AdapterName -match $AdapterPattern }).Count -gt 0) {
        return
    }
    $sample = $Endpoints | Where-Object { $_.AdapterName -match $AdapterPattern -and $_.ParentInstanceId } | Select-Object -First 1
    if (-not $sample) {
        throw "Audio device is unavailable: $AdapterPattern"
    }
    Invoke-PnPUtil 'enable' $sample.ParentInstanceId
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 100
        $current = Get-AudioEndpoints
        if (@($current | Where-Object { $_.Active -and $_.AdapterName -match $AdapterPattern }).Count -gt 0) {
            return
        }
    }
    throw "Audio device did not become active: $AdapterPattern"
}

function Enable-CaptureEndpoint {
    param(
        [object[]]$Endpoints,
        [string]$AdapterPattern,
        [string]$CacheName
    )
    $active = Find-ActiveCapture $Endpoints $AdapterPattern
    if ($active) {
        Save-EndpointCache $CacheName $active
        return $active
    }

    $cachedId = Read-EndpointCache $CacheName
    if (-not $cachedId) {
        throw "No capture endpoint is available for $AdapterPattern."
    }
    Invoke-PnPUtil 'enable' "SWD\MMDEVAPI\$cachedId"
    $enabled = Wait-EndpointActive $cachedId
    if (-not $enabled) {
        throw "Capture endpoint did not become active: $AdapterPattern."
    }
    Save-EndpointCache $CacheName $enabled
    return $enabled
}

function Disable-CaptureEndpoint {
    param(
        [object[]]$Endpoints,
        [string]$AdapterPattern,
        [string]$CacheName
    )
    $active = Find-ActiveCapture $Endpoints $AdapterPattern
    if (-not $active) { return }
    Save-EndpointCache $CacheName $active
    Invoke-PnPUtil 'disable' $active.InstanceId
    if (-not (Wait-EndpointInactive $active.Id)) {
        throw "Capture endpoint did not become inactive: $($active.AdapterName)."
    }
}

function Disable-EndpointSysFx {
    param([object]$Endpoint)
    $hr = [FastAudio.Native]::SetDisableSysFx($Endpoint.Id, 1)
    if ($hr -ne 0) {
        throw "Disable_SysFx failed for $($Endpoint.AdapterName) with HRESULT 0x$('{0:X8}' -f $hr)"
    }
}

function Set-DefaultForAllRoles {
    param([string]$EndpointId)
    for ($role = 0; $role -lt 3; $role++) {
        $hr = [FastAudio.Native]::SetDefault($EndpointId, $role)
        if ($hr -ne 0) {
            throw "SetDefault failed with HRESULT 0x$('{0:X8}' -f $hr)"
        }
    }
}

function Get-ModeSummary {
    $endpoints = Get-AudioEndpoints
    foreach ($line in [FastAudio.Native]::GetDefaults()) {
        $parts = $line.Split(':')
        if ($parts.Count -lt 4) { continue }
        $name = 'Unknown'
        if ($parts[3]) {
            $target = $endpoints | Where-Object { $_.Id -eq $parts[3].ToLowerInvariant() } | Select-Object -First 1
            if ($target) {
                $name = "$($target.AdapterName) / $($target.Description)"
                if (-not $target.Active) { $name = "$name [DISABLED]" }
            }
        }
        '{0} {1}: {2}' -f $parts[0], $parts[1], $name
    }
}

try {
    $started = Get-Date
    Write-ModeLog "Fast mode requested: $Mode"
    $endpoints = Get-AudioEndpoints

    if ($Mode -eq 'Headset') {
        Ensure-MediaDevice $endpoints 'MCHOSE G9'
        Ensure-MediaDevice $endpoints 'Realtek High Definition Audio'
        $endpoints = Get-AudioEndpoints
        $headsetRender = Find-PrimaryRender $endpoints 'MCHOSE G9'
        if (-not $headsetRender) {
            throw 'MCHOSE G9 render endpoint is unavailable.'
        }
        $headsetCapture = Enable-CaptureEndpoint $endpoints 'MCHOSE G9' 'g9-capture'
        $endpoints = Get-AudioEndpoints
        $headsetRender = Find-PrimaryRender $endpoints 'MCHOSE G9'
        Disable-EndpointSysFx $headsetRender
        if ($headsetCapture.Active) { Disable-EndpointSysFx $headsetCapture }
        Set-DefaultForAllRoles $headsetRender.Id
        Set-DefaultForAllRoles $headsetCapture.Id
        Disable-CaptureEndpoint $endpoints 'Realtek High Definition Audio' 'realtek-capture'
        Save-EndpointCache 'g9-render' $headsetRender
    }
    elseif ($Mode -in @('Speaker', 'Desktop')) {
        Ensure-MediaDevice $endpoints 'Realtek High Definition Audio'
        Ensure-MediaDevice $endpoints 'MCHOSE G9'
        $endpoints = Get-AudioEndpoints
        $desktopRender = Find-PrimaryRender $endpoints 'Realtek High Definition Audio'
        if (-not $desktopRender) {
            throw 'Realtek render endpoint is unavailable.'
        }
        foreach ($g9Endpoint in @($endpoints | Where-Object { $_.Active -and $_.AdapterName -match 'MCHOSE G9' })) {
            Disable-EndpointSysFx $g9Endpoint
        }
        Set-DefaultForAllRoles $desktopRender.Id
        Save-EndpointCache 'realtek-render' $desktopRender

        $desktopCapture = Find-ActiveCapture $endpoints 'Realtek High Definition Audio'
        if ($desktopCapture) {
            Set-DefaultForAllRoles $desktopCapture.Id
            Save-EndpointCache 'realtek-capture' $desktopCapture
        }
        elseif ($Mode -eq 'Desktop') {
            throw 'Realtek microphone endpoint is unavailable. Plug the microphone into the motherboard 3.5 mm jack.'
        }
        Disable-CaptureEndpoint $endpoints 'MCHOSE G9' 'g9-capture'
    }

    $summary = Get-ModeSummary
    foreach ($line in $summary) {
        Write-ModeLog "FAST VERIFY $line"
    }
    if ($Mode -ne 'Status') {
        Set-Content -LiteralPath $StatePath -Value $Mode -Encoding ASCII
    }
    $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
    Write-ModeLog "Fast mode completed: $Mode in $elapsed seconds"
    $summary
    exit 0
}
catch {
    Write-ModeLog "FAST ERROR $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
