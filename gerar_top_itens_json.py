#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""
Gera um JSON com rankings Top 5 de itens (Faturados e Perdas) para a aba
"Top Itens" do dashboard. Reaproveita a leitura/remocao de ruido/classificacao
de analisar_evolucao_diaria_item.py em vez de duplicar essa logica.
"""

import argparse
import json
from datetime import date, datetime
from pathlib import Path

import pandas as pd

from analisar_evolucao_diaria_item import (
    read_itens,
    read_orcamentos,
    resolve_commercial_period,
    remover_ruido,
    gerar_resumo_todos_itens,
    classificar,
)

BASE_DIR = Path(__file__).resolve().parent
ALERTAS_DIR = BASE_DIR / "alertas"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Gera o JSON de rankings Top 5 (Faturados/Perdas) por item para o dashboard."
    )
    parser.add_argument("-i", "--orcamentos", required=True, help="Arquivo de orcamentos tratado (.xlsx).")
    parser.add_argument("-it", "--itens", required=True, help="Arquivo de itens tratado (.xlsx).")
    parser.add_argument("--start", default="", help="Data de inicio (YYYY-MM-DD). Padrao: inicio do mes comercial atual.")
    parser.add_argument("--end", default="", help="Data de fim (YYYY-MM-DD). Padrao: hoje.")
    parser.add_argument("--delta_horas", type=float, default=360, help="Janela em horas p/ cluster de ruido. Padrao: 360.")
    parser.add_argument("--sim_min", type=float, default=0.50, help="Similaridade minima (Jaccard) p/ cluster. Padrao: 0.50.")
    parser.add_argument(
        "-o",
        "--output",
        default="",
        help="Arquivo JSON de saida. Se vazio, salva em alertas/top_itens_card_teams_<timestamp>.json",
    )
    return parser.parse_args()


def format_int(value) -> str:
    if pd.isna(value):
        return "0"
    return f"{int(round(float(value))):,}".replace(",", ".")


def format_money_short(value) -> str:
    if pd.isna(value):
        return "R$ 0"
    val = float(value)
    if abs(val) >= 1_000_000:
        return f"R$ {val / 1_000_000:.2f} MI".replace(".", ",")
    if abs(val) >= 1_000:
        return f"R$ {val / 1_000:.0f} Mil".replace(".", ",")
    return f"R$ {val:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def montar_itens_orcamento(itens_df: pd.DataFrame, num_orcamento: int) -> list:
    grupo = itens_df[itens_df["IDOrcamentoPrinc"] == num_orcamento]
    linhas = []
    for _, row in grupo.iterrows():
        valor_item = float(row.get("VlTot", 0) or 0)
        quantidade = float(row.get("Quantidade", 0) or 0)
        preco_tabela = float(row.get("PrecoTabela", 0) or 0)
        preco_promocao = float(row.get("PrecoPromocao", 0) or 0)
        preco_praticado = valor_item / quantidade if quantidade > 0 else 0.0
        desconto_pct = (
            round((preco_tabela - preco_praticado) / preco_tabela * 100, 2)
            if preco_tabela > 0
            else 0.0
        )
        linhas.append({
            "codigo": str(row.get("CodigoErp", "") or "").strip(),
            "descricao": str(row.get("Descricao", "") or "").strip(),
            "quantidade": quantidade,
            "quantidade_fmt": format_int(row.get("Quantidade", 0)),
            "preco_tabela": format_money_short(preco_tabela),
            "preco_tabela_numero": preco_tabela,
            "preco_promocao": format_money_short(preco_promocao) if preco_promocao > 0 else "-",
            "preco_praticado": format_money_short(preco_praticado),
            "preco_praticado_numero": preco_praticado,
            "desconto_pct": desconto_pct if preco_tabela > 0 else None,
            "valor": format_money_short(valor_item),
            "valor_numero": valor_item,
        })
    return linhas


def montar_detalhe_item(itens: pd.DataFrame, working_df: pd.DataFrame, codigo: str, sufixo_classe: str) -> list:
    itens_codigo = itens[itens["CodigoErp"] == codigo]
    itens_agg = itens_codigo.groupby("IDOrcamentoPrinc", as_index=False).agg(
        Quantidade_Item=("Quantidade", "sum"),
        Valor_Item=("VlTot", "sum"),
    )
    merged = working_df.merge(
        itens_agg, left_on="Num_Orcamento", right_on="IDOrcamentoPrinc", how="inner"
    )
    if merged.empty:
        return []

    merged["Classificacao"] = merged.apply(classificar, axis=1)
    filtrado = merged[merged["Classificacao"] == sufixo_classe].sort_values("Valor_Item", ascending=False)

    linhas = []
    for _, row in filtrado.iterrows():
        data_criacao = row["Data_Criacao"]
        valor_orcamento = float(row["Valor"]) if pd.notna(row["Valor"]) else 0.0
        pct_item_orcamento = round(float(row["Valor_Item"]) / valor_orcamento * 100, 1) if valor_orcamento > 0 else 0.0
        quantidade_item = float(row["Quantidade_Item"]) if pd.notna(row["Quantidade_Item"]) else 0.0
        preco_unitario = float(row["Valor_Item"]) / quantidade_item if quantidade_item > 0 else 0.0
        linhas.append(
            {
                "data_criacao": data_criacao.strftime("%d/%m/%Y") if pd.notna(data_criacao) else "-",
                "data_criacao_iso": data_criacao.strftime("%Y-%m-%d") if pd.notna(data_criacao) else "",
                "num_orcamento": int(row["Num_Orcamento"]),
                "cliente": str(row.get("Cliente", "") or ""),
                "tipo_cliente": str(row.get("Tipo_Cliente", "") or ""),
                "vendedor": str(row.get("Vendedor", "") or ""),
                "volume_item": quantidade_item,
                "volume_item_fmt": format_int(row["Quantidade_Item"]),
                "preco_unitario": round(preco_unitario, 2),
                "preco_unitario_fmt": format_money_short(preco_unitario),
                "valor_item": round(float(row["Valor_Item"]), 2),
                "valor_item_fmt": format_money_short(row["Valor_Item"]),
                "valor_orcamento": round(valor_orcamento, 2),
                "valor_orcamento_fmt": format_money_short(row["Valor"]),
                "pct_item_orcamento": pct_item_orcamento,
                "passou_revisao_gestor": int(row["Revisao_Gestor"]) if "Revisao_Gestor" in row.index and pd.notna(row["Revisao_Gestor"]) else 0,
                "status": str(row.get("Status_Atual", "") or "").strip(),
                "itens": montar_itens_orcamento(itens, int(row["Num_Orcamento"])),
            }
        )
    return linhas


def montar_ranking_bloco(
    tabela: pd.DataFrame, itens: pd.DataFrame, working_df: pd.DataFrame, sufixo_classe: str
) -> dict:
    col_orcamentos = f"Orcamentos_{sufixo_classe}"
    col_quantidade = f"Quantidade_{sufixo_classe}"
    col_valor = f"Valor_{sufixo_classe}"

    detalhes_cache = {}

    def detalhe_de(codigo: str) -> list:
        if codigo not in detalhes_cache:
            detalhes_cache[codigo] = montar_detalhe_item(itens, working_df, codigo, sufixo_classe)
        return detalhes_cache[codigo]

    def linha_de(row) -> dict:
        codigo = str(row["CodigoErp"])
        return {
            "codigo": codigo,
            "descricao": str(row["Descricao"]),
            "orcamentos": int(row[col_orcamentos]),
            "volume": int(row[col_quantidade]),
            "volume_fmt": format_int(row[col_quantidade]),
            "valor_numero": round(float(row[col_valor]), 2),
            "valor": format_money_short(row[col_valor]),
            "detalhe": detalhe_de(codigo),
        }

    top5_quantidade = [linha_de(row) for _, row in tabela.sort_values(col_orcamentos, ascending=False).head(5).iterrows()]
    top5_volume = [linha_de(row) for _, row in tabela.sort_values(col_quantidade, ascending=False).head(5).iterrows()]
    top5_valor = [linha_de(row) for _, row in tabela.sort_values(col_valor, ascending=False).head(5).iterrows()]

    total_valor = float(tabela[col_valor].sum())
    top5_valor_soma = sum(item["valor_numero"] for item in top5_valor)
    concentracao_pct = round(top5_valor_soma / total_valor * 100, 1) if total_valor > 0 else 0.0
    total_itens = int((tabela[col_orcamentos] > 0).sum())

    return {
        "top5_quantidade": top5_quantidade,
        "top5_volume": top5_volume,
        "top5_valor": top5_valor,
        "concentracao_top5_valor_pct": concentracao_pct,
        "valor_total": round(total_valor, 2),
        "valor_total_fmt": format_money_short(total_valor),
        "total_itens": total_itens,
    }


def main():
    args = parse_args()

    itens = read_itens(args.itens)
    mapa_codes = {int(oid): set(sub["CodigoErp"].tolist()) for oid, sub in itens.groupby("IDOrcamentoPrinc")}

    orcamentos = read_orcamentos(args.orcamentos, precisa_ruido=True)
    orcamentos = orcamentos.dropna(subset=["Data_Criacao"]).copy()

    hoje = date.today()
    if args.start:
        dt_start = pd.to_datetime(args.start, errors="coerce")
        if pd.isna(dt_start):
            raise ValueError(f"Data invalida em --start: '{args.start}'. Use YYYY-MM-DD.")
        commercial_start = dt_start.date()
    else:
        commercial_start, _ = resolve_commercial_period(hoje)

    if args.end:
        dt_end = pd.to_datetime(args.end, errors="coerce")
        if pd.isna(dt_end):
            raise ValueError(f"Data invalida em --end: '{args.end}'. Use YYYY-MM-DD.")
        end_date = dt_end.date()
    else:
        end_date = hoje

    mask = (orcamentos["Data_Criacao"].dt.date >= commercial_start) & (
        orcamentos["Data_Criacao"].dt.date <= end_date
    )
    df_periodo = orcamentos[mask].copy()
    if df_periodo.empty:
        raise ValueError(f"Nenhum orcamento criado entre {commercial_start:%d/%m/%Y} e {end_date:%d/%m/%Y}.")

    _, working_df, _ = remover_ruido(df_periodo, mapa_codes, args.delta_horas, args.sim_min)

    try:
        tabela = gerar_resumo_todos_itens(itens, working_df)
    except ValueError:
        # Periodo sem oportunidades ainda (ex.: logo apos a virada do mes comercial).
        # Nao e um erro do pipeline: gera um bloco vazio em vez de derrubar a rodada inteira.
        print(
            "Aviso: nenhum item encontrado no periodo apos a remocao de ruido. "
            "Gerando JSON de top itens vazio."
        )
        tabela = None

    bloco_vazio = {
        "top5_quantidade": [],
        "top5_volume": [],
        "top5_valor": [],
        "concentracao_top5_valor_pct": 0.0,
        "valor_total": 0.0,
        "valor_total_fmt": format_money_short(0),
        "total_itens": 0,
    }

    resultado = {
        "atualizado_em": datetime.now().strftime("%d/%m/%Y %H:%M"),
        "periodo": f"{commercial_start:%d/%m/%Y} a {end_date:%d/%m/%Y}",
        "faturados": montar_ranking_bloco(tabela, itens, working_df, "Faturado") if tabela is not None else bloco_vazio,
        "perdas": montar_ranking_bloco(tabela, itens, working_df, "Enviados_Cliente_Nao_Aprovado") if tabela is not None else bloco_vazio,
    }

    if args.output:
        output_path = Path(args.output)
    else:
        ALERTAS_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = ALERTAS_DIR / f"top_itens_card_teams_{timestamp}.json"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(resultado, f, ensure_ascii=False, indent=2)

    print(f"Arquivo gerado: {output_path}")
    print(f"Periodo: {commercial_start:%d/%m/%Y} a {end_date:%d/%m/%Y}")
    print(f"Codigos no ranking de faturados: {len(resultado['faturados']['top5_valor'])}")
    print(f"Codigos no ranking de perdas: {len(resultado['perdas']['top5_valor'])}")


if __name__ == "__main__":
    main()
