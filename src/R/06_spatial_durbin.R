# Stage 06 — Spatial Durbin Model
#
# Motivation (Stage 05 finding):
#   Frontier economies show persistently negative own-country GERD IRFs.
#   Catch-up economies show weak positive effects at h=8.
#   The Coe-Helpman (1995) / Jaffe (1986) mechanism predicts that R&D in
#   frontier countries generates positive spillovers absorbed by neighbours
#   via trade, imitation, and FDI. The spatial model separates:
#     - Direct effect:   beta  (own-country GERD → own growth)
#     - Indirect effect: theta (neighbour GERD → own growth via W)
#     - Total effect:    beta + theta
#
# Spatial weights (W):
#   W1 — Inverse great-circle distance between capitals, row-normalised
#   W2 — Binary contiguity (shared land border), row-normalised
#   W3 — Income-proximity weights: 1/|ln_y_pc_i - ln_y_pc_j|, row-normalised
#        (closer in income space → stronger spillover channel; Benhabib-Spiegel)
#
# Models (all two-way FE, DK SEs via fixest unless noted):
#   SDM_X1  growth_y ~ gerd_pct + W1*gerd + controls  (spatial lag-X, W1)
#   SDM_X2  growth_y ~ gerd_pct + W2*gerd + controls  (spatial lag-X, W2)
#   SDM_X3  growth_y ~ gerd_pct + W3*gerd + controls  (spatial lag-X, W3)
#   SDM_ML  Full SDM with rho (spatial lag of y) via splm ML — W1
#
# Direct/indirect decomposition follows LeSage & Pace (2009) for SDM_ML.

suppressPackageStartupMessages({
  library(fixest)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(splm)
  library(spdep)
})

.this_dir <- (function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("--file=", "", args[grep("--file=", args)])
  if (length(f) && nzchar(f)) return(dirname(normalizePath(f)))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(ctx)) return(dirname(normalizePath(ctx)))
  }
  getwd()
})()
source(file.path(.this_dir, "00_load.R"))

# ── Capital city coordinates (WGS84) ─────────────────────────────────────────
CAPITALS <- tibble::tribble(
  ~country, ~lat,    ~lon,
  "AT",  48.21,  16.37,   # Vienna
  "BE",  50.85,   4.35,   # Brussels
  "BG",  42.70,  23.32,   # Sofia
  "CY",  35.17,  33.36,   # Nicosia
  "CZ",  50.08,  14.44,   # Prague
  "DE",  52.52,  13.40,   # Berlin
  "DK",  55.68,  12.57,   # Copenhagen
  "EE",  59.44,  24.75,   # Tallinn
  "ES",  40.42,  -3.70,   # Madrid
  "FI",  60.17,  24.94,   # Helsinki
  "FR",  48.86,   2.35,   # Paris
  "GR",  37.98,  23.73,   # Athens
  "HR",  45.81,  15.97,   # Zagreb
  "HU",  47.50,  19.04,   # Budapest
  "IE",  53.33,  -6.25,   # Dublin
  "IS",  64.13, -21.89,   # Reykjavik
  "IT",  41.90,  12.50,   # Rome
  "LT",  54.69,  25.28,   # Vilnius
  "LU",  49.61,   6.13,   # Luxembourg
  "LV",  56.95,  24.11,   # Riga
  "MT",  35.90,  14.51,   # Valletta
  "NL",  52.37,   4.90,   # Amsterdam
  "NO",  59.91,  10.75,   # Oslo
  "PL",  52.23,  21.01,   # Warsaw
  "PT",  38.72,  -9.14,   # Lisbon
  "RO",  44.43,  26.10,   # Bucharest
  "SE",  59.33,  18.07,   # Stockholm
  "SI",  46.05,  14.51,   # Ljubljana
  "SK",  48.15,  17.11,   # Bratislava
  "CH",  46.95,   7.45,   # Bern
  "GB",  51.51,  -0.13    # London
)

