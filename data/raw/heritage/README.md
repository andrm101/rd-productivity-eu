# Heritage Foundation — Index of Economic Freedom

**Source URL:** https://www.heritage.org/index/explore  
**Download method:** Manual export (bulk CSV not available via public API)  
**Vintage:** Document on download (2017 and 2020 methodology revisions — see note)

## How to download

1. Go to https://www.heritage.org/index/explore
2. Select "Download Data" → full dataset CSV
3. Save as `data/raw/heritage/heritage_ief.csv`

## Required columns

```
country_iso2, year, ief_overall, ief_rl, ief_gs, ief_re, ief_om
```

Where:
- `ief_rl`  = Rule of Law sub-index (property rights + judicial effectiveness + government integrity)
- `ief_gs`  = Government Size sub-index (tax burden + government spending + fiscal health)
- `ief_re`  = Regulatory Efficiency sub-index (business freedom + labor freedom + monetary freedom)
- `ief_om`  = Open Markets sub-index (trade freedom + investment freedom + financial freedom)

## Methodology revision note (Data Quality Risk R3)

Heritage revised methodology in 2017 and again in 2020. Pre-2017 sub-indices are
not perfectly comparable to post-2017. Use WGI as parallel institutional measure
and cross-check findings. Both sources are estimated in the main analysis; Heritage
sub-indices reported in robustness section if discrepancies emerge.
