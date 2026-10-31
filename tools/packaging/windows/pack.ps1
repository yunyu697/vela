# 生成 Windows 发布包：ZIP / NSIS EXE / WiX MSI。
#
# 用法 (pwsh):
#   ./pack.ps1 -Version 0.1.0 -ReleaseDir build/windows/x64/runner/Release -OutDir artifacts
#
# 依赖（由 CI 安装）:
#   - makensis  (NSIS)
#   - wix       (dotnet tool, WiX v4)
#
# 设计: ZIP 与 EXE 为必需产物；MSI 若构建失败仅告警，不阻断整体流程。
param(
  [string]$Version  = "0.1.0",
  [string]$ReleaseDir,
  [string]$OutDir   = "artifacts",
  [string]$AppName  = "Vela"
)

$ErrorActionPreference = "Stop"
if (-not $ReleaseDir -or -not (Test-Path $ReleaseDir)) {
  Write-Error "缺少有效的 ReleaseDir: $ReleaseDir"
  exit 1
}
$ReleaseDir = Resolve-Path $ReleaseDir
$OutDir = Resolve-Path $OutDir
$Pkg = "$AppName-$Version-windows-x64"

# ---------- 1) ZIP ----------
Write-Host "==> 构建 ZIP: $Pkg.zip"
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath "$OutDir\$Pkg.zip" -Force
Write-Host "    done: $((Get-Item "$OutDir\$Pkg.zip").Length) bytes"

# ---------- 2) NSIS EXE ----------
Write-Host "==> 构建 NSIS EXE: $Pkg-setup.exe"
$nsi = @"
!include "MUI2.nsh"
Name "$AppName"
OutFile "$OutDir\$Pkg-setup.exe"
InstallDir "`$PROGRAMFILES64\$AppName"
RequestExecutionLevel admin
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetOutPath "`$INSTDIR"
  File /r "$ReleaseDir\*"
  CreateDirectory "`$SMPROGRAMS\$AppName"
  CreateShortCut "`$SMPROGRAMS\$AppName\$AppName.lnk" "`$INSTDIR\$AppName.exe"
  CreateShortCut "`$DESKTOP\$AppName.lnk" "`$INSTDIR\$AppName.exe"
  WriteUninstaller "`$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName" "DisplayName" "$AppName"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName" "UninstallString" "`"`$INSTDIR\uninstall.exe`""
SectionEnd

Section "Uninstall"
  RMDir /r "`$INSTDIR"
  Delete "`$SMPROGRAMS\$AppName\$AppName.lnk"
  Delete "`$DESKTOP\$AppName.lnk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
SectionEnd
"@
$nsiPath = "$OutDir\installer.nsi"
Set-Content -Path $nsiPath -Value $nsi -Encoding ASCII
& makensis "$nsiPath"
if (Test-Path "$OutDir\$Pkg-setup.exe") {
  Write-Host "    done: $((Get-Item "$OutDir\$Pkg-setup.exe").Length) bytes"
} else {
  Write-Error "NSIS 未生成 exe"
  exit 1
}

# ---------- 3) WiX MSI (best-effort) ----------
Write-Host "==> 构建 WiX MSI: $Pkg.msi (best-effort)"
try {
  # dotnet 全局工具通过 `dotnet wix` 调用
  $wixOk = $false
  try { & dotnet wix --version | Out-Null; $wixOk = $true } catch { }
  if (-not $wixOk) {
    Write-Warning "未找到 wix CLI，跳过 MSI"
  } else {
    $harvest = "$OutDir\harvest.wxs"
    & dotnet wix heat dir "$ReleaseDir" -o "$harvest" -nologo -gg -sreg -srd -sfrag -scom `
      -cg VelaComponents -var var.SourceDir -dr INSTALLFOLDER -platform x64
    $product = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Product Id="*" Name="$AppName" Version="$Version" Manufacturer="$AppName"
           Language="1033" UpgradeCode="2F4A1B9C-7E3D-4C5A-9B12-3E8F0A1C2D33">
    <Package InstallerVersion="500" Compressed="yes" Platform="x64" />
    <MajorUpgrade DowngradeErrorMessage="已安装更新版本。" />
    <MediaTemplate EmbedCab="yes" />
    <Feature Id="Main" Title="$AppName" Level="1">
      <ComponentGroupRef Id="VelaComponents" />
    </Feature>
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="$AppName" />
    </StandardDirectory>
  </Product>
</Wix>
"@
    $productPath = "$OutDir\product.wxs"
    Set-Content -Path $productPath -Value $product -Encoding UTF8
    & dotnet wix build "$productPath" "$harvest" -dSourceDir="$ReleaseDir" `
      -o "$OutDir\$Pkg.msi" -ext WixToolset.UI.wixext
    if (Test-Path "$OutDir\$Pkg.msi") {
      Write-Host "    done: $((Get-Item "$OutDir\$Pkg.msi").Length) bytes"
    } else {
      Write-Warning "wix build 未产出 msi"
    }
  }
} catch {
  Write-Warning "MSI 构建失败（不影响 ZIP/EXE）: $_"
}
