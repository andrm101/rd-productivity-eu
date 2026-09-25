# Eurostat raw data — rd-productivity-eu

**Source URL:** https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/  
**Fetched by:** `src/python/01_ingest_eurostat.py`  
**Vintage pin:** 2026-06 Eurostat extract  

## Files

| File | Dataset code | Variable | Unit |
|---|---|---|---|
| `gerd.parquet` | rd_e_gerdtot | GERD % GDP | % |
| `berd.parquet` | rd_e_berdindr2 | Business R&D % GDP | % |
| `goverd.parquet` | rd_e_gerdgov | Government R&D % GDP | % |
| `herd.parquet` | rd_e_gerdhes | Higher-Ed R&D % GDP | % |
| `researchers.parquet` | rd_p_persocc | Researchers per 1000 active pop (FTE) | per 1000 |
| `rd_personnel.parquet` | rd_p_persempoc | R&D personnel % employment | % |
| `gdp_pps.parquet` | nama_10_pc | GDP per capita, PPS (EU27_2020=100) | index |
| `tertiary.parquet` | edat_lfse_03 | Tertiary attainment 25–64 | % |
| `lll.parquet` | trng_lfse_01 | Lifelong learning 25–64 | % |
| `patents_epo.parquet` | pat_ep_ntot | EPO patent applications per million | per million |
| `pop_growth.parquet` | demo_gind | Population growth (crude natural increase) | % |
| `gross_savings.parquet` | nama_10_gdp | Gross savings % GDP | % |

## GERD revision policy (Data Quality Risk R1)

Eurostat revises GERD back ~3 years routinely. Pinned vintage must be documented
in all publications. Re-running after a vintage update will flag changed series
in `reports/01_audit_log.md`.

## Ireland note (Data Quality Risk R2)

Ireland's 2015 GDP-PPS shows a +26.3% jump (FDI-accounting artefact, "leprechaun
economics"). GNI* (modified gross national income, CSO Ireland) is used as
robustness outcome. Place manually downloaded CSO file at:
  `data/raw/eurostat/ireland_gni_star.csv`
  Columns: year, gni_star_per_capita_eur (current prices)
