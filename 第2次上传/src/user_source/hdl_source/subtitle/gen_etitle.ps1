# gen_etitle.ps1 - 应急画面点阵 → ../emergency_overlay.v 里 BEGIN ETITLE / END ETITLE 之间（erom 的初值，一块 BRAM9K）
#   地址 0~191：中文标题 {字号 4 位, 行 4 位}，12 个字：0~3 紧急撤离（一级）、4~7 就地避险（二级）、8~11 区域警戒（三级），
#              黑体 16×16，每行一个 16 位字，bit15 = 最左边
#   地址 256~：英文 {1, 二级, 行 3 位, 0, 第几个 16 列 3 位}，5×7 字模，每个字母 6 列（5 列 + 1 列空），bit15 = 最左边
#   改标题：改下面 $Text（必须正好 12 个字）；改英文：改 $En1 / $En2（大写字母和空格，最多 21 个字），
#   双击 gen_etitle.bat，再在 TD 里重新编译
$Text = '紧急撤离就地避险区域警戒'
$En1  = 'EMERGENCY EVACUATION'
$En2  = 'TAKE SHELTER'
$File = Join-Path (Split-Path $PSScriptRoot -Parent) 'emergency_overlay.v'
Add-Type -AssemblyName System.Drawing
if ($Text.Length -ne 12) { Write-Host 'ERROR: $Text must be exactly 12 characters'; exit 1 }
# 5×7 字模（和参考例程 promax_text_overlay 一样），每行 5 位，高位在左
$Glyph5 = @{
  'A' = @(0x0E,0x11,0x11,0x1F,0x11,0x11,0x11); 'B' = @(0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E)
  'C' = @(0x0F,0x10,0x10,0x10,0x10,0x10,0x0F); 'D' = @(0x1E,0x11,0x11,0x11,0x11,0x11,0x1E)
  'E' = @(0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F); 'F' = @(0x1F,0x10,0x10,0x1E,0x10,0x10,0x10)
  'G' = @(0x0F,0x10,0x10,0x13,0x11,0x11,0x0F); 'H' = @(0x11,0x11,0x11,0x1F,0x11,0x11,0x11)
  'I' = @(0x0E,0x04,0x04,0x04,0x04,0x04,0x0E); 'K' = @(0x11,0x12,0x14,0x18,0x14,0x12,0x11)
  'L' = @(0x10,0x10,0x10,0x10,0x10,0x10,0x1F); 'M' = @(0x11,0x1B,0x15,0x15,0x11,0x11,0x11)
  'N' = @(0x11,0x19,0x15,0x13,0x11,0x11,0x11); 'O' = @(0x0E,0x11,0x11,0x11,0x11,0x11,0x0E)
  'P' = @(0x1E,0x11,0x11,0x1E,0x10,0x10,0x10); 'R' = @(0x1E,0x11,0x11,0x1E,0x14,0x12,0x11)
  'S' = @(0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E); 'T' = @(0x1F,0x04,0x04,0x04,0x04,0x04,0x04)
  'U' = @(0x11,0x11,0x11,0x11,0x11,0x11,0x0E); 'V' = @(0x11,0x11,0x11,0x11,0x11,0x0A,0x04)
  'W' = @(0x11,0x11,0x11,0x15,0x15,0x1B,0x11); 'X' = @(0x11,0x11,0x0A,0x04,0x0A,0x11,0x11)
  'Y' = @(0x11,0x11,0x0A,0x04,0x04,0x04,0x04); ' ' = @(0,0,0,0,0,0,0)
}
$mem = @{}
# 中文标题
$font = New-Object System.Drawing.Font('SimHei', 16, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
for ($c = 0; $c -lt 12; $c++) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $g.DrawString($Text[$c], $font, [System.Drawing.Brushes]::Black, -2, 0)
    $g.Dispose()
    for ($y = 0; $y -lt 16; $y++) {
        $w = 0
        for ($x = 0; $x -lt 16; $x++) { if ($bmp.GetPixel($x, $y).R -lt 128) { $w = $w -bor (1 -shl (15 - $x)) } }
        if ($w -ne 0) { $mem[$c * 16 + $y] = $w }
    }
    $bmp.Dispose()
}
# 英文：一行像素 = 每个字母 6 列，拼成一长串，再每 16 列切一个字
foreach ($k in 0, 1) {
    $s = if ($k -eq 0) { $En1 } else { $En2 }
    if ($s.Length -gt 21) { Write-Host "ERROR: English line $($k + 1) longer than 21 letters"; exit 1 }
    for ($r = 0; $r -lt 7; $r++) {
        $bits = New-Object System.Collections.Generic.List[int]
        foreach ($ch in $s.ToCharArray()) {
            $key = [string]$ch
            if (-not $Glyph5.ContainsKey($key)) { Write-Host "ERROR: letter '$key' has no 5x7 glyph"; exit 1 }
            $row = $Glyph5[$key][$r]
            for ($b = 4; $b -ge 0; $b--) { $bits.Add(($row -shr $b) -band 1) }
            $bits.Add(0)
        }
        for ($wd = 0; $wd -lt 8; $wd++) {
            $w = 0
            for ($i = 0; $i -lt 16; $i++) { $p = $wd * 16 + $i; if ($p -lt $bits.Count -and $bits[$p]) { $w = $w -bor (1 -shl (15 - $i)) } }
            if ($w -ne 0) { $mem[256 + $k * 128 + $r * 16 + $wd] = $w }
        }
    }
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// BEGIN ETITLE')
[void]$sb.AppendLine("// generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') from: $Text / $En1 / $En2")
[void]$sb.AppendLine('integer ei;')
[void]$sb.AppendLine('initial begin')
[void]$sb.AppendLine("    for (ei = 0; ei < 512; ei = ei + 1) erom[ei] = 16'h0000;")
foreach ($a in ($mem.Keys | Sort-Object)) { [void]$sb.AppendLine(("    erom[{0}] = 16'h{1:X4};" -f $a, $mem[$a])) }
[void]$sb.AppendLine('end')
[void]$sb.Append('// END ETITLE')
$src = [IO.File]::ReadAllText($File)
$nl = if ($src.Contains("`r`n")) { "`r`n" } else { "`n" }
$block = $sb.ToString().Replace("`r`n", "`n").Replace("`n", $nl)
$i0 = $src.IndexOf('// BEGIN ETITLE'); $i1 = $src.IndexOf('// END ETITLE')
if ($i0 -lt 0 -or $i1 -lt $i0) { Write-Host "ERROR: markers not found in $File"; exit 1 }
$out = $src.Substring(0, $i0) + $block + $src.Substring($i1 + '// END ETITLE'.Length)
[IO.File]::WriteAllText($File, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: wrote erom ($($mem.Count) non-zero words) into $File"
