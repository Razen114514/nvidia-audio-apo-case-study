param(
    [ValidateSet('Disable', 'Enable', 'Status')]
    [string]$State = 'Status'
)

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $PSScriptRoot 'g9-sysfx-test.log'

function Write-TestLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($State -ne 'Status' -and -not (Test-IsAdmin)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-State', $State
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

if (-not ('AudioSysFx.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AudioSysFx
{
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
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    internal class CPolicyConfigClient { }

    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPolicyConfig
    {
        [PreserveSig]
        int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr format);
        [PreserveSig]
        int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool isDefault, out IntPtr format);
        [PreserveSig]
        int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig]
        int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig]
        int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool isDefault, IntPtr defaultPeriod, IntPtr minimumPeriod);
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
        private static readonly Guid PkeyGuid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
        private const uint PkeyPid = 5;
        private const ushort VT_UI4 = 19;

        public static int GetDisableSysFx(string deviceId, out uint value)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(typeof(CPolicyConfigClient));
            var key = new PROPERTYKEY();
            key.fmtid = PkeyGuid;
            key.pid = PkeyPid;
            PROPVARIANT prop;
            int hr = policy.GetPropertyValue(deviceId, true, ref key, out prop);
            value = hr == 0 ? prop.ulVal : 0;
            return hr;
        }

        public static int SetDisableSysFx(string deviceId, uint value)
        {
            var policy = (IPolicyConfig)Activator.CreateInstance(typeof(CPolicyConfigClient));
            var key = new PROPERTYKEY();
            key.fmtid = PkeyGuid;
            key.pid = PkeyPid;
            var prop = new PROPVARIANT();
            prop.vt = VT_UI4;
            prop.ulVal = value;
            return policy.SetPropertyValue(deviceId, true, ref key, ref prop);
        }
    }
}
'@
}

function Get-G9Endpoints {
    @(
        Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -match 'MCHOSE G9' -and
                $_.Present -and
                $_.Status -eq 'OK'
            }
    )
}

function Get-EndpointId {
    param([object]$Endpoint)
    return ($Endpoint.InstanceId -replace '^SWD\\MMDEVAPI\\', '').ToLowerInvariant()
}

$endpoints = Get-G9Endpoints
if ($endpoints.Count -eq 0) {
    throw 'No active MCHOSE G9 audio endpoints were found.'
}

$results = @()
foreach ($endpoint in $endpoints) {
    $endpointId = Get-EndpointId $endpoint
    $before = 0
    $getHr = [AudioSysFx.Native]::GetDisableSysFx($endpointId, [ref]$before)

    $setHr = $null
    if ($State -ne 'Status') {
        $targetValue = if ($State -eq 'Disable') { [uint32]1 } else { [uint32]0 }
        $setHr = [AudioSysFx.Native]::SetDisableSysFx($endpointId, $targetValue)
        Write-TestLog "State=$State Endpoint=$endpointId SetHr=0x$('{0:X8}' -f $setHr)"
    }

    $after = 0
    $getAfterHr = [AudioSysFx.Native]::GetDisableSysFx($endpointId, [ref]$after)
    $results += [pscustomobject]@{
        Name = $endpoint.FriendlyName
        EndpointId = $endpointId
        Before = $before
        GetHr = ('0x{0:X8}' -f $getHr)
        SetHr = if ($null -eq $setHr) { $null } else { '0x{0:X8}' -f $setHr }
        After = $after
        GetAfterHr = ('0x{0:X8}' -f $getAfterHr)
    }
}

$results
