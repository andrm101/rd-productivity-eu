"""
Stage 01.3 — OECD + Penn World Table ingest

OECD MSTI (locally placed data/raw/oecd/MSTI OECD.csv):
  SDMX long format — REF_AREA (ISO3), MEASURE, UNIT_MEASURE, TIME_PERIOD, OBS_VALUE
  Measures extracted:
    msti_gerd_pct      — GERD % GDP (MEASURE=G, UNIT_MEASURE=PT_B1GQ)
    msti_researchers   — Researchers FTE (MEASURE=T_RS, UNIT_MEASURE=FTE)
  Note: triadic patents not present in this MSTI export; stub columns retained
        for downstream joins (triadic_pct, stem_share will be NaN).

PISA 2022 Math Scores (locally placed data/raw/oecd/PISA Math Scores.csv):
  Single-wave cross-section (2022 only) — used as time-invariant level shifter.
  Output: pisa_math_2022 per country.

Penn World Table 10.01:
  Check for manually placed data/raw/pwt/pwt1001.xlsx first (official download).
  Variables retained:
    rtfpna    — TFP (level, US=1, 2017 PPPs, national accounts basis)
    rgdpna    — Real GDP (mil. 2017 USD)
    pop       — Population (millions)
    hc        — Human capital index (average years of schooling + Mincerian returns)
    labsh     — Labour share of income
    delta     — Capital depreciation rate (used in n+g+delta construction)
  Coverage: 1950–2019; TFP missing for 2020–2024.

Output files:
  data/raw/oecd/oecd_msti.parquet
  data/raw/oecd/oecd_pisa.parquet
  data/raw/pwt/pwt1001.parquet
"""

import logging
from pathlib import Path
import importlib.util

import requests
import pandas as pd

log = logging.getLogger(__name__)

