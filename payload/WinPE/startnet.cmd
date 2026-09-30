@echo off
rem W11AUTO - WinPE startup. Build-Media.ps1 copies this into boot.wim (Windows\System32\startnet.cmd).
title W11AUTO
echo Kaynnistetaan W11AUTO...
wpeinit
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1
wpeutil SetKeyboardLayout 040b:0000040b >nul 2>&1

set W11=
for /l %%i in (1,1,15) do (
  if not defined W11 (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do if exist %%d:\W11AUTO\W11AUTO.tag set W11=%%d:\W11AUTO
    if not defined W11 ping -n 2 127.0.0.1 >nul
  )
)
if not defined W11 (
  echo.
  echo W11AUTO-kansiota ei loytynyt asennusmedialta. Komentokehote avataan.
  goto :shell
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%W11%\WinPE\Deploy.ps1"

:shell
cmd /k