# Haversine distance (km) — vectorised
haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- 6371
  phi1 <- lat1 * pi / 180;  phi2 <- lat2 * pi / 180
  dphi <- (lat2 - lat1) * pi / 180
  dlam <- (lon2 - lon1) * pi / 180
  a <- sin(dphi/2)^2 + cos(phi1)*cos(phi2)*sin(dlam/2)^2
  2 * r * asin(sqrt(a))
}

# ── Build weights matrices ────────────────────────────────────────────────────
countries <- CAPITALS$country
n <- length(countries)

# Distance matrix (explicit loop avoids Vectorize/outer class ambiguity)
D <- matrix(0, n, n, dimnames = list(countries, countries))
for (i in seq_len(n)) for (j in seq_len(n)) {
  if (i != j)
    D[i, j] <- haversine_km(CAPITALS$lat[i], CAPITALS$lon[i],
                             CAPITALS$lat[j], CAPITALS$lon[j])
}

# W1: inverse distance, row-normalised (zero diagonal)
W1_raw <- 1 / D; diag(W1_raw) <- 0
W1 <- sweep(W1_raw, 1, rowSums(W1_raw), "/")

# W2: binary contiguity (shared land border)
# Defined manually for the 31-country set
BORDERS <- list(
  AT = c("DE","CZ","SK","HU","SI","IT","CH"),
  BE = c("NL","DE","LU","FR"),
  BG = c("RO","GR","TR","RS","MK"),
  CY = c(),
  CZ = c("DE","PL","SK","AT"),
  DE = c("DK","NL","BE","LU","FR","CH","AT","CZ","PL"),
  DK = c("DE"),
  EE = c("LV","RU","FI"),
  ES = c("PT","FR","AD"),
  FI = c("SE","NO","EE","RU"),
  FR = c("BE","LU","DE","CH","IT","ES","MC"),
  GR = c("BG","MK","AL"),
  HR = c("SI","HU","RS","BA","ME"),
  HU = c("AT","SK","UA","RO","RS","HR","SI"),
  IE = c("GB"),
  IS = c(),
  IT = c("FR","CH","AT","SI"),
  LT = c("LV","BY","PL","RU"),
  LU = c("BE","DE","FR"),
  LV = c("EE","LT","BY","RU"),
  MT = c(),
  NL = c("BE","DE"),
  NO = c("SE","FI","RU"),
  PL = c("DE","CZ","SK","UA","BY","LT","RU"),
  PT = c("ES"),
  RO = c("UA","MD","BG","RS","HU"),
  SE = c("NO","FI"),
  SI = c("IT","AT","HU","HR"),
  SK = c("CZ","PL","UA","HU","AT"),
  CH = c("DE","FR","IT","AT","LI"),
  GB = c("IE")
)
W2_raw <- matrix(0, n, n, dimnames = list(countries, countries))
for (i in countries) {
  nbrs <- intersect(BORDERS[[i]], countries)
  if (length(nbrs)) W2_raw[i, nbrs] <- 1
}
# row-normalise (islands get zero row → leave as zero); sweep() preserves matrix class
rs2 <- rowSums(W2_raw)
W2 <- sweep(W2_raw, 1, pmax(rs2, 1e-10), "/")

cat(sprintf("W1 (inv-dist): min=%.4f, max=%.4f\n",
            min(W1[W1>0]), max(W1[W1>0])))
cat(sprintf("W2 (contiguity): avg neighbours=%.1f\n",
            mean(rowSums(W2_raw))))

# ── Load panel ────────────────────────────────────────────────────────────────
panel_full <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(savings = savings_pct / 100,
         year_int = as.integer(year)) |>
  arrange(country, year_int)

years     <- sort(unique(panel_full$year_int))
countries_panel <- sort(unique(panel_full$country))

# ── Compute spatial lags ──────────────────────────────────────────────────────
# For each year t, spatial_lag_var[i,t] = sum_j w[i,j] * var[j,t]
# We build a long-format panel column for each W and variable.

