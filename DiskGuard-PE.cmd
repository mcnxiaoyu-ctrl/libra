@echo off
chcp 936 >nul 2>nul
setlocal
title DiskGuard PE

if not exist "%SystemRoot%\System32\diskpart.exe" (
    echo [ERROR] diskpart.exe not found.
    pause
    exit /b 1
)

set "TMPDP=%TEMP%"
if "%TMPDP%"=="" set "TMPDP=X:\"
if not exist "%TMPDP%\" set "TMPDP=X:\"
set "DPFILE=%TMPDP%\dg_pe_dp.txt"

:MENU
cls
echo ================================================
echo    DiskGuard PE  -  ���̸��빤��
echo ================================================
echo.
echo    1   �г����д���
echo    2   ֻ������      (�� DiskGenius / ��������)
echo    3   ��Ϊ�ѻ�      (���ײ����أ�DiskGenius �ῴ����)
echo    4   ȡ��ֻ��
echo    5   ����
echo    6   �����Զ�����  (�����λỰ��Ч)
echo    7   �ָ��Զ�����
echo    8   ��ԭ����: ��ֻ�� + ���� + �ָ��Զ�����
echo    0   �˳�
echo.
set "SEL="
set /p "SEL=��ѡ��: "

if "%SEL%"=="1" goto LIST
if "%SEL%"=="2" goto OP_RO
if "%SEL%"=="3" goto OP_OFF
if "%SEL%"=="4" goto OP_CLRRO
if "%SEL%"=="5" goto OP_ON
if "%SEL%"=="6" goto OP_NOMNT
if "%SEL%"=="7" goto OP_AUTOMNT
if "%SEL%"=="8" goto OP_RESET
if "%SEL%"=="0" goto END

echo ��Чѡ�
pause
goto MENU

:LIST
cls
echo ==== �����б� ====
echo.
>"%DPFILE%" echo list disk
>>"%DPFILE%" echo exit
diskpart /s "%DPFILE%"
echo.
echo ��ʾ: ���� 1907.7GB ���ҵ��ǿ����Ҫ�������̡�
pause
goto MENU

:OP_RO
cls
call :PICK
if errorlevel 1 goto MENU
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo attributes disk set readonly
>>"%DPFILE%" echo online disk
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
echo.
echo ==== ִ��: ֻ������ ====
diskpart /s "%DPFILE%"
echo.
echo ��ɡ����ڿ����� DiskGenius ��ȡ��д�����ᱻ�ܾ���
pause
goto MENU

:OP_OFF
cls
call :PICK
if errorlevel 1 goto MENU
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo offline disk
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
echo.
echo ==== ִ��: ��Ϊ�ѻ� ====
diskpart /s "%DPFILE%"
echo.
echo ��ɡ��������ѻ�����������κξ���
pause
goto MENU

:OP_CLRRO
cls
call :PICK
if errorlevel 1 goto MENU
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo attributes disk clear readonly
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
echo.
echo ==== ִ��: ȡ��ֻ�� ====
diskpart /s "%DPFILE%"
echo.
pause
goto MENU

:OP_ON
cls
call :PICK
if errorlevel 1 goto MENU
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo online disk
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
echo.
echo ==== ִ��: ���� ====
diskpart /s "%DPFILE%"
echo.
pause
goto MENU

:OP_NOMNT
cls
>"%DPFILE%" echo automount disable
>>"%DPFILE%" echo exit
echo ==== ִ��: �����Զ����� ====
diskpart /s "%DPFILE%"
echo.
echo ��ɡ����λỰ���½���ľ������Զ������̷���
pause
goto MENU

:OP_AUTOMNT
cls
>"%DPFILE%" echo automount enable
>>"%DPFILE%" echo exit
echo ==== ִ��: �ָ��Զ����� ====
diskpart /s "%DPFILE%"
echo.
pause
goto MENU

:OP_RESET
cls
echo ���Ը���ִ��: ���ֻ�� -> ���������ָ��Զ����ء�
echo.
call :PICK
if errorlevel 1 goto MENU
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo attributes disk clear readonly
>>"%DPFILE%" echo online disk
>>"%DPFILE%" echo automount enable
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
echo.
echo ==== ִ��: һ����ԭ ====
diskpart /s "%DPFILE%"
echo.
echo ��ɡ��������ǻ��̣���ԭ�������̰γ���
pause
goto MENU

:PICK
set "DN="
set /p "DN=��������̱�� (ֱ�ӻس�ȡ��): "
if "%DN%"=="" exit /b 1

set "BAD="
for /f "delims=0123456789" %%A in ("%DN%") do set "BAD=1"
if defined BAD (
    echo �����Ч��ֻ���������֡�
    pause
    exit /b 1
)

echo.
echo ---- ���������Ĵ��� ----
>"%DPFILE%" echo select disk %DN%
>>"%DPFILE%" echo detail disk
>>"%DPFILE%" echo exit
diskpart /s "%DPFILE%"
echo.
echo ��˶�������ͺź�������
set "OK="
set /p "OK=ȷ������������ YES, ������������ȡ��: "
if /i not "%OK%"=="YES" exit /b 1
exit /b 0

:END
endlocal
exit /b 0
