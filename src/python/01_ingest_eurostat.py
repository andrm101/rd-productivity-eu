"""
Stage 01.1 — Eurostat ingest
Fetches GERD, BERD, GOVERD, HERD, researchers, GDP-PPS, education, and patents
for all 29 panel countries via the eurostat package (SDMX JSON API).

Idempotent: re-running on the same date is a no-op if the manifest already
records a successful pull for today's vintage.

Outputs (data/raw/eurostat/):
  gerd.parquet            rd_e_gerdtot     GERD % GDP
  berd.parquet            rd_e_berdindr2   Business R&D % GDP
  goverd.parquet          rd_e_gerdgov     Government R&D % GDP
  herd.parquet            rd_e_gerdhes     Higher-Ed R&D % GDP
  researchers.parquet     rd_p_persocc     Researchers per 1000 active pop (FTE)
  rd_personnel.parquet    rd_p_persempoc   R&D personnel % total employment
  gdp_pps.parquet         nama_10_pc       GDP per capita, PPS (2015=100 ref)
  tertiary.parquet        edat_lfse_03     Tertiary attainment 25-64
  lll.parquet             trng_lfse_01     Lifelong learning rate
  patents_epo.parquet     pat_ep_ntot      EPO patent applications per million
  trademarks.parquet      ipr_ta_reg       EUIPO trademark registrations per million
  pop_growth.parquet      demo_gind        Population growth
  gross_savings.parquet   nama_10_gdp      Gross savings % GDP
"""

import importlib.util
import logging
from pathlib import Path

import eurostat
import pandas as pd


