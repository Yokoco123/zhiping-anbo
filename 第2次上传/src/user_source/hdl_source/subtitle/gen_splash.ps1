# gen_splash.ps1 - render splash.txt into ../splash_rom.v (boot screen / self-check text bitmaps)
# Same idea as gen_subtitle.ps1: every string becomes a run of 16-bit columns (bit 0 = top row),
# all strings packed back to back in one ROM; a table gives start / length / centred x for each.
#   TITLE : Microsoft YaHei Bold, 48 rows -> stored as 3 strings (rows 0-15, 16-31, 32-47)
#   DIGITS: "0123456789%/" in fixed 8-column cells
#   ICONS : 16-column cells drawn with lines: check, warning, cross, spinner x4, fire, no-blocking, exit, first aid
#   others: SimSun 16px
# String ids are FIXED (boot_splash.v depends on them) = order of $Ids below.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$ScreenW = 640
$InFile  = Join-Path $PSScriptRoot 'splash.txt'
$OutFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'splash_rom.v'
$Ids = @('TITLE0', 'TITLE1', 'TITLE2', 'SUB_CN', 'SUB_EN', 'DIGITS', 'ICONS', 'HEAD',
         'L_DISP', 'L_SET', 'L_CARD', 'L_MUS', 'L_PIC', 'L_EMG',
         'R_DISP_OK', 'R_SET_WAIT', 'R_SET_OK', 'R_SET_DEF', 'R_SET_ERR',
         'R_CARD_WAIT', 'R_CARD_NO', 'R_CARD_OK', 'R_CARD_ERR', 'R_MUS_OK', 'R_MUS_NO',
         'R_PIC_WAIT', 'R_PIC_OK', 'R_PIC_PART', 'R_PIC_ERR',
         'R_EMG_WAIT', 'R_EMG_OK', 'R_EMG_NO', 'R_EMG_ERR',
         'CHECK_CN', 'CHECK_EN', 'DONE_CN', 'DONE_EN', 'NOCARD_CN', 'NOCARD_EN',
         'FS_CN', 'FS_EN', 'FMT_CN', 'FMT_EN', 'READ_CN', 'READ_EN',
         'SAFE_T0', 'SAFE_T1', 'SAFE_T2', 'SAFE_SUB', 'S1_CN', 'S1_EN', 'S2_CN', 'S2_EN',
         'S3_CN', 'S3_EN', 'S4_CN', 'S4_EN', 'SAFE_NOTE', 'LOST_CN', 'LOST_EN', 'BACK_CN', 'BACK_EN',
         'REJ_CN', 'REJ_EN',
         'L_FONT', 'R_FONT_OK', 'R_FONT_NO', 'R_FONT_ERR')     # 64..67 (string id is 7 bits)