compute_slag <- function(panel, W, var, suffix) {
  common <- sort(intersect(countries_panel, rownames(W)))
  W_sub  <- W[common, common]                                 # subset to panel countries
  W_sub  <- sweep(W_sub, 1, pmax(rowSums(W_sub), 1e-10), "/") # re-normalise rows

  result <- panel |>
    select(country, year_int, all_of(var)) |>
    filter(country %in% common) |>
    pivot_wider(names_from = country, values_from = all_of(var)) |>
    arrange(year_int)

  yr_vec <- result$year_int
  X_mat  <- as.matrix(result[, common, drop = FALSE])  # T x N
  WX_mat <- X_mat %*% t(W_sub)                         # T x N

  colnames(WX_mat) <- paste0("W", suffix, "_", common)  # use common, not countries_panel
  slag_long <- as.data.frame(WX_mat) |>
    mutate(year_int = yr_vec) |>
    pivot_longer(-year_int, names_to = "ckey", values_to = paste0("W", suffix, "_", var)) |>
    mutate(country = sub(paste0("^W", suffix, "_"), "", ckey)) |>
    select(country, year_int, all_of(paste0("W", suffix, "_", var)))
  slag_long
}

# Spatial lags of gerd_pct and growth_y for both W1 and W2
cat("Computing spatial lags...\n")
sl_W1_gerd   <- compute_slag(panel_full, W1, "gerd_pct",  "1")
sl_W2_gerd   <- compute_slag(panel_full, W2, "gerd_pct",  "2")
sl_W1_growth <- compute_slag(panel_full, W1, "growth_y",  "1")
sl_W3_krd    <- compute_slag(panel_full, W1, "ln_krd",    "1")

panel <- panel_full |>
  left_join(sl_W1_gerd,   by = c("country","year_int")) |>
  left_join(sl_W2_gerd,   by = c("country","year_int")) |>
  left_join(sl_W1_growth, by = c("country","year_int")) |>
  left_join(sl_W3_krd,    by = c("country","year_int"))

cat(sprintf("Spatial lag W1_gerd range: %.3f – %.3f\n",
            min(panel$W1_gerd_pct, na.rm=TRUE),
            max(panel$W1_gerd_pct, na.rm=TRUE)))

# ── W3: income-proximity weights (time-varying) ───────────────────────────────
# Constructed at sample-mean income level (time-invariant for stability)
mean_lny <- panel |>
  group_by(country) |>
  summarise(mean_ln_y = mean(ln_y_pc, na.rm=TRUE), .groups="drop")

nc <- length(countries_panel)
W3_raw <- matrix(0, nc, nc, dimnames = list(countries_panel, countries_panel))
for (i in countries_panel) for (j in countries_panel) {
  if (i == j) next
  yi <- mean_lny$mean_ln_y[mean_lny$country == i]
  yj <- mean_lny$mean_ln_y[mean_lny$country == j]
  if (length(yi) && length(yj))
    W3_raw[i, j] <- 1 / (abs(yi - yj) + 0.001)
}
W3 <- sweep(W3_raw, 1, pmax(rowSums(W3_raw), 1e-10), "/")

sl_W3_gerd <- compute_slag(panel_full, W3, "gerd_pct", "3")
panel <- panel |> left_join(sl_W3_gerd, by = c("country","year_int"))

# ── Models: Spatial lag-X (fixest, DK SEs) ───────────────────────────────────
dk_sdm <- function(fml, data = panel) {
  fixest::feols(fml,
                data     = data |> mutate(year = year_int),
                panel.id = ~ country + year,
                vcov     = "DK")
}

# Baseline without spatial lag
m_base <- dk_sdm(growth_y ~ gerd_pct + savings + tertiary_25_64 + n_g_d + dtf
                 | country + year_int)

# SDM-X: direct (gerd_pct) + indirect (W*gerd) — three weight matrices
m_sdmx1 <- dk_sdm(growth_y ~ gerd_pct + W1_gerd_pct + savings + tertiary_25_64
                  + n_g_d + dtf | country + year_int)

