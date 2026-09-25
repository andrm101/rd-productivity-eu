"""
Stage 01.4 — Institutional quality data ingest

Sources:
  1. World Governance Indicators (WGI) — World Bank public API (wbgapi)
       wgi_gov_eff     Government effectiveness
       wgi_rule_of_law Rule of law
       wgi_reg_quality Regulatory quality
       wgi_voice       Voice and accountability
       wgi_polstab     Political stability
       wgi_corruption  Control of corruption

  2. KOF Globalisation Index (ETH Zürich) — public CSV download
       kof_index       Overall KOF globalisation index
       kof_econ        Economic globalisation sub-index
       kof_social      Social globalisation sub-index
       kof_political   Political globalisation sub-index

  3. Heritage Foundation Index of Economic Freedom — PLACEHOLDER
     Heritage does not provide a free bulk API. If you supply the raw CSV
     (exported from heritage.org/index/explore), place it at:
       data/raw/heritage/heritage_ief.csv
     with columns: country_iso2, year, ief_overall, ief_rl, ief_gs, ief_re, ief_om
     This script will process it if present; otherwise skip with a warning.

Output: data/raw/wgi/wgi_kof.parquet
        data/raw/heritage/heritage_ief.parquet  (if Heritage CSV present)
"""

import logging
from pathlib import Path
import importlib.util

import pandas as pd
import wbgapi

log = logging.getLogger(__name__)