$small = New-Object System.Drawing.Font('SimSun', 16, [System.Drawing.GraphicsUnit]::Pixel)
$big   = New-Object System.Drawing.Font('Microsoft YaHei', 44, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor
         [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor
         [System.Windows.Forms.TextFormatFlags]::SingleLine

# bitmap -> list of 16-bit columns (rows y0..y0+15)
function Get-Cols($bmp, [int]$x0, [int]$w, [int]$y0) {
    $cols = New-Object System.Collections.Generic.List[int]
    for ($x = $x0; $x -lt $x0 + $w; $x++) {
        $v = 0
        for ($r = 0; $r -lt 16; $r++) {
            $y = $y0 + $r
            if ($x -ge 0 -and $x -lt $bmp.Width -and $y -ge 0 -and $y -lt $bmp.Height -and $bmp.GetPixel($x, $y).R -lt 128) {
                $v = $v -bor (1 -shl $r)
            }
        }
        $cols.Add($v)
    }
    return ,$cols
}

# 16px SimSun, same as the subtitles
function Render-Small([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return ,(New-Object System.Collections.Generic.List[int]) }
    $sz  = [System.Windows.Forms.TextRenderer]::MeasureText($text, $small, (New-Object System.Drawing.Size(60000, 40)), $flags)
    $bmp = New-Object System.Drawing.Bitmap($sz.Width, 24)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $small, (New-Object System.Drawing.Point(0, 0)),
        [System.Drawing.Color]::Black, [System.Drawing.Color]::White, $flags)
    $g.Dispose()
    $cols = Get-Cols $bmp 0 $sz.Width 0
    $bmp.Dispose()
    return ,$cols
}

# Title: draw large, crop to the ink, centre vertically in 48 rows; returns 3 lists (row bands)
function Render-Title([string]$text) {
    $sz  = [System.Windows.Forms.TextRenderer]::MeasureText($text, $big, (New-Object System.Drawing.Size(60000, 200)), $flags)
    $bmp = New-Object System.Drawing.Bitmap(($sz.Width + 8), ($sz.Height + 8))
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $big, (New-Object System.Drawing.Point(4, 4)),
        [System.Drawing.Color]::Black, [System.Drawing.Color]::White, $flags)
    $g.Dispose()
    $x0 = $bmp.Width; $x1 = -1; $y0 = $bmp.Height; $y1 = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            if ($bmp.GetPixel($x, $y).R -lt 128) {
                if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
                if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
            }
        }
    }
    if ($x1 -lt 0) { $bmp.Dispose(); return ,@((New-Object System.Collections.Generic.List[int]), (New-Object System.Collections.Generic.List[int]), (New-Object System.Collections.Generic.List[int])) }
    $h = $y1 - $y0 + 1
    if ($h -gt 48) { Write-Host "WARNING: title is $h rows high, cropped to 48"; $h = 48 }
    $top = $y0 - [int][Math]::Floor((48 - $h) / 2)
    $bands = @((Get-Cols $bmp $x0 ($x1 - $x0 + 1) $top), (Get-Cols $bmp $x0 ($x1 - $x0 + 1) ($top + 16)),
               (Get-Cols $bmp $x0 ($x1 - $x0 + 1) ($top + 32)))
    $bmp.Dispose()
    return ,$bands
}

# Icons, 16x16 each, drawn with lines (no special font needed):
#   0 check  1 warning triangle  2 cross  3..6 spinner (270-degree arc, rotated 90 degrees each step)
#   7 fire  8 no-blocking (circle + slash)  9 exit (door + arrow)  10 first aid (cross)
function Render-Icons() {
    $bmp = New-Object System.Drawing.Bitmap(176, 16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $blk = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 2.6)
    $wht = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.0)
    # check
    $g.DrawLines($blk, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(2, 8)), (New-Object System.Drawing.Point(6, 12)), (New-Object System.Drawing.Point(13, 3))))
    # warning: filled triangle with a white "!"
    $tri = [System.Drawing.Point[]]@((New-Object System.Drawing.Point(24, 1)), (New-Object System.Drawing.Point(31, 14)), (New-Object System.Drawing.Point(17, 14)))
    $g.FillPolygon([System.Drawing.Brushes]::Black, $tri)
    $g.DrawLine($wht, 24, 5, 24, 9)
    $g.FillRectangle([System.Drawing.Brushes]::White, 23, 11, 2, 2)
    # cross
    $g.DrawLine($blk, 35, 3, 44, 12)
    $g.DrawLine($blk, 44, 3, 35, 12)
    # spinner
    $arc = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 2.2)
    for ($k = 0; $k -lt 4; $k++) {
        $g.DrawArc($arc, (48 + $k * 16 + 2), 2, 11, 11, (-90 + $k * 90), 270)
    }
    # fire: filled flame outline with a small white core
    $flame = [System.Drawing.Point[]]@((New-Object System.Drawing.Point(120, 1)), (New-Object System.Drawing.Point(125, 6)),
              (New-Object System.Drawing.Point(126, 11)), (New-Object System.Drawing.Point(123, 15)), (New-Object System.Drawing.Point(117, 15)),
              (New-Object System.Drawing.Point(114, 11)), (New-Object System.Drawing.Point(115, 6)), (New-Object System.Drawing.Point(117, 8)))
    $g.FillPolygon([System.Drawing.Brushes]::Black, $flame)
    $g.FillEllipse([System.Drawing.Brushes]::White, 119, 10, 3, 4)
    # no-blocking: circle with a slash
    $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 2.0)
    $g.DrawEllipse($ring, 130, 2, 12, 12)
    $g.DrawLine($ring, 132, 4, 140, 12)
    # exit: door frame and an arrow going out
    $thin = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.6)
    $g.DrawRectangle($thin, 145, 2, 6, 12)
    $g.DrawLine($blk, 149, 8, 158, 8)
    $g.DrawLines($thin, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(155, 5)), (New-Object System.Drawing.Point(158, 8)),
              (New-Object System.Drawing.Point(155, 11))))
    # first aid: thick cross
    $g.FillRectangle([System.Drawing.Brushes]::Black, 166, 2, 4, 12)
    $g.FillRectangle([System.Drawing.Brushes]::Black, 162, 6, 12, 4)
    $g.Dispose()
    $cols = Get-Cols $bmp 0 176 0
    $bmp.Dispose()
    return ,$cols
}

