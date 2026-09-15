#!/usr/bin/env python
# -*- coding: utf-8 -*-

import argparse
import json
import unicodedata
from datetime import datetime
from pathlib import Path

import pandas as pd


STATUS_GROUPS = {
    "em_aberto": [
        ("Aguardando Aprovação Cliente", "Aguardando Aprovacao Cliente"),
        ("Aguardando Pagamento", "Aguardando Pagamento (Cartao de Credito)"),
        ("Em confecção", "Em Confeccao (retornou apos recusa do cliente)"),
        ("Alvará Sanitário", "Alvara Sanitario"),
        ("Análise de Crédito", "Analise de Credito"),
    ],
    "perdido": [
        ("Cancelado por Inatividade", "Cancelado por Inatividade"),
        ("Orçamento Cancelado", "Orcamento Cancelado"),
    ],
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Gera um JSON resumido da rodada para uso em AI Builder / Power Automate."
    )
    parser.add_argument("--oportunidades", required=True, help="Arquivo oportunidades_reais_auto_...xlsx")
    parser.add_argument("--entrada-dax1", required=True, help="Arquivo dax_orcamentos_tratado_power_automate_...xlsx tratado em entrada/")
    parser.add_argument(
        "--itens",
        default="",
        help="Arquivo dax_itens_tratado_power_automate_...xlsx tratado em entrada/ (opcional). "
        "Quando informado, anexa a lista de itens de cada orcamento do Top 3 em Aberto/Perdidos.",
    )
    parser.add_argument("--start-date", default="", help="Periodo inicial solicitado no formato YYYY-MM-DD.")
    parser.add_argument("--end-date", default="", help="Periodo final solicitado no formato YYYY-MM-DD.")
    parser.add_argument(
        "--commercial-start-date",
        default="",
        help="Inicio do mes comercial no formato YYYY-MM-DD.",
    )
    parser.add_argument(
        "--commercial-end-date",
        default="",
        help="Fim do mes comercial no formato YYYY-MM-DD.",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="",
        help="Arquivo JSON de saida. Se vazio, salva em alertas/resumo_insight_<timestamp>.json",
    )
    return parser.parse_args()


def normalize_text(value: str) -> str:
    text = "" if value is None else str(value)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return text.strip().lower()


def format_int(value) -> str:
    if pd.isna(value):
        return "0"
    return f"{int(round(float(value))):,}".replace(",", ".")


def format_budget_id(value) -> str:
    if pd.isna(value):
        return ""
    return str(int(round(float(value))))


def format_pct(value) -> str:
    if pd.isna(value):
        return "0,00%"
    return f"{float(value):.2f}%".replace(".", ",")


def format_money_short(value) -> str:
    if pd.isna(value):
        return "R$ 0"
    val = float(value)
    if abs(val) >= 1_000_000:
        return f"R$ {val / 1_000_000:.2f} MI".replace(".", ",")
    if abs(val) >= 1_000:
        return f"R$ {val / 1_000:.0f} Mil".replace(".", ",")
    return f"R$ {val:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def load_itens_por_orcamento(itens_path: Path | None) -> dict:
    if not itens_path:
        return {}
    itens_df = pd.read_excel(itens_path)
    itens_df["IDOrcamentoPrinc"] = pd.to_numeric(itens_df["IDOrcamentoPrinc"], errors="coerce")
    itens_df = itens_df.dropna(subset=["IDOrcamentoPrinc"])

    resultado: dict = {}
    for orc_id, grupo in itens_df.groupby("IDOrcamentoPrinc"):
        linhas = []
        for _, row in grupo.iterrows():
            valor_item = float(row.get("VlTot", 0) or 0)
            quantidade_item = float(row.get("Quantidade", 0) or 0)
            preco_tabela = float(row.get("PrecoTabela", 0) or 0)
            preco_promocao = float(row.get("PrecoPromocao", 0) or 0)
            preco_praticado = valor_item / quantidade_item if quantidade_item > 0 else 0.0
            desconto_pct = (
                round((preco_tabela - preco_praticado) / preco_tabela * 100, 2)
                if preco_tabela > 0
                else 0.0
            )
            linhas.append(
                {
                    "codigo": str(row.get("CodigoErp", "") or "").strip(),
                    "descricao": str(row.get("Descricao", "") or "").strip(),
                    "quantidade": quantidade_item,
                    "quantidade_fmt": format_int(row.get("Quantidade", 0)),
                    "preco_tabela": format_money_short(preco_tabela),
                    "preco_tabela_numero": preco_tabela,
                    "preco_promocao": format_money_short(preco_promocao) if preco_promocao > 0 else "-",
                    "preco_praticado": format_money_short(preco_praticado),
                    "preco_praticado_numero": preco_praticado,
                    "desconto_pct": desconto_pct if preco_tabela > 0 else None,
                    "valor": format_money_short(valor_item),
                    "valor_numero": valor_item,
                }
            )
        resultado[int(orc_id)] = sorted(linhas, key=lambda l: l["valor_numero"], reverse=True)
    return resultado


