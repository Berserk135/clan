# STALZONE: поиск выгодных лотов на аукционе с учётом комиссии.
# Запуск:  powershell -ExecutionPolicy Bypass -File sc-deals.ps1          (бесконечный цикл)
#          powershell -ExecutionPolicy Bypass -File sc-deals.ps1 -Once    (один проход)
#          powershell -ExecutionPolicy Bypass -File sc-deals.ps1 -Find "бинт"  (поиск ID предмета)
param(
    [switch]$Once,
    [string]$Find
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root      = $PSScriptRoot
$Cfg       = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Api       = 'https://eapi.stalcraft.net'
$DbFile    = Join-Path $Root 'items-db.json'
$SeenFile  = Join-Path $Root 'seen-lots.json'
$Headers   = @{ 'Client-Id' = $Cfg.client_id; 'Client-Secret' = $Cfg.client_secret }
$Commission = [double]$Cfg.commission_percent / 100

function Get-Json([string]$Url, [hashtable]$Hdr = @{}) {
    for ($try = 1; $try -le 3; $try++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $Hdr
            $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            $left = $r.Headers['x-ratelimit-remaining']
            if ($left -and [int]$left -lt 5) {
                $resetMs = [int64]$r.Headers['x-ratelimit-reset']
                $wait = [math]::Max(1, ($resetMs - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000)
                Write-Host "Лимит запросов почти исчерпан, жду $([int]$wait) с" -ForegroundColor DarkYellow
                Start-Sleep -Seconds ([int]$wait + 1)
            }
            return $text | ConvertFrom-Json
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 429) { Start-Sleep -Seconds 30; continue }
            if ($code -eq 401) { throw 'Ошибка 401: неверный Client ID / Client Secret в config.json' }
            if ($code -eq 404) { return $null }
            if ($try -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

# ---------- База предметов (ID <-> название) ----------
function Get-ItemDb {
    $fresh = (Test-Path $DbFile) -and ((Get-Item $DbFile).LastWriteTime -gt (Get-Date).AddDays(-7))
    if (-not $fresh) {
        Write-Host 'Скачиваю базу предметов...' -ForegroundColor DarkGray
        $realm = if ($Cfg.region -eq 'RU') { 'ru' } else { 'global' }
        $list = Get-Json "https://raw.githubusercontent.com/EXBO-Studio/stalcraft-database/main/$realm/listing.json"
        $db = foreach ($it in $list) {
            [pscustomobject]@{
                id = [IO.Path]::GetFileNameWithoutExtension($it.data)
                ru = $it.name.lines.ru
                en = $it.name.lines.en
                category = ($it.data -split '/')[2]
            }
        }
        $db | ConvertTo-Json -Depth 3 | Set-Content $DbFile -Encoding UTF8
    }
    Get-Content $DbFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

$Db = Get-ItemDb
$ById = @{}
foreach ($it in $Db) { $ById[$it.id] = $it }

if ($Find) {
    $Db | Where-Object { $_.ru -like "*$Find*" -or $_.en -like "*$Find*" } |
        Format-Table id, ru, en, category -AutoSize
    return
}

function Resolve-Item([string]$Entry) {
    if ($ById.ContainsKey($Entry)) { return $ById[$Entry] }
    $m = @($Db | Where-Object { $_.ru -eq $Entry -or $_.en -eq $Entry })
    if ($m.Count -eq 1) { return $m[0] }
    if ($m.Count -gt 1) {
        Write-Host "«$Entry»: несколько предметов ($(($m.id) -join ', ')), укажите ID" -ForegroundColor Yellow
    } else {
        Write-Host "«$Entry»: предмет не найден (попробуйте -Find)" -ForegroundColor Yellow
    }
    $null
}

# ---------- Уже отправленные лоты (чтобы не дублировать) ----------
$Seen = @{}
if (Test-Path $SeenFile) {
    (Get-Content $SeenFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $Seen[$_.Name] = [datetime]$_.Value }
}
function Save-Seen {
    $cut = (Get-Date).AddDays(-3)
    $keep = @{}
    foreach ($k in $Seen.Keys) { if ($Seen[$k] -gt $cut) { $keep[$k] = $Seen[$k].ToString('o') } }
    $keep | ConvertTo-Json | Set-Content $SeenFile -Encoding UTF8
}

function Send-Notify([string]$Text) {
    Write-Host $Text -ForegroundColor Green
    Write-Host ''
    if ($Cfg.telegram_bot_token -and $Cfg.telegram_chat_id) {
        try {
            $body = @{ chat_id = $Cfg.telegram_chat_id; text = $Text; parse_mode = 'HTML' } | ConvertTo-Json
            Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($Cfg.telegram_bot_token)/sendMessage" `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        } catch { Write-Host "Telegram: $($_.Exception.Message)" -ForegroundColor Red }
    } else {
        [Console]::Beep(880, 200)
    }
}

function Get-Median([double[]]$v) {
    $s = $v | Sort-Object
    $n = $s.Count
    if ($n % 2) { $s[[int][math]::Floor($n / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}

function Fmt([double]$x) { '{0:N0}' -f $x }

# ---------- Проверка одного предмета ----------
function Test-Item($Item) {
    $base = "$Api/$($Cfg.region)/auction/$($Item.id)"

    $hist = Get-Json "$base/history?limit=200" $Headers
    if (-not $hist) { return }
    $since = (Get-Date).AddDays(-[double]$Cfg.history_days)   # [datetime]'...Z' приводится к локальному времени
    $unit = @($hist.prices | Where-Object { $_.amount -gt 0 -and [datetime]$_.time -gt $since } |
              ForEach-Object { $_.price / $_.amount })
    if ($unit.Count -lt [int]$Cfg.min_sales) {
        Write-Host ("  {0}: мало продаж за {1} дн. ({2}), пропускаю" -f $Item.ru, $Cfg.history_days, $unit.Count) -ForegroundColor DarkGray
        return
    }
    $market = Get-Median $unit
    $netUnit = $market * (1 - $Commission)   # сколько получим с 1 шт. после комиссии

    $lots = Get-Json "$base/lots?limit=100&sort=buyout_price&order=asc" $Headers
    $found = 0
    foreach ($lot in $lots.lots) {
        if ($lot.buyoutPrice -le 0 -or $lot.amount -le 0) { continue }
        $buyUnit = $lot.buyoutPrice / $lot.amount
        if ($buyUnit -ge $netUnit) { break }   # лоты отсортированы по цене, дальше только дороже

        $profit = ($netUnit - $buyUnit) * $lot.amount
        $pct = ($netUnit - $buyUnit) / $buyUnit * 100
        if ($profit -lt [double]$Cfg.min_profit -or $pct -lt [double]$Cfg.min_profit_percent) { continue }

        $key = "$($Item.id)|$($lot.startTime)|$($lot.buyoutPrice)|$($lot.amount)"
        if ($Seen.ContainsKey($key)) { continue }
        $Seen[$key] = Get-Date
        $found++

        $ends = ([datetime]$lot.endTime).ToLocalTime().ToString('dd.MM HH:mm')
        Send-Notify (@(
            "<b>$($Item.ru)</b> ($($Item.id)) x$($lot.amount)"
            "Выкуп: $(Fmt $lot.buyoutPrice) ($(Fmt $buyUnit)/шт.)"
            "Рынок (медиана $($unit.Count) продаж): $(Fmt $market)/шт."
            "После комиссии $($Cfg.commission_percent)%: $(Fmt $netUnit)/шт."
            "Прибыль: <b>$(Fmt $profit)</b> (+$([math]::Round($pct))%)"
            "Лот до: $ends"
        ) -join "`n")
    }
    Write-Host ("  {0}: рынок {1}/шт., выгодных новых лотов: {2}" -f $Item.ru, (Fmt $market), $found)
}

# ---------- Основной цикл ----------
$Items = @($Cfg.items | ForEach-Object { Resolve-Item $_ } | Where-Object { $_ })
if (-not $Items) { Write-Host 'В config.json нет ни одного корректного предмета' -ForegroundColor Red; return }

while ($true) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Проверяю $($Items.Count) предм., регион $($Cfg.region)" -ForegroundColor Cyan
    foreach ($it in $Items) {
        try { Test-Item $it } catch { Write-Host "  $($it.ru): $($_.Exception.Message)" -ForegroundColor Red }
    }
    Save-Seen
    if ($Once) { break }
    Start-Sleep -Seconds ([int]([double]$Cfg.poll_minutes * 60))
}
