param(
  [string]$Config = ".\automacao_config.json",
  [string]$JsonDir = "",
  [string]$Dax1Pattern = "dax_query_base_orcamentos_funil_*.json",
  [string]$Dax2Pattern = "dax_query_base_itens_funil_*.json",
  [ValidateSet("Teste", "Producao")]
  [string]$Ambiente = "Teste",
  [string]$StartDate = "",
  [string]$EndDate = "",
  [switch]$NoSharePoint,
  [switch]$NoPublicarDashboard,
  [switch]$ForceRun
)

$ErrorActionPreference = "Stop"

function ConvertTo-RunGuardName {
  param([string]$Value)
  return (($Value -replace '[^A-Za-z0-9_.-]', '_') -replace '_+', '_').Trim('_')
}

function Start-RunGuard {
  param(
    [string]$Name,
    [string]$Key,
    [int]$DuplicateWindowMinutes = 5,
    [switch]$Force
  )

  $guardDir = Join-Path $PSScriptRoot ".run_guard"
  if (-not (Test-Path $guardDir)) {
    New-Item -ItemType Directory -Path $guardDir | Out-Null
  }

  $safeName = ConvertTo-RunGuardName ("{0}_{1}" -f $Name, $Key)
  $script:RunGuardLockPath = Join-Path $guardDir ("{0}.lock" -f $safeName)
  $script:RunGuardMarkerPath = Join-Path $guardDir ("{0}.last" -f $safeName)

  if (-not $Force) {
    if (Test-Path $script:RunGuardLockPath) {
      $lockAge = (Get-Date) - (Get-Item $script:RunGuardLockPath).LastWriteTime
      if ($lockAge.TotalHours -lt 6) {
        Write-Host "Execucao identica ja esta em andamento. Bloqueando duplicidade."
        Write-Host "Use -ForceRun se realmente quiser ignorar a trava."
        return $false
      }
      Write-Host "Lock antigo encontrado. Removendo trava pendente antes de continuar."
      Remove-Item $script:RunGuardLockPath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $script:RunGuardMarkerPath) {
      $lastRun = Get-Item $script:RunGuardMarkerPath
      $age = (Get-Date) - $lastRun.LastWriteTime
      if ($age.TotalMinutes -lt $DuplicateWindowMinutes) {
        Write-Host ("Execucao identica concluida ha {0:N1} min. Bloqueando possivel duplicidade." -f $age.TotalMinutes)
        Write-Host "Use -ForceRun se realmente quiser rodar novamente."
        return $false
      }
    }
  }

  Set-Content -Path $script:RunGuardLockPath -Value ("Inicio={0}`nKey={1}" -f (Get-Date).ToString("s"), $Key) -Encoding UTF8
  return $true
}

function Complete-RunGuard {
  param([bool]$Succeeded)

  if ($script:RunGuardLockPath -and (Test-Path $script:RunGuardLockPath)) {
    Remove-Item $script:RunGuardLockPath -Force -ErrorAction SilentlyContinue
  }
  if ($Succeeded -and $script:RunGuardMarkerPath) {
    Set-Content -Path $script:RunGuardMarkerPath -Value ("Fim={0}" -f (Get-Date).ToString("s")) -Encoding UTF8
  }
}

function Get-EasterSunday {
  param([int]$Year)

  $a = $Year % 19
  $b = [math]::Floor($Year / 100)
  $c = $Year % 100
  $d = [math]::Floor($b / 4)
  $e = $b % 4
  $f = [math]::Floor(($b + 8) / 25)
  $g = [math]::Floor(($b - $f + 1) / 3)
  $h = (19 * $a + $b - $d - $g + 15) % 30
  $i = [math]::Floor($c / 4)
  $k = $c % 4
  $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
  $m = [math]::Floor(($a + 11 * $h + 22 * $l) / 451)
  $month = [math]::Floor(($h + $l - 7 * $m + 114) / 31)
  $day = (($h + $l - 7 * $m + 114) % 31) + 1
  return Get-Date -Year $Year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
}

