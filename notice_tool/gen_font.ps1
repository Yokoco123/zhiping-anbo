# gen_font.ps1 - build FONT.BIN (SimSun 16px bitmap font) for the info screen's serial notices.
# Install once: in the serial app send  "<PIN> 装字库", wait for READY, then send FONT.BIN with the "file" button.
#
# Glyphs (one 32-byte slot each, in this order; serial_cmd.v maps code points the same way):
#   U+0020..007E   95   ASCII        half width (8 columns)
#   U+00A0..00FF   96   Latin-1      full width (16 columns)
#   U+2000..206F  112   punctuation  full width
#   U+3000..303F   64   CJK punct.   full width
#   U+4E00..9FFF 20992  CJK          full width
#   U+FF00..FFEF  240   full-width forms
# A slot = 16 columns x 2 bytes (high byte first); column bits: bit 0 = top row. Half-width glyphs use columns 0..7.
# File = data (padded with 0 to whole 256-byte pages) + one 256-byte trailer page:
#   "ZPFONT01" | glyph count (4, big-endian) | data bytes (4) | CRC32 of the data (4) | FF ...
#   CRC32: poly 04C11DB7, init FFFFFFFF, MSB first, no final xor.
# Options: -Hex file.hex  (also write the data+trailer as one byte per line, for simulation)
#          -Preview "text" (draw the text with the finished font into FONT_preview.png)
param([string]$Hex = '', [string]$Preview = '寻物启事：一卡通遗失于图书馆二楼 Lost card, Library 2F (Tel 110)')

$src = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
public static class FontGen {
    public static readonly int[] RangeLo = { 0x20, 0xA0, 0x2000, 0x3000, 0x4E00, 0xFF00 };
    public static readonly int[] RangeHi = { 0x7E, 0xFF, 0x206F, 0x303F, 0x9FFF, 0xFFEF };
    public static int Count() { int n = 0; for (int r = 0; r < RangeLo.Length; r++) n += RangeHi[r] - RangeLo[r] + 1; return n; }
    // code point -> glyph index, -1 if not in the font
    public static int Index(int cp) {
        int b = 0;
        for (int r = 0; r < RangeLo.Length; r++) {
            if (cp >= RangeLo[r] && cp <= RangeHi[r]) return b + cp - RangeLo[r];
            b += RangeHi[r] - RangeLo[r] + 1;
        }
        return -1;
    }
    public static byte[] Build() {
        int n = Count();
        int dataLen = ((n * 32 + 255) / 256) * 256;
        byte[] buf = new byte[dataLen];
        Font f = new Font("SimSun", 16, GraphicsUnit.Pixel);
        TextFormatFlags fl = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        Bitmap bmp = new Bitmap(24, 24, PixelFormat.Format32bppArgb);
        Graphics g = Graphics.FromImage(bmp);
        int[] px = new int[24 * 24];
        int gi = 0;
        for (int r = 0; r < RangeLo.Length; r++) {
            for (int cp = RangeLo[r]; cp <= RangeHi[r]; cp++, gi++) {
                g.Clear(Color.White);
                TextRenderer.DrawText(g, ((char)cp).ToString(), f, new Point(0, 0), Color.Black, Color.White, fl);
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, 24, 24), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
                bmp.UnlockBits(d);
                int w = (r == 0) ? 8 : 16;
                for (int x = 0; x < w; x++) {
                    int col = 0;
                    for (int y = 0; y < 16; y++) if (((px[y * 24 + x] >> 16) & 255) < 128) col |= 1 << y;
                    buf[gi * 32 + 2 * x]     = (byte)(col >> 8);
                    buf[gi * 32 + 2 * x + 1] = (byte)(col & 255);
                }
            }
        }
        g.Dispose(); bmp.Dispose();
        byte[] file = new byte[dataLen + 256];
        Array.Copy(buf, file, dataLen);
        for (int i = 0; i < 256; i++) file[dataLen + i] = 0xFF;
        byte[] magic = System.Text.Encoding.ASCII.GetBytes("ZPFONT01");
        Array.Copy(magic, 0, file, dataLen, 8);
        Put32(file, dataLen + 8, (uint)n);
        Put32(file, dataLen + 12, (uint)dataLen);
        Put32(file, dataLen + 16, Crc32(buf));
        return file;
    }
    static void Put32(byte[] b, int at, uint v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }
    public static uint Crc32(byte[] data) {
        uint c = 0xFFFFFFFF;
        foreach (byte d in data) {
            c ^= (uint)d << 24;
            for (int i = 0; i < 8; i++) c = ((c & 0x80000000) != 0) ? (c << 1) ^ 0x04C11DB7 : (c << 1);
        }
        return c;
    }
    // draw text with the finished font (UTF-16 -> code points -> glyph slots), same rules as the FPGA
    public static Bitmap Render(byte[] file, string text) {
        System.Collections.Generic.List<int> cols = new System.Collections.Generic.List<int>();
        for (int i = 0; i < text.Length; i++) {
            int cp = text[i];
            int gi = Index(cp); if (gi < 0) gi = Index('?');
            int w = (cp >= 0x20 && cp <= 0x7E) || Index(cp) < 0 ? 8 : 16;
            for (int x = 0; x < w; x++) cols.Add((file[gi * 32 + 2 * x] << 8) | file[gi * 32 + 2 * x + 1]);
        }
        Bitmap b = new Bitmap(Math.Max(cols.Count, 1), 20);
        for (int x = 0; x < cols.Count; x++)
            for (int y = 0; y < 20; y++)
                b.SetPixel(x, y, (y >= 2 && y < 18 && ((cols[x] >> (y - 2)) & 1) != 0) ? Color.Black : Color.FromArgb(255, 210, 60));
        return b;
    }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing, System.Windows.Forms

$out = Join-Path $PSScriptRoot 'FONT.BIN'
Write-Host 'rendering 21599 glyphs (SimSun 16px) ...'
$t0 = Get-Date
$file = [FontGen]::Build()
[IO.File]::WriteAllBytes($out, $file)
$n = [FontGen]::Count()
Write-Host ("OK: wrote {0} ({1} bytes, {2} glyphs, {3:N1} s); at 115200 bps the transfer takes about {4} s" -f $out, $file.Length, $n, ((Get-Date) - $t0).TotalSeconds, [int]($file.Length * 10 / 115200))

if ($Preview -ne '') {
    $pv = [FontGen]::Render($file, $Preview)
    $pf = Join-Path $PSScriptRoot 'FONT_preview.png'
    $pv.Save($pf, [System.Drawing.Imaging.ImageFormat]::Png); $pv.Dispose()
    Write-Host "preview: $pf"
}
if ($Hex -ne '') {
    $sb = New-Object System.Text.StringBuilder ($file.Length * 4)
    foreach ($x in $file) { [void]$sb.Append($x.ToString('X2')).Append("`n") }
    [IO.File]::WriteAllText($Hex, $sb.ToString())
    Write-Host "wrote $Hex"
}
