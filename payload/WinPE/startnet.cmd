@echo off
wpeinit
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
wpeutil SetKeyboardLayout 040b:0000040b
for /l %%i in (1,1,15) do (
  for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do if exist %%d:\W11AUTO\W11AUTO.tag (powershell -NoProfile -ExecutionPolicy Bypass -File %%d:\W11AUTO\WinPE\Deploy.ps1 & goto :eof)
  ping -n 2 127.0.0.1 >nul
)
