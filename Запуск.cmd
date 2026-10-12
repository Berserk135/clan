@echo off
chcp 65001 >nul
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
    echo Не найден Python. Установите его с https://www.python.org/downloads/ ^(галочка "Add python.exe to PATH"^) и запустите снова.
    pause
    exit /b 1
)

python -c "import fastapi, uvicorn, httpx" >nul 2>nul
if errorlevel 1 (
    echo Первый запуск: устанавливаю библиотеки из requirements.txt...
    python -m pip install -r requirements.txt
    if errorlevel 1 (
        echo Не удалось установить библиотеки. Проверьте интернет и запустите снова.
        pause
        exit /b 1
    )
)

python -m szdesk %*
pause
