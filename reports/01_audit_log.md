# Data Audit Log — Stage 01

**Vintage:** 2026-06  
**Generated:** 2026-05-23T11:20:28  

## Coverage Gate (core spec, primary panel)

| Variable | Expected obs | Non-missing | Coverage % | Gate (≥95%) |
|---|---|---|---|---|
| `ln_y_pc` | 783 | 783 | 100.0% | PASS |
| `gerd_pct` | 783 | 779 | 99.5% | PASS |
| `savings_pct` | 783 | 762 | 97.3% | PASS |
| `n_g_d` | 783 | 783 | 100.0% | PASS |
| `tertiary_25_64` | 783 | 766 | 97.8% | PASS |

**Overall gate:** PASSED ✓

## Missingness by Country (core variables)

| Country | ln_y_pc | gerd_pct | savings_pct | n_g_d | tertiary_25_64 |
|---|---|---|---|---|---|
| AT | 0 missing | 0 missing | 7 missing | 0 missing | 4 missing |
| BE | 0 missing | 0 missing | 4 missing | 0 missing | 0 missing |
| BG | 0 missing | 0 missing | 0 missing | 0 missing | 2 missing |
| CH | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| CY | 0 missing | 0 missing | 0 missing | 0 missing | 1 missing |
| CZ | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| DE | 0 missing | 0 missing | 0 missing | 0 missing | 1 missing |
| DK | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| EE | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| ES | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| FI | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| FR | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| GR | 0 missing | 0 missing | 1 missing | 0 missing | 0 missing |
| HR | 0 missing | 2 missing | 1 missing | 0 missing | 4 missing |
| HU | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| IE | 0 missing | 0 missing | 7 missing | 0 missing | 1 missing |
| IS | 0 missing | 0 missing | 0 missing | 0 missing | 1 missing |
| IT | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| LT | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| LU | 0 missing | 0 missing | 1 missing | 0 missing | 1 missing |
| LV | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| MT | 0 missing | 2 missing | 0 missing | 0 missing | 2 missing |
| NL | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| NO | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| PL | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| PT | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| RO | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| SE | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |
| SK | 0 missing | 0 missing | 0 missing | 0 missing | 0 missing |

## Outlier Flags

Countries with potential outlier values flagged for manual review:

- **Ireland 2015**: GDP-PPS jump detected. Use GNI*-per-capita in robustness specification.