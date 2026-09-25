"""
Master runner for Stage 01 — runs all five ingest scripts in sequence.
Usage: python src/python/run_stage01.py
"""
import logging
import importlib.util
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("run_stage01")


def _run_module(fname: str) -> bool:
    path = Path(__file__).resolve().parent / fname
    log.info("=" * 60)
    log.info("Running %s", fname)
    log.info("=" * 60)
    spec = importlib.util.spec_from_file_location(fname.replace(".py",""), path)
    m = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(m)
        m.run()
        return True
    except Exception as exc:
        log.error("%s failed: %s", fname, exc, exc_info=True)
        return False


if __name__ == "__main__":
    scripts = [
        "01_ingest_eurostat.py",
        "02_ingest_worldbank.py",
        "03_ingest_oecd_pwt.py",
        "04_ingest_institutional.py",
        "05_build_panel.py",
    ]
    results = {}
    for script in scripts:
        results[script] = _run_module(script)

    log.info("=" * 60)
    log.info("Stage 01 Summary")
    log.info("=" * 60)
    for script, ok in results.items():
        status = "OK" if ok else "FAILED"
        log.info("  %-40s %s", script, status)

    if all(results.values()):
        log.info("All Stage 01 scripts completed successfully.")
    else:
        failed = [s for s, ok in results.items() if not ok]
        log.warning("Failed scripts: %s — review errors above.", failed)
