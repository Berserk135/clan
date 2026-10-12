# Обновляет module-names.json — названия свойств оружейных модулей.
# Берёт их из файла локализации установленной игры (ключи item.wpn_mod.adv.* и modules.*).
# Запуск после патча игры: powershell -ExecutionPolicy Bypass -File update-module-names.ps1
param([string]$Lang = 'D:\EXBO\runtime\stalcraft\modassets\assets\stalker\lang\ru.lang')

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

if (-not (Test-Path $Lang)) {
    # игру могли поставить в другую папку — ищем файл локализации
    $found = Get-ChildItem 'C:\', 'D:\', 'E:\' -Directory -Filter 'EXBO' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'runtime\stalcraft\modassets\assets\stalker\lang\ru.lang' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { Write-Host "Не найден файл локализации игры. Укажите путь: -Lang <путь к ru.lang>" -ForegroundColor Red; exit 1 }
    $Lang = $found
}
Write-Host "Читаю $Lang"

$name = @{}; $stat = @{}; $desc = @{}
foreach ($l in [IO.File]::ReadAllLines($Lang, [Text.Encoding]::UTF8)) {
    if ($l -match '^item\.wpn_mod\.adv\.([a-z0-9_]+)\.name=(.+)$') { $name[$matches[1]] = $matches[2].Trim() }
    elseif ($l -match '^item\.wpn_mod\.adv\.([a-z0-9_]+)\.long\.name=(.+)$') { $stat[$matches[1]] = $matches[2].Trim() }
    elseif ($l -match '^modules\.([a-z0-9_]+)\.description=(.+)$') { $desc[$matches[1]] = $matches[2].Trim() }
}

$o = [ordered]@{}
$o['_'] = @(
    'Названия свойств оружейных модулей, взяты из файла локализации установленной игры:',
    "$Lang (ключи item.wpn_mod.adv.* и modules.*).",
    'name — слово из названия модуля, stat — характеристика, desc — что делает свойство.',
    'Обновить после патча игры: powershell -ExecutionPolicy Bypass -File update-module-names.ps1'
)
foreach ($k in ($name.Keys | Sort-Object)) { $o[$k] = [ordered]@{ name = $name[$k]; stat = $stat[$k]; desc = $desc[$k] } }

$out = Join-Path $PSScriptRoot 'module-names.json'
[IO.File]::WriteAllText($out, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
Write-Host "Записано свойств: $($name.Count) -> $out" -ForegroundColor Green
Write-Host 'Перезапустите программу, чтобы названия применились.'
