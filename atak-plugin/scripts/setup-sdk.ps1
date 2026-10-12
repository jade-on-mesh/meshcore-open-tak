<#
One-time setup for building the MeshCore ATAK plugin on Windows
(PowerShell version of setup-sdk.sh).

  powershell -ExecutionPolicy Bypass -File scripts\setup-sdk.ps1 C:\path\to\ATAK-CIV-5.8.0.5-SDK.zip
  powershell -ExecutionPolicy Bypass -File scripts\setup-sdk.ps1 C:\path\to\ATAK-CIV-5.8.0.5-SDK

The ATAK-CIV SDK comes from tak.gov and can't live in this repo. This puts it
in atak-plugin\sdk\atak-civ (without its ~400 MB atak.apk), copies the Gradle
wrapper jar from the SDK's plugin template, and points local.properties at it.
A .7z download: extract the .zip inside it with 7-Zip first.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Sdk
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot
$sdkDir = Join-Path $here 'sdk'
$dest = Join-Path $sdkDir 'atak-civ'
$Sdk = (Resolve-Path -LiteralPath $Sdk).Path

$tmp = $null
try {
    if (Test-Path -LiteralPath $Sdk -PathType Container) {
        $root = $Sdk
    } elseif ($Sdk -match '\.zip$') {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("atak-sdk-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Write-Host "Unpacking $Sdk ..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Sdk)
        try {
            foreach ($e in $zip.Entries) {
                # Skip folders and the bundled ATAK app (not needed to build).
                if ($e.FullName.EndsWith('/') -or $e.Name -eq 'atak.apk') { continue }
                $out = [IO.Path]::GetFullPath((Join-Path $tmp $e.FullName))
                if (-not $out.StartsWith($tmp)) { continue }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            }
        } finally {
            $zip.Dispose()
        }
        $root = $tmp
    } elseif ($Sdk -match '\.7z(\.\d+)?$|_7z\.\d+$') {
        throw "Extract the .7z with 7-Zip first, then pass the .zip (or folder) inside it."
    } else {
        throw "Expected a .zip or a folder: $Sdk"
    }

    # The folder that holds main.jar is the SDK root, whatever it is named.
    $jar = Get-ChildItem -LiteralPath $root -Filter 'main.jar' -Recurse -Depth 3 -File |
        Select-Object -First 1
    if (-not $jar) { throw "No main.jar found in ${Sdk}: is this the ATAK SDK?" }
    $sdkRoot = $jar.DirectoryName

    New-Item -ItemType Directory -Force -Path $sdkDir | Out-Null
    if ((Resolve-Path -LiteralPath $sdkRoot).Path -ne [IO.Path]::GetFullPath($dest)) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest | Out-Null
        Get-ChildItem -LiteralPath $sdkRoot | Where-Object { $_.Name -ne 'atak.apk' } |
            Copy-Item -Destination $dest -Recurse -Force
    }

    $version = ''
    if ((Split-Path -Leaf $sdkRoot) -match '\d+\.\d+\.\d+(\.\d+)?') { $version = $Matches[0] }
    if (-not $version) {
        $vf = Join-Path $dest 'VERSION.txt'
        $version = if (Test-Path $vf) { (Get-Content $vf -Raw).Trim() } else { 'unknown' }
    }
    Write-Host "ATAK SDK: $version"

    $template = $null
    foreach ($t in @('samples\plugintemplate', 'plugin-examples\plugintemplate')) {
        $w = Join-Path $dest "$t\gradle\wrapper\gradle-wrapper.jar"
        if (Test-Path -LiteralPath $w) { $template = $w; break }
    }
    if (-not $template) { throw "No plugintemplate with a Gradle wrapper in the SDK" }
    $wrapperDir = Join-Path $here 'gradle\wrapper'
    New-Item -ItemType Directory -Force -Path $wrapperDir | Out-Null
    Copy-Item -LiteralPath $template -Destination $wrapperDir -Force

    # local.properties is read by Java: use forward slashes (a backslash is an
    # escape character there) and no byte-order mark.
    function To-PropPath([string]$p) { return $p -replace '\\', '/' }
    $props = Join-Path $here 'local.properties'
    if (Test-Path -LiteralPath $props) {
        $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($props))
    } else {
        $android = $env:ANDROID_HOME
        if (-not $android) { $android = $env:ANDROID_SDK_ROOT }
        if (-not $android) {
            $default = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
            $android = if (Test-Path -LiteralPath $default) { $default } else { 'C:/path/to/Android/Sdk' }
        }
        $lines = [Collections.Generic.List[string]]@(
            '# Android SDK (Android Studio: File > Project Structure > SDK Location)',
            "sdk.dir=$(To-PropPath $android)",
            '# Debug builds are signed with the SDK''s development key by default. To use',
            '# your own, set takDebugKeyFile, takDebugKeyFilePassword, takDebugKeyAlias',
            '# and takDebugKeyPassword. Release builds need the takRelease* equivalents.'
        )
        Write-Host "Wrote local.properties; check sdk.dir."
    }
    function Set-Prop([string]$key, [string]$value) {
        $lines.RemoveAll([Predicate[string]] { param($l) $l.StartsWith("$key=") }) | Out-Null
        $lines.Add("$key=$value")
    }
    Set-Prop 'takdev.plugin' (To-PropPath (Join-Path $dest 'atak-gradle-takdev.jar'))
    # Where takdev finds ATAK's main.jar and the development keystore.
    Set-Prop 'sdk.path' (To-PropPath $dest)
    [IO.File]::WriteAllLines($props, $lines)

    $gradle = Get-Content -Raw (Join-Path $here 'app\build.gradle')
    if ($gradle -match 'ATAK_VERSION = "([0-9.]+)"') {
        $want = $Matches[1]
        if (-not $version.StartsWith($want)) {
            Write-Warning "app\build.gradle targets ATAK $want but this SDK is $version. Set ATAK_VERSION to match before building."
        }
    }
    Write-Host "Next: .\gradlew.bat assembleCivDebug"
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
