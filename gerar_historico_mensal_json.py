#!/usr/bin/env python
# -*- coding: utf-8 -*-

import argparse
import json
from datetime import datetime
from pathlib import Path

import pandas as pd

ALERTAS_DIR = Path("alertas")


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Converte o resumo mensal do funil (saida de gerar_resumo_mensal_funil.py) "
            "em JSON para o grafico de historico do dashboard."
        )
    )
    parser.add_argument(
        "-i",
        "--input",
        required=True,
        help="Arquivo resumo_mensal_funil_*.xlsx gerado por gerar_resumo_mensal_funil.py",
    )
    parser.add_argument(
        "--meses",
        type=int,
        default=12,
        help="Quantidade maxima de meses mais recentes a incluir (default: 12). Use 0 para incluir todos.",
    )
    parser.add_argument(
        "--sheet",
        default="Resumo_Mensal_Funil",
        help="Aba a ser lida (default: Resumo_Mensal_Funil, visao por Data de Criacao).",
    )
    parser.add_argument("-o", "--output", default="", help="Arquivo JSON de saida.")
    return parser.parse_args()


def format_money_short(value) -> str:
    if pd.isna(value):
        return "R$ 0"
    val = float(value)
    if abs(val) >= 1_000_000:
        return f"R$ {val / 1_000_000:.1f} Mi".replace(".", ",")
    if abs(val) >= 1_000:
        return f"R$ {val / 1_000:.0f} Mil".replace(".", ",")
    return f"R$ {val:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def format_int(value) -> str:
    if pd.isna(value):
        return "0"
    return f"{int(round(float(value))):,}".replace(",", ".")


def main():
    args = parse_args()

    df = pd.read_excel(args.input, sheet_name=args.sheet)

    if "Periodo Completo" in df.columns:
        descartados = int((~df["Periodo Completo"].astype(bool)).sum())
        df = df[df["Periodo Completo"].astype(bool)].copy()
        if descartados:
            print(f"Aviso: {descartados} mes(es) parcial(is) descartado(s) (fora do limite do mes comercial).")

    if args.meses > 0:
        df = df.tail(args.meses).reset_index(drop=True)

    if df.empty:
        raise ValueError(f"A aba '{args.sheet}' de '{args.input}' nao tem nenhuma linha completa.")

    meses = df["Mês/Ano Comercial"].tolist()

    enviados_qtd = df["Enviados_Qtd (Sem Ruído)"]
    faturado_qtd = df["Faturado_Qtd (Sem Ruído)"]
    wr_volume = (df["Win Rate (Volume) % (Sem Ruído)"] * 100).round(2)

    enviados_valor = df["Enviados_Valor (Sem Ruído)"]
    faturado_valor = df["Faturado_Valor (Sem Ruído)"]
    wr_valor = (df["Win Rate (Valor) % (Sem Ruído)"] * 100).round(2)

    resultado = {
        "atualizado_em": datetime.now().strftime("%d/%m/%Y %H:%M"),
        "meses": meses,
        "volume": {
            "enviados": [round(float(v), 0) for v in enviados_qtd],
            "enviados_fmt": [format_int(v) for v in enviados_qtd],
            "faturados": [round(float(v), 0) for v in faturado_qtd],
            "faturados_fmt": [format_int(v) for v in faturado_qtd],
            "win_rate_pct": [round(float(v), 2) for v in wr_volume],
        },
        "valor": {
            "enviados": [round(float(v), 2) for v in enviados_valor],
            "enviados_fmt": [format_money_short(v) for v in enviados_valor],
            "faturados": [round(float(v), 2) for v in faturado_valor],
            "faturados_fmt": [format_money_short(v) for v in faturado_valor],
            "win_rate_pct": [round(float(v), 2) for v in wr_valor],
        },
    }

    if args.output:
        output_path = Path(args.output)
    else:
        ALERTAS_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = ALERTAS_DIR / f"historico_mensal_card_teams_{timestamp}.json"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(resultado, f, ensure_ascii=False, indent=2)

    print(f"Arquivo gerado: {output_path}")
    print(f"Meses incluidos: {len(meses)} ({meses[0]} a {meses[-1]})")


if __name__ == "__main__":
    main()
