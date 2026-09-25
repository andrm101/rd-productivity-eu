"""
Central configuration for the rd-productivity-eu pipeline.
All paths are relative to the project root; resolved at import time.
"""
from pathlib import Path
import logging

# ── Project root (two levels up from this file: src/python/ → project root) ──
ROOT = Path(__file__).resolve().parents[2]

RAW       = ROOT / "data" / "raw"
STAGED    = ROOT / "data" / "staged"
PROCESSED = ROOT / "data" / "processed"
REPORTS   = ROOT / "reports"
FIGURES   = ROOT / "figures"
DB_PATH   = ROOT / "data" / "panel.duckdb"

# ── Vintage pin ───────────────────────────────────────────────────────────────
DATA_VINTAGE = "2026-06"   # update if re-running against a newer extract

# ── Panel dimensions ─────────────────────────────────────────────────────────
YEAR_START = 1998
YEAR_END   = 2024

# EU-25 thesis countries + Ireland + EEA triad
COUNTRIES_PRIMARY = [
    # Original 25
    "AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI",
    "FR", "GR", "HR", "HU", "IT", "LT", "LU", "LV", "MT", "NL",
    "PL", "PT", "RO", "SE", "SK",
    # Corrections / extensions
    "IE",  # Ireland (error of omission in thesis)
    # EEA non-EU triad
    "NO", "IS", "CH",
]

# UK included only in Brexit robustness slice (2010–2019)
COUNTRIES_BREXIT = ["GB"]

N_COUNTRIES = len(COUNTRIES_PRIMARY)   # 29

# ── Regime break dummies ──────────────────────────────────────────────────────
REGIME_BREAKS = {
    "gfc":      2008,
    "covid":    2020,
    "ukraine":  2022,
}

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
