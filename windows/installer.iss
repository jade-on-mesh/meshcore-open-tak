; MeshCore Open TAK installer (Inno Setup 6), built by .github/workflows/build.yml:
;   ISCC /DAppVersion=9.5.0-tak /DNumericVersion=9.5.0.1234
;        /DSourceDir=...\build\windows\x64\runner\Release /DOutputDir=...\dist installer.iss
; Installs per user (no administrator prompt), so the app's own updater can run
; it silently: meshcore-open-tak-windows-setup.exe /SILENT closes the running
; app, updates it and starts it again.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef NumericVersion
  #define NumericVersion "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

#define AppName "MeshCore Open TAK"
#define AppExe "meshcore_open.exe"

[Setup]
AppId={{6E1B2C4A-7F3D-4B8E-9A21-5C0D7E3F9B10}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#NumericVersion}
AppPublisher=jade-on-mesh
AppPublisherURL=https://github.com/jade-on-mesh/meshcore-open-tak
AppUpdatesURL=https://github.com/jade-on-mesh/meshcore-open-tak/releases/tag/latest-build
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=meshcore-open-tak-windows-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Flutter's assets and plugin DLLs change between builds; start clean.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Also runs after a silent update, so the app comes back by itself.
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall
