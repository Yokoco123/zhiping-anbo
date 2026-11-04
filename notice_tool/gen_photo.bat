@echo off
rem Drag a photo onto this file (or double-click and pick one) -> PHOTO.BIN + PHOTO_preview.png
rem Default: the whole photo, white bars. To fill the frame instead, edit -Mode fit below to -Mode crop (cut the sides) or -Mode stretch.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gen_photo.ps1" -Path "%~1" -Mode fit
pause
