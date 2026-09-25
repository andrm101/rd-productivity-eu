"""
Stage 01.2 — World Bank ingest
Fetches via wbgapi (World Bank public REST API).

Series pulled:
  NY.GDP.PCAP.PP.KD   GDP per capita, PPP (constant 2017 USD) — WB version
  NY.GNS.ICTR.ZS      Gross savings % GDP
  SP.POP.GROW         Population growth (annual %)
  SE.TER.ENRR         School enrolment tertiary % (gross) — supplementary
  IT.NET.USER.ZS      Individuals using the Internet % — proxy for digital capital

Output: data/raw/worldbank/wb_series.parquet  (long format)
"""

import logging
from pathlib import Path

import pandas as pd
import wbgapi

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))

log = logging.getLogger(__name__)

# Lazy import — config file uses no-leading-number name
def _load_config():
    import importlib.util, os
    cfg_path = Path(__file__).resolve().parent / "00_config.py"
    spec = importlib.util.spec_from_file_location("config", cfg_path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def _load_utils():
    import importlib.util
    u_path = Path(__file__).resolve().parent / "00_utils.py"
    spec = importlib.util.spec_from_file_location("utils", u_path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# WB country codes (ISO2 → ISO3 mapping needed by wbgapi)
_ISO2_TO_ISO3 = {
    "AT":"AUT","BE":"BEL","BG":"BGR","CY":"CYP","CZ":"CZE","DE":"DEU",
    "DK":"DNK","EE":"EST","ES":"ESP","FI":"FIN","FR":"FRA","GR":"GRC",
    "HR":"HRV","HU":"HUN","IE":"IRL","IT":"ITA","IS":"ISL","LT":"LTU",
    "LU":"LUX","LV":"LVA","MT":"MLT","NL":"NLD","NO":"NOR","PL":"POL",
    "PT":"PRT","RO":"ROU","SE":"SWE","SI":"SVN","SK":"SVK","CH":"CHE",
    "GB":"GBR",
}

SERIES = [
    ("NY.GDP.PCAP.PP.KD", "gdp_pc_ppp_2017usd"),
    ("NY.GNS.ICTR.ZS",    "savings_pct_wb"),
    ("SP.POP.GROW",        "pop_growth_wb"),
    ("SE.TER.ENRR",        "tertiary_enrolment"),
    ("IT.NET.USER.ZS",     "internet_users_pct"),
]


def run() -> None:
    cfg   = _load_config()
    utils = _load_utils()

    OUT_DIR  = cfg.RAW / "worldbank"
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    MANIFEST = OUT_DIR / "manifest.jsonl"

    source_id = "worldbank_stage01"
    if utils.is_already_ingested(MANIFEST, source_id, cfg.DATA_VINTAGE):
        log.info("World Bank already ingested for vintage %s today — skipping.", cfg.DATA_VINTAGE)
        return

    all_iso3 = [
        _ISO2_TO_ISO3[c]
        for c in cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT
        if c in _ISO2_TO_ISO3
    ]
    years = list(range(cfg.YEAR_START, cfg.YEAR_END + 1))

    frames: list[pd.DataFrame] = []
    for series_code, col_name in SERIES:
        log.info("Fetching %s (%s)…", series_code, col_name)
        try:
            df_raw = wbgapi.data.DataFrame(
                series_code, economy=all_iso3, time=years, labels=False
            )
            # wbgapi returns wide (years as columns), index = economy
            df = df_raw.reset_index()
            df = df.melt(id_vars=["economy"], var_name="year", value_name=col_name)
            df["year"] = df["year"].astype(str).str.replace("YR", "").astype(int)
            # Map ISO3 back to ISO2
            inv_map = {v: k for k, v in _ISO2_TO_ISO3.items()}
            df["country"] = df["economy"].map(inv_map)
            df = df.dropna(subset=["country"])
            df = df[["country", "year", col_name]].copy()
            df[col_name] = pd.to_numeric(df[col_name], errors="coerce")
            frames.append(df)
            log.info("  → %s  (%d rows)", col_name, len(df.dropna(subset=[col_name])))
        except Exception as exc:
            log.error("Failed %s: %s", series_code, exc)

    if not frames:
        log.error("No World Bank series fetched.")
        return

    # Merge all series on country × year
    base = frames[0]
    for f in frames[1:]:
        base = base.merge(f, on=["country", "year"], how="outer")
    base = base.sort_values(["country", "year"]).reset_index(drop=True)

    out_path = OUT_DIR / "wb_series.parquet"
    base.to_parquet(out_path, index=False)
    log.info("World Bank ingest complete — %d rows written to %s", len(base), out_path.name)

    utils.write_manifest(
        MANIFEST, source_id,
        source_url="https://api.worldbank.org/v2/",
        files=[out_path], vintage=cfg.DATA_VINTAGE,
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s")
    run()
