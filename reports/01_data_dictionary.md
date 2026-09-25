# Data Dictionary — rd-productivity-eu

**Vintage:** 2026-06
**Panel:** N=29 primary countries + 1 Brexit robustness slice
**Window:** 1998–2024

| Variable | Label | Unit | Source | Dataset code | Vintage |
|---|---|---|---|---|---|
| `ln_y_pc` | Log GDP per capita (PPS) | ln(index, EU27=100) | Eurostat | nama_10_pc | 2026-06 |
| `ln_tfp` | Log TFP (PWT, US=1) | ln(ratio) | Penn World Table 10.01 | rtfpna | 2021 |
| `gerd_pct` | GERD % GDP | % | Eurostat | rd_e_gerdtot | 2026-06 |
| `berd_pct` | Business R&D % GDP | % | Eurostat | rd_e_berdindr2 | 2026-06 |
| `goverd_pct` | Government R&D % GDP | % | Eurostat | rd_e_gerdgov | 2026-06 |
| `herd_pct` | Higher-Ed R&D % GDP | % | Eurostat | rd_e_gerdhes | 2026-06 |
| `researchers_pm` | Researchers per 1000 active population (FTE) | per 1000 | Eurostat | rd_p_persocc | 2026-06 |
| `rd_personnel_pct` | R&D personnel % employment | % | Eurostat | rd_p_persempoc | 2026-06 |
| `tertiary_25_64` | Tertiary attainment 25–64 | % | Eurostat | edat_lfse_03 | 2026-06 |
| `lll_part` | Lifelong learning participation 25–64 | % | Eurostat | trng_lfse_01 | 2026-06 |
| `pat_pct` | EPO patents per million inhabitants | per million | Eurostat | pat_ep_ntot | 2026-06 |
| `triadic_pct` | Triadic patent families per million pop | per million | OECD MSTI | — | 2024 |
| `stem_share` | STEM graduates % total tertiary | % | OECD MSTI | — | 2024 |
| `savings_pct` | Gross savings % GDP | % | Eurostat | nama_10_gdp | 2026-06 |
| `pop_growth` | Population growth rate | % | Eurostat | demo_gind | 2026-06 |
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