m_sdmx2 <- dk_sdm(growth_y ~ gerd_pct + W2_gerd_pct + savings + tertiary_25_64
                  + n_g_d + dtf | country + year_int)

m_sdmx3 <- dk_sdm(growth_y ~ gerd_pct + W3_gerd_pct + savings + tertiary_25_64
                  + n_g_d + dtf | country + year_int)

# SDM-X with ln_krd (knowledge stock)
m_sdmx_krd <- dk_sdm(growth_y ~ ln_krd + W1_ln_krd + savings + tertiary_25_64
                     + n_g_d + dtf | country + year_int)

cat("\n═══ Spatial Durbin Model-X results ═══\n")
fixest::etable(m_base, m_sdmx1, m_sdmx2, m_sdmx3, m_sdmx_krd,
               keep    = c("gerd_pct","W1_gerd_pct","W2_gerd_pct","W3_gerd_pct",
                           "ln_krd","W1_ln_krd","savings","n_g_d","dtf"),
               headers = c("Baseline","W1 inv-dist","W2 contiguity",
                           "W3 income-prox","W1 krd"))

# ── Direct / indirect / total effects summary ─────────────────────────────────
cat("\n═══ Direct, Indirect (spillover), Total effects ═══\n")
for (lbl in c("m_sdmx1","m_sdmx2","m_sdmx3")) {
  mod  <- get(lbl)
  beta <- tryCatch(coef(mod)["gerd_pct"],   error=function(e) NA_real_)
  thet <- tryCatch(coef(mod)[grep("W._gerd_pct", names(coef(mod)))][1],
                   error=function(e) NA_real_)
  cat(sprintf("  %-12s  direct=%.4f  indirect=%.4f  total=%.4f\n",
              lbl, beta, thet, beta + thet))
}

# ── Full SDM with rho via splm ────────────────────────────────────────────────
cat("\n═══ Full SDM (splm, ML, W1) ═══\n")
tryCatch({
  # splm::spml requires a balanced panel; keep only years where all panel
  # countries have complete data across all required variables.
  pd_splm_raw <- panel |>
    select(country, year_int, growth_y, gerd_pct, savings,
           tertiary_25_64, n_g_d, dtf) |>
    filter(!is.na(growth_y) & !is.na(gerd_pct) & !is.na(savings) &
           !is.na(tertiary_25_64) & !is.na(n_g_d) & !is.na(dtf))

  full_n <- n_distinct(pd_splm_raw$country)
  balanced_years <- pd_splm_raw |>
    group_by(year_int) |>
    filter(n() == full_n) |>
    pull(year_int) |>
    unique()

  pd_splm <- pd_splm_raw |>
    filter(year_int %in% balanced_years) |>
    arrange(country, year_int) |>
    as.data.frame()

  cat(sprintf("  Balanced splm panel: %d countries x %d years = %d obs\n",
              n_distinct(pd_splm$country), n_distinct(pd_splm$year_int), nrow(pd_splm)))

  # Build listw AFTER pd_splm is known (subset W1 to panel countries in balanced data)
  cp_splm <- sort(intersect(unique(pd_splm$country), rownames(W1)))
  W1_sub  <- W1[cp_splm, cp_splm]
  listw1  <- spdep::mat2listw(W1_sub, style = "W", zero.policy = TRUE)

  m_sdm_ml <- splm::spml(
    growth_y ~ gerd_pct + savings + tertiary_25_64 + n_g_d + dtf,
    data    = pd_splm,
    index   = c("country","year_int"),
    listw   = listw1,
    model   = "within",
    effect  = "twoways",
    lag     = TRUE,    # spatial lag of y (rho)
    spatial.error = "none"
  )
  cat("\n-- splm SDM (within, two-way FE, ML) --\n")
  print(summary(m_sdm_ml))

  # splm uses "lambda" for the spatial autoregressive coefficient
  rho <- coef(m_sdm_ml)["lambda"]
  cat(sprintf("\nlambda (spatial autoregression) = %.4f  p = %.4f\n",
              rho, summary(m_sdm_ml)$CoefTable["lambda", "Pr(>|t|)"]))
  if (!is.na(rho) && abs(rho) < 0.1)
    cat("  lambda near 0: spatial autocorrelation in growth is weak after controls.\n")
  else
    cat("  |lambda| > 0.1: cross-country growth co-movement beyond common shocks.\n")
}, error = function(e) {
  cat("splm ML failed:", conditionMessage(e), "\n")
  cat("Proceeding with spatial lag-X (fixest) results as primary.\n")
})