function Get-BrazilNationalHolidays {
  param([int]$Year)

  $easter = Get-EasterSunday -Year $Year
  return @(
    (Get-Date -Year $Year -Month 1 -Day 1)
    ($easter.AddDays(-2))
    (Get-Date -Year $Year -Month 4 -Day 21)
    (Get-Date -Year $Year -Month 5 -Day 1)
    (Get-Date -Year $Year -Month 9 -Day 7)
    (Get-Date -Year $Year -Month 10 -Day 12)
    (Get-Date -Year $Year -Month 11 -Day 2)
    (Get-Date -Year $Year -Month 11 -Day 15)
    (Get-Date -Year $Year -Month 11 -Day 20)
    (Get-Date -Year $Year -Month 12 -Day 25)
  )
}

function Test-BusinessDay {
  param([datetime]$Date)

  if ($Date.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
    return $false
  }

  $holidays = Get-BrazilNationalHolidays -Year $Date.Year
  return -not ($holidays | Where-Object { $_.Date -eq $Date.Date } | Select-Object -First 1)
}

function Get-PenultimateBusinessDayOfMonth {
  param(
    [int]$Year,
    [int]$Month
  )

  $daysInMonth = [datetime]::DaysInMonth($Year, $Month)
  $cursor = Get-Date -Year $Year -Month $Month -Day $daysInMonth -Hour 0 -Minute 0 -Second 0
  $businessDays = @()

  while ($cursor.Month -eq $Month) {
    if (Test-BusinessDay -Date $cursor) {
      $businessDays += $cursor.Date
      if ($businessDays.Count -eq 2) {
        return $businessDays[1]
      }
    }
    $cursor = $cursor.AddDays(-1)
  }

  throw "Nao foi possivel identificar o penultimo dia util de $Month/$Year."
}

function Resolve-CommercialPeriod {
  param([datetime]$ReferenceDate)

  $currentClose = Get-PenultimateBusinessDayOfMonth -Year $ReferenceDate.Year -Month $ReferenceDate.Month

  if ($ReferenceDate.Date -le $currentClose.Date) {
    $commercialEnd = $currentClose
    $previousMonthDate = $ReferenceDate.AddMonths(-1)
    $previousClose = Get-PenultimateBusinessDayOfMonth -Year $previousMonthDate.Year -Month $previousMonthDate.Month
    $commercialStart = $previousClose.AddDays(1)
  }
  else {
    $commercialStart = $currentClose.AddDays(1)
    $nextMonthDate = $ReferenceDate.AddMonths(1)
    $commercialEnd = Get-PenultimateBusinessDayOfMonth -Year $nextMonthDate.Year -Month $nextMonthDate.Month
  }

  return @{
    CommercialStart = $commercialStart.Date
    CommercialEnd = $commercialEnd.Date
  }
}

function Resolve-CurrentPeriod {
  param(
    [string]$RequestedStartDate,
    [string]$RequestedEndDate
  )

  if ($RequestedStartDate -and $RequestedEndDate) {
    $currentStart = [datetime]::ParseExact($RequestedStartDate, "yyyy-MM-dd", $null)
    $currentEnd = [datetime]::ParseExact($RequestedEndDate, "yyyy-MM-dd", $null)
    $commercialPeriod = Resolve-CommercialPeriod -ReferenceDate $currentEnd
    return @{
      CurrentStart = $currentStart
      CurrentEnd = $currentEnd
      CommercialStart = $commercialPeriod.CommercialStart
      CommercialEnd = $commercialPeriod.CommercialEnd
      UsedDefault = $false
    }
  }

  if (($RequestedStartDate -and -not $RequestedEndDate) -or (-not $RequestedStartDate -and $RequestedEndDate)) {
    throw "Informe StartDate e EndDate juntos no formato yyyy-MM-dd ou deixe ambos vazios."
  }

  $yesterday = (Get-Date).Date.AddDays(-1)
  $commercialPeriod = Resolve-CommercialPeriod -ReferenceDate $yesterday
  return @{
    CurrentStart = $commercialPeriod.CommercialStart
    CurrentEnd = $yesterday
    CommercialStart = $commercialPeriod.CommercialStart
    CommercialEnd = $commercialPeriod.CommercialEnd
    UsedDefault = $true
  }
}

function Get-LatestFile {
  param(
    [string]$Directory,
    [string]$Pattern
  )

  if (-not (Test-Path $Directory)) {
    throw "Diretorio nao encontrado: $Directory"
  }

  $item = Get-ChildItem -LiteralPath $Directory -Filter $Pattern -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $item) {
    throw "Arquivo nao encontrado em $Directory com o padrao $Pattern"
  }

  return $item.FullName
}