def format_ticket_short(value) -> str:
    if pd.isna(value):
        return "R$ 0"
    val = float(value)
    if abs(val) >= 1_000_000:
        return f"R$ {val / 1_000_000:.2f} MI".replace(".", ",")
    if abs(val) >= 1_000:
        return f"R$ {val / 1_000:.1f} Mil".replace(".", ",")
    return f"R$ {val:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def build_metric_map(df: pd.DataFrame) -> dict[str, float]:
    columns_norm = {normalize_text(col): col for col in df.columns}
    metric_col = columns_norm.get("metrica")
    value_col = columns_norm.get("sem ruido")
    if not metric_col or not value_col:
        raise ValueError("A aba Comparativo_Geral_Total nao possui as colunas esperadas: 'Metrica' e 'Sem Ruido'.")
    return dict(zip(df[metric_col].astype(str), df[value_col]))


def load_metric_sheet(path: Path, sheet_name: str, required: bool = True) -> dict[str, float]:
    try:
        df = pd.read_excel(path, sheet_name=sheet_name)
    except ValueError:
        if required:
            raise
        return {}
    return build_metric_map(df)


def get_metric(metrics: dict[str, float], *names: str, default: float = 0) -> float:
    for name in names:
        if name in metrics:
            return metrics[name]
    return default


def load_periodo(path: Path) -> str:
    df = pd.read_excel(path, sheet_name="DAX1_Tratado")
    columns_norm = {normalize_text(col): col for col in df.columns}
    data_col = columns_norm.get("data de criacao")
    if not data_col:
        raise ValueError("Arquivo da DAX 1 tratada nao possui a coluna 'Data de Criacao'.")
    datas = pd.to_datetime(df[data_col], errors="coerce").dropna()
    if datas.empty:
        return "nao identificado"
    return f"{datas.min():%d/%m/%Y} a {datas.max():%d/%m/%Y}"


def load_max_period_date(path: Path) -> datetime | None:
    df = pd.read_excel(path, sheet_name="DAX1_Tratado")
    columns_norm = {normalize_text(col): col for col in df.columns}
    data_col = columns_norm.get("data de criacao")
    if not data_col:
        return None
    datas = pd.to_datetime(df[data_col], errors="coerce").dropna()
    if datas.empty:
        return None
    return datas.max().to_pydatetime()


def resolve_periodo(path: Path, start_date: str, end_date: str) -> str:
    if start_date and end_date:
        try:
            start_dt = datetime.strptime(start_date, "%Y-%m-%d")
            end_dt = datetime.strptime(end_date, "%Y-%m-%d")
            return f"{start_dt:%d/%m/%Y} a {end_dt:%d/%m/%Y}"
        except ValueError:
            pass
    return load_periodo(path)


def resolve_commercial_period(start_date: str, end_date: str) -> str:
    if start_date and end_date:
        try:
            start_dt = datetime.strptime(start_date, "%Y-%m-%d")
            end_dt = datetime.strptime(end_date, "%Y-%m-%d")
            return f"{start_dt:%d/%m/%Y} a {end_dt:%d/%m/%Y}"
        except ValueError:
            pass
    return "nao identificado"


