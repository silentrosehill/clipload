; Inno Setup script for Clipload. Built by .github/workflows/windows.yml.
; Installs per user (no admin), so "Update yt-dlp" can replace yt-dlp.exe in place.

#ifndef AppVersion
  #define AppVersion "2.0"
#endif

[Setup]
AppId={{6B0E2F55-3C1A-4C55-9C57-6C1D0A2F7E11}
AppName=Clipload
AppVersion={#AppVersion}
AppPublisher=Clipload
DefaultDirName={localappdata}\Programs\Clipload
DefaultGroupName=Clipload
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Clipload-Setup
SetupIconFile=clipload.ico
UninstallDisplayIcon={app}\Clipload.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "startup"; Description: "Start Clipload when I sign in"

[Files]
Source: "dist\Clipload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Clipload"; Filename: "{app}\Clipload.exe"
Name: "{autodesktop}\Clipload"; Filename: "{app}\Clipload.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Clipload"; ValueData: """{app}\Clipload.exe"" --background"; Flags: uninsdeletevalue; Tasks: startup
Root: HKCU; Subkey: "Software\Classes\clipload"; ValueType: string; ValueData: "URL:Clipload"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\clipload"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\clipload\shell\open\command"; ValueType: string; ValueData: """{app}\Clipload.exe"" ""%1"""

[Run]
Filename: "{app}\Clipload.exe"; Description: "Open Clipload"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM Clipload.exe /F"; Flags: runhidden; RunOnceId: "StopClipload"