function Get-LatestFileAfter {
  param(
    [string]$Directory,
    [string]$Pattern,
    [datetime]$After
  )

  $candidates = Get-ChildItem $Directory -Filter $Pattern |
    Where-Object { $_.LastWriteTime -ge $After } |
    Sort-Object LastWriteTime -Descending

  if (-not $candidates) {
    throw "Nenhum arquivo encontrado em $Directory com o padrao $Pattern apos $After"
  }

  return $candidates[0].FullName
}

function Invoke-Python {
  param(
    [string]$PythonExecutable,
    [string[]]$Arguments
  )

  $pythonParts = $PythonExecutable -split '\s+'
  $pythonCmd = $pythonParts[0]
  $pythonCmdArgs = @()
  if ($pythonParts.Length -gt 1) {
    $pythonCmdArgs = $pythonParts[1..($pythonParts.Length - 1)]
  }

  & $pythonCmd @pythonCmdArgs @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Comando Python falhou: $($Arguments -join ' ')"
  }
}

$inicioExecucao = Get-Date
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ambienteKey = $Ambiente.ToLowerInvariant()

$configObj = Get-Content $Config -Raw | ConvertFrom-Json
$pythonExe = $configObj.python_executable
if (-not $pythonExe) { $pythonExe = "py -3.12" }

if (-not $JsonDir) { $JsonDir = $configObj.paths.json_dir }
if (-not $JsonDir) {
  throw "Informe -JsonDir ou configure 'paths.json_dir' em $Config."
}

Write-Host "Iniciando fluxo Power Automate -> Python..."
Write-Host "Timestamp da rodada: $timestamp"
Write-Host "Ambiente selecionado: $Ambiente"
Write-Host "Pasta JSON: $JsonDir"

$resolvedCurrentPeriod = Resolve-CurrentPeriod -RequestedStartDate $StartDate -RequestedEndDate $EndDate
$effectiveStartDate = $resolvedCurrentPeriod.CurrentStart.ToString("yyyy-MM-dd")
$effectiveEndDate = $resolvedCurrentPeriod.CurrentEnd.ToString("yyyy-MM-dd")
$commercialStartDate = $resolvedCurrentPeriod.CommercialStart.ToString("yyyy-MM-dd")
$commercialEndDate = $resolvedCurrentPeriod.CommercialEnd.ToString("yyyy-MM-dd")

if ($resolvedCurrentPeriod.UsedDefault) {
  Write-Host "Periodo nao informado. Usando padrao: mes comercial ate ontem."
}
Write-Host "Mes comercial:" ($resolvedCurrentPeriod.CommercialStart.ToString("dd/MM/yyyy")) "a" ($resolvedCurrentPeriod.CommercialEnd.ToString("dd/MM/yyyy"))
Write-Host "Periodo do insight:" ($resolvedCurrentPeriod.CurrentStart.ToString("dd/MM/yyyy")) "a" ($resolvedCurrentPeriod.CurrentEnd.ToString("dd/MM/yyyy"))

$runGuardKey = "ambiente={0};start={1};end={2};nosharepoint={3}" -f $Ambiente, $effectiveStartDate, $effectiveEndDate, [bool]$NoSharePoint
if (-not (Start-RunGuard -Name "rodar_fluxo_funil" -Key $runGuardKey -Force:$ForceRun)) {
  return
}
$runGuardSucceeded = $false

$insightJsonDir = $configObj.alerts.insight_json_dir
if ($configObj.alerts.environments -and $configObj.alerts.environments.$ambienteKey) {
  if ($configObj.alerts.environments.$ambienteKey.insight_json_dir) {
    $insightJsonDir = $configObj.alerts.environments.$ambienteKey.insight_json_dir
  }
}
$dashboardPublishDir = $configObj.paths.dashboard_analise_funil_publish_dir

$dax1Json = Get-LatestFile -Directory $JsonDir -Pattern $Dax1Pattern
$dax2Json = Get-LatestFile -Directory $JsonDir -Pattern $Dax2Pattern

