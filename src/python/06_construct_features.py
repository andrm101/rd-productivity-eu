"""
Stage 03 — Feature engineering: knowledge capital, frontier distance,
absorptive capacity, Bloom difficulty, distributed lags.

Reads panel_long from panel.duckdb, adds derived variables, overwrites
panel_long and panel_wide in-place. Idempotent: NEW_COLS are dropped and
re-computed on every run.

New variables
─────────────
krd_pct          R&D knowledge stock % GDP  (perpetual inventory, delta_R=0.15)
ln_krd           log(krd_pct)
frontier_ln_y    95th-pct of primary-panel ln_y_pc each year
dtf              frontier_ln_y - ln_y_pc  (0 = on frontier)
rel_frontier     exp(-dtf) = y_it / y_frontier_t
gerd_x_hc        gerd_pct x tertiary_25_64/100  (Nelson-Phelps)
krd_x_dtf        ln_krd x dtf  (imitation vs innovation margin)
delta_ln_tfp     annual delta-ln(TFP) within country
research_prod    delta_ln_tfp / log1p(researchers_pm)  (Bloom et al. 2020)
ln_difficulty    cumulative research_prod  (higher = harder, limited to 2019)
gerd_lag1..3     gerd_pct shifted 1-3 years within country
krd_lag1..3      krd_pct shifted 1-3 years within country
gerd_avg3        rolling 3-year average GERD
wgi_composite    mean of 6 WGI indicators
"""

import logging
from pathlib import Path
import importlib.util

import duckdb
import numpy as np
import pandas as pd

log = logging.getLogger(__name__)