def resolve_title_period_date(
    entrada_dax1_path: Path, commercial_end_date: str, start_date: str, end_date: str
) -> datetime:
    # O titulo deve refletir o mes do ciclo comercial (mesmo mes exibido em
    # "Mes Comercial"), nao o fim da fatia "ate ontem" analisada - senao o
    # titulo mostra o mes anterior nos primeiros dias de um ciclo novo.
    if commercial_end_date:
        try:
            return datetime.strptime(commercial_end_date, "%Y-%m-%d")
        except ValueError:
            pass

    if start_date and end_date:
        try:
            return datetime.strptime(end_date, "%Y-%m-%d")
        except ValueError:
            pass

    fallback = load_max_period_date(entrada_dax1_path)
    if fallback is not None:
        return fallback

    return datetime.now()


def build_group_summary(oportunidades_df: pd.DataFrame, group_key: str, itens_por_orcamento: dict | None = None) -> dict:
    itens_por_orcamento = itens_por_orcamento or {}
    work = oportunidades_df.copy()
    work["Status_Norm"] = work["Status Atual"].astype(str).map(normalize_text)
    work["Valor"] = pd.to_numeric(work["Valor"], errors="coerce").fillna(0)
    col_revisao_gestor = next(
        (c for c in work.columns if "revis" in c.lower() and "gestor" in c.lower()), None
    )
    col_tipo_cliente = next(
        (c for c in work.columns if "tipo" in c.lower() and "cliente" in c.lower()), None
    )

    def montar_linha_orcamento(row) -> dict:
        orc_id = int(row["ID_Orcamento"]) if pd.notna(row["ID_Orcamento"]) else None
        data_criacao = row.get("Data")
        revisao_valor = row.get(col_revisao_gestor) if col_revisao_gestor else None
        tipo_cliente = str(row.get(col_tipo_cliente, "") or "").strip() if col_tipo_cliente else ""
        return {
            "orcamento": format_budget_id(row["ID_Orcamento"]),
            "vendedor": str(row["Vendedor"]).strip(),
            "cliente": str(row["Cliente"]).strip(),
            "tipo_cliente": tipo_cliente,
            "valor": format_money_short(row["Valor"]),
            "valor_numero": float(row["Valor"]),
            "status": display_map.get(row["Status_Norm"], str(row["Status Atual"]).strip()),
            "data_criacao": data_criacao.strftime("%d/%m/%Y") if pd.notna(data_criacao) else "-",
            "data_criacao_iso": data_criacao.strftime("%Y-%m-%d") if pd.notna(data_criacao) else "",
            "revisao_gestor": bool(pd.notna(revisao_valor) and float(revisao_valor) == 1),
            "itens": itens_por_orcamento.get(orc_id, []),
        }

    display_map = {normalize_text(src): display for src, display in STATUS_GROUPS[group_key]}
    target_norms = list(display_map.keys())
    subset = work[work["Status_Norm"].isin(target_norms)].copy()

    status_totals = []
    top_orcamentos = []

    if not subset.empty:
        totals = (
            subset.groupby("Status_Norm", dropna=False)
            .agg(
                valor_total=("Valor", "sum"),
                quantidade=("ID_Orcamento", "nunique"),
            )
            .sort_values("valor_total", ascending=False)
        )
        for status_norm, row in totals.iterrows():
            orcamentos_status = subset[subset["Status_Norm"] == status_norm].sort_values(
                "Valor", ascending=False
            )
            status_totals.append(
                {
                    "status": display_map.get(status_norm, status_norm),
                    "quantidade": int(row["quantidade"]),
                    "quantidade_fmt": format_int(row["quantidade"]),
                    "valor": format_money_short(row["valor_total"]),
                    "valor_numero": float(row["valor_total"]),
                    "orcamentos": [montar_linha_orcamento(r) for _, r in orcamentos_status.iterrows()],
                }
            )

        top_rows = subset.sort_values("Valor", ascending=False).head(5)
        for _, row in top_rows.iterrows():
            top_orcamentos.append(montar_linha_orcamento(row))

    principal = status_totals[0] if status_totals else {
        "status": "",
        "quantidade": 0,
        "quantidade_fmt": "0",
        "valor": "R$ 0",
        "valor_numero": 0.0,
    }

    empty_status = {
        "status": "",
        "quantidade": 0,
        "quantidade_fmt": "",
        "valor": "",
        "valor_numero": 0.0,
        "orcamentos": [],
    }
    while len(status_totals) < 5:
        status_totals.append(empty_status.copy())

    empty_top = {
        "orcamento": "",
        "vendedor": "",
        "cliente": "",
        "tipo_cliente": "",
        "valor": "",
        "valor_numero": 0.0,
        "status": "",
        "data_criacao": "",
        "data_criacao_iso": "",
        "revisao_gestor": False,
        "itens": [],
    }
    while len(top_orcamentos) < 5:
        top_orcamentos.append(empty_top.copy())

    return {
        "principal_status": principal["status"],
        "quantidade_principal_status": principal["quantidade"],
        "quantidade_principal_status_fmt": principal["quantidade_fmt"],
        "valor_principal_status": principal["valor"],
        "status_totais": status_totals,
        "top_5": top_orcamentos,
    }


