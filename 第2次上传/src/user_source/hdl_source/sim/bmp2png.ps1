# sim/splash_out/*.bmp -> *.png (仿真抓的帧转成图片方便看)
Add-Type -AssemblyName System.Drawing
Get-ChildItem $args[0] -Filter *.bmp | ForEach-Object {
  $img = [System.Drawing.Image]::FromFile($_.FullName)
  $img.Save(($_.FullName -replace '\.bmp$', '.png'), [System.Drawing.Imaging.ImageFormat]::Png); $img.Dispose() }