if (-not (Test-Path $InFile)) { Write-Host "ERROR: $InFile not found"; exit 1 }
$texts = @{}
foreach ($line in [IO.File]::ReadAllLines($InFile, [Text.Encoding]::UTF8)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $eq = $t.IndexOf('=')
    if ($eq -lt 1) { Write-Host "WARNING: skipped line: $t"; continue }
    $texts[$t.Substring(0, $eq).Trim().ToUpper()] = $t.Substring($eq + 1).Trim()
}
function Get-Text([string]$k) {
    if ($texts.ContainsKey($k)) { return $texts[$k] }
    Write-Host "WARNING: $k missing in splash.txt"; return ''
}

# ---- build all strings in id order ----
$strings = New-Object System.Collections.ArrayList     # each: @{ name; text; cols }
$tb = Render-Title (Get-Text 'TITLE')
$sb2 = Render-Title (Get-Text 'SAFE_TITLE')
foreach ($k in $Ids) {
    switch -regex ($k) {
        '^TITLE(\d)$' { $cols = $tb[[int]$Matches[1]]; $txt = Get-Text 'TITLE' }
        '^SAFE_T(\d)$' { $cols = $sb2[[int]$Matches[1]]; $txt = Get-Text 'SAFE_TITLE' }
        '^DIGITS$' {
            $cols = New-Object System.Collections.Generic.List[int]
            foreach ($ch in '0123456789%/'.ToCharArray()) {
                $c = Render-Small ([string]$ch)
                for ($i = 0; $i -lt 8; $i++) { if ($i -lt $c.Count) { $cols.Add($c[$i]) } else { $cols.Add(0) } }
            }
            $txt = '0123456789%/'
        }
        '^ICONS$' { $cols = Render-Icons; $txt = 'check warn cross spin*4 fire noblock exit aid' }
        default {
            $txt  = Get-Text $k
            $cols = Render-Small $txt
            $max  = if ($k.StartsWith('L_')) { 160 } elseif ($k -match '^(LOST|BACK|REJ)_') { 260 } elseif ($k -match '^S\d_') { 480 } elseif ($k.StartsWith('R_PIC_')) { 270 } elseif ($k.StartsWith('R_')) { 300 } else { $ScreenW }
            if ($cols.Count -gt $max) {
                Write-Host "WARNING: $k is $($cols.Count) px wide, cut to $max"
                $cols.RemoveRange($max, $cols.Count - $max)
            }
        }
    }
    [void]$strings.Add(@{ name = $k; text = $txt; cols = $cols })
}

$total = 0
foreach ($s in $strings) { $total += $s.cols.Count }
if ($total -gt 16384) { Write-Host "ERROR: $total columns in total, more than 16384 - shorten the text"; exit 1 }
$depth = [int]([Math]::Ceiling($total / 2048.0) * 2048)

