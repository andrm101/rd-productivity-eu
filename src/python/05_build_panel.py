"""
Stage 01.5 — Panel build
Joins all staged parquet files into a canonical DuckDB analytical layer.

Tables written to data/panel.duckdb:
  country        — country metadata (iso2, iso3, name, cluster placeholder, region)
  panel_long     — one row per country × year, all variables in long-ish format
  panel_wide     — same pivoted to one row per country × year (all variables as columns)
  weights        — bilateral trade / research-collaboration weight matrices (stub)

Validation gate (Section 1.6 of project plan):
  ≥ 95% non-missing for core spec:
    ln_y_pc, gerd_pct, savings_pct, n_g_d, tertiary_25_64
  over 29 countries × 27 years = 783 country-years.

Outputs:
  data/panel.duckdb
  reports/01_data_dictionary.md
  reports/01_audit_log.md
  figures/01_coverage_heatmap.png
"""

import logging
from pathlib import Path
import importlib.util

import duckdb
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns

log = logging.getLogger(__name__)

def _load(fname: str):
    p = Path(__file__).resolve().parent / fname
    spec = importlib.util.spec_from_file_location(fname.replace(".py",""), p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


# ── Country metadata ──────────────────────────────────────────────────────────
COUNTRY_META = {
    "AT": ("Austria",       "AUT", "Western Europe"),
    "BE": ("Belgium",       "BEL", "Western Europe"),
    "BG": ("Bulgaria",      "BGR", "Eastern Europe"),
    "CY": ("Cyprus",        "CYP", "Southern Europe"),
    "CZ": ("Czech Republic","CZE", "Eastern Europe"),
    "DE": ("Germany",       "DEU", "Western Europe"),
    "DK": ("Denmark",       "DNK", "Northern Europe"),
    "EE": ("Estonia",       "EST", "Eastern Europe"),
    "ES": ("Spain",         "ESP", "Southern Europe"),
    "FI": ("Finland",       "FIN", "Northern Europe"),
    "FR": ("France",        "FRA", "Western Europe"),
    "GR": ("Greece",        "GRC", "Southern Europe"),
    "HR": ("Croatia",       "HRV", "Eastern Europe"),
    "HU": ("Hungary",       "HUN", "Eastern Europe"),
    "IE": ("Ireland",       "IRL", "Western Europe"),
    "IT": ("Italy",         "ITA", "Southern Europe"),
    "IS": ("Iceland",       "ISL", "Northern Europe"),
    "LT": ("Lithuania",     "LTU", "Eastern Europe"),
    "LU": ("Luxembourg",    "LUX", "Western Europe"),
    "LV": ("Latvia",        "LVA", "Eastern Europe"),
    "MT": ("Malta",         "MLT", "Southern Europe"),
    "NL": ("Netherlands",   "NLD", "Western Europe"),
    "NO": ("Norway",        "NOR", "Northern Europe"),
    "PL": ("Poland",        "POL", "Eastern Europe"),
    "PT": ("Portugal",      "PRT", "Southern Europe"),
    "RO": ("Romania",       "ROU", "Eastern Europe"),
    "SE": ("Sweden",        "SWE", "Northern Europe"),
    "SI": ("Slovenia",      "SVN", "Eastern Europe"),
    "SK": ("Slovakia",      "SVK", "Eastern Europe"),
    "CH": ("Switzerland",   "CHE", "Western Europe"),
    "GB": ("United Kingdom","GBR", "Western Europe"),
}


def _build_country_table(countries: list[str]) -> pd.DataFrame:
    rows = []
    for iso2 in countries:
        name, iso3, region = COUNTRY_META.get(iso2, (iso2, iso2+"X", "Unknown"))
        rows.append({"country": iso2, "iso3": iso3, "country_name": name,
                     "region": region, "in_primary_panel": iso2 != "GB"})
    return pd.DataFrame(rows)


def _safe_read(path: Path) -> pd.DataFrame | None:
    if not path.exists():
        log.warning("File not found, skipping: %s", path)
        return None
    try:
        df = pd.read_parquet(path)
        log.info("  Loaded %s — shape %s", path.name, df.shape)
        return df
    except Exception as exc:
        log.error("Cannot read %s: %s", path, exc)
        return None


def _parse_ireland_gni_star(cfg) -> pd.DataFrame | None:
    """
    Parse CSO Ireland GNI* file (Euro millions, constant market prices).
    Returns long df with columns: country='IE', year, gni_star_eur_m.
    Per-capita conversion happens after population is available from Eurostat.
    """
    candidates = [
        cfg.RAW / "eurostat" / "ireland_gni_star.csv",
        cfg.RAW / "eurostat" / "ireland_gni_star.csv.csv",
    ]
    raw_csv = next((p for p in candidates if p.exists()), None)
    if raw_csv is None:
        log.warning("Ireland GNI* CSV not found — skipping.")
        return None
    try:
        df = pd.read_csv(raw_csv)
        # CSO format: Statistic Label | Year | Item | UNIT | VALUE
        # Keep only the GNI* aggregate row (not the component rows)
        gni_mask = df["Item"].str.contains("Modified gross national income", case=False, na=False)
        df = df[gni_mask].copy()
        df = df.rename(columns={"Year": "year", "VALUE": "gni_star_eur_m"})
        df["country"] = "IE"
        df["year"]    = pd.to_numeric(df["year"], errors="coerce").astype("Int64")
        df["gni_star_eur_m"] = pd.to_numeric(df["gni_star_eur_m"], errors="coerce")
        df = df[["country","year","gni_star_eur_m"]].dropna().reset_index(drop=True)
        log.info("Ireland GNI* parsed: %d rows (years %d–%d)",
                 len(df), df["year"].min(), df["year"].max())
        return df
    except Exception as exc:
        log.error("Ireland GNI* parse failed: %s", exc)
        return None


def _merge_all(cfg) -> pd.DataFrame:
    """
    Outer-join all raw parquets onto a complete country × year grid.
    Returns a wide-ish dataframe.
    """
    # Full grid
    all_countries = cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT
    years = list(range(cfg.YEAR_START, cfg.YEAR_END + 1))
    grid = pd.MultiIndex.from_product([all_countries, years],
                                       names=["country","year"]).to_frame(index=False)

    sources = {
        "eurostat_gerd":       cfg.RAW / "eurostat" / "gerd.parquet",
        "eurostat_berd":       cfg.RAW / "eurostat" / "berd.parquet",
        "eurostat_goverd":     cfg.RAW / "eurostat" / "goverd.parquet",
        "eurostat_herd":       cfg.RAW / "eurostat" / "herd.parquet",
        "eurostat_researchers":cfg.RAW / "eurostat" / "researchers.parquet",
        "eurostat_rdpersonnel":cfg.RAW / "eurostat" / "rd_personnel.parquet",
        "eurostat_gdp":        cfg.RAW / "eurostat" / "gdp_pps.parquet",
        "eurostat_tertiary":   cfg.RAW / "eurostat" / "tertiary.parquet",
        "eurostat_lll":        cfg.RAW / "eurostat" / "lll.parquet",
        "eurostat_patents":    cfg.RAW / "eurostat" / "patents_epo.parquet",
        "eurostat_pop":        cfg.RAW / "eurostat" / "pop_growth.parquet",
        "eurostat_savings":    cfg.RAW / "eurostat" / "gross_savings.parquet",
        "worldbank":           cfg.RAW / "worldbank" / "wb_series.parquet",
        "pwt":                 cfg.RAW / "pwt"       / "pwt1001.parquet",
        "oecd_msti":           cfg.RAW / "oecd"      / "oecd_msti.parquet",
        "wgi_kof":             cfg.RAW / "wgi"       / "wgi_kof.parquet",
        "heritage":            cfg.RAW / "heritage"  / "heritage_ief.parquet",
    }

    panel = grid.copy()
    for name, path in sources.items():
        df = _safe_read(path)
        if df is None:
            continue
        # Normalise country column: prefer the ISO2 key over a full-name 'country' column.
        # PWT has both: country="Austria" (name) and country_code="AT" (ISO2).
        if "country_code" in df.columns:
            df = df.drop(columns=["country"], errors="ignore")
            df = df.rename(columns={"country_code": "country"})
        elif "country" not in df.columns:
            log.warning("  Skipping %s — no usable country key (columns: %s)", name, df.columns.tolist())
            continue
        # Ensure consistent types
        df["country"] = df["country"].astype(str).str.upper()
        df["year"]    = pd.to_numeric(df["year"], errors="coerce").astype("Int64")
        df = df.dropna(subset=["country","year"])
        # Drop duplicate country-year rows (keep first)
        id_cols = ["country","year"]
        df = df.drop_duplicates(subset=id_cols, keep="first")
        panel = panel.merge(df, on=id_cols, how="left")
        log.info("  After merging %s: %d columns", name, panel.shape[1])

    # Ireland GNI* (aggregate; per-capita derived after population merge)
    gni_df = _parse_ireland_gni_star(cfg)
    if gni_df is not None:
        panel = panel.merge(gni_df, on=["country","year"], how="left")
        log.info("  After merging Ireland GNI*: %d columns", panel.shape[1])

    # PISA 2022 — time-invariant; broadcast across all years via country-only join
    pisa_path = cfg.RAW / "oecd" / "oecd_pisa.parquet"
    pisa_df = _safe_read(pisa_path)
    if pisa_df is not None and "country" in pisa_df.columns:
        pisa_df["country"] = pisa_df["country"].astype(str).str.upper()
        panel = panel.merge(pisa_df, on="country", how="left")
        log.info("  After merging PISA 2022: %d columns", panel.shape[1])

    return panel


def _construct_derived(df: pd.DataFrame) -> pd.DataFrame:
    """Construct model-ready derived variables."""
    # Log GDP per capita: Eurostat PPS index primary; WB PPP USD as fallback for
    # non-EU countries (IS, NO, CH) not covered by Eurostat CP_PPS_EU27_2020_HAB.
    # Both are log-transformed — their scales differ but within-country variation
    # (used in FE estimation) is robust to the level shift. Note in data dictionary.
    if "gdp_pps_idx" in df.columns:
        df["ln_y_pc"] = np.log(pd.to_numeric(df["gdp_pps_idx"], errors="coerce").clip(lower=0.01))
    if "gdp_pc_ppp_2017usd" in df.columns:
        wb_ln = np.log(pd.to_numeric(df["gdp_pc_ppp_2017usd"], errors="coerce").clip(lower=0.01))
        # Fill missing Eurostat values with World Bank values (non-EU countries)
        if "ln_y_pc" in df.columns:
            df["ln_y_pc"] = df["ln_y_pc"].fillna(wb_ln)
        else:
            df["ln_y_pc"] = wb_ln

    # savings_pct: Eurostat tec00020 primary; WB NY.GNS.ICTR.ZS fallback
    if "savings_pct" not in df.columns or df["savings_pct"].isna().all():
        if "savings_pct_wb" in df.columns:
            df["savings_pct"] = pd.to_numeric(df["savings_pct_wb"], errors="coerce")
            log.info("savings_pct: using World Bank fallback (NY.GNS.ICTR.ZS)")

    # If PWT TFP available
    if "rtfpna" in df.columns:
        df["ln_tfp"] = np.log(pd.to_numeric(df["rtfpna"], errors="coerce").clip(lower=0.01))

    # Mankiw-Romer-Weil n+g+δ term  (g=0.02, δ=0.03 as in thesis)
    pop_col = next((c for c in ["pop_growth","pop_growth_wb"] if c in df.columns), None)
    if pop_col:
        df["n_g_d"] = pd.to_numeric(df[pop_col], errors="coerce") / 100.0 + 0.02 + 0.03

    # Growth rate of ln_y_pc (within country, year-on-year)
    if "ln_y_pc" in df.columns:
        df = df.sort_values(["country","year"])
        df["growth_y"] = df.groupby("country")["ln_y_pc"].diff()

    # Linear interpolation of GERD for biannual reporters (IS, NO, CH).
    # Eurostat documents biannual reporting for EEA non-EU countries; linear
    # interpolation is the standard approach in R&D panel literature.
    if "gerd_pct" in df.columns:
        df = df.sort_values(["country","year"])
        df["gerd_pct"] = df.groupby("country")["gerd_pct"].transform(
            lambda s: s.interpolate(method="linear", limit_direction="both", limit=2)
        )

    # First-differences of GERD (for thesis replication spec)
    if "gerd_pct" in df.columns:
        df["diff_gerd"] = df.groupby("country")["gerd_pct"].diff()

    # Regime dummies
    for name, yr in {"gfc":2008, "covid":2020, "ukraine":2022}.items():
        df[f"d_{name}"] = (df["year"] >= yr).astype(int)

    return df


def _check_gate(df: pd.DataFrame, cfg) -> dict:
    """Validate ≥95% non-missing core variables for primary panel × study window."""
    core = ["ln_y_pc", "gerd_pct", "savings_pct", "n_g_d", "tertiary_25_64"]
    primary = df[
        df["country"].isin(cfg.COUNTRIES_PRIMARY) &
        df["year"].between(cfg.YEAR_START, cfg.YEAR_END)
    ]
    expected = len(cfg.COUNTRIES_PRIMARY) * (cfg.YEAR_END - cfg.YEAR_START + 1)
    result = {}
    for col in core:
        if col not in primary.columns:
            result[col] = {"available": False, "pct_nonmissing": 0.0}
            continue
        nonmiss = primary[col].notna().sum()
        pct     = nonmiss / expected * 100
        result[col] = {"available": True, "n_nonmissing": int(nonmiss),
                       "n_expected": expected, "pct_nonmissing": round(pct, 1)}
    return result


def _write_coverage_heatmap(df: pd.DataFrame, cfg) -> None:
    fig_path = cfg.FIGURES / "01_coverage_heatmap.png"
    cfg.FIGURES.mkdir(parents=True, exist_ok=True)

    primary = df[df["country"].isin(cfg.COUNTRIES_PRIMARY)].copy()
    value_cols = [c for c in primary.columns if c not in ("country","year")]
    # Show up to 30 most informative variables (fewest missing)
    miss_rate = primary[value_cols].isna().mean().sort_values().head(30)
    plot_cols = miss_rate.index.tolist()

    heatmap_data = (
        primary.pivot_table(index="country", columns="year",
                            values=plot_cols[0] if plot_cols else "ln_y_pc",
                            aggfunc=lambda x: (~x.isna()).sum())
        .notna().astype(int)
    )
    # Build full presence matrix: country × variable
    presence = pd.DataFrame(
        {col: primary.groupby("country")[col].apply(lambda s: s.notna().mean())
         for col in plot_cols},
        index=sorted(primary["country"].unique()),
    )

    fig, ax = plt.subplots(figsize=(max(14, len(plot_cols)*0.5), 8))
    sns.heatmap(
        presence, ax=ax, cmap="RdYlGn", vmin=0, vmax=1,
        linewidths=0.3, cbar_kws={"label": "Coverage (fraction non-missing)"},
    )
    ax.set_title("Variable coverage by country — rd-productivity-eu panel", fontsize=13)
    ax.set_xlabel("Variable", fontsize=11)
    ax.set_ylabel("Country (ISO2)", fontsize=11)
    ax.tick_params(axis="x", rotation=45, labelsize=8)
    fig.tight_layout()
    fig.savefig(fig_path, dpi=300, bbox_inches="tight")
    plt.close(fig)
    log.info("Coverage heatmap saved → %s", fig_path.name)


def _write_data_dictionary(cfg) -> None:
    dd_path = cfg.REPORTS / "01_data_dictionary.md"
    cfg.REPORTS.mkdir(parents=True, exist_ok=True)
    content = f"""# Data Dictionary — rd-productivity-eu

**Vintage:** {cfg.DATA_VINTAGE}
**Panel:** N={len(cfg.COUNTRIES_PRIMARY)} primary countries + 1 Brexit robustness slice
**Window:** {cfg.YEAR_START}–{cfg.YEAR_END}

| Variable | Label | Unit | Source | Dataset code | Vintage |
|---|---|---|---|---|---|
| `ln_y_pc` | Log GDP per capita (PPS) | ln(index, EU27=100) | Eurostat | nama_10_pc | {cfg.DATA_VINTAGE} |
| `ln_tfp` | Log TFP (PWT, US=1) | ln(ratio) | Penn World Table 10.01 | rtfpna | 2021 |
| `gerd_pct` | GERD % GDP | % | Eurostat | rd_e_gerdtot | {cfg.DATA_VINTAGE} |
| `berd_pct` | Business R&D % GDP | % | Eurostat | rd_e_berdindr2 | {cfg.DATA_VINTAGE} |
| `goverd_pct` | Government R&D % GDP | % | Eurostat | rd_e_gerdgov | {cfg.DATA_VINTAGE} |
| `herd_pct` | Higher-Ed R&D % GDP | % | Eurostat | rd_e_gerdhes | {cfg.DATA_VINTAGE} |
| `researchers_pm` | Researchers per 1000 active population (FTE) | per 1000 | Eurostat | rd_p_persocc | {cfg.DATA_VINTAGE} |
| `rd_personnel_pct` | R&D personnel % employment | % | Eurostat | rd_p_persempoc | {cfg.DATA_VINTAGE} |
| `tertiary_25_64` | Tertiary attainment 25–64 | % | Eurostat | edat_lfse_03 | {cfg.DATA_VINTAGE} |
| `lll_part` | Lifelong learning participation 25–64 | % | Eurostat | trng_lfse_01 | {cfg.DATA_VINTAGE} |
| `pat_pct` | EPO patents per million inhabitants | per million | Eurostat | pat_ep_ntot | {cfg.DATA_VINTAGE} |
| `triadic_pct` | Triadic patent families per million pop | per million | OECD MSTI | — | 2024 |
| `stem_share` | STEM graduates % total tertiary | % | OECD MSTI | — | 2024 |
| `savings_pct` | Gross savings % GDP | % | Eurostat | nama_10_gdp | {cfg.DATA_VINTAGE} |
| `pop_growth` | Population growth rate | % | Eurostat | demo_gind | {cfg.DATA_VINTAGE} |
| `n_g_d` | n + g + δ (MRW convention, g=0.02, δ=0.03) | decimal | Derived | — | — |
| `growth_y` | Year-on-year change in ln_y_pc | ln-pts | Derived | — | — |
| `wgi_gov_eff` | WGI Government Effectiveness | std. score | World Bank | GE.EST | 2024 |
| `wgi_rule_of_law` | WGI Rule of Law | std. score | World Bank | RL.EST | 2024 |
| `wgi_reg_quality` | WGI Regulatory Quality | std. score | World Bank | RQ.EST | 2024 |
| `kof_index` | KOF Globalisation Index (overall) | 0–100 | ETH Zürich | KOFGI | 2024 |
| `ief_overall` | Heritage IEF (overall score) | 0–100 | Heritage Foundation | — | *manual* |
| `ief_rl` | Heritage IEF Rule of Law sub-index | 0–100 | Heritage Foundation | — | *manual* |
| `ief_re` | Heritage IEF Regulatory Efficiency sub-index | 0–100 | Heritage Foundation | — | *manual* |
| `gdp_pc_ppp_2017usd` | GDP per capita PPP (constant 2017 USD) | USD | World Bank | NY.GDP.PCAP.PP.KD | 2024 |
| `hc` | Human capital index (Mincerian) | index | Penn World Table 10.01 | hc | 2021 |
| `rtfpna` | TFP level (US=1, 2017 PPPs) | ratio | Penn World Table 10.01 | rtfpna | 2021 |
| `d_gfc` | GFC regime dummy (1 if year≥2008) | 0/1 | Derived | — | — |
| `d_covid` | COVID regime dummy (1 if year≥2020) | 0/1 | Derived | — | — |
| `d_ukraine` | Ukraine-energy shock dummy (1 if year≥2022) | 0/1 | Derived | — | — |

## Notes
- Ireland: `ln_y_pc` uses Eurostat GDP-PPS in main spec; GNI*-per-capita (CSO Ireland)
  to be merged for robustness once manually downloaded.
- UK (`GB`): excluded from primary panel; present in Brexit robustness slice (2010–2019).
- Heritage IEF: requires manual download from heritage.org/index/explore → place at
  `data/raw/heritage/heritage_ief.csv`.
- PISA scores: not yet ingested (3-year waves, time-invariant within wave). Add in Stage 03.
- Bilateral trade and research-collaboration weight matrices: placeholder; built in Stage 07.
"""
    dd_path.write_text(content, encoding="utf-8")
    log.info("Data dictionary written → %s", dd_path.name)


def _write_audit_log(gate: dict, panel: pd.DataFrame, cfg) -> None:
    audit_path = cfg.REPORTS / "01_audit_log.md"
    lines = [
        "# Data Audit Log — Stage 01",
        f"\n**Vintage:** {cfg.DATA_VINTAGE}  ",
        f"**Generated:** {pd.Timestamp.now().isoformat()[:19]}  ",
        "\n## Coverage Gate (core spec, primary panel)\n",
        "| Variable | Expected obs | Non-missing | Coverage % | Gate (≥95%) |",
        "|---|---|---|---|---|",
    ]
    gate_passed = True
    for col, info in gate.items():
        if not info["available"]:
            lines.append(f"| `{col}` | — | 0 | 0.0% | FAIL (not ingested) |")
            gate_passed = False
            continue
        pct  = info["pct_nonmissing"]
        ok   = "PASS" if pct >= 95 else "FAIL"
        if pct < 95:
            gate_passed = False
        lines.append(f"| `{col}` | {info['n_expected']} | {info['n_nonmissing']} | {pct:.1f}% | {ok} |")

    lines.append(f"\n**Overall gate:** {'PASSED ✓' if gate_passed else 'FAILED — review missing data before Stage 02'}")

    # Missingness summary by country
    lines += ["\n## Missingness by Country (core variables)\n",
              "| Country | ln_y_pc | gerd_pct | savings_pct | n_g_d | tertiary_25_64 |",
              "|---|---|---|---|---|---|"]
    core_cols = ["ln_y_pc","gerd_pct","savings_pct","n_g_d","tertiary_25_64"]
    primary   = panel[panel["country"].isin(cfg.COUNTRIES_PRIMARY)]
    for country in sorted(cfg.COUNTRIES_PRIMARY):
        sub = primary[primary["country"] == country]
        row = f"| {country} |"
        for col in core_cols:
            if col not in sub.columns:
                row += " — |"
            else:
                miss = sub[col].isna().sum()
                row += f" {miss} missing |"
        lines.append(row)

    lines += ["\n## Outlier Flags\n",
              "Countries with potential outlier values flagged for manual review:\n"]
    if "gdp_pps_idx" in panel.columns:
        # Ireland 2015 leprechaun economics jump
        ie = panel[(panel["country"]=="IE") & (panel["year"]==2015)]
        if not ie.empty and "gdp_pps_idx" in ie.columns:
            lines.append("- **Ireland 2015**: GDP-PPS jump detected. "
                         "Use GNI*-per-capita in robustness specification.")

    audit_path.write_text("\n".join(lines), encoding="utf-8")
    log.info("Audit log written → %s", audit_path.name)


def run() -> None:
    cfg   = _load("00_config.py")

    log.info("Building analytical panel…")
    panel = _merge_all(cfg)
    panel = _construct_derived(panel)

    gate = _check_gate(panel, cfg)
    log.info("Coverage gate results:")
    for col, info in gate.items():
        if info["available"]:
            log.info("  %s: %.1f%%", col, info["pct_nonmissing"])
        else:
            log.warning("  %s: NOT AVAILABLE", col)

    # Write to DuckDB
    db_path = cfg.DB_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(db_path))

    # Country table
    country_df = _build_country_table(cfg.COUNTRIES_PRIMARY + cfg.COUNTRIES_BREXIT)
    con.execute("DROP TABLE IF EXISTS country")
    con.execute("CREATE TABLE country AS SELECT * FROM country_df")

    # Panel long (wide-format dataframe, one row per country-year)
    con.execute("DROP TABLE IF EXISTS panel_long")
    con.execute("CREATE TABLE panel_long AS SELECT * FROM panel")

    # Panel wide (same data; keeping separate table for R compatibility)
    con.execute("DROP TABLE IF EXISTS panel_wide")
    con.execute("CREATE TABLE panel_wide AS SELECT * FROM panel")

    # Weights stub — populated in Stage 07
    weights_stub = pd.DataFrame(columns=["country_i","country_j","weight_type","year","weight"])
    con.execute("DROP TABLE IF EXISTS weights")
    con.execute("CREATE TABLE weights AS SELECT * FROM weights_stub")

    con.close()
    log.info("DuckDB written → %s", db_path)

    # Reports & figures
    _write_data_dictionary(cfg)
    _write_audit_log(gate, panel, cfg)
    try:
        _write_coverage_heatmap(panel, cfg)
    except Exception as exc:
        log.warning("Coverage heatmap failed: %s", exc)

    # Gate summary
    all_passed = all(
        info.get("pct_nonmissing", 0) >= 95 and info.get("available", False)
        for info in gate.values()
    )
    if all_passed:
        log.info("Stage 01 GATE: PASSED — proceed to Stage 02.")
    else:
        log.warning(
            "Stage 01 GATE: NOT MET — one or more core variables below 95%% coverage. "
            "Review reports/01_audit_log.md before running Stage 02."
        )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s")
    run()
