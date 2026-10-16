param(
  [string]$Config = ".\automacao_config.json",
  [string]$JsonDir = "",
  [string]$Dax1Pattern = "dax_query_base_orcamentos_funil_*.json",
  [string]$Dax2Pattern = "dax_query_base_itens_funil_*.json",
  [switch]$SkipLogin,
  [ValidateSet("Teste", "Producao")]
  [string]$Ambiente = "Teste",
  [string]$StartDate = "",
  [string]$EndDate = "",
  [switch]$NoPublicarComparativo,
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

function Get-BusinessDayCount {
  param(
    [datetime]$Start,
    [datetime]$End
  )

  $count = 0
  $cursor = $Start.Date
  while ($cursor -le $End.Date) {
    if (Test-BusinessDay -Date $cursor) {
      $count++
    }
    $cursor = $cursor.AddDays(1)
  }
  return $count
}

function Get-PreviousMonthSameDay {
  param([datetime]$Date)

  $prevBase = $Date.AddMonths(-1)
  $daysInMonth = [datetime]::DaysInMonth($prevBase.Year, $prevBase.Month)
  $day = [math]::Min($Date.Day, $daysInMonth)
  return Get-Date -Year $prevBase.Year -Month $prevBase.Month -Day $day -Hour 0 -Minute 0 -Second 0
}

function Get-EquivalentPreviousPeriod {
  param(
    [datetime]$CurrentStart,
    [datetime]$CurrentEnd,
    [datetime]$PreviousCommercialStart,
    [datetime]$PreviousCommercialEnd
  )

  $businessDays = Get-BusinessDayCount -Start $CurrentStart -End $CurrentEnd
  $previousStart = $PreviousCommercialStart.Date
  $previousEnd = $previousStart
  $accumulated = 0

  while (($accumulated -lt $businessDays) -and ($previousEnd.Date -le $PreviousCommercialEnd.Date)) {
    if (Test-BusinessDay -Date $previousEnd) {
      $accumulated++
    }
    if ($accumulated -lt $businessDays) {
      $previousEnd = $previousEnd.AddDays(1)
    }
  }

  if ($accumulated -lt $businessDays) {
    $previousEnd = $PreviousCommercialEnd.Date
  }

  return @{
    PreviousStart = $previousStart
    PreviousEnd = $previousEnd
    BusinessDays = $businessDays
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

function New-TempConfig {
  param(
    [pscustomobject]$BaseConfig,
    [string]$ArquivoRuido,
    [string]$ArquivoItens,
    [string]$StartDate,
    [string]$EndDate,
    [string]$Suffix
  )

  $tempConfig = $BaseConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $tempConfig.inputs.ruidos = $ArquivoRuido
  $tempConfig.inputs.itens = $ArquivoItens
  $tempConfig.filters.start = $StartDate
  $tempConfig.filters.end = $EndDate

  $configPath = Join-Path ".\entrada" ("automacao_config_comparativo_{0}_{1}.json" -f $Suffix, (Get-Date -Format "yyyyMMdd_HHmmss"))
  $tempConfig | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8
  return $configPath
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

Write-Host "Iniciando comparativo Funil..."
Write-Host "Timestamp da rodada: $timestamp"
Write-Host "Ambiente selecionado: $Ambiente"
Write-Host "Pasta JSON: $JsonDir"

$resolvedCurrentPeriod = Resolve-CurrentPeriod -RequestedStartDate $StartDate -RequestedEndDate $EndDate
$currentStart = $resolvedCurrentPeriod.CurrentStart
$currentEnd = $resolvedCurrentPeriod.CurrentEnd
$startDateStr = $currentStart.ToString("yyyy-MM-dd")
$endDateStr = $currentEnd.ToString("yyyy-MM-dd")
$currentCommercialStart = $resolvedCurrentPeriod.CommercialStart
$currentCommercialEnd = $resolvedCurrentPeriod.CommercialEnd
$previousCommercialReference = $currentCommercialStart.AddDays(-1)
$previousCommercialPeriod = Resolve-CommercialPeriod -ReferenceDate $previousCommercialReference
$equivalent = Get-EquivalentPreviousPeriod `
  -CurrentStart $currentStart `
  -CurrentEnd $currentEnd `
  -PreviousCommercialStart $previousCommercialPeriod.CommercialStart `
  -PreviousCommercialEnd $previousCommercialPeriod.CommercialEnd

$previousStartStr = $equivalent.PreviousStart.ToString("yyyy-MM-dd")
$previousEndStr = $equivalent.PreviousEnd.ToString("yyyy-MM-dd")
$diasUteis = [int]$equivalent.BusinessDays
$currentCommercialStartStr = $currentCommercialStart.ToString("yyyy-MM-dd")
$currentCommercialEndStr = $currentCommercialEnd.ToString("yyyy-MM-dd")
$previousCommercialStartStr = $previousCommercialPeriod.CommercialStart.ToString("yyyy-MM-dd")
$previousCommercialEndStr = $previousCommercialPeriod.CommercialEnd.ToString("yyyy-MM-dd")

if ($resolvedCurrentPeriod.UsedDefault) {
  Write-Host "Periodo atual nao informado. Usando padrao: mes comercial ate ontem."
}
Write-Host "Mes comercial atual:" ($currentCommercialStart.ToString("dd/MM/yyyy")) "a" ($currentCommercialEnd.ToString("dd/MM/yyyy"))
Write-Host "Periodo atual:" ($currentStart.ToString("dd/MM/yyyy")) "a" ($currentEnd.ToString("dd/MM/yyyy"))
Write-Host "Mes comercial anterior:" ($previousCommercialPeriod.CommercialStart.ToString("dd/MM/yyyy")) "a" ($previousCommercialPeriod.CommercialEnd.ToString("dd/MM/yyyy"))
Write-Host "Periodo anterior equivalente:" ($equivalent.PreviousStart.ToString("dd/MM/yyyy")) "a" ($equivalent.PreviousEnd.ToString("dd/MM/yyyy"))
Write-Host "Dias uteis considerados:" $diasUteis

$runGuardKey = "ambiente={0};start={1};end={2};prevstart={3};prevend={4};nopublicar={5}" -f $Ambiente, $startDateStr, $endDateStr, $previousStartStr, $previousEndStr, [bool]$NoPublicarComparativo
if (-not (Start-RunGuard -Name "rodar_fluxo_comparativo_funil" -Key $runGuardKey -Force:$ForceRun)) {
  return
}
$runGuardSucceeded = $false

if ($SkipLogin) {
  Write-Host "SkipLogin informado. No fluxo atual baseado em Power Automate esse parametro nao e necessario, mas foi mantido por compatibilidade."
}

$comparativoJsonDir = $null
if ($configObj.alerts.environments -and $configObj.alerts.environments.$ambienteKey) {
  $comparativoJsonDir = $configObj.alerts.environments.$ambienteKey.comparativo_json_dir
}
$dashboardPublishDir = $configObj.paths.dashboard_analise_funil_publish_dir

$dax1Json = $null
$dax2Json = $null
$baseMarkerPath = ".\.ultima_base_funil.json"
if (Test-Path $baseMarkerPath) {
  try {
    $baseMarker = Get-Content $baseMarkerPath -Raw | ConvertFrom-Json
    $markerAge = (Get-Date) - [datetime]$baseMarker.timestamp
    if ($markerAge.TotalHours -le 6 -and (Test-Path $baseMarker.dax1) -and (Test-Path $baseMarker.dax2)) {
      $dax1Json = $baseMarker.dax1
      $dax2Json = $baseMarker.dax2
      Write-Host "Reaproveitando a mesma base do Insight Funil (rodada de $($baseMarker.timestamp))."
    }
  }
  catch {
    Write-Host "Nao foi possivel ler .ultima_base_funil.json. Buscando arquivo mais recente."
  }
}
if (-not $dax1Json -or -not $dax2Json) {
  Write-Host "Nenhuma base recente do Insight Funil encontrada. Buscando o arquivo mais recente diretamente."
  $dax1Json = Get-LatestFile -Directory $JsonDir -Pattern $Dax1Pattern
  $dax2Json = Get-LatestFile -Directory $JsonDir -Pattern $Dax2Pattern
}

Write-Host "JSON DAX 1:" $dax1Json
Write-Host "JSON DAX 2:" $dax2Json

$entradaDir = ".\entrada"
if (-not (Test-Path $entradaDir)) {
  New-Item -ItemType Directory -Path $entradaDir | Out-Null
}

$arquivoRuido = Join-Path $entradaDir ("dax_orcamentos_tratado_comparativo_power_automate_{0}.xlsx" -f $timestamp)
$arquivoItens = Join-Path $entradaDir ("dax_itens_tratado_comparativo_power_automate_{0}.xlsx" -f $timestamp)

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

$configTempA = $null
$configTempB = $null

try {
  $configTempA = New-TempConfig -BaseConfig $configObj -ArquivoRuido $arquivoRuido -ArquivoItens $arquivoItens -StartDate $previousStartStr -EndDate $previousEndStr -Suffix "periodo_a"
  $configTempB = New-TempConfig -BaseConfig $configObj -ArquivoRuido $arquivoRuido -ArquivoItens $arquivoItens -StartDate $startDateStr -EndDate $endDateStr -Suffix "periodo_b"

  $runAStart = Get-Date
  Write-Host "Executando pipeline do periodo anterior..."
  $pipelineArgsA = @(
    ".\automacao_pipeline.py",
    "--config", $configTempA
  )
  Invoke-Python -PythonExecutable $pythonExe -Arguments $pipelineArgsA

  $oportunidadesA = Get-LatestFileAfter -Directory ".\historico" -Pattern "oportunidades_reais_auto_*.xlsx" -After $runAStart
  $resumoA = Join-Path ".\alertas" ("resumo_insight_periodo_a_{0}.json" -f $timestamp)

  Write-Host "Gerando resumo do periodo anterior..."
  Invoke-Python -PythonExecutable $pythonExe -Arguments @(
    ".\gerar_resumo_insight_json.py",
    "--oportunidades", $oportunidadesA,
    "--entrada-dax1", $arquivoRuido,
    "--itens", $arquivoItens,
    "--start-date", $previousStartStr,
    "--end-date", $previousEndStr,
    "--commercial-start-date", $previousCommercialStartStr,
    "--commercial-end-date", $previousCommercialEndStr,
    "-o", $resumoA
  )

  $runBStart = Get-Date
  Write-Host "Executando pipeline do periodo atual..."
  $pipelineArgsB = @(
    ".\automacao_pipeline.py",
    "--config", $configTempB
  )
  Invoke-Python -PythonExecutable $pythonExe -Arguments $pipelineArgsB

  $oportunidadesB = Get-LatestFileAfter -Directory ".\historico" -Pattern "oportunidades_reais_auto_*.xlsx" -After $runBStart
  $resumoB = Join-Path ".\alertas" ("resumo_insight_periodo_atual_{0}.json" -f $timestamp)

  Write-Host "Gerando resumo do periodo atual..."
  Invoke-Python -PythonExecutable $pythonExe -Arguments @(
    ".\gerar_resumo_insight_json.py",
    "--oportunidades", $oportunidadesB,
    "--entrada-dax1", $arquivoRuido,
    "--itens", $arquivoItens,
    "--start-date", $startDateStr,
    "--end-date", $endDateStr,
    "--commercial-start-date", $currentCommercialStartStr,
    "--commercial-end-date", $currentCommercialEndStr,
    "-o", $resumoB
  )

  $comparativoLocal = Join-Path ".\alertas" ("comparativo_resumo_insight_card_teams_{0}.json" -f $timestamp)
  $slideUpdaterScript = ".\atualizar_dashboard_comparativo_js.py"

  Write-Host "Gerando comparativo consolidado..."
  Invoke-Python -PythonExecutable $pythonExe -Arguments @(
    ".\gerar_comparativo_resumo_insight_periodos.py",
    "--arquivo-a", $resumoA,
    "--arquivo-b", $resumoB,
    "--dias-uteis-a", ([string]$diasUteis),
    "--dias-uteis-b", ([string]$diasUteis),
    "-o", $comparativoLocal
  )

  Write-Host "Resumo periodo anterior:" $resumoA
  Write-Host "Resumo periodo atual:" $resumoB
  Write-Host "Comparativo final:" $comparativoLocal

  if (Test-Path $slideUpdaterScript) {
    Write-Host "Atualizando slide interativo de Win Rate..."
    Invoke-Python -PythonExecutable $pythonExe -Arguments @(
      $slideUpdaterScript,
      "-i", $comparativoLocal
    )
  }
  else {
    Write-Host "Script de atualizacao do slide nao encontrado. Seguindo sem atualizar o HTML interativo."
  }

  $comparativoDashboardJs = ".\Dashboard Analise Funil\data\comparativo_dashboard.js"
  if ($NoPublicarDashboard) {
    Write-Host "NoPublicarDashboard informado. Slide de comparativo mantido apenas localmente."
  }
  elseif ($dashboardPublishDir) {
    if (-not (Test-Path $dashboardPublishDir)) {
      throw "Diretorio de dashboard_analise_funil_publish_dir nao encontrado: $dashboardPublishDir"
    }
    if (Test-Path $comparativoDashboardJs) {
      $comparativoDashboardJsDestino = Join-Path $dashboardPublishDir "comparativo_dashboard.js"
      Copy-Item $comparativoDashboardJs $comparativoDashboardJsDestino -Force
      Write-Host "Slide de comparativo publicado para:" $comparativoDashboardJsDestino
    }
    else {
      Write-Host "Arquivo $comparativoDashboardJs nao encontrado. Slide de comparativo nao foi publicado."
    }
  }
  else {
    Write-Host "dashboard_analise_funil_publish_dir nao configurado. Dashboard publico nao foi atualizado."
  }

  if ($NoPublicarComparativo) {
    Write-Host "NoPublicarComparativo informado. Comparativo mantido apenas localmente em:" $comparativoLocal
  }
  elseif ($comparativoJsonDir) {
    if (-not (Test-Path $comparativoJsonDir)) {
      throw "Diretorio de comparativo_json_dir nao encontrado: $comparativoJsonDir"
    }
    $comparativoDestino = Join-Path $comparativoJsonDir (Split-Path $comparativoLocal -Leaf)
    Copy-Item $comparativoLocal $comparativoDestino -Force
    Write-Host "Comparativo copiado para:" $comparativoDestino
    Write-Host "Power Automate deve assumir a postagem no Teams a partir desse arquivo."
  }
  else {
    Write-Host "comparativo_json_dir nao configurado. Nenhum envio automatico ao Teams sera feito."
  }
  $runGuardSucceeded = $true
}
finally {
  foreach ($tempFile in @($configTempA, $configTempB)) {
    if ($tempFile -and (Test-Path $tempFile)) {
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
  }
  Complete-RunGuard -Succeeded $runGuardSucceeded
}

$fimExecucao = Get-Date
$duracao = $fimExecucao - $inicioExecucao
Write-Host ""
Write-Host "Comparativo Funil concluido."
Write-Host ("Inicio: {0}" -f $inicioExecucao.ToString("dd/MM/yyyy HH:mm:ss"))
Write-Host ("Fim:    {0}" -f $fimExecucao.ToString("dd/MM/yyyy HH:mm:ss"))
Write-Host ("Tempo total: {0}min {1}s" -f $duracao.Minutes, $duracao.Seconds)