# ── Moran's I on FE residuals ─────────────────────────────────────────────────
cat("\n═══ Moran's I test on FE residuals (W1) ═══\n")
tryCatch({
  # residuals(m_base) has one entry per fitted obs (NAs dropped); re-attach by row
  panel_used <- panel |>
    filter(!is.na(growth_y) & !is.na(gerd_pct) & !is.na(savings) &
           !is.na(tertiary_25_64) & !is.na(n_g_d) & !is.na(dtf))
  resid_panel <- panel_used |>
    mutate(e = residuals(m_base)) |>
    select(country, year_int, e)

  # Use a single representative year (most recent with full coverage)
  yr_rep <- resid_panel |> group_by(year_int) |>
    summarise(n=n(), .groups="drop") |> filter(n == max(n)) |>
    pull(year_int) |> max()

  e_vec <- resid_panel |> filter(year_int == yr_rep) |>
    arrange(country) |> pull(e)
  names(e_vec) <- resid_panel |> filter(year_int == yr_rep) |>
    arrange(country) |> pull(country)

  W1_yr <- W1[names(e_vec), names(e_vec)]
  lw    <- spdep::mat2listw(W1_yr, style = "W")
  mi    <- spdep::moran.test(e_vec, lw)
  cat(sprintf("  Year %d: Moran's I = %.4f  p = %.4f  %s\n",
              yr_rep, mi$estimate["Moran I statistic"], mi$p.value,
              if (mi$p.value < 0.05) "[spatial dependence in residuals]"
              else "[no significant spatial clustering]"))
}, error = function(e) cat("Moran test failed:", conditionMessage(e), "\n"))

# ── Coefficient plot: direct vs indirect ─────────────────────────────────────
effects_df <- tibble::tibble(
  weights = c("Inv-dist (W1)","Contiguity (W2)","Income-prox (W3)"),
  direct  = c(coef(m_sdmx1)["gerd_pct"],
              coef(m_sdmx2)["gerd_pct"],
              coef(m_sdmx3)["gerd_pct"]),
  indirect = c(coef(m_sdmx1)["W1_gerd_pct"],
               coef(m_sdmx2)["W2_gerd_pct"],
               coef(m_sdmx3)["W3_gerd_pct"])
) |>
  pivot_longer(c(direct, indirect), names_to = "effect", values_to = "coef")

p_eff <- ggplot(effects_df, aes(x = weights, y = coef, fill = effect)) +
  geom_col(position = position_dodge(0.7), width = 0.6) +
  geom_hline(yintercept = 0, linewidth = 0.4) +
  scale_fill_manual(values = c(direct="#2166ac", indirect="#d6604d"), name=NULL) +
  labs(title = "Spatial Durbin: direct vs indirect GERD effects",
       subtitle = "Indirect = spatial spillover from neighbours' R&D. Two-way FE, DK SEs.",
       x = "Weights matrix", y = "Coefficient on gerd_pct",
       caption = "Source: Eurostat GERD, Eurostat GDP. Spatial weights: see notes.") +
  theme_pub()

figs_dir <- file.path(proj_root, "figures")
ggsave(file.path(figs_dir, "06_spatial_effects.png"), p_eff,
       width = 10, height = 5, dpi = 300)
cat("\nSpatial effects plot saved.\n")