Write-Host "JSON DAX 1:" $dax1Json
Write-Host "JSON DAX 2:" $dax2Json

$baseMarker = @{
  dax1 = $dax1Json
  dax2 = $dax2Json
  timestamp = (Get-Date).ToString("s")
  ambiente = $Ambiente
}
$baseMarker | ConvertTo-Json | Set-Content -Path ".\.ultima_base_funil.json" -Encoding UTF8

$entradaDir = ".\entrada"
if (-not (Test-Path $entradaDir)) {
  New-Item -ItemType Directory -Path $entradaDir | Out-Null
}

$arquivoRuido = Join-Path $entradaDir ("dax_orcamentos_tratado_power_automate_{0}.xlsx" -f $timestamp)
$arquivoItens = Join-Path $entradaDir ("dax_itens_tratado_power_automate_{0}.xlsx" -f $timestamp)

Write-Host "Convertendo DAX 1..."
Invoke-Python -PythonExecutable $pythonExe -Arguments @(
  ".\tratar_dax_orcamentos_json_power_automate.py",
  "-i", $dax1Json,
  "-o", $arquivoRuido
)

Write-Host "Convertendo DAX 2..."
Invoke-Python -PythonExecutable $pythonExe -Arguments @(
  ".\tratar_dax_itens_json_power_automate.py",
  "-i", $dax2Json,
  "-o", $arquivoItens
)

Write-Host "Arquivo DAX 1 tratado:" $arquivoRuido
Write-Host "Arquivo DAX 2 tratado:" $arquivoItens

$configObj.inputs.ruidos = $arquivoRuido
$configObj.inputs.itens = $arquivoItens
$configObj.filters.start = $effectiveStartDate
$configObj.filters.end = $effectiveEndDate

$configTemp = Join-Path $entradaDir ("automacao_config_power_automate_{0}.json" -f $timestamp)
$configObj | ConvertTo-Json -Depth 20 | Set-Content $configTemp -Encoding UTF8

