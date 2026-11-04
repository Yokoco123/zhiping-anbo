# gen_pbar.ps1 - 参数条字形 → ../param_bar_overlay.v 里 BEGIN PBAR / END PBAR 之间（pbrom 的初值）
#   字号 0~9 = 数字（8 像素宽，放在左边 8 位），10~18 = 亮 度 对 比 音 量 轮 播 秒（16 像素宽）
#   黑体 16 像素，每个字左右居中；地址 {字号 5 位, 行 4 位}，bit15 = 最左边
#   改字：改下面 $Han（必须正好 9 个字，顺序和 param_bar_overlay.v 里的 G_ 常数一致），双击 gen_pbar.bat，再在 TD 里重新编译
$Han  = '亮度对比音量轮播秒'
$File = Join-Path (Split-Path $PSScriptRoot -Parent) 'param_bar_overlay.v'
Add-Type -AssemblyName System.Drawing
if ($Han.Length -ne 9) { Write-Host 'ERROR: $Han must be exactly 9 characters'; exit 1 }
$font = New-Object System.Drawing.Font('SimHei', 16, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$chars = @('0','1','2','3','4','5','6','7','8','9') + ($Han.ToCharArray() | ForEach-Object { [string]$_ })
$mem = @{}
for ($c = 0; $c -lt $chars.Count; $c++) {
    $cw = if ($c -lt 10) { 8 } else { 16 }
    $bmp = New-Object System.Drawing.Bitmap 24, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $g.DrawString($chars[$c], $font, [System.Drawing.Brushes]::Black, 2, 0)
    $g.Dispose()
    # 墨迹的左右范围 → 居中到 cw 宽
    $x0 = 99; $x1 = -1
    for ($y = 0; $y -lt 16; $y++) { for ($x = 0; $x -lt 24; $x++) { if ($bmp.GetPixel($x, $y).R -lt 128) { if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x } } } }
    if ($x1 -lt 0) { $bmp.Dispose(); continue }
    $ink = $x1 - $x0 + 1
    if ($ink -gt $cw) { Write-Host "WARNING: '$($chars[$c])' is $ink pixels wide, cut to $cw" }
    $off = [Math]::Floor(($cw - $ink) / 2); if ($off -lt 0) { $off = 0 }
    for ($y = 0; $y -lt 16; $y++) {
        $w = 0
        for ($x = $x0; $x -le $x1; $x++) {
            $col = $x - $x0 + $off
            if ($col -lt $cw -and $bmp.GetPixel($x, $y).R -lt 128) { $w = $w -bor (1 -shl (15 - $col)) }
        }
        if ($w -ne 0) { $mem[$c * 16 + $y] = $w }
    }
    $bmp.Dispose()
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// BEGIN PBAR')
[void]$sb.AppendLine("// generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') from: 0123456789 $Han")
[void]$sb.AppendLine('integer pi;')
[void]$sb.AppendLine('initial begin')
[void]$sb.AppendLine("    for (pi = 0; pi < 512; pi = pi + 1) pbrom[pi] = 16'h0000;")
foreach ($a in ($mem.Keys | Sort-Object)) { [void]$sb.AppendLine(("    pbrom[{0}] = 16'h{1:X4};" -f $a, $mem[$a])) }
[void]$sb.AppendLine('end')
[void]$sb.Append('// END PBAR')
$src = [IO.File]::ReadAllText($File)
$nl = if ($src.Contains("`r`n")) { "`r`n" } else { "`n" }
$block = $sb.ToString().Replace("`r`n", "`n").Replace("`n", $nl)
$i0 = $src.IndexOf('// BEGIN PBAR'); $i1 = $src.IndexOf('// END PBAR')
if ($i0 -lt 0 -or $i1 -lt $i0) { Write-Host "ERROR: markers not found in $File"; exit 1 }
$out = $src.Substring(0, $i0) + $block + $src.Substring($i1 + '// END PBAR'.Length)
[IO.File]::WriteAllText($File, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: wrote pbrom ($($mem.Count) non-zero rows) into $File"
