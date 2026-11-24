# Runs a program in the session of a signed-in user, from SYSTEM: the sign-in scripts of the groups
# (Invoke-Logon.ps1). The process gets the user's own token (for an administrator under UAC, the token without
# elevation), the user's environment with variables added (the secrets a script names: only in that process, never
# on disk) and pipes for its output, which SYSTEM reads, so the log and Loki get it. Windows only; needs SYSTEM
# (WTSQueryUserToken). C# 5, which Windows PowerShell 5.1 compiles, only when first needed (Initialize-WmUserSession):
# lib\Managed.ps1 loads this file for every run, and most runs have nothing to run as a user.

function Initialize-WmUserSession {
    if ('Wmanager.UserSession' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Wmanager
{
    public class UserSessionInfo
    {
        public int SessionId;
        public string User;
        public string Domain;
        public string LogonId;   // the logon session (LUID) of the user's token: one per sign-in
        public string Sid;       // the user's SID: the same at every sign-in
    }

    public class UserProcessResult
    {
        public bool TimedOut;
        public int ExitCode;
        public string Output;
        public string Errors;
    }

    public static class UserSession
    {
        [StructLayout(LayoutKind.Sequential)]
        struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

        [StructLayout(LayoutKind.Sequential)]
        struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_STATISTICS
        {
            public LUID TokenId; public LUID AuthenticationId; public long ExpirationTime; public int TokenType;
            public int ImpersonationLevel; public int DynamicCharged; public int DynamicAvailable; public int GroupCount;
            public int PrivilegeCount; public LUID ModifiedId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars;
            public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow;
            public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSEnumerateSessions(IntPtr hServer, int reserved, int version, out IntPtr sessionInfo, out int count);
        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr memory);
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW")]
        static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSQueryUserToken(int sessionId, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attributes, int impersonationLevel, int tokenType, out IntPtr newToken);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);
        [DllImport("userenv.dll", SetLastError = true)]
        static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
        [DllImport("userenv.dll", SetLastError = true)]
        static extern bool DestroyEnvironmentBlock(IntPtr environment);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SECURITY_ATTRIBUTES attributes, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr handle, int mask, int flags);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInfo);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out int exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        const int WTSActive = 0;
        const int WTSUserName = 5;
        const int WTSDomainName = 7;
        const int TokenUser = 1;
        const int TokenStatistics = 10;
        const uint MAXIMUM_ALLOWED = 0x02000000;
        const int SecurityImpersonation = 2;
        const int TokenPrimary = 1;
        const int HANDLE_FLAG_INHERIT = 1;
        const int STARTF_USESHOWWINDOW = 0x1;
        const int STARTF_USESTDHANDLES = 0x100;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x400;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint WAIT_TIMEOUT = 0x102;

        static string QueryString(int sessionId, int infoClass)
        {
            IntPtr buffer; int bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes)) return "";
            try { return Marshal.PtrToStringUni(buffer) ?? ""; } finally { WTSFreeMemory(buffer); }
        }

        static string SidOf(IntPtr token)
        {
            int size;
            GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out size);
            IntPtr info = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetTokenInformation(token, TokenUser, info, size, out size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation");
                // TOKEN_USER starts with the pointer to the SID
                return new System.Security.Principal.SecurityIdentifier(Marshal.ReadIntPtr(info)).Value;
            }
            finally { Marshal.FreeHGlobal(info); }
        }

        static string LogonIdOf(IntPtr token)
        {
            int size = Marshal.SizeOf(typeof(TOKEN_STATISTICS));
            IntPtr info = Marshal.AllocHGlobal(size);
            try
            {
                int returned;
                if (!GetTokenInformation(token, TokenStatistics, info, size, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation");
                TOKEN_STATISTICS s = (TOKEN_STATISTICS)Marshal.PtrToStructure(info, typeof(TOKEN_STATISTICS));
                return string.Format("{0:X8}{1:X8}", s.AuthenticationId.HighPart, s.AuthenticationId.LowPart);
            }
            finally { Marshal.FreeHGlobal(info); }
        }

        // The sessions with a signed-in user at their desktop (active: not disconnected, not the lock of another user)
        public static List<UserSessionInfo> GetActiveSessions()
        {
            List<UserSessionInfo> result = new List<UserSessionInfo>();
            IntPtr list; int count;
            if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out list, out count)) throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSEnumerateSessions");
            try
            {
                int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++)
                {
                    WTS_SESSION_INFO s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(list.ToInt64() + i * size), typeof(WTS_SESSION_INFO));
                    if (s.State != WTSActive) continue;
                    IntPtr token;
                    if (!WTSQueryUserToken(s.SessionId, out token)) continue;   // no user in it (session 0, the sign-in screen)
                    try
                    {
                        UserSessionInfo u = new UserSessionInfo();
                        u.SessionId = s.SessionId;
                        u.User = QueryString(s.SessionId, WTSUserName);
                        u.Domain = QueryString(s.SessionId, WTSDomainName);
                        u.LogonId = LogonIdOf(token);
                        u.Sid = SidOf(token);
                        if (u.User.Length > 0) result.Add(u);
                    }
                    finally { CloseHandle(token); }
                }
            }
            finally { WTSFreeMemory(list); }
            return result;
        }

        static Dictionary<string, string> ReadEnvironment(IntPtr block)
        {
            Dictionary<string, string> env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            IntPtr p = block;
            while (true)
            {
                string entry = Marshal.PtrToStringUni(p);
                if (string.IsNullOrEmpty(entry)) break;
                int eq = entry.IndexOf('=', 1);   // "=C:=C:\..." entries start with '='
                if (eq > 0) env[entry.Substring(0, eq)] = entry.Substring(eq + 1);
                p = new IntPtr(p.ToInt64() + (entry.Length + 1) * 2);
            }
            return env;
        }

        // Reads the pipe to its end in the background; the stream owns the handle from here on
        static Task<string> StartReading(IntPtr pipe, Encoding encoding)
        {
            FileStream stream = new FileStream(new SafeFileHandle(pipe, true), FileAccess.Read, 4096, false);
            return new StreamReader(stream, encoding).ReadToEndAsync();
        }

        // Runs commandLine as the user of the session, hidden, with the user's environment plus extra (which wins),
        // in directory (the user's TEMP when empty). Waits timeoutMs at most; then kills the process tree.
        public static UserProcessResult Run(int sessionId, string commandLine, Dictionary<string, string> extra, string directory,
                                            int timeoutMs, int codePage)
        {
            IntPtr userToken = IntPtr.Zero, token = IntPtr.Zero, envBlock = IntPtr.Zero, newBlock = IntPtr.Zero;
            IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero, errRead = IntPtr.Zero, errWrite = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try
            {
                if (!WTSQueryUserToken(sessionId, out userToken)) throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken");
                if (!DuplicateTokenEx(userToken, MAXIMUM_ALLOWED, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out token))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx");
                if (!CreateEnvironmentBlock(out envBlock, token, false)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock");
                Dictionary<string, string> env = ReadEnvironment(envBlock);
                if (extra != null) foreach (KeyValuePair<string, string> kv in extra) env[kv.Key] = kv.Value;
                if (string.IsNullOrEmpty(directory) && env.ContainsKey("TEMP")) directory = env["TEMP"];
                List<string> keys = new List<string>(env.Keys);
                keys.Sort(StringComparer.OrdinalIgnoreCase);
                StringBuilder block = new StringBuilder();
                foreach (string k in keys) { block.Append(k).Append('=').Append(env[k]).Append('\0'); }
                block.Append('\0');
                newBlock = Marshal.StringToHGlobalUni(block.ToString());

                SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
                sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                sa.bInheritHandle = true;
                if (!CreatePipe(out outRead, out outWrite, ref sa, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe");
                if (!CreatePipe(out errRead, out errWrite, ref sa, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe");
                SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
                SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);

                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                si.lpDesktop = "winsta0\\default";
                si.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
                si.wShowWindow = 0;
                si.hStdOutput = outWrite;
                si.hStdError = errWrite;
                if (!CreateProcessAsUser(token, null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true,
                        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, newBlock, string.IsNullOrEmpty(directory) ? null : directory, ref si, out pi))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser");
                // The child has its ends; with ours closed, reading ends when the child (and what inherited them) ends
                CloseHandle(outWrite); outWrite = IntPtr.Zero;
                CloseHandle(errWrite); errWrite = IntPtr.Zero;

                Encoding encoding = Encoding.GetEncoding(codePage);
                Task<string> outTask = StartReading(outRead, encoding); outRead = IntPtr.Zero;
                Task<string> errTask = StartReading(errRead, encoding); errRead = IntPtr.Zero;

                UserProcessResult result = new UserProcessResult();
                if (WaitForSingleObject(pi.hProcess, (uint)timeoutMs) == WAIT_TIMEOUT)
                {
                    result.TimedOut = true;
                    using (Process kill = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + pi.dwProcessId + " /T /F") { UseShellExecute = false, CreateNoWindow = true }))
                    { kill.WaitForExit(30000); }
                    WaitForSingleObject(pi.hProcess, 30000);
                }
                else
                {
                    int code;
                    GetExitCodeProcess(pi.hProcess, out code);
                    result.ExitCode = code;
                }
                result.Output = outTask.Wait(10000) ? outTask.Result : "";
                result.Errors = errTask.Wait(10000) ? errTask.Result : "";
                return result;
            }
            finally
            {
                foreach (IntPtr h in new IntPtr[] { pi.hProcess, pi.hThread, outRead, outWrite, errRead, errWrite, token, userToken })
                    if (h != IntPtr.Zero) CloseHandle(h);
                if (envBlock != IntPtr.Zero) DestroyEnvironmentBlock(envBlock);
                if (newBlock != IntPtr.Zero) Marshal.FreeHGlobal(newBlock);
            }
        }
    }
}
'@
}

# The sessions with a signed-in user: SessionId, User, Domain, LogonId (one per sign-in), Sid
function Get-WmUserSessions {
    Initialize-WmUserSession
    return @([Wmanager.UserSession]::GetActiveSessions())
}

# Runs a Windows PowerShell script as the user of session $SessionId, hidden, with $Environment added to the user's
# own. Returns ExitCode ($null after the timeout, when the process tree is killed), Output and Errors, like
# Invoke-WmScriptProcess.
function Invoke-WmUserScript {
    param(
        [Parameter(Mandatory = $true)][int]$SessionId,
        [Parameter(Mandatory = $true)][string]$File,
        [hashtable]$Environment = @{},
        [int]$TimeoutMinutes = 5
    )
    Initialize-WmUserSession
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = "`"$ps`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$File`""
    $extra = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($k in $Environment.Keys) { $extra[[string]$k] = [string]$Environment[$k] }
    # A console process without a window writes in the OEM code page (852 on Polish Windows)
    $oem = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    $r = [Wmanager.UserSession]::Run($SessionId, $command, $extra, '', $TimeoutMinutes * 60000, $oem)
    $code = $null
    if (-not $r.TimedOut) { $code = $r.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; Output = [string]$r.Output; Errors = [string]$r.Errors }
}
