# rd-productivity-eu

**R&D → Productivity, EU Panel — Capstone Extension of 2025 Bachelor's Thesis**

Andrei Manoloiu · MSc Data Science, SDU Kolding

---

## Project summary

Extends the 2025 bachelor's thesis (augmented Solow, N=25 EU, 1998–2023, FE/RE Hausman)
into a publication-grade panel econometrics project addressing the thesis's own flagged
limitations: GMM/IV, spatial spillovers, endogenous-growth specifications, institutional
moderation, and cluster stability.

**Panel:** N=29 (EU-25 + Ireland + Norway + Iceland + Switzerland), 1998–2024  
**Stack:** Python (ingest, ML, visualisation) + R (econometrics) + DuckDB (bridge)

---

## Architecture

```mermaid
flowchart TD
    Eurostat["Eurostat (2026-06 extract)"] --> S01["Stage 01 — src/python/<br/>run_stage01.py -> panel.duckdb"]
    PWT["Penn World Table 10.01"] --> S01
    Manual["Manual: Heritage IEF,<br/>Ireland GNI*, PISA"] --> S01
    S01 --> Gate["Coverage gate<br/>>=95% non-missing, 29x27 country-years"]
    Gate --> S02["Stage 02 — src/R/02_replicate_thesis.R"]
    S02 --> S03["Stage 03 — src/R/03_extended_models.R"]
    S03 --> S04["Stage 04 — src/R/04_system_gmm.R"]
    S04 --> S05["Stage 05 — src/R/05_local_projections.R"]
    S05 --> S06["Stage 06 — src/R/06_spatial_durbin.R"]
    S06 --> S07["Stage 07 — src/R/07_causal_forest.R"]
    S07 --> S08["Stage 08 — src/R/08_clustering.R"]
    S08 --> S09["Stage 09 — src/R/09_robustness.R<br/>-> reports/09_robustness_summary.csv"]
    S09 --> Draft["reports/main.Rmd -> main.pdf<br/>(rendered draft already exists)"]
```

Note: stages actually live in `src/python/` (ingest) and `src/R/` (econometrics) as numbered scripts, not in a `notebooks/` folder — the folder exists but is currently empty.

## Execution order

```
Week 1  Stage 01 — Data pipeline      python src/python/run_stage01.py
Week 2  Stage 02 — Replication        Rscript src/R/02_replicate_thesis.R
Week 2  Stage 03 — Extended models    Rscript src/R/03_extended_models.R
Week 3  Stage 04 — System GMM         Rscript src/R/04_system_gmm.R
Week 3  Stage 05 — Local projections  Rscript src/R/05_local_projections.R
Week 4  Stage 06 — Spatial Durbin     Rscript src/R/06_spatial_durbin.R
Week 5  Stage 07 — Causal forest      Rscript src/R/07_causal_forest.R
Week 6  Stage 08 — Clustering v2      Rscript src/R/08_clustering.R
Week 6  Stage 09 — Robustness         Rscript src/R/09_robustness.R
Week 7  Stage 10 — Paper draft        reports/main.Rmd (rendered -> reports/main.pdf)
```

---

## Quick start

```bash
# 1. Create conda environment
conda env create -f environment.yml
conda activate rd-productivity-eu

# 2. Run Stage 01 (downloads all data, builds panel.duckdb)
python src/python/run_stage01.py

# 3. Check coverage gate
cat reports/01_audit_log.md

# 4. Run Stage 02 replication
Rscript src/R/02_replicate_thesis.R
```

---

## Manual data required

The following sources cannot be fetched programmatically and must be placed manually:

| File | Source | Path |
|---|---|---|
| Heritage IEF | heritage.org/index/explore → Export CSV | `data/raw/heritage/heritage_ief.csv` |
| Ireland GNI\* | cso.ie → National Accounts → Modified GNI | `data/raw/eurostat/ireland_gni_star.csv` |
| PISA scores | oecd.org/pisa/data/ → PISA 2022 database | `data/raw/oecd/pisa_scores.csv` |

Expected columns for `heritage_ief.csv`:
```
country_iso2, year, ief_overall, ief_rl, ief_gs, ief_re, ief_om
```

---

## Data vintage

All Eurostat series pinned to **2026-06 extract**. PWT version **10.01** (Feenstra et al.
2015). Heritage IEF: document year on ingestion. Manifest files written to each
`data/raw/<source>/manifest.jsonl`.

---

## Key hypotheses (pre-registered)

Status as of Stage 09 (`src/R/09_robustness.R`, run 2026-09-25 — see
`reports/09_robustness_summary.csv` for full point estimates). Findings are
reported honestly: only H4 (a pre-existing rejection) and H6 came back
supported — the rest are genuine nulls, not forced to look positive.

| H | Statement | Tested by | Result |
|---|---|---|---|
| H1 | γ_GOVERD > γ_BERD (public R&D effect > private), p < 0.05 | Stage 09 (first test) | Not supported (diff=+0.040, p=0.35) |
| H2 | LP impulse response of GERD on TFP peaks at 5–7 years | Stage 05, robustness-checked in Stage 09 | Not supported (peak h=8 baseline, h=2 ex-COVID) |
| H3 | GERD × distance-to-frontier interaction is negative | Stage 09 direct test (Stage 03 tested a related but not identical krd×dtf/gerd×hc specification) | Not supported (p=0.79, and sign not robust to swapping dtf for rel_frontier) |
| H4 | Indirect / direct SDM effect ratio > 1 (research-collaboration weights) | Stage 06 — **rejected**: spatial spillovers non-significant across all three weight matrices (λ=0.107, p=0.33). Stage 09 confirms via leave-one-country-out jackknife that this null isn't driven by a single country. | Rejected (Stage 06); null confirmed robust (29/29 jackknife) |
| H5 | Catch-up cluster absorbs more spillovers than innovator cluster | Stage 09 (first test) | Not supported (interaction p=0.43) |
| H6 | Bootstrap-ARI ≥ 0.75 for k=2 clusters | Stage 09 (first test) | **Supported** (mean ARI=1.000, B=200) |
| H7 | GERD coefficient smaller in 2011–2024 than 1998–2010 (Bloom et al.) | Stage 09 (first test; `reports/main.Rmd` previously noted this explicitly as untested) | Not supported (|coef| grew 0.002→0.014, opposite of the Bloom direction) |

---

## Stage 01 gate

Before Stage 02: ≥ 95% non-missing for `ln_y_pc, gerd_pct, savings_pct, n_g_d,
tertiary_25_64` over 29 × 27 = 783 country-years. Check `reports/01_audit_log.md`.
