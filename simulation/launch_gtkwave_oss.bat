@echo off
setlocal
set "OSS_ROOT=C:\Users\TOSHIBA\Downloads\oss-cad-suite"
set "VCD_FILE=C:\CONNECTED DELAY LINES\simulation\tdc_sweep_top_tb.vcd"

if not exist "%OSS_ROOT%\environment.bat" (
  echo ERROR: Missing environment script: %OSS_ROOT%\environment.bat
  exit /b 1
)

if not exist "%OSS_ROOT%\bin\gtkwave.exe" (
  echo ERROR: Missing GTKWave executable: %OSS_ROOT%\bin\gtkwave.exe
  exit /b 1
)

if not exist "%VCD_FILE%" (
  echo ERROR: Missing VCD file: %VCD_FILE%
  exit /b 1
)

call "%OSS_ROOT%\environment.bat"
start "" "%OSS_ROOT%\bin\gtkwave.exe" "%VCD_FILE%"
echo GTKWave launched with OSS CAD environment.
