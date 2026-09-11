param(
  [ValidateSet("Teste", "Producao")]
  [string]$Ambiente = "Producao"
)

Set-Location -Path $PSScriptRoot

function Arquivar-SnapshotMensalSeFechou {
  param([datetime]$Since)

  # Usa a mesma regra de mes comercial (penultimo dia util) ja validada em
  # analisar_evolucao_diaria_item.py, em vez de duplicar o calculo de
  # feriados/dias uteis aqui em PowerShell. O Fluxo 1/2 rodam com dados ate
  # "ontem" - se ontem foi exatamente o dia de fechamento do mes comercial,
  # a rodada de hoje e a que fecha esse mes, e arquivamos as 3 fontes.
  $yesterday = (Get-Date).Date.AddDays(-1)
  $pyCode = @"
from datetime import date
from analisar_evolucao_diaria_item import resolve_commercial_period
ref = date($($yesterday.Year), $($yesterday.Month), $($yesterday.Day))
start, end = resolve_commercial_period(ref)
print(start.isoformat())
print(end.isoformat())
print('1' if end == ref else '0')
"@
  $resultado = & py -3.12 -c $pyCode
  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao calcular o mes comercial via analisar_evolucao_diaria_item.py"
  }

  $linhas = $resultado | Where-Object { $_ -ne '' }
  $commercialStart = $linhas[0]
  $commercialEnd = $linhas[1]
  $mesFechou = $linhas[2] -eq '1'

  if (-not $mesFechou) {
    Write-Host "Mes comercial ainda nao fechou (ultimo dia com dado: $($yesterday.ToString('dd/MM/yyyy'))). Nenhum snapshot arquivado hoje."
    return
  }

  Write-Host "Mes comercial fechou ontem ($commercialEnd). Arquivando snapshot das 3 abas..."

  $snapshotLabel = $commercialEnd.Substring(0, 7)
  $snapshotDir = Join-Path ".\historico\snapshots_mensais" $snapshotLabel
  if (-not (Test-Path $snapshotDir)) {
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
  }

  $fontes = @(
    @{ Padrao = "resumo_insight_card_teams_*.json"; Destino = "resumo_atual.json" }
    @{ Padrao = "top_itens_card_teams_*.json"; Destino = "top_itens.json" }
    @{ Padrao = "comparativo_resumo_insight_card_teams_*.json"; Destino = "comparativo.json" }
  )

  $faltando = @()
  foreach ($fonte in $fontes) {
    $arquivo = Get-ChildItem ".\alertas" -Filter $fonte.Padrao -File |
      Where-Object { $_.LastWriteTime -ge $Since } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($arquivo) {
      Copy-Item $arquivo.FullName (Join-Path $snapshotDir $fonte.Destino) -Force
    }
    else {
      $faltando += $fonte.Padrao
    }
  }

  if ($faltando.Count -gt 0) {
    Write-Host "AVISO: nao encontrei arquivos gerados nesta rodada para: $($faltando -join ', '). Snapshot ficou incompleto em $snapshotDir"
    return
  }

  $meta = [ordered]@{
    mes_comercial     = $snapshotLabel
    periodo_comercial = "$commercialStart a $commercialEnd"
    gerado_em         = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  } | ConvertTo-Json
  Set-Content -Path (Join-Path $snapshotDir "meta.json") -Value $meta -Encoding UTF8

  Write-Host "Snapshot mensal arquivado em: $snapshotDir"

  Atualizar-HistoricoMensalConsolidado -Since $Since -SnapshotLabel $snapshotLabel
}