def _load(fname):
    p = Path(__file__).resolve().parent / fname
    spec = importlib.util.spec_from_file_location(fname.replace(".py", ""), p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


DELTA_R    = 0.15   # R&D depreciation (Hall, Mairesse & Mohnen 2010)
G_TECH     = 0.02   # technology growth rate (MRW convention)
SEED_DENOM = DELTA_R + G_TECH  # = 0.17

NEW_COLS = [
    "krd_pct", "ln_krd",
    "frontier_ln_y", "dtf", "rel_frontier",
    "gerd_x_hc", "krd_x_dtf",
    "delta_ln_tfp", "research_prod", "ln_difficulty",
    "gerd_lag1", "gerd_lag2", "gerd_lag3",
    "krd_lag1",  "krd_lag2",  "krd_lag3",
    "gerd_avg3",
    "wgi_composite",
]


def _knowledge_stock(df: pd.DataFrame) -> pd.DataFrame:
    """
    Perpetual inventory: K_t = GERD_t + (1 - delta_R) * K_{t-1}
    Seed: K_0 = GERD_{first available} / (delta_R + g)
    gerd_pct is already interpolated in Stage 01 for biannual reporters.
    """
    df = df.sort_values(["country", "year"]).copy()
    krd_vals: list[float] = []

    for _, grp in df.groupby("country", sort=False):
        grp = grp.sort_values("year")
        gerd = grp["gerd_pct"].values.astype(float)
        k = np.full(len(gerd), np.nan)
        first = next((i for i, v in enumerate(gerd) if not np.isnan(v)), None)
        if first is None:
            krd_vals.extend(k.tolist())
            continue
        k[first] = gerd[first] / SEED_DENOM
        for t in range(first + 1, len(gerd)):
            prev = k[t - 1] if not np.isnan(k[t - 1]) else gerd[t] / SEED_DENOM
            if np.isnan(gerd[t]):
                k[t] = (1 - DELTA_R) * prev
            else:
                k[t] = gerd[t] + (1 - DELTA_R) * prev
        krd_vals.extend(k.tolist())

    df["krd_pct"] = krd_vals
    df["ln_krd"]  = np.log(
        pd.to_numeric(df["krd_pct"], errors="coerce").clip(lower=0.001)
    )
    return df


def _frontier_distance(df: pd.DataFrame, primary: list[str]) -> pd.DataFrame:
    """
    Frontier = 95th percentile of primary-panel ln_y_pc each year.
    95th pct avoids Luxembourg/Ireland GDP measurement outliers.
    """
    frontier = (
        df[df["country"].isin(primary)]
        .groupby("year")["ln_y_pc"]
        .quantile(0.95)
        .rename("frontier_ln_y")
        .reset_index()
    )
    df = df.merge(frontier, on="year", how="left")
    df["dtf"]         = (df["frontier_ln_y"] - df["ln_y_pc"]).clip(lower=0)
    df["rel_frontier"] = np.exp(-df["dtf"])
    return df


def _interactions(df: pd.DataFrame) -> pd.DataFrame:
    gerd  = pd.to_numeric(df["gerd_pct"],       errors="coerce")
    hc    = pd.to_numeric(df["tertiary_25_64"],  errors="coerce")
    ln_k  = pd.to_numeric(df["ln_krd"],          errors="coerce")
    dtf   = pd.to_numeric(df["dtf"],             errors="coerce")
    df["gerd_x_hc"]  = gerd * hc / 100.0
    df["krd_x_dtf"]  = ln_k * dtf
    return df


def _bloom_difficulty(df: pd.DataFrame) -> pd.DataFrame:
    """
    Bloom et al. (2020): research productivity = TFP growth / researcher input.
    Coverage limited to years where PWT rtfpna is non-null (1998-2019).
    """
    df = df.sort_values(["country", "year"]).copy()
    df["delta_ln_tfp"] = df.groupby("country")["ln_tfp"].diff()
    researchers = pd.to_numeric(df["researchers_pm"], errors="coerce")
    df["research_prod"] = (
        df["delta_ln_tfp"] / np.log1p(researchers.clip(lower=0))
    )
    # Cumulative sum of research productivity (starting from each country's
    # earliest available year). Declining trend = ideas getting harder.
    df["ln_difficulty"] = df.groupby("country")["research_prod"].transform(
        lambda s: s.cumsum()
    )
    return df


def _distributed_lags(df: pd.DataFrame) -> pd.DataFrame:
    df = df.sort_values(["country", "year"]).copy()
    for lag in [1, 2, 3]:
        df[f"gerd_lag{lag}"] = df.groupby("country")["gerd_pct"].shift(lag)
        df[f"krd_lag{lag}"]  = df.groupby("country")["krd_pct"].shift(lag)

    g0 = df["gerd_pct"].fillna(np.nan)
    g1 = df["gerd_lag1"]
    g2 = df["gerd_lag2"]
    valid_count = g0.notna().astype(int) + g1.notna().astype(int) + g2.notna().astype(int)
    df["gerd_avg3"] = (g0.fillna(0) + g1.fillna(0) + g2.fillna(0)) / valid_count.replace(0, np.nan)
    return df


def _governance_composite(df: pd.DataFrame) -> pd.DataFrame:
    wgi_cols = [
        "wgi_gov_eff", "wgi_rule_of_law", "wgi_reg_quality",
        "wgi_voice", "wgi_polstab", "wgi_corruption",
    ]
    present = [c for c in wgi_cols if c in df.columns]
    if present:
        df["wgi_composite"] = (
            df[present].apply(pd.to_numeric, errors="coerce").mean(axis=1)
        )
    return df


def run() -> None:
    cfg     = _load("00_config.py")
    db_path = cfg.DB_PATH

    log.info("Loading panel_long…")
    con = duckdb.connect(str(db_path))
    df  = con.execute("SELECT * FROM panel_long").df()

    # Drop stale Stage-03 columns (idempotent re-run)
    df = df.drop(columns=[c for c in NEW_COLS if c in df.columns], errors="ignore")

    df = _knowledge_stock(df)
    df = _frontier_distance(df, cfg.COUNTRIES_PRIMARY)
    df = _interactions(df)
    df = _bloom_difficulty(df)
    df = _distributed_lags(df)
    df = _governance_composite(df)

    log.info("Writing enriched panel (%d cols) back to DuckDB…", df.shape[1])
    con.execute("DROP TABLE IF EXISTS panel_long")
    con.execute("CREATE TABLE panel_long AS SELECT * FROM df")
    con.execute("DROP TABLE IF EXISTS panel_wide")
    con.execute("CREATE TABLE panel_wide AS SELECT * FROM df")
    con.close()

    krd_cov   = df["krd_pct"].notna().mean() * 100
    dtf_cov   = df["dtf"].notna().mean() * 100
    bloom_cov = df["research_prod"].notna().mean() * 100
    log.info("krd_pct coverage:     %.1f%%", krd_cov)
    log.info("dtf coverage:         %.1f%%", dtf_cov)
    log.info("research_prod:        %.1f%%  (PWT TFP ceiling 2019)", bloom_cov)
    log.info("Stage 03 complete — %d total columns.", df.shape[1])


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
    )
    run()
