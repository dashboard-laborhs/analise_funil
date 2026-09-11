from __future__ import annotations

import argparse
import json
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
ALERTAS_DIR = BASE_DIR / "alertas"
DEFAULT_OUTPUT = BASE_DIR / "Dashboard Analise Funil" / "data" / "historico_dashboard.js"


def find_latest_json() -> Path:
    arquivos = sorted(
        ALERTAS_DIR.glob("historico_mensal_card_teams_*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not arquivos:
        raise FileNotFoundError("Nenhum JSON de historico mensal encontrado em alertas.")
    return arquivos[0]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Gera o arquivo JS usado pelo modal de historico mensal do dashboard interativo."
    )
    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        help="Caminho do JSON de historico mensal. Se omitido, usa o mais recente da pasta alertas.",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Caminho do arquivo JS de saída.",
    )
    args = parser.parse_args()

    input_path = args.input if args.input else find_latest_json()
    output_path = args.output

    with input_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False, indent=2)
    content = "window.WIN_RATE_HISTORICO_DATA = " + payload + ";\n"

    with output_path.open("w", encoding="utf-8") as f:
        f.write(content)

    print(f"Arquivo de dados gerado: {output_path}")
    print(f"Fonte usada: {input_path}")


if __name__ == "__main__":
    main()
