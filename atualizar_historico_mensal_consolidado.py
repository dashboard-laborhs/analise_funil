#!/usr/bin/env python
# -*- coding: utf-8 -*-

import argparse
from pathlib import Path

import pandas as pd

MONTH_ORDER_PT = {
    "Jan": 1, "Fev": 2, "Mar": 3, "Abr": 4, "Mai": 5, "Jun": 6,
    "Jul": 7, "Ago": 8, "Set": 9, "Out": 10, "Nov": 11, "Dez": 12,
}

DEFAULT_CONSOLIDADO = Path("historico") / "historico_mensal_consolidado.xlsx"


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Junta as linhas completas de um resumo_mensal_funil_*.xlsx (gerado por "
            "gerar_resumo_mensal_funil.py) num historico consolidado que so cresce, "
            "substituindo qualquer mes ja existente com o mesmo rotulo."
        )
    )
    parser.add_argument(
        "-i",
        "--input",
        required=True,
        help="Arquivo resumo_mensal_funil_*.xlsx com as abas Resumo_Mensal_Funil e Resumo_Mensal_Funil_Data_Fat.",
    )
    parser.add_argument(
        "--consolidado",
        default=str(DEFAULT_CONSOLIDADO),
        help=f"Arquivo consolidado a atualizar (default: {DEFAULT_CONSOLIDADO}).",
    )
    return parser.parse_args()


def sort_key(mes_ano: str):
    mes, ano = mes_ano.split("/")
    return (int(ano), MONTH_ORDER_PT[mes])


def merge_sheet(novo_df: pd.DataFrame, existente_df: pd.DataFrame | None) -> pd.DataFrame:
    novo_completo = novo_df[novo_df["Periodo Completo"] == True].copy()  # noqa: E712
    if existente_df is None or existente_df.empty:
        combinado = novo_completo
    else:
        mantidos = existente_df[~existente_df["Mês/Ano Comercial"].isin(novo_completo["Mês/Ano Comercial"])]
        combinado = pd.concat([mantidos, novo_completo], ignore_index=True)
    combinado = combinado.sort_values(
        by="Mês/Ano Comercial", key=lambda s: s.map(sort_key)
    ).reset_index(drop=True)
    return combinado


def main():
    args = parse_args()
    consolidado_path = Path(args.consolidado)

    sheets_novo = pd.read_excel(args.input, sheet_name=None)
    sheets_existente = pd.read_excel(consolidado_path, sheet_name=None) if consolidado_path.exists() else {}

    resultado = {}
    novos_meses = []
    for sheet_name, novo_df in sheets_novo.items():
        existente_df = sheets_existente.get(sheet_name)
        combinado = merge_sheet(novo_df, existente_df)
        resultado[sheet_name] = combinado
        if sheet_name == "Resumo_Mensal_Funil":
            existentes_labels = set(existente_df["Mês/Ano Comercial"]) if existente_df is not None else set()
            novos_meses = [
                m for m in novo_df.loc[novo_df["Periodo Completo"] == True, "Mês/Ano Comercial"]  # noqa: E712
                if m not in existentes_labels
            ]

    consolidado_path.parent.mkdir(parents=True, exist_ok=True)
    with pd.ExcelWriter(consolidado_path, engine="openpyxl") as writer:
        for sheet_name, df in resultado.items():
            df.to_excel(writer, sheet_name=sheet_name, index=False)

    total_meses = len(resultado.get("Resumo_Mensal_Funil", []))
    print(f"Consolidado atualizado: {consolidado_path}")
    print(f"Total de meses no consolidado: {total_meses}")
    if novos_meses:
        print(f"Mes(es) novo(s) incluido(s) nesta rodada: {', '.join(novos_meses)}")
    else:
        print("Nenhum mes novo incluido nesta rodada (ja estavam no consolidado ou nenhum periodo completo).")


if __name__ == "__main__":
    main()
