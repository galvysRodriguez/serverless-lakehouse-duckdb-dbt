"""CLI de desarrollo: ``lakehouse generate`` y ``lakehouse run``."""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, timedelta

from lakehouse.config import load_settings
from lakehouse.generate import generate_day
from lakehouse.metrics import report
from lakehouse.runner import run_dbt


def _date(value: str) -> date:
    return date.fromisoformat(value)


def _days(start: date, end: date) -> list[date]:
    return [start + timedelta(days=i) for i in range((end - start).days + 1)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lakehouse")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="escribe datos raw sintéticos en LAKE_ROOT")
    gen.add_argument("--start", type=_date, default=date.today() - timedelta(days=6))
    gen.add_argument("--end", type=_date, default=date.today())

    run = sub.add_parser("run", help="ejecuta dbt para uno o varios días")
    run.add_argument("--date", type=_date, help="día a procesar (por defecto hoy UTC)")
    run.add_argument("--start", type=_date, help="inicio de un rango a procesar día por día")
    run.add_argument("--end", type=_date, help="fin del rango (inclusive)")
    run.add_argument(
        "--command", dest="dbt_command", default="build", choices=["build", "run", "test"]
    )
    run.add_argument("--select", help="selector de dbt, p. ej. tag:gold")
    run.add_argument(
        "--full-scan",
        action="store_true",
        help="backfill: reprocesa todas las particiones en una sola ejecución",
    )

    rep = sub.add_parser("report", help="resumen de duración y costo estimado de las ejecuciones")
    rep.add_argument("--days", type=int, default=30)

    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", force=True)
    settings = load_settings()

    if args.command == "generate":
        for d in _days(args.start, args.end):
            counts = generate_day(settings, d)
            print(f"{d}: {counts}")
        return 0

    if args.command == "report":
        print(report(settings, args.days))
        return 0

    if args.full_scan:
        if args.date or args.start or args.end:
            parser.error("--full-scan no admite fechas: procesa todo el lago")
        return 0 if run_dbt(settings, None, command=args.dbt_command, full_scan=True).success else 1

    if args.start or args.end:
        if not (args.start and args.end):
            parser.error("--start y --end van juntos")
        dates = _days(args.start, args.end)
    else:
        dates = [args.date]

    # Un día por invocación, igual que en la nube: cada ejecución lee solo su partición.
    for d in dates:
        result = run_dbt(settings, d, command=args.dbt_command, select=args.select)
        if not result.success:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