# ---- write Verilog ----
$sb   = New-Object System.Text.StringBuilder
$body = New-Object System.Text.StringBuilder
$tab  = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('`timescale 1ns/1ps')
[void]$sb.AppendLine('// -----------------------------------------------------------------------------')
[void]$sb.AppendLine('// AUTO-GENERATED by subtitle/gen_splash.ps1 from subtitle/splash.txt -- do not edit by hand')
[void]$sb.AppendLine("// generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sb.AppendLine('// Boot screen text: one 16-bit word per column, bit 0 = top row, strings packed back to back.')
[void]$sb.AppendLine("// $total columns used, ROM depth $depth (BRAM32K)")
$addr = 0
for ($id = 0; $id -lt $strings.Count; $id++) {
    $s   = $strings[$id]
    $n   = $s.cols.Count
    $x0  = [int][Math]::Floor(($ScreenW - $n) / 2)
    if ($x0 -lt 0) { $x0 = 0 }
    [void]$sb.AppendLine(("//   id {0,2} {1,-11} start {2,4}  len {3,3}  x0 {4,3}  {5}" -f $id, $s.name, $addr, $n, $x0, $s.text))
    [void]$tab.AppendLine(("            7'd{0}: begin s_start = 14'd{1}; s_len = 10'd{2}; s_x0 = 10'd{3}; end" -f $id, $addr, $n, $x0))
    for ($i = 0; $i -lt $n; $i++) {
        if ($s.cols[$i] -ne 0) { [void]$body.AppendLine(('        mem[{0}] = 16''h{1:X4};' -f ($addr + $i), $s.cols[$i])) }
    }
    Write-Host ("{0,-11} {1,4} px  {2}" -f $s.name, $n, $s.text)
    $addr += $n
}
[void]$sb.AppendLine('// -----------------------------------------------------------------------------')
[void]$sb.AppendLine('module splash_rom (')
[void]$sb.AppendLine('    input  wire        clk,')
[void]$sb.AppendLine('    input  wire [13:0] raddr,')
[void]$sb.AppendLine('    output reg  [15:0] rdata,')
[void]$sb.AppendLine('    input  wire [6:0]  sid,             // string id -> where it is and where it goes on screen')
[void]$sb.AppendLine('    output reg  [13:0] s_start,')
[void]$sb.AppendLine('    output reg  [9:0]  s_len,')
[void]$sb.AppendLine('    output reg  [9:0]  s_x0,')
[void]$sb.AppendLine('    output wire [9:0]  w_lost,          // badge widths = the wider of its two lines (badge is right-aligned)')
[void]$sb.AppendLine('    output wire [9:0]  w_back,')
[void]$sb.AppendLine('    output wire [9:0]  w_rej')
[void]$sb.AppendLine(');')
$wid = @{}
foreach ($s in $strings) { $wid[$s.name] = $s.cols.Count }
[void]$sb.AppendLine(("    assign w_lost = 10'd{0};" -f [Math]::Max($wid['LOST_CN'], $wid['LOST_EN'])))
[void]$sb.AppendLine(("    assign w_back = 10'd{0};" -f [Math]::Max($wid['BACK_CN'], $wid['BACK_EN'])))
[void]$sb.AppendLine(("    assign w_rej  = 10'd{0};" -f [Math]::Max($wid['REJ_CN'], $wid['REJ_EN'])))
[void]$sb.AppendLine("    reg [15:0] mem [0:$($depth - 1)] /* fehdl force_ram=1, ram_style=""bram_32k"" */;")
[void]$sb.AppendLine('    integer i;')
[void]$sb.AppendLine('    initial begin')
[void]$sb.AppendLine("        for (i = 0; i < $depth; i = i + 1)")
[void]$sb.AppendLine("            mem[i] = 16'h0000;")
[void]$sb.Append($body.ToString())
[void]$sb.AppendLine('    end')
[void]$sb.AppendLine('    always @(posedge clk)')
[void]$sb.AppendLine('        rdata <= mem[raddr];')
[void]$sb.AppendLine('    always @(*) begin')
[void]$sb.AppendLine('        case (sid)')
[void]$sb.Append($tab.ToString())
[void]$sb.AppendLine("            default: begin s_start = 14'd0; s_len = 10'd0; s_x0 = 10'd0; end")
[void]$sb.AppendLine('        endcase')
[void]$sb.AppendLine('    end')
[void]$sb.AppendLine('endmodule')
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "OK: wrote $OutFile ($total columns, depth $depth)"