def _load(fname: str):
    p = Path(__file__).resolve().parent / fname
    spec = importlib.util.spec_from_file_location(fname.replace(".py", ""), p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

_cfg   = _load("00_config.py")
_utils = _load("00_utils.py")

COUNTRIES_PRIMARY = _cfg.COUNTRIES_PRIMARY
COUNTRIES_BREXIT  = _cfg.COUNTRIES_BREXIT
RAW               = _cfg.RAW
YEAR_START        = _cfg.YEAR_START
YEAR_END          = _cfg.YEAR_END
DATA_VINTAGE      = _cfg.DATA_VINTAGE
write_manifest    = _utils.write_manifest
is_already_ingested = _utils.is_already_ingested

log = logging.getLogger(__name__)

OUT_DIR = RAW / "eurostat"
OUT_DIR.mkdir(parents=True, exist_ok=True)
MANIFEST = OUT_DIR / "manifest.jsonl"
ALL_COUNTRIES = COUNTRIES_PRIMARY + COUNTRIES_BREXIT

# ── Dataset registry ──────────────────────────────────────────────────────────
# Each entry: (dataset_code, output_stem, filters, value_col_rename)
# filters is a dict passed to eurostat.get_data_df(code, filters=...)
DATASETS = [
    # GERD % GDP — all sectors (also used to derive GOVERD and HERD below)
    ("rd_e_gerdtot",   "gerd",         {"unit": "PC_GDP", "sectperf": "TOTAL"}, "gerd_pct"),
    # Business enterprise R&D % GDP (rd_e_berdindr2 = BERD by NACE industry)
    ("rd_e_berdindr2", "berd",         {"unit": "PC_GDP", "nace_r2": "TOTAL"},  "berd_pct"),
    # Researchers FTE (valid units: FTE, HC; valid prof_pos: RSE, TEC, OTH, TOTAL)
    ("rd_p_persocc",   "researchers",  {"unit": "FTE", "sex": "T", "prof_pos": "RSE"}, "researchers_pm"),
    # GDP per capita PPS (unit suffix _HAB = per inhabitant)
    ("nama_10_pc",     "gdp_pps",      {"unit": "CP_PPS_EU27_2020_HAB", "na_item": "B1GQ"}, "gdp_pps_idx"),
    # Tertiary educational attainment, 25–64
    ("edat_lfse_03",   "tertiary",     {"sex": "T", "age": "Y25-64", "isced11": "ED5-8"}, "tertiary_25_64"),
    # Lifelong learning participation 25–64
    ("trng_lfse_01",   "lll",          {"sex": "T", "age": "Y25-64"},                    "lll_part"),
    # EPO patent applications per million inhabitants
    ("pat_ep_ntot",    "patents_epo",  {"unit": "P_MHAB"},                               "pat_pct"),
    # Gross national saving rate % GDP (Eurostat SDG / national accounts indicator)
    ("tec00020",       "gross_savings",{},                                               "savings_pct"),
    # Population — annual change absolute (crude growth)
    ("demo_gind",      "pop_abs",      {"indic_de": "CNMIGRAT"},                         "pop_cnmigrat"),
]


def _fetch_dataset(
    code: str,
    stem: str,
    filters: dict,
    value_col: str,
) -> pd.DataFrame | None:
    log.info("Fetching %s (%s)…", code, stem)
    try:
        raw = eurostat.get_data_df(code, flags=False)
    except Exception as exc:
        log.error("Failed to fetch %s: %s", code, exc)
        return None

    if raw is None or raw.empty:
        log.warning("%s returned empty dataframe", code)
        return None

    # Apply filters: keep only rows matching filter values
    for col, val in filters.items():
        col_lower = col.lower()
        # Try exact column name, then case-insensitive match
        matched = [c for c in raw.columns if c.lower() == col_lower]
        if matched:
            raw = raw[raw[matched[0]].astype(str).str.upper() == str(val).upper()]

    # The eurostat package returns wide format with geo as "geo\TIME_PERIOD" or similar.
    # Identify geo column first (before melt so we can rename it cleanly).
    geo_col = next(
        (c for c in raw.columns
         if c.lower().startswith("geo") or c.lower() == "geo\\time_period"),
        None,
    )
    if geo_col is None:
        log.warning("No geo column found in %s — columns: %s", code, raw.columns.tolist()[:10])
        return None
    raw = raw.rename(columns={geo_col: "country"})

    # Melt year columns — eurostat returns wide by default (one col per year)
    year_cols = [c for c in raw.columns if str(c).isdigit()]
    id_cols   = [c for c in raw.columns if not str(c).isdigit()]
    df = raw.melt(id_vars=id_cols, value_vars=year_cols, var_name="year", value_name=value_col)

    df["country"] = df["country"].astype(str).str.strip().str.upper()
    # Eurostat uses EL for Greece and UK for United Kingdom; remap to standard ISO2
    df["country"] = df["country"].replace({"EL": "GR", "UK": "GB"})
    df["year"]    = df["year"].astype(int)

    # Filter to panel scope
    all_panel = set(COUNTRIES_PRIMARY + COUNTRIES_BREXIT)
    df = df[
        df["country"].isin(all_panel) &
        df["year"].between(YEAR_START, YEAR_END)
    ][["country", "year", value_col]].copy()

    df[value_col] = pd.to_numeric(df[value_col], errors="coerce")
    df = df.dropna(subset=[value_col])
    df = df.sort_values(["country", "year"]).reset_index(drop=True)
    return df


def _extract_goverd_herd() -> None:
    """
    GOVERD (sectperf=GOV) and HERD (sectperf=HES) are not separate Eurostat
    datasets — they are subsets of rd_e_gerdtot. Extract them from the raw
    GERD fetch (which downloads all sectperf values) by re-fetching with
    sector-specific filters.
    """
    for sectperf, stem, col in [("GOV", "goverd", "goverd_pct"), ("HES", "herd", "herd_pct")]:
        out_path = OUT_DIR / f"{stem}.parquet"
        log.info("Extracting %s from rd_e_gerdtot (sectperf=%s)…", stem, sectperf)
        df = _fetch_dataset("rd_e_gerdtot", stem, {"unit": "PC_GDP", "sectperf": sectperf}, col)
        if df is not None and not df.empty:
            df.to_parquet(out_path, index=False)
            log.info("  → %s  (%d rows, %d countries)", out_path.name, len(df), df["country"].nunique())
        else:
            log.warning("  → %s  SKIPPED (no data)", stem)


def run() -> None:
    source_id = "eurostat_stage01"
    if is_already_ingested(MANIFEST, source_id, DATA_VINTAGE):
        log.info("Eurostat already ingested for vintage %s today — skipping.", DATA_VINTAGE)
        return

    written: list[Path] = []
    for code, stem, filters, value_col in DATASETS:
        out_path = OUT_DIR / f"{stem}.parquet"
        df = _fetch_dataset(code, stem, filters, value_col)
        if df is not None and not df.empty:
            df.to_parquet(out_path, index=False)
            written.append(out_path)
            log.info("  → %s  (%d rows, %d countries)",
                     out_path.name, len(df), df["country"].nunique())
        else:
            log.warning("  → %s  SKIPPED (no data)", stem)

    # GOVERD and HERD extracted from rd_e_gerdtot by sector
    _extract_goverd_herd()
    for stem in ["goverd", "herd"]:
        p = OUT_DIR / f"{stem}.parquet"
        if p.exists():
            written.append(p)

    write_manifest(
        MANIFEST, source_id,
        source_url="https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/",
        files=written, vintage=DATA_VINTAGE,
    )
    log.info("Eurostat ingest complete — %d files written.", len(written))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s")
    run()
