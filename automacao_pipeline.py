#!/usr/bin/env python
# -*- coding: utf-8 -*-

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Orquestra o pipeline analitico do funil.")
    parser.add_argument("--config", required=True, help="Caminho do arquivo de configuracao JSON.")
    return parser.parse_args()


def load_config(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def run_command(args: list[str]) -> None:
    print("Executando:", " ".join(args))
    result = subprocess.run(args, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"Falha ao executar comando: {' '.join(args)}")


def latest_output(history_dir: Path, stem: str, after: datetime) -> Path:
    candidates = [
        p for p in history_dir.glob(f"{stem}_*.xlsx") if datetime.fromtimestamp(p.stat().st_mtime) >= after
    ]
    if not candidates:
        candidates = list(history_dir.glob(f"{stem}_*.xlsx"))
    if not candidates:
        raise FileNotFoundError(f"Nenhum arquivo encontrado para o padrao {stem}_*.xlsx em {history_dir}")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def main():
    args = parse_args()
    config_path = Path(args.config).resolve()
    cfg = load_config(config_path)

    root = Path.cwd()
    history_dir = (root / cfg["paths"]["history_dir"]).resolve()
    history_dir.mkdir(parents=True, exist_ok=True)

    scripts = cfg["scripts"]
    inputs = cfg["inputs"]
    outputs = cfg["outputs"]
    filters = cfg.get("filters", {})
    cluster = cfg.get("cluster", {})

    python_cmd = [sys.executable]

    started = datetime.now()
    step1_script = str((root / scripts["step1"]).resolve())
    run_command(
        python_cmd
        + [
            step1_script,
            "-i",
            str((root / inputs["ruidos"]).resolve()),
            "-it",
            str((root / inputs["itens"]).resolve()),
            "-o",
            outputs["oportunidades_stem"],
            "--delta_horas",
            str(cluster.get("delta_horas", 360)),
            "--sim_min",
            str(cluster.get("sim_min", 0.5)),
        ]
        + (["--start", str(filters["start"])] if filters.get("start") else [])
        + (["--end", str(filters["end"])] if filters.get("end") else [])
        + (
            ["--debug_id", str(cluster["debug_id"])]
            if cluster.get("debug_id") is not None
            else []
        )
    )
    latest_output(history_dir, outputs["oportunidades_stem"], started)

    print("Pipeline concluido com sucesso.")


if __name__ == "__main__":
    main()
