# Stage 02 — Diagnostic Battery

## Hausman Test
```

	Hausman Test

data:  thesis_formula
chisq = 29.557, df = 5, p-value = 1.803e-05
alternative hypothesis: one model is inconsistent

```

## Pesaran CD Test
```

	Pesaran CD test for cross-sectional dependence in panels

data:  diff_gdp_cap ~ gerd + ideas_cap + savings + human_cap + n_g_d
z = 36.194, p-value < 2.2e-16
alternative hypothesis: cross-sectional dependence

```

## Serial Correlation (BG)
```

	Breusch-Godfrey/Wooldridge test for serial correlation in panel models

data:  thesis_formula
chisq = 50.542, df = 13, p-value = 2.406e-06
alternative hypothesis: serial correlation in idiosyncratic errors

```

## Breusch-Pagan LM
```

	Lagrange Multiplier Test - (Breusch-Pagan)

data:  thesis_formula
chisq = 1.521, df = 1, p-value = 0.2175
alternative hypothesis: significant effects

```

