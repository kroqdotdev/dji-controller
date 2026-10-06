<#
.SYNOPSIS
  Brings a running app's main window to the front of the desktop, for screenshots taken over SSH.
  It has to run inside the desktop session, so launch it with Start-Gui.ps1 (with the full path to
  pwsh: Task Scheduler does not search PATH):
.EXAMPLE
  Start-Gui.ps1 (Get-Command pwsh).Source -ArgumentList '-NoProfile -WindowStyle Hidden -File C:\Users\sauer\code\lavboard\windows\tools\Focus-Window.ps1 Lavboard'
#>
param([Parameter(Mandatory)][string]$ProcessName)
Add-Type -Namespace Lavboard -Name Window -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
$process = Get-Process $ProcessName -ErrorAction Stop | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $process) { exit 1 }
$window = $process.MainWindowHandle
[Lavboard.Window]::ShowWindow($window, 9) | Out-Null # SW_RESTORE
# Windows won't hand the foreground to a background process, but a topmost window is drawn above
# everything; making it topmost and then not leaves it in front.
$flags = 0x0001 -bor 0x0002 -bor 0x0040 # SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
[Lavboard.Window]::SetWindowPos($window, [IntPtr]-1, 0, 0, 0, 0, $flags) | Out-Null # HWND_TOPMOST
[Lavboard.Window]::SetWindowPos($window, [IntPtr]-2, 0, 0, 0, 0, $flags) | Out-Null # HWND_NOTOPMOST
[Lavboard.Window]::SetForegroundWindow($window) | Out-Null
