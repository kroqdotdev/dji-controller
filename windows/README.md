# Lavboard for Windows

A native Windows build of Lavboard, in progress. The macOS app in `App/` is the reference for features and behaviour.

## Layout

- `src/LavboardEngine`: the native audio engine, a C++ DLL. It compiles the real-time mixer and resampler from `Shared/AudioCore` (the same C code the macOS app runs) and adds the Windows device layer on WASAPI.
- `src/Lavboard.Core`: P/Invoke bindings to the engine and managed wrappers, shared by the app and the tests.
- `src/Lavboard`: the app, WinUI 3 on the Windows App SDK, unpackaged and self-contained.
- `tests/Lavboard.Tests`: xunit tests that run the shared core through the DLL, checking that the MSVC build behaves like the macOS one.
- `tools/`: helpers for building and testing over SSH.

## Building

You need Visual Studio 2026 (or 2022 17.14 or later) with the **Desktop development with C++**, **.NET desktop development** and **Windows application development** workloads, the Windows SDK 10.0.26100 and the .NET 10 SDK.

From a Developer PowerShell:

```powershell
msbuild windows\Lavboard.slnx -restore -p:Configuration=Debug -p:Platform=x64
windows\artifacts\bin\Lavboard.Tests\Debug\net10.0-windows10.0.26100.0\Lavboard.Tests.exe
windows\artifacts\bin\Lavboard\Debug\net10.0-windows10.0.26100.0\win-x64\Lavboard.exe
```

`dotnet build` can't build the C++ engine, so use Visual Studio's `msbuild` (or open `Lavboard.slnx` in Visual Studio).

## Testing over SSH

SSH sessions have no desktop. On the dev VM, `Start-Gui.ps1` launches an app on the logged-in desktop and `Get-Screenshot.ps1` captures it. `tools/Focus-Window.ps1` brings a window to the front first, since Windows won't let a background launch take the foreground.
