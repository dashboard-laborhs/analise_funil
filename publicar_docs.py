#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Gera docs/index.html (versao publica, GitHub Pages) a partir do dashboard
local "Dashboard Analise Funil/dashboard_analise_funil.dc.html".

A versao publica e o mesmo HTML com 3 adaptacoes (ver README, secao 10):

1. os 4 <script src="./data/*.js"> apontam para os links de
   compartilhamento do SharePoint (com onerror para detectar falta de login
   e um parametro v=<agora> para nao usar copia antiga em cache);
2. o dashboard comeca invisivel (visibility:{{ rootVisibility }}) e so
   aparece quando os dados carregam (gate dashboardVisible);
3. o modal "Entre com sua conta corporativa" e o script que decide entre
   revelar o dashboard ou mostrar o modal (publicacao/bloco_sem_acesso.html).

Cada substituicao precisa casar exatamente uma vez. Se o .dc.html mudar a
ponto de alguma nao casar mais, o script para com erro em vez de gerar uma
versao publica quebrada.

Uso:
    py -3.12 publicar_docs.py           # grava docs/index.html
    py -3.12 publicar_docs.py --check   # so confere se docs/index.html esta em dia
"""

import argparse
import re
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
ORIGEM = REPO_DIR / "Dashboard Analise Funil" / "dashboard_analise_funil.dc.html"
DESTINO = REPO_DIR / "docs" / "index.html"
BLOCO_SEM_ACESSO = REPO_DIR / "publicacao" / "bloco_sem_acesso.html"

SHAREPOINT_BASE = (
    "https://bunzlbr.sharepoint.com/:u:/r/sites/InsightsVendas/"
    "Documentos%20Compartilhados/Producao/StaticWebApp/"
)

# arquivo de dados -> (query string do link de compartilhamento, flag de falha)
FONTES_DADOS = {
    "comparativo_dashboard.js": (
        "d=wcb1370849edf402bb9f5c5a5e102238d&csf=1&web=1&e=blbV6Y",
        "__COMPARATIVO_DATA_FAILED",
    ),
    "resumo_insight_dashboard.js": (
        "d=wace37474b95349bba0eeda688649cb00&csf=1&web=1&e=bo635p",
        "__RESUMO_DATA_FAILED",
    ),
    "top_itens_dashboard.js": (
        "d=w108bfa0aec2849c98b7616edc1a5a0ad&csf=1&web=1&e=Vcd9fB",
        "__TOPITENS_DATA_FAILED",
    ),
    "historico_dashboard.js": (
        "d=w40531f7e429949d59ff24a7dc0336331&csf=1&web=1&e=0LNPWe",
        "__HISTORICO_DATA_FAILED",
    ),
}


def substituir_uma_vez(texto: str, padrao: str, novo, descricao: str) -> str:
    resultado, n = re.subn(padrao, novo, texto, flags=re.MULTILINE)
    if n != 1:
        raise SystemExit(
            f"Erro: '{descricao}' casou {n} vezes no .dc.html (esperado 1). "
            "Ajuste publicar_docs.py antes de publicar."
        )
    return resultado


def gerar_html_publico(html: str, bloco_sem_acesso: str) -> str:
    for arquivo, (query, flag) in FONTES_DADOS.items():
        html = substituir_uma_vez(
            html,
            rf'^<script src="\./data/{re.escape(arquivo)}"></script>$',
            lambda _m, a=arquivo, q=query, f=flag: (
                # document.write com &v=<agora> para o navegador nao reaproveitar
                # uma copia antiga do arquivo em cache (os dados mudam todo dia).
                f"<script>document.write('<script src=\"{SHAREPOINT_BASE}{a}?{q}&v=' + Date.now() + "
                f"'\" onerror=\"window.{f} = true;\"><\\/script>');</script>"
            ),
            f"script ./data/{arquivo}",
        )

    html = substituir_uma_vez(
        html,
        r'^<div ref="\{\{ rootRef \}\}" style="(.*);">$',
        r'<div id="df-dashboard-root" ref="{{ rootRef }}" style="\1;visibility:{{ rootVisibility }};">',
        "div raiz do dashboard",
    )
    html = substituir_uma_vez(
        html,
        r"^(  state = \{ .*) \};$",
        r"\1, dashboardVisible: false };",
        "state inicial do componente",
    )
    html = substituir_uma_vez(
        html,
        r"^(    this\.rootRef = React\.createRef\(\);\n    this\._raf = null;)$",
        r"\1\n    window.__dcDashboard = this;",
        "construtor (rootRef)",
    )
    html = substituir_uma_vez(
        html,
        r"^(      scale: this\.state\.scale,)$",
        r"\1\n      rootVisibility: this.state.dashboardVisible ? 'visible' : 'hidden',",
        "renderVals (scale)",
    )
    html = substituir_uma_vez(
        html,
        r"^</body>$",
        lambda _m: "\n" + bloco_sem_acesso + "</body>",
        "fechamento do body",
    )
    return html


def main():
    parser = argparse.ArgumentParser(description="Gera docs/index.html a partir do dashboard local.")
    parser.add_argument("--check", action="store_true", help="So confere, sem gravar (sai com erro se estiver desatualizado).")
    args = parser.parse_args()

    html = ORIGEM.read_text(encoding="utf-8").replace("\r\n", "\n")
    bloco = BLOCO_SEM_ACESSO.read_text(encoding="utf-8").replace("\r\n", "\n")
    publico = gerar_html_publico(html, bloco)

    if args.check:
        atual = DESTINO.read_text(encoding="utf-8").replace("\r\n", "\n") if DESTINO.exists() else ""
        if atual != publico:
            print("docs/index.html esta desatualizado. Rode: py -3.12 publicar_docs.py")
            sys.exit(1)
        print("docs/index.html em dia com o dashboard local.")
        return

    DESTINO.write_text(publico, encoding="utf-8", newline="\n")
    print(f"Gerado: {DESTINO}")


if __name__ == "__main__":
    main()