def _load(fname: str):
    p = Path(__file__).resolve().parent / fname
    spec = importlib.util.spec_from_file_location(fname.replace(".py",""), p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


# ── PWT 10.01 ─────────────────────────────────────────────────────────────────
PWT_OWID_CSV = (
    "https://raw.githubusercontent.com/owid/owid-datasets/master/"
    "datasets/Penn%20World%20Table%2010.0%20(Feenstra%20et%20al.%20(2015))/"
    "Penn%20World%20Table%2010.0%20(Feenstra%20et%20al.%20(2015)).csv"
)

PWT_VARS = ["countrycode", "country", "year", "rgdpna", "pop", "hc", "rtfpna", "labsh", "delta"]

_ISO3_TO_ISO2 = {
    "AUT":"AT","BEL":"BE","BGR":"BG","CYP":"CY","CZE":"CZ","DEU":"DE",
    "DNK":"DK","EST":"EE","ESP":"ES","FIN":"FI","FRA":"FR","GRC":"GR",
    "HRV":"HR","HUN":"HU","IRL":"IE","ITA":"IT","ISL":"IS","LTU":"LT",
    "LUX":"LU","LVA":"LV","MLT":"MT","NLD":"NL","NOR":"NO","POL":"PL",
    "PRT":"PT","ROU":"RO","SWE":"SE","SVN":"SI","SVK":"SK","CHE":"CH",
    "GBR":"GB",
}

# ── PISA country name → ISO2 ──────────────────────────────────────────────────
_PISA_NAME_TO_ISO2 = {
    "Austria":"AT","Belgium":"BE","Bulgaria":"BG","Cyprus":"CY","Czech Republic":"CZ",
    "Germany":"DE","Denmark":"DK","Estonia":"EE","Spain":"ES","Finland":"FI",
    "France":"FR","Greece":"GR","Croatia":"HR","Hungary":"HU","Ireland":"IE",
    "Italy":"IT","Iceland":"IS","Lithuania":"LT","Luxembourg":"LU","Latvia":"LV",
    "Malta":"MT","Netherlands":"NL","Norway":"NO","Poland":"PL","Portugal":"PT",
    "Romania":"RO","Sweden":"SE","Slovenia":"SI","Slovak Republic":"SK","Switzerland":"CH",
    "United Kingdom":"GB",
}


def _fetch_pwt(out_dir: Path, cfg) -> Path | None:
    out_path = out_dir / "pwt1001.parquet"

    manual_xlsx = out_dir / "pwt1001.xlsx"
    df = None

    if manual_xlsx.exists():
        log.info("Loading PWT from manually placed XLSX: %s", manual_xlsx)
        try:
            df = pd.read_excel(manual_xlsx, sheet_name="Data", engine="openpyxl")
            log.info("PWT XLSX loaded (%d rows)", len(df))
        except Exception as exc:
            log.warning("Manual XLSX load failed: %s", exc)

    if df is None:
        log.info("Trying OWID PWT CSV mirror…")
        try:
            df = pd.read_csv(PWT_OWID_CSV)
            log.info("OWID PWT CSV downloaded (%d rows)", len(df))
        except Exception as exc:
            log.warning("OWID CSV failed (%s).", exc)

    if df is None:
        log.warning(
            "PWT 10.01 not available.\n"
            "Manual download: https://dataverse.nl/dataset.xhtml?persistentId=doi:10.34894/QT5BCC\n"
            "Place pwt1001.xlsx in data/raw/pwt/ and re-run.\n"
            "Writing placeholder — TFP (ln_tfp) will be missing until PWT is supplied."
        )
        placeholder = pd.DataFrame(columns=["country_code","year","rgdpna","pop","hc",
                                             "rtfpna","labsh","delta"])
        placeholder.to_parquet(out_path, index=False)
        return out_path

    df.columns = [c.lower().strip() for c in df.columns]

    available = [v for v in PWT_VARS if v in df.columns]
    missing   = [v for v in PWT_VARS if v not in df.columns]
    if missing:
        log.warning("PWT variables not found (may vary by source): %s", missing)

    df = df[available].copy()
    df["year"] = pd.to_numeric(df["year"], errors="coerce").astype("Int64")

    if "countrycode" in df.columns:
        df["country_iso2"] = df["countrycode"].map(_ISO3_TO_ISO2)
    else:
        df["country_iso2"] = df.get("country", pd.Series(dtype=str))

    panel_countries = set(cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT)
    df = df[
        df["country_iso2"].isin(panel_countries) &
        df["year"].between(cfg.YEAR_START, cfg.YEAR_END)
    ].rename(columns={"country_iso2": "country_code"}).reset_index(drop=True)

    df.to_parquet(out_path, index=False)
    log.info("PWT saved → %s (%d rows)", out_path.name, len(df))
    return out_path


def _fetch_oecd_msti(out_dir: Path, cfg) -> Path | None:
    """
    Parse the manually placed MSTI OECD.csv (SDMX long format).
    Extracts GERD % GDP and Researchers FTE as supplementary OECD series.
    Triadic patents and STEM graduates are not present in this export —
    stub columns are written as NaN for downstream join compatibility.
    Falls back to SDMX live endpoint if the local file is absent.
    """
    out_path = out_dir / "oecd_msti.parquet"
    manual_csv = out_dir / "MSTI OECD.csv"

    iso2_set = set(cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT)

    if manual_csv.exists():
        log.info("Parsing local MSTI file: %s", manual_csv)
        try:
            df_raw = pd.read_csv(manual_csv, low_memory=False)
            df_raw.columns = [c.strip() for c in df_raw.columns]

            # Required columns: REF_AREA (ISO3), MEASURE, UNIT_MEASURE, TIME_PERIOD, OBS_VALUE
            country_col = "REF_AREA"
            measure_col = "MEASURE"
            unit_col    = "UNIT_MEASURE"
            year_col    = "TIME_PERIOD"
            value_col   = "OBS_VALUE"

            for c in [country_col, measure_col, unit_col, year_col, value_col]:
                if c not in df_raw.columns:
                    raise ValueError(f"Expected column '{c}' not found in MSTI CSV.")

            def _extract_series(measure_code: str, unit_code: str, out_col: str) -> pd.DataFrame | None:
                sub = df_raw[
                    (df_raw[measure_col] == measure_code) &
                    (df_raw[unit_col] == unit_code)
                ][[country_col, year_col, value_col]].copy()
                if sub.empty:
                    log.warning("MSTI: no rows for MEASURE=%s UNIT=%s", measure_code, unit_code)
                    return None
                sub.columns = ["country_iso3", "year", out_col]
                sub["country"] = sub["country_iso3"].str.strip().str.upper().map(_ISO3_TO_ISO2)
                sub["year"]    = pd.to_numeric(sub["year"], errors="coerce").astype("Int64")
                sub[out_col]   = pd.to_numeric(sub[out_col], errors="coerce")
                sub = sub[
                    sub["country"].isin(iso2_set) &
                    sub["year"].between(cfg.YEAR_START, cfg.YEAR_END)
                ]
                return sub[["country", "year", out_col]].dropna(subset=[out_col]).reset_index(drop=True)

            gerd    = _extract_series("G",    "PT_B1GQ", "msti_gerd_pct")
            rsch    = _extract_series("T_RS", "FTE",     "msti_researchers_fte")

            # Build result: outer join on country/year; add empty stub columns for
            # triadic_pct and stem_share (not in this MSTI export).
            parts = [p for p in [gerd, rsch] if p is not None and not p.empty]
            if not parts:
                raise ValueError("No usable series extracted from local MSTI CSV.")

            result = parts[0]
            for p in parts[1:]:
                result = result.merge(p, on=["country", "year"], how="outer")

            # Stub columns keep downstream join stable
            result["triadic_pct"] = float("nan")
            result["stem_share"]  = float("nan")
            result = result.sort_values(["country", "year"]).reset_index(drop=True)
            result.to_parquet(out_path, index=False)
            log.info("MSTI saved → %s (%d rows, %d countries)", out_path.name,
                     len(result), result["country"].nunique())
            return out_path

        except Exception as exc:
            log.error("Local MSTI parse failed: %s — falling back to live SDMX.", exc)

    # ── Live SDMX fallback ────────────────────────────────────────────────────
    sdmx_url = (
        "https://sdmx.oecd.org/public/rest/data/"
        "OECD.STI.STP,DSD_MSTI@DF_MSTI,1.0/"
        "all?dimensionAtObservation=AllDimensions&format=csvfilewithlabels"
    )
    log.info("Trying OECD SDMX live endpoint…")
    try:
        resp = requests.get(sdmx_url, timeout=120)
        resp.raise_for_status()
        from io import StringIO
        df_raw = pd.read_csv(StringIO(resp.text))
        df_raw.columns = [c.lower().strip() for c in df_raw.columns]

        c_col = next((c for c in df_raw.columns if "ref_area" in c or c == "country"), None)
        y_col = next((c for c in df_raw.columns if "time" in c or "year" in c), None)
        m_col = next((c for c in df_raw.columns if c == "measure"), None)
        v_col = next((c for c in df_raw.columns if c in ("obs_value","value","obsvalue")), None)

        if not all([c_col, y_col, v_col]):
            raise ValueError("Cannot identify required SDMX columns.")

        placeholder = pd.DataFrame(columns=["country","year","msti_gerd_pct",
                                             "msti_researchers_fte","triadic_pct","stem_share"])
        placeholder.to_parquet(out_path, index=False)
        log.warning("SDMX endpoint returned data but parsing is minimal — placeholder written.")
        return out_path

    except Exception as exc:
        log.error("OECD MSTI all sources failed: %s — writing empty placeholder.", exc)
        placeholder = pd.DataFrame(columns=["country","year","msti_gerd_pct",
                                             "msti_researchers_fte","triadic_pct","stem_share"])
        placeholder.to_parquet(out_path, index=False)
        return out_path


def _fetch_pisa(out_dir: Path, cfg) -> Path | None:
    """
    Parse PISA 2022 Math Scores CSV (manually placed).
    Single cross-section — used as time-invariant level shifter in Stage 05+.
    Output: country, pisa_math_2022.
    """
    out_path   = out_dir / "oecd_pisa.parquet"
    pisa_csv   = out_dir / "PISA Math Scores.csv"

    if not pisa_csv.exists():
        log.warning("PISA CSV not found at %s — skipping.", pisa_csv)
        return None

    # File format: 2-line meta header, then 'Category','Mathematics performance (PISA)'
    df = pd.read_csv(pisa_csv, skiprows=2)
    df.columns = ["country_name", "pisa_math_2022"]

    # Strip trailing asterisks (PISA uses * for non-OECD observers)
    df["country_name"] = df["country_name"].str.strip().str.rstrip("*").str.strip()
    df["pisa_math_2022"] = pd.to_numeric(df["pisa_math_2022"], errors="coerce")

    df["country"] = df["country_name"].map(_PISA_NAME_TO_ISO2)

    panel = set(cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT)
    df = df[df["country"].isin(panel)][["country", "pisa_math_2022"]].dropna(subset=["country"])

    df.to_parquet(out_path, index=False)
    log.info("PISA 2022 saved → %s (%d countries)", out_path.name, len(df))
    unmapped = set(panel) - set(df["country"].unique())
    if unmapped:
        log.warning("PISA: no score for %s (not in 2022 wave)", sorted(unmapped))
    return out_path


def run() -> None:
    cfg   = _load("00_config.py")
    utils = _load("00_utils.py")

    pwt_dir  = cfg.RAW / "pwt";  pwt_dir.mkdir(parents=True, exist_ok=True)
    oecd_dir = cfg.RAW / "oecd"; oecd_dir.mkdir(parents=True, exist_ok=True)
    manifest = cfg.RAW / "oecd" / "manifest.jsonl"

    source_id = "oecd_pwt_stage01"
    if utils.is_already_ingested(manifest, source_id, cfg.DATA_VINTAGE):
        log.info("OECD/PWT already ingested today — skipping.")
        return

    written = []
    pwt_path  = _fetch_pwt(pwt_dir, cfg)
    msti_path = _fetch_oecd_msti(oecd_dir, cfg)
    pisa_path = _fetch_pisa(oecd_dir, cfg)

    if pwt_path:  written.append(pwt_path)
    if msti_path: written.append(msti_path)
    if pisa_path: written.append(pisa_path)

    utils.write_manifest(
        manifest, source_id,
        source_url="https://www.rug.nl/ggdc/productivity/pwt/ | https://stats.oecd.org/",
        files=written, vintage=cfg.DATA_VINTAGE,
    )
    log.info("OECD/PWT ingest complete.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s")
    run()
