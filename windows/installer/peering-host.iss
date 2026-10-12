; Unsigned per-user installer for Peering Host. Build with installer\build.ps1, which passes MyAppVersion and SourceExe.

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\target\release\peering-host.exe"
#endif
#define MyAppName "Peering Host"
#define MyAppExe "peering-host.exe"

[Setup]
AppId={{6C1E0B7A-4D2F-4E8B-9A53-2F7D1B8E0C41}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Peering
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=PeeringHostSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExe}

[Tasks]
Name: "autostart"; Description: "Start {#MyAppName} when I sign in"; Flags: unchecked

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "{#MyAppExe}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExe}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "Start {#MyAppName}"; Flags: nowait postinstall skipifsilent