function Atualizar-HistoricoMensalConsolidado {
  param(
    [datetime]$Since,
    [string]$SnapshotLabel
  )

  # A linha do mes que acabou de fechar cabe folgada na janela rolante da
  # extracao diaria (~2-3 meses), entao reaproveitamos os arquivos DAX que o
  # Fluxo 1 acabou de tratar em vez de exigir uma extracao mais ampla. O
  # historico consolidado so cresce: cada rodada faz upsert por mes, nunca
  # duplica.
  $configObj = Get-Content ".\automacao_config.json" -Raw | ConvertFrom-Json
  $pythonExe = $configObj.python_executable
  if (-not $pythonExe) { $pythonExe = "py -3.12" }
  $pythonParts = $pythonExe -split '\s+'
  $pythonCmd = $pythonParts[0]
  $pythonCmdArgs = @()
  if ($pythonParts.Length -gt 1) { $pythonCmdArgs = $pythonParts[1..($pythonParts.Length - 1)] }

  $arquivoRuido = Get-ChildItem ".\entrada" -Filter "dax_orcamentos_tratado_power_automate_*.xlsx" -File |
    Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $arquivoItens = Get-ChildItem ".\entrada" -Filter "dax_itens_tratado_power_automate_*.xlsx" -File |
    Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

  if (-not $arquivoRuido -or -not $arquivoItens) {
    Write-Host "AVISO: nao encontrei os arquivos DAX tratados desta rodada. Historico consolidado nao foi atualizado."
    return
  }

  & $pythonCmd @pythonCmdArgs ".\gerar_resumo_mensal_funil.py" -i $arquivoRuido.FullName -it $arquivoItens.FullName -o "resumo_mensal_fechamento"
  if ($LASTEXITCODE -ne 0) { throw "gerar_resumo_mensal_funil.py falhou ao processar o fechamento de $SnapshotLabel." }

  $resumoMensalGerado = Get-ChildItem ".\historico" -Filter "resumo_mensal_fechamento_*.xlsx" -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $resumoMensalGerado) {
    throw "gerar_resumo_mensal_funil.py nao produziu o arquivo esperado para o fechamento de $SnapshotLabel."
  }

  & $pythonCmd @pythonCmdArgs ".\atualizar_historico_mensal_consolidado.py" -i $resumoMensalGerado.FullName
  if ($LASTEXITCODE -ne 0) { throw "atualizar_historico_mensal_consolidado.py falhou." }

  & $pythonCmd @pythonCmdArgs ".\gerar_historico_mensal_json.py" -i ".\historico\historico_mensal_consolidado.xlsx" --meses 12
  if ($LASTEXITCODE -ne 0) { throw "gerar_historico_mensal_json.py falhou." }

  & $pythonCmd @pythonCmdArgs ".\atualizar_dashboard_historico_js.py"
  if ($LASTEXITCODE -ne 0) { throw "atualizar_dashboard_historico_js.py falhou." }

  $historicoDashboardJs = ".\Dashboard Analise Funil\data\historico_dashboard.js"
  $dashboardPublishDir = $configObj.paths.dashboard_analise_funil_publish_dir
  if ($dashboardPublishDir -and (Test-Path $dashboardPublishDir) -and (Test-Path $historicoDashboardJs)) {
    Copy-Item $historicoDashboardJs (Join-Path $dashboardPublishDir "historico_dashboard.js") -Force
    Write-Host "Historico mensal consolidado publicado para:" (Join-Path $dashboardPublishDir "historico_dashboard.js")
  }
  else {
    Write-Host "Historico mensal consolidado atualizado localmente (nao publicado - verifique dashboard_analise_funil_publish_dir)."
  }
}

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir ("agendamento_fluxos_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $logFile -Append | Out-Null

try {
  $snapshotCheckStart = Get-Date

  Write-Host "=== Iniciando Fluxo 1 (Insight Funil) - $Ambiente ==="
  try {
    & ".\rodar_fluxo_funil.ps1" -Ambiente $Ambiente -SkipItensPerdas
  }
  catch {
    Write-Host "ERRO no Fluxo 1: $_"
    Write-Host "Fluxo 2 nao sera executado."
    throw
  }

  Write-Host ""
  Write-Host "=== Fluxo 1 concluido. Iniciando Fluxo 2 (Comparativo) - $Ambiente ==="
  try {
    & ".\rodar_fluxo_comparativo_funil.ps1" -Ambiente $Ambiente -SkipItensPerdas
  }
  catch {
    Write-Host "ERRO no Fluxo 2: $_"
    throw
  }

  Write-Host ""
  Write-Host "=== Fluxo 1 e Fluxo 2 concluidos com sucesso. ==="

  Write-Host ""
  Write-Host "=== Verificando fechamento do mes comercial ==="
  try {
    Arquivar-SnapshotMensalSeFechou -Since $snapshotCheckStart
  }
  catch {
    Write-Host "AVISO: falha ao verificar/arquivar snapshot mensal: $_"
    Write-Host "Isso nao afeta os dados publicados pelos Fluxos 1 e 2."
  }
}
finally {
  Stop-Transcript | Out-Null
}