def build_summary(
    oportunidades_path: Path,
    entrada_dax1_path: Path,
    start_date: str = "",
    end_date: str = "",
    commercial_start_date: str = "",
    commercial_end_date: str = "",
    itens_path: Path | None = None,
) -> dict:
    lista_oportunidades = pd.read_excel(oportunidades_path, sheet_name="Lista_Oportunidades_Reais")
    metrics = load_metric_sheet(oportunidades_path, "Comparativo_Geral_Total")
    metrics_data_fat = load_metric_sheet(
        oportunidades_path,
        "Comp_Geral_Total_Data_Fat",
        required=False,
    )

    itens_por_orcamento = load_itens_por_orcamento(itens_path)
    resumo_aberto = build_group_summary(lista_oportunidades, "em_aberto", itens_por_orcamento)
    resumo_perdido = build_group_summary(lista_oportunidades, "perdido", itens_por_orcamento)

    qtd_enviados = int(round(float(metrics.get("Qtd Enviados", 0))))
    valor_enviado_numero = float(metrics.get("Valor Enviado", 0) or 0)
    qtd_faturados = int(round(float(metrics.get("Qtd Faturados", 0))))
    valor_faturado_numero = float(metrics.get("Valor Faturado", 0) or 0)

    qtd_enviados_data_faturamento = int(round(float(metrics_data_fat.get("Qtd Enviados", 0) or 0)))
    valor_enviado_numero_data_faturamento = float(metrics_data_fat.get("Valor Enviado", 0) or 0)
    qtd_faturados_data_faturamento = int(round(float(metrics_data_fat.get("Qtd Faturados", 0) or 0)))
    valor_faturado_numero_data_faturamento = float(metrics_data_fat.get("Valor Faturado", 0) or 0)
    qtd_nao_convertidas = int(round(float(get_metric(metrics, "Nao Convertidas (Qtd)", "Perdas (Qtd)"))))
    valor_nao_convertido_numero = float(
        get_metric(metrics, "Nao Convertidas (Valor)", "Perdas (Valor)") or 0
    )

    ticket_medio_gerado_numero = valor_enviado_numero / qtd_enviados if qtd_enviados else 0.0
    ticket_medio_convertido_numero = valor_faturado_numero / qtd_faturados if qtd_faturados else 0.0
    ticket_medio_nao_convertido_numero = (
        valor_nao_convertido_numero / qtd_nao_convertidas if qtd_nao_convertidas else 0.0
    )

    agora = datetime.now()
    referencia_periodo = resolve_title_period_date(entrada_dax1_path, commercial_end_date, start_date, end_date)
    meses_pt = {
        1: "Janeiro",
        2: "Fevereiro",
        3: "Marco",
        4: "Abril",
        5: "Maio",
        6: "Junho",
        7: "Julho",
        8: "Agosto",
        9: "Setembro",
        10: "Outubro",
        11: "Novembro",
        12: "Dezembro",
    }
    mes_analise = f"{meses_pt[referencia_periodo.month]}/{referencia_periodo:%y}"
    return {
        "titulo": f"Resumo Executivo do Funil | {mes_analise} | {agora:%d/%m/%Y}",
        "mes_comercial": resolve_commercial_period(commercial_start_date, commercial_end_date),
        "periodo": resolve_periodo(entrada_dax1_path, start_date, end_date),
        "atualizado_em": agora.strftime("%d/%m/%Y %H:%M"),
        "qtd_enviados": qtd_enviados,
        "qtd_enviados_fmt": format_int(qtd_enviados),
        "valor_enviado": format_money_short(valor_enviado_numero),
        "valor_enviado_numero": valor_enviado_numero,
        "ticket_medio_gerado": format_ticket_short(ticket_medio_gerado_numero),
        "ticket_medio_gerado_numero": float(ticket_medio_gerado_numero),
        "qtd_faturados": qtd_faturados,
        "qtd_faturados_fmt": format_int(qtd_faturados),
        "valor_faturado": format_money_short(valor_faturado_numero),
        "valor_faturado_numero": valor_faturado_numero,
        "ticket_medio_convertido": format_ticket_short(ticket_medio_convertido_numero),
        "ticket_medio_convertido_numero": float(ticket_medio_convertido_numero),
        "qtd_nao_convertidas": qtd_nao_convertidas,
        "qtd_nao_convertidas_fmt": format_int(qtd_nao_convertidas),
        "valor_nao_convertido": format_money_short(valor_nao_convertido_numero),
        "valor_nao_convertido_numero": valor_nao_convertido_numero,
        "ticket_medio_nao_convertido": format_ticket_short(ticket_medio_nao_convertido_numero),
        "ticket_medio_nao_convertido_numero": float(ticket_medio_nao_convertido_numero),
        "win_rate_qtd": format_pct(metrics.get("Win Rate (Volume) %", 0)),
        "win_rate_qtd_numero": float(metrics.get("Win Rate (Volume) %", 0) or 0),
        "win_rate_valor": format_pct(metrics.get("Win Rate (Valor) %", 0)),
        "win_rate_valor_numero": float(metrics.get("Win Rate (Valor) %", 0) or 0),
        "win_rate_qtd_data_faturamento": format_pct(
            metrics_data_fat.get("Win Rate (Volume) %", 0)
        ),
        "win_rate_qtd_data_faturamento_numero": float(
            metrics_data_fat.get("Win Rate (Volume) %", 0) or 0
        ),
        "win_rate_valor_data_faturamento": format_pct(
            metrics_data_fat.get("Win Rate (Valor) %", 0)
        ),
        "win_rate_valor_data_faturamento_numero": float(
            metrics_data_fat.get("Win Rate (Valor) %", 0) or 0
        ),
        "qtd_enviados_data_faturamento": qtd_enviados_data_faturamento,
        "qtd_enviados_data_faturamento_fmt": format_int(qtd_enviados_data_faturamento),
        "valor_enviado_data_faturamento": format_money_short(valor_enviado_numero_data_faturamento),
        "valor_enviado_numero_data_faturamento": valor_enviado_numero_data_faturamento,
        "qtd_faturados_data_faturamento": qtd_faturados_data_faturamento,
        "qtd_faturados_data_faturamento_fmt": format_int(qtd_faturados_data_faturamento),
        "valor_faturado_data_faturamento": format_money_short(valor_faturado_numero_data_faturamento),
        "valor_faturado_numero_data_faturamento": valor_faturado_numero_data_faturamento,
        "em_aberto": resumo_aberto,
        "perdido": resumo_perdido,
    }


def main():
    args = parse_args()
    oportunidades_path = Path(args.oportunidades).resolve()
    entrada_dax1_path = Path(args.entrada_dax1).resolve()
    itens_path = Path(args.itens).resolve() if args.itens else None

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = (
        Path(args.output).resolve()
        if args.output
        else (Path.cwd() / "alertas" / f"resumo_insight_{timestamp}.json")
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)

    summary = build_summary(
        oportunidades_path,
        entrada_dax1_path,
        start_date=args.start_date,
        end_date=args.end_date,
        commercial_start_date=args.commercial_start_date,
        commercial_end_date=args.commercial_end_date,
        itens_path=itens_path,
    )
    output_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"JSON de insight gerado em: {output_path}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