try {
  Write-Host "Executando pipeline..."
  $runStep1Start = Get-Date
  $pipelineArgs = @(
    ".\automacao_pipeline.py",
    "--config", $configTemp
  )
  Invoke-Python -PythonExecutable $pythonExe -Arguments $pipelineArgs

  $oportunidadesGerado = Get-LatestFileAfter -Directory ".\historico" -Pattern "oportunidades_reais_auto_*.xlsx" -After $runStep1Start
  $insightJsonLocal = Join-Path ".\alertas" ("resumo_insight_card_teams_{0}.json" -f $timestamp)
  $slideResumoUpdaterScript = ".\atualizar_dashboard_resumo_insight_js.py"

  Write-Host "Gerando JSON de insight..."
  $resumoArgs = @(
    ".\gerar_resumo_insight_json.py",
    "--oportunidades", $oportunidadesGerado,
    "--entrada-dax1", $arquivoRuido,
    "--itens", $arquivoItens,
    "--start-date", $effectiveStartDate,
    "--end-date", $effectiveEndDate,
    "--commercial-start-date", $commercialStartDate,
    "--commercial-end-date", $commercialEndDate,
    "-o", $insightJsonLocal
  )

  Invoke-Python -PythonExecutable $pythonExe -Arguments $resumoArgs

  if (Test-Path $slideResumoUpdaterScript) {
    Write-Host "Atualizando slide interativo - Resumo Atual..."
    Invoke-Python -PythonExecutable $pythonExe -Arguments @(
      $slideResumoUpdaterScript,
      "-i", $insightJsonLocal
    )
  }
  else {
    Write-Host "Script de atualizacao do slide de resumo nao encontrado. Seguindo sem atualizar o HTML interativo."
  }

  $resumoDashboardJs = ".\Dashboard Analise Funil\data\resumo_insight_dashboard.js"
  if ($NoPublicarDashboard) {
    Write-Host "NoPublicarDashboard informado. Slide de resumo mantido apenas localmente."
  }
  elseif ($dashboardPublishDir) {
    if (-not (Test-Path $dashboardPublishDir)) {
      throw "Diretorio de dashboard_analise_funil_publish_dir nao encontrado: $dashboardPublishDir"
    }
    if (Test-Path $resumoDashboardJs) {
      $resumoDashboardJsDestino = Join-Path $dashboardPublishDir "resumo_insight_dashboard.js"
      Copy-Item $resumoDashboardJs $resumoDashboardJsDestino -Force
      Write-Host "Slide de resumo publicado para:" $resumoDashboardJsDestino
    }
    else {
      Write-Host "Arquivo $resumoDashboardJs nao encontrado. Slide de resumo nao foi publicado."
    }
  }
  else {
    Write-Host "dashboard_analise_funil_publish_dir nao configurado. Dashboard publico nao foi atualizado."
  }

  $topItensJsonLocal = Join-Path ".\alertas" ("top_itens_card_teams_{0}.json" -f $timestamp)
  Write-Host "Gerando JSON de top itens..."
  Invoke-Python -PythonExecutable $pythonExe -Arguments @(
    ".\gerar_top_itens_json.py",
    "-i", $arquivoRuido,
    "-it", $arquivoItens,
    "--start", $effectiveStartDate,
    "--end", $effectiveEndDate,
    "-o", $topItensJsonLocal
  )

  $topItensUpdaterScript = ".\atualizar_dashboard_top_itens_js.py"
  if (Test-Path $topItensUpdaterScript) {
    Write-Host "Atualizando slide interativo - Top Itens..."
    Invoke-Python -PythonExecutable $pythonExe -Arguments @(
      $topItensUpdaterScript,
      "-i", $topItensJsonLocal
    )
  }
  else {
    Write-Host "Script de atualizacao do slide de top itens nao encontrado. Seguindo sem atualizar o HTML interativo."
  }

  $topItensDashboardJs = ".\Dashboard Analise Funil\data\top_itens_dashboard.js"
  if ($NoPublicarDashboard) {
    Write-Host "NoPublicarDashboard informado. Slide de top itens mantido apenas localmente."
  }
  elseif ($dashboardPublishDir) {
    if (-not (Test-Path $dashboardPublishDir)) {
      throw "Diretorio de dashboard_analise_funil_publish_dir nao encontrado: $dashboardPublishDir"
    }
    if (Test-Path $topItensDashboardJs) {
      $topItensDashboardJsDestino = Join-Path $dashboardPublishDir "top_itens_dashboard.js"
      Copy-Item $topItensDashboardJs $topItensDashboardJsDestino -Force
      Write-Host "Slide de top itens publicado para:" $topItensDashboardJsDestino
    }
    else {
      Write-Host "Arquivo $topItensDashboardJs nao encontrado. Slide de top itens nao foi publicado."
    }
  }
  else {
    Write-Host "dashboard_analise_funil_publish_dir nao configurado. Slide de top itens nao foi publicado."
  }

  if ($NoSharePoint) {
    Write-Host "NoSharePoint informado. JSON de insight mantido apenas localmente em:" $insightJsonLocal
  }
  elseif ($insightJsonDir) {
    if (-not (Test-Path $insightJsonDir)) {
      throw "Diretorio de insight_json_dir nao encontrado: $insightJsonDir"
    }
    $insightJsonDestino = Join-Path $insightJsonDir (Split-Path $insightJsonLocal -Leaf)
    Copy-Item $insightJsonLocal $insightJsonDestino -Force
    Write-Host "JSON de insight copiado para:" $insightJsonDestino
    Write-Host "Power Automate deve assumir a postagem no Teams a partir desse arquivo."
  }
  else {
    Write-Host "insight_json_dir nao configurado. Nenhum envio automatico ao Teams sera feito."
  }
  $runGuardSucceeded = $true
}
finally {
  if (Test-Path $configTemp) {
    Remove-Item $configTemp -Force -ErrorAction SilentlyContinue
  }
  Complete-RunGuard -Succeeded $runGuardSucceeded
}

$fimExecucao = Get-Date
$duracao = $fimExecucao - $inicioExecucao
Write-Host ""
Write-Host "Fluxo Power Automate -> Python concluido."
Write-Host ("Inicio: {0}" -f $inicioExecucao.ToString("dd/MM/yyyy HH:mm:ss"))
Write-Host ("Fim:    {0}" -f $fimExecucao.ToString("dd/MM/yyyy HH:mm:ss"))
Write-Host ("Tempo total: {0}min {1}s" -f $duracao.Minutes, $duracao.Seconds)
