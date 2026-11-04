# gen_photo.ps1 - build PHOTO.BIN (one photo for a notice) for the info screen.
# Usage: drag a photo (jpg / png / bmp) onto gen_photo.bat, or run it and pick a file.
#   Then in the serial app send  "<PIN> <photo keyword>n"  (n = notice 1..4), wait for READY, send PHOTO.BIN with the "file" button.
#
# The photo is turned upright (EXIF orientation) and made 720 x 640 (9:8; smaller photos are scaled up):
#   -Mode fit     (default) the whole photo, scaled to fit, white bars where the shape differs
#   -Mode crop    fill the frame, cut off the parts that stick out (keeps the middle)
#   -Mode stretch fill the frame by stretching (people look fatter / thinner)
# The FPGA averages every 2 x 2 block in hardware and shows 360 x 320 on the notice page.
# File = data (921600 bytes = 3600 pages) + one 256-byte trailer page:
#   data: output rows from the bottom (row 319) to the top (row 0); in each row 360 blocks from left to right;
#         a block = source pixels (2x,2y) (2x+1,2y) (2x,2y+1) (2x+1,2y+1), each RGB565 high byte first -> 8 bytes, 2880 bytes per row
#   trailer: "ZPPHOT02" | width 720, height 640 (2 + 2, big-endian) | data bytes (4) | CRC32 of the data (4) | FF ...
#   CRC32: poly 04C11DB7, init FFFFFFFF, MSB first, no final xor (same as FONT.BIN).
# Writes PHOTO.BIN and PHOTO_preview.png (exactly what the screen will show) next to this script.
# Options: -Mode fit|crop|stretch, -Name name (default PHOTO -> PHOTO.BIN / PHOTO_preview.png)
#          -Hex file.hex  (also write the file as one byte per line, for simulation)
param([string]$Path = '', [string]$Mode = 'fit', [string]$Name = 'PHOTO', [string]$Hex = '')

$src = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class PhotoGen {
    public const int W = 720, H = 640, OW = 360, OH = 320;
    public static Bitmap Prepare(string path, string mode, out int srcW, out int srcH) {
        Image img = Image.FromFile(path);
        // EXIF orientation (phone photos)
        foreach (int id in img.PropertyIdList) {
            if (id != 0x0112) continue;
            int o = img.GetPropertyItem(id).Value[0];
            RotateFlipType t = RotateFlipType.RotateNoneFlipNone;
            if (o == 2) t = RotateFlipType.RotateNoneFlipX;
            else if (o == 3) t = RotateFlipType.Rotate180FlipNone;
            else if (o == 4) t = RotateFlipType.Rotate180FlipX;
            else if (o == 5) t = RotateFlipType.Rotate90FlipX;
            else if (o == 6) t = RotateFlipType.Rotate90FlipNone;
            else if (o == 7) t = RotateFlipType.Rotate270FlipX;
            else if (o == 8) t = RotateFlipType.Rotate270FlipNone;
            img.RotateFlip(t);
        }
        srcW = img.Width; srcH = img.Height;
        // source rectangle (cx, cy, cw, ch) -> destination rectangle (dx, dy, dw, dh) in the 720 x 640 frame
        int cx = 0, cy = 0, cw = srcW, ch = srcH, dx = 0, dy = 0, dw = W, dh = H;
        bool wide = (long)srcW * H > (long)srcH * W;            // wider than 3:4
        if (mode == "crop") {                                   // keep the middle
            if (wide) cw = (int)Math.Round((double)srcH * W / H); else ch = (int)Math.Round((double)srcW * H / W);
            if (cw < 1) cw = 1; if (ch < 1) ch = 1;
            cx = (srcW - cw) / 2; cy = (srcH - ch) / 2;
        } else if (mode != "stretch") {                         // fit: whole photo, bars
            if (wide) { dh = (int)Math.Round((double)W * srcH / srcW); if (dh < 1) dh = 1; dy = (H - dh) / 2; }
            else      { dw = (int)Math.Round((double)H * srcW / srcH); if (dw < 1) dw = 1; dx = (W - dw) / 2; }
        }
        Bitmap b = new Bitmap(W, H, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.White);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            using (ImageAttributes ia = new ImageAttributes()) {
                ia.SetWrapMode(WrapMode.TileFlipXY);          // no dark edge when scaling
                g.DrawImage(img, new Rectangle(dx, dy, dw, dh), cx, cy, cw, ch, GraphicsUnit.Pixel, ia);
            }
        }
        img.Dispose();
        return b;
    }
    static byte[] Pixels(Bitmap b) {           // B G R per pixel, rows top to bottom, no padding
        BitmapData d = b.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        byte[] row = new byte[d.Stride];
        byte[] px = new byte[W * H * 3];
        for (int y = 0; y < H; y++) {
            Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), row, 0, d.Stride);
            Array.Copy(row, 0, px, y * W * 3, W * 3);
        }
        b.UnlockBits(d);
        return px;
    }
    public static byte[] Build(Bitmap b) {
        byte[] px = Pixels(b);
        int dataLen = W * H * 2;
        byte[] file = new byte[dataLen + 256];
        int k = 0;
        for (int oy = OH - 1; oy >= 0; oy--)
            for (int ox = 0; ox < OW; ox++)
                for (int j = 0; j < 4; j++) {
                    int x = 2 * ox + (j & 1), y = 2 * oy + (j >> 1);
                    int a = (y * W + x) * 3;
                    int r5 = (px[a + 2] * 31 + 127) / 255, g6 = (px[a + 1] * 63 + 127) / 255, b5 = (px[a] * 31 + 127) / 255;
                    int v = (r5 << 11) | (g6 << 5) | b5;
                    file[k++] = (byte)(v >> 8); file[k++] = (byte)(v & 255);
                }
        for (int i = 0; i < 256; i++) file[dataLen + i] = 0xFF;
        byte[] magic = System.Text.Encoding.ASCII.GetBytes("ZPPHOT02");
        Array.Copy(magic, 0, file, dataLen, 8);
        file[dataLen + 8] = (byte)(W >> 8); file[dataLen + 9] = (byte)(W & 255); file[dataLen + 10] = (byte)(H >> 8); file[dataLen + 11] = (byte)(H & 255);
        Put32(file, dataLen + 12, (uint)dataLen);
        Put32(file, dataLen + 16, Crc32(file, dataLen));
        return file;
    }
    static void Put32(byte[] b, int at, uint v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }
    public static uint Crc32(byte[] data, int n) {
        uint c = 0xFFFFFFFF;
        for (int k = 0; k < n; k++) {
            c ^= (uint)data[k] << 24;
            for (int i = 0; i < 8; i++) c = ((c & 0x80000000) != 0) ? (c << 1) ^ 0x04C11DB7 : (c << 1);
        }
        return c;
    }
    // what the FPGA shows: RGB565 -> 888 (top bits copied down), 2 x 2 average with rounding, from the file itself
    public static Bitmap Preview(byte[] file) {
        Bitmap p = new Bitmap(OW, OH, PixelFormat.Format24bppRgb);
        int k = 0;
        for (int oy = OH - 1; oy >= 0; oy--)
            for (int ox = 0; ox < OW; ox++) {
                int sb = 0, sg = 0, sr = 0;
                for (int j = 0; j < 4; j++) {
                    int v = (file[k] << 8) | file[k + 1]; k += 2;
                    int r5 = v >> 11, g6 = (v >> 5) & 63, b5 = v & 31;
                    sr += (r5 << 3) | (r5 >> 2); sg += (g6 << 2) | (g6 >> 4); sb += (b5 << 3) | (b5 >> 2);
                }
                p.SetPixel(ox, oy, Color.FromArgb((sr + 2) >> 2, (sg + 2) >> 2, (sb + 2) >> 2));
            }
        return p;
    }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing

if ($Path -eq '') {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Photos|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|All files|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Host 'no file chosen'; exit 1 }
    $Path = $dlg.FileName
}
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "ERROR: file not found: $Path"; exit 1 }

$w = 0; $h = 0
$Mode = $Mode.ToLower()
if (@('fit', 'crop', 'stretch') -notcontains $Mode) { Write-Host "ERROR: -Mode must be fit, crop or stretch"; exit 1 }
try { $bmp = [PhotoGen]::Prepare((Resolve-Path -LiteralPath $Path).ProviderPath, $Mode, [ref]$w, [ref]$h) }
catch { Write-Host "ERROR: cannot read this picture: $($_.Exception.Message)"; exit 1 }
if ($w -lt 720 -or $h -lt 640) { Write-Host ("note: the photo is {0} x {1} (after turning upright), smaller than 720 x 640 - scaled up" -f $w, $h) }
$file = [PhotoGen]::Build($bmp)
$bmp.Dispose()

$out = Join-Path $PSScriptRoot ($Name + '.BIN')
[IO.File]::WriteAllBytes($out, $file)
$pv = [PhotoGen]::Preview($file)
$pf = Join-Path $PSScriptRoot ($Name + '_preview.png')
$pv.Save($pf, [System.Drawing.Imaging.ImageFormat]::Png); $pv.Dispose()
Write-Host ("OK ({4}): {0} -> {1} ({2} bytes); at 921600 bps the transfer takes about {3} s" -f $Path, $out, $file.Length, [int]($file.Length * 10 / 921600), $Mode)
Write-Host "preview (what the screen shows): $pf"
if ($Hex -ne '') {
    $sb = New-Object System.Text.StringBuilder ($file.Length * 3)
    foreach ($x in $file) { [void]$sb.Append($x.ToString('X2')).Append("`n") }
    [IO.File]::WriteAllText($Hex, $sb.ToString())
    Write-Host "wrote $Hex"
}
