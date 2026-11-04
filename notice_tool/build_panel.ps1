# build_panel.ps1 - control_panel.cs → 智屏安播控制台.exe（用 Windows 自带的 .NET Framework 编译器，不用安装 Visual Studio）
$here = $PSScriptRoot
$src  = [IO.File]::ReadAllText((Join-Path $here 'control_panel.cs'), [Text.Encoding]::UTF8)
$exe  = Join-Path $here '智屏安播控制台.exe'
if (Test-Path $exe) {
    try { Remove-Item $exe -Force -ErrorAction Stop } catch { Write-Host 'ERROR: 智屏安播控制台.exe 正在运行，请先关掉它再编译'; exit 1 }
}
try {
    Add-Type -TypeDefinition $src -Language CSharp -OutputType WindowsApplication -OutputAssembly $exe `
             -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Management -ErrorAction Stop
} catch { $_.Exception.Errors | ForEach-Object { Write-Host "line $($_.Line): $($_.ErrorText)" } }
if (Test-Path $exe) { Write-Host "OK: $exe" } else { Write-Host 'ERROR: build failed'; exit 1 }