def _load(fname: str):
    p = Path(__file__).resolve().parent / fname
    spec = importlib.util.spec_from_file_location(fname.replace(".py",""), p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


# ── WGI series codes ──────────────────────────────────────────────────────────
WGI_SERIES = [
    ("GE.EST",  "wgi_gov_eff"),
    ("RL.EST",  "wgi_rule_of_law"),
    ("RQ.EST",  "wgi_reg_quality"),
    ("VA.EST",  "wgi_voice"),
    ("PV.EST",  "wgi_polstab"),
    ("CC.EST",  "wgi_corruption"),
]

_ISO2_TO_ISO3 = {
    "AT":"AUT","BE":"BEL","BG":"BGR","CY":"CYP","CZ":"CZE","DE":"DEU",
    "DK":"DNK","EE":"EST","ES":"ESP","FI":"FIN","FR":"FRA","GR":"GRC",
    "HR":"HRV","HU":"HUN","IE":"IRL","IT":"ITA","IS":"ISL","LT":"LTU",
    "LU":"LUX","LV":"LVA","MT":"MLT","NL":"NLD","NO":"NOR","PL":"POL",
    "PT":"PRT","RO":"ROU","SE":"SWE","SI":"SVN","SK":"SVK","CH":"CHE",
    "GB":"GBR",
}

# ── KOF Globalisation Index (ETH Zürich) ─────────────────────────────────────
# Public CSV available at https://kof.ethz.ch/en/forecasts-and-indicators/indicators/kof-globalisation-index.html
# Direct download link (may require manual retrieval if URL changes)
KOF_URL = "https://ethz.ch/content/dam/ethz/special-interest/dual/kof-dam/documents/Globalization/2024/KOFGI_2024_public.xlsx"


def _fetch_wgi(cfg, iso3_list: list[str], years: list[int]) -> pd.DataFrame | None:
    """
    Download each WGI indicator as a CSV zip from the World Bank bulk download
    endpoint (wbgapi cannot access WGI source 3 correctly).
    """
    import io, zipfile, requests

    inv_map = {v: k for k, v in _ISO2_TO_ISO3.items()}
    iso3_set = set(iso3_list)
    year_set = set(years)
    frames = []

    for code, col_name in WGI_SERIES:
        log.info("Fetching WGI %s (%s) via bulk CSV…", code, col_name)
        url = f"https://api.worldbank.org/v2/en/indicator/{code}?downloadformat=csv"
        try:
            resp = requests.get(url, timeout=60)
            resp.raise_for_status()
            with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
                # The zip contains metadata CSV + data CSV; data file is largest
                csv_name = max(zf.namelist(), key=lambda n: zf.getinfo(n).file_size)
                with zf.open(csv_name) as f:
                    raw = pd.read_csv(f, skiprows=4, encoding="utf-8", low_memory=False)

            # World Bank CSV format: Country Name, Country Code, Indicator Name,
            # Indicator Code, <year columns>
            raw.columns = [str(c).strip() for c in raw.columns]
            code_col = next((c for c in raw.columns if c.lower() in
                             ("country code", "countrycode")), None)
            if code_col is None:
                raise ValueError(f"Cannot find country code column in {csv_name}")

            year_cols = [c for c in raw.columns if c.isdigit()]
            keep = [code_col] + year_cols
            df = raw[keep].copy()
            df = df[df[code_col].isin(iso3_set)]
            df = df.melt(id_vars=[code_col], value_vars=year_cols,
                         var_name="year", value_name=col_name)
            df["year"]    = pd.to_numeric(df["year"], errors="coerce").astype("Int64")
            df["country"] = df[code_col].map(inv_map)
            df = df.dropna(subset=["country"])
            df = df[df["year"].isin(year_set)]
            df[col_name] = pd.to_numeric(df[col_name], errors="coerce")
            df = df[["country","year",col_name]].reset_index(drop=True)
            frames.append(df)
            log.info("  → %s: %d non-null values (%d countries)",
                     col_name, df[col_name].notna().sum(), df["country"].nunique())

        except Exception as exc:
            log.error("WGI %s failed: %s", code, exc)

    if not frames:
        return None
    base = frames[0]
    for f in frames[1:]:
        base = base.merge(f, on=["country","year"], how="outer")
    return base.sort_values(["country","year"]).reset_index(drop=True)


_ISO3_TO_ISO2_KOF = {
    "AUT":"AT","BEL":"BE","BGR":"BG","CYP":"CY","CZE":"CZ","DEU":"DE",
    "DNK":"DK","EST":"EE","ESP":"ES","FIN":"FI","FRA":"FR","GRC":"GR",
    "HRV":"HR","HUN":"HU","IRL":"IE","ITA":"IT","ISL":"IS","LTU":"LT",
    "LUX":"LU","LVA":"LV","MLT":"MT","NLD":"NL","NOR":"NO","POL":"PL",
    "PRT":"PT","ROU":"RO","SWE":"SE","SVN":"SI","SVK":"SK","CHE":"CH",
    "GBR":"GB",
}


def _fetch_kof(out_dir: Path, cfg) -> pd.DataFrame | None:
    import requests
    log.info("Fetching KOF Globalisation Index…")

    # Check for manually placed file first (in raw root or wgi subfolder)
    manual_candidates = [
        cfg.RAW / "KOFGI_2025_public.xlsx",
        cfg.RAW / "KOFGI_2024_public.xlsx",
        out_dir / "kofgi_raw.xlsx",
    ]
    kof_path = next((p for p in manual_candidates if p.exists()), None)

    if kof_path is None:
        log.info("No local KOF file found — attempting download…")
        kof_path = out_dir / "kofgi_raw.xlsx"
        try:
            resp = requests.get(KOF_URL, timeout=60)
            resp.raise_for_status()
            with open(kof_path, "wb") as f:
                f.write(resp.content)
        except Exception as exc:
            log.warning("KOF download failed (%s) — creating placeholder.", exc)
            return pd.DataFrame(columns=["country","year","kof_index","kof_econ","kof_social","kof_political"])

    try:
        df_raw = pd.read_excel(kof_path, engine="openpyxl")
        log.info("KOF loaded from %s, shape %s", kof_path.name, df_raw.shape)
        # KOF 2025 columns: code (ISO3), country, year, KOFGI, KOFEcGI, KOFSoGI, KOFPoGI, ...
        # Keep original case for matching
        col_map_raw = {c: c for c in df_raw.columns}
        df_raw.columns = [c.strip() for c in df_raw.columns]

        # KOF 2025 actual column structure: code (ISO3), country, year, KOFGI, KOFEcGI, KOFSoGI, KOFPoGI
        code_col  = next((c for c in df_raw.columns if c.lower() in ("code","iso","iso_code","country_code")), None)
        year_col  = next((c for c in df_raw.columns if c.lower() in ("year","time")), None)
        # Match case-insensitively using exact KOF 2025 names or fallbacks
        kofgi_col = next((c for c in df_raw.columns if c.upper() in ("KOFGI","KOF_INDEX")), None)
        kof_e_col = next((c for c in df_raw.columns if c.upper() in ("KOFECGI","KOFECON","KOF_ECON")), None)
        kof_s_col = next((c for c in df_raw.columns if c.upper() in ("KOFSOGI","KOFSOCIAL","KOF_SOCIAL")), None)
        kof_p_col = next((c for c in df_raw.columns if c.upper() in ("KOFPOGI","KOFPOLITICAL","KOF_POLITICAL")), None)

        log.info("KOF column matches: code=%s year=%s kofgi=%s econ=%s social=%s pol=%s",
                 code_col, year_col, kofgi_col, kof_e_col, kof_s_col, kof_p_col)

        rename_map = {}
        if kofgi_col: rename_map[kofgi_col] = "kof_index"
        if kof_e_col: rename_map[kof_e_col] = "kof_econ"
        if kof_s_col: rename_map[kof_s_col] = "kof_social"
        if kof_p_col: rename_map[kof_p_col] = "kof_political"

        keep_cols = [c for c in [code_col, year_col] + list(rename_map.keys()) if c]
        df = df_raw[keep_cols].rename(columns={code_col: "country_iso3", year_col: "year"} | rename_map)
        # KOF uses ISO3 — map to ISO2
        df["country"] = df["country_iso3"].str.upper().str.strip().map(_ISO3_TO_ISO2_KOF)
        df["year"]    = pd.to_numeric(df["year"], errors="coerce").astype("Int64")

        panel = set(cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT)
        df = df[df["country"].isin(panel) & df["year"].between(cfg.YEAR_START, cfg.YEAR_END)]
        kof_value_cols = [c for c in ["kof_index","kof_econ","kof_social","kof_political"] if c in df.columns]
        for c in kof_value_cols:
            df[c] = pd.to_numeric(df[c], errors="coerce")
        df = df[["country","year"] + kof_value_cols].dropna(subset=["country"]).reset_index(drop=True)
        log.info("KOF parsed: %d rows, %d countries", len(df), df["country"].nunique())
        return df

    except Exception as exc:
        log.warning("KOF fetch failed (%s) — creating placeholder.", exc)
        return pd.DataFrame(columns=["country","year","kof_index","kof_econ","kof_social","kof_political"])


_HERITAGE_NAME_TO_ISO2 = {
    "Austria":"AT","Belgium":"BE","Bulgaria":"BG","Cyprus":"CY","Czech Republic":"CZ",
    "Germany":"DE","Denmark":"DK","Estonia":"EE","Spain":"ES","Finland":"FI",
    "France":"FR","Greece":"GR","Croatia":"HR","Hungary":"HU","Ireland":"IE",
    "Italy":"IT","Iceland":"IS","Lithuania":"LT","Luxembourg":"LU","Latvia":"LV",
    "Malta":"MT","Netherlands":"NL","Norway":"NO","Poland":"PL","Portugal":"PT",
    "Romania":"RO","Sweden":"SE","Slovenia":"SI","Slovakia":"SK","Switzerland":"CH",
    "United Kingdom":"GB",
}

def _process_heritage(heritage_dir: Path) -> Path | None:
    # Accept both heritage_ief.csv and heritage_ief.csv.csv (double-extension from Windows save)
    raw_csv = next(
        (p for p in [heritage_dir / "heritage_ief.csv", heritage_dir / "heritage_ief.csv.csv"]
         if p.exists()), None
    )
    out_path = heritage_dir / "heritage_ief.parquet"
    if raw_csv is None:
        log.warning(
            "Heritage IEF CSV not found in %s.\n"
            "Download from https://www.heritage.org/index/explore and save as:\n"
            "  data/raw/heritage/heritage_ief.csv",
            heritage_dir,
        )
        return None

    # Heritage export has a 3-line header block before the actual column row
    df = pd.read_csv(raw_csv, skiprows=3)
    df.columns = [c.strip() for c in df.columns]
    log.info("Heritage raw: %d rows, columns: %s", len(df), df.columns.tolist())

    # Map country names → ISO2
    df["country"] = df["Country"].map(_HERITAGE_NAME_TO_ISO2)
    df["year"]    = pd.to_numeric(df["Index Year"], errors="coerce").astype("Int64")
    df["ief_overall"] = pd.to_numeric(df.get("Overall Score", pd.Series(dtype=float)), errors="coerce")

    # Construct sub-indices from the 12 component pillars
    # Rule of Law pillar
    rl_cols = ["Property Rights", "Government Integrity", "Judicial Effectiveness"]
    # Government Size pillar
    gs_cols = ["Tax Burden", "Government Spending", "Fiscal Health"]
    # Regulatory Efficiency pillar
    re_cols = ["Business Freedom", "Labor Freedom", "Monetary Freedom"]
    # Open Markets pillar
    om_cols = ["Trade Freedom", "Investment Freedom", "Financial Freedom"]

    for target, cols in [("ief_rl", rl_cols), ("ief_gs", gs_cols),
                         ("ief_re", re_cols), ("ief_om", om_cols)]:
        present = [c for c in cols if c in df.columns]
        if present:
            df[target] = df[present].apply(pd.to_numeric, errors="coerce").mean(axis=1)
        else:
            log.warning("Heritage: no columns found for %s (%s)", target, cols)
            df[target] = float("nan")

    keep = ["country","year","ief_overall","ief_rl","ief_gs","ief_re","ief_om"]
    df = df[keep].dropna(subset=["country","year"]).reset_index(drop=True)
    df.to_parquet(out_path, index=False)
    log.info("Heritage IEF processed → %s (%d rows, %d countries)",
             out_path.name, len(df), df["country"].notna().sum())
    return out_path


def run() -> None:
    cfg   = _load("00_config.py")
    utils = _load("00_utils.py")

    wgi_dir  = cfg.RAW / "wgi";      wgi_dir.mkdir(parents=True, exist_ok=True)
    her_dir  = cfg.RAW / "heritage"; her_dir.mkdir(parents=True, exist_ok=True)
    manifest = wgi_dir / "manifest.jsonl"

    source_id = "institutional_stage01"
    if utils.is_already_ingested(manifest, source_id, cfg.DATA_VINTAGE):
        log.info("Institutional data already ingested today — skipping.")
        return

    iso3_list = [
        _ISO2_TO_ISO3[c]
        for c in cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT
        if c in _ISO2_TO_ISO3
    ]
    years = list(range(cfg.YEAR_START, cfg.YEAR_END + 1))

    # WGI
    wgi_df = _fetch_wgi(cfg, iso3_list, years)
    # KOF
    kof_df = _fetch_kof(wgi_dir, cfg)

    written = []
    if wgi_df is not None and kof_df is not None:
        combined = wgi_df.merge(kof_df, on=["country","year"], how="outer")
        out_path = wgi_dir / "wgi_kof.parquet"
        combined.to_parquet(out_path, index=False)
        written.append(out_path)
        log.info("WGI + KOF saved → %s (%d rows)", out_path.name, len(combined))
    elif wgi_df is not None:
        out_path = wgi_dir / "wgi_kof.parquet"
        wgi_df.to_parquet(out_path, index=False)
        written.append(out_path)

    # Heritage (opportunistic — only if CSV placed manually)
    her_path = _process_heritage(her_dir)
    if her_path:
        written.append(her_path)

    utils.write_manifest(
        manifest, source_id,
        source_url="https://info.worldbank.org/governance/wgi/ | https://kof.ethz.ch/",
        files=written, vintage=cfg.DATA_VINTAGE,
    )
    log.info("Institutional ingest complete.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s")
    run()
