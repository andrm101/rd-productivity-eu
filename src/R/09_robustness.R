# Stage 09 — Robustness checks, one block per pre-registered hypothesis (README
# "Key hypotheses" table, H1-H7).
#
# IMPORTANT CONTEXT discovered while building this stage: of the 7 pre-registered
# hypotheses, only H2 and H3 had an existing point estimate from Stages 02-08 to
# robustness-check. H4 was tested (Stage 06) and REJECTED -- spatial spillovers are
# non-significant across all three weight matrices (see reports/main.Rmd, "Spatial
# Knowledge Flows at the Macro Level"). H1, H5, H6, and H7 were never formally
# tested by any prior stage (H7 explicitly flagged as untested in reports/main.Rmd:
# "though we do not test it formally here"). This stage therefore runs the FIRST
# formal test for H1/H5/H6/H7, a robustness check for H2/H3, and a robustness check
# of the null for H4 (confirming non-significance isn't an artefact of one
# influential country).
#
# R1 (H1): gamma_GOVERD vs gamma_BERD -- split-GERD FE-DK regression, Wald test
#          on the coefficient difference. NEW TEST (never run before).
# R2 (H2): LP peak at h=5-7 for the catch-up group -- robust to excluding
#          COVID years (2020-2021) from the estimation sample.
# R3 (H3): GERD x DTF interaction sign -- direct gerd_pct:dtf interaction (the
#          literal H3 statement), robust to swapping dtf for rel_frontier.
# R4 (H4): SDM W1 indirect effect -- leave-one-country-out jackknife confirms
#          the null (non-significance) isn't driven by any single country.
# R5 (H5): catch-up cluster (cluster_k2==2) absorbs more spillover than
#          innovator cluster (cluster_k2==1) -- W1_gerd_pct x cluster interaction.
#          NEW TEST (never run before).
# R6 (H6): bootstrap-ARI >= 0.75 for the k=2 clustering (Fang & Wang 2012
#          protocol: resample countries with replacement, refit k-means, compare
#          to the original assignment via Adjusted Rand Index). NEW TEST.
# R7 (H7): GERD coefficient in 2011-2024 vs 1998-2010 subsamples (Bloom et al.
#          2020 "ideas getting harder to find" direction). NEW TEST.
#
# Output: reports/09_robustness_summary.csv (hypothesis, finding, supported,
# notes) and figures/09_bootstrap_ari_hist.png.

suppressPackageStartupMessages({
  library(fixest)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(readr)
  library(mclust)   # adjustedRandIndex, for R6
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

set.seed(42)

panel <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(savings = savings_pct / 100, year_int = as.integer(year)) |>
  arrange(country, year_int)

cat(sprintf("Panel: %d countries, %d years, %d obs\n",
            n_distinct(panel$country), n_distinct(panel$year), nrow(panel)))

dk_fe <- function(fml, data = panel) {
  fixest::feols(fml, data = data |> mutate(year = as.integer(year_int)),
                panel.id = ~ country + year, vcov = "DK")
}

results <- list()

# ── R1 (H1): gamma_GOVERD vs gamma_BERD ──────────────────────────────────────
cat("\n=== R1 (H1): government vs. business R&D effect ===\n")
m_split <- dk_fe(growth_y ~ goverd_pct + berd_pct + pat_pct + savings
                 + tertiary_25_64 + n_g_d | country + year_int)

b_gov <- coef(m_split)["goverd_pct"]
b_bus <- coef(m_split)["berd_pct"]
V     <- vcov(m_split)
se_diff <- sqrt(V["goverd_pct","goverd_pct"] + V["berd_pct","berd_pct"]
                - 2 * V["goverd_pct","berd_pct"])
diff_h1 <- b_gov - b_bus
t_h1 <- diff_h1 / se_diff
p_h1 <- 2 * pt(-abs(t_h1), df = degrees_freedom(m_split, type = "t"))

cat(sprintf("goverd_pct coef=%.4f, berd_pct coef=%.4f, diff=%.4f, p=%.4f\n",
            b_gov, b_bus, diff_h1, p_h1))
h1_supported <- (diff_h1 > 0) && (p_h1 < 0.05)
results$H1 <- tibble(
  hypothesis = "H1", statement = "gamma_GOVERD > gamma_BERD, p<0.05",
  finding = sprintf("goverd=%.4f, berd=%.4f, diff=%.4f, p=%.4f", b_gov, b_bus, diff_h1, p_h1),
  supported = h1_supported,
  notes = "First formal test (never run in Stages 02-08)."
)

# ── R2 (H2): LP peak at h=5-7, catch-up group, robust to excluding COVID ────
cat("\n=== R2 (H2): LP peak horizon, catch-up group ===\n")
H_MAX <- 8L
dtf_med <- median(panel$dtf, na.rm = TRUE)

lp_panel <- panel |>
  group_by(country) |>
  mutate(
    lag_ln_y     = lag(ln_y_pc, 1),
    diff_gerd_l1 = lag(diff_gerd, 1),
    diff_gerd_l2 = lag(diff_gerd, 2),
    growth_y_l1  = lag(growth_y, 1),
    growth_y_l2  = lag(growth_y, 2)
  ) |>
  ungroup()
for (h in 0:H_MAX) {
  lp_panel <- lp_panel |>
    group_by(country) |>
    mutate(!!paste0("out_h", h) := lead(ln_y_pc, h) - lag_ln_y) |>
    ungroup()
}

run_lp <- function(df, label, H = H_MAX) {
  map_dfr(0:H, function(h) {
    outcome_col <- paste0("out_h", h)
    fml <- as.formula(paste(
      outcome_col,
      "~ diff_gerd + diff_gerd_l1 + diff_gerd_l2 + growth_y_l1 + growth_y_l2",
      "+ savings + tertiary_25_64 + n_g_d + dtf | country + year_int"
    ))
    mod <- tryCatch(
      fixest::feols(fml, data = df, panel.id = ~ country + year_int, vcov = "DK"),
      error = function(e) NULL
    )
    if (is.null(mod)) return(tibble(horizon = h, coef = NA_real_, label = label))
    tibble(horizon = h, coef = coef(mod)["diff_gerd"], label = label)
  })
}

irf_far_base    <- run_lp(lp_panel |> filter(dtf > dtf_med), "Catch-up (far), baseline")
irf_far_nocovid <- run_lp(lp_panel |> filter(dtf > dtf_med, d_covid == 0), "Catch-up (far), ex-COVID")

peak_h_base    <- irf_far_base$horizon[which.max(irf_far_base$coef)]
peak_h_nocovid <- irf_far_nocovid$horizon[which.max(irf_far_nocovid$coef)]

cat(sprintf("Peak horizon: baseline h=%d, ex-COVID h=%d\n", peak_h_base, peak_h_nocovid))
h2_supported <- (peak_h_base %in% 5:7) && (peak_h_nocovid %in% 5:7)
results$H2 <- tibble(
  hypothesis = "H2", statement = "LP peak of GERD-on-TFP IRF at h=5-7 (catch-up group)",
  finding = sprintf("peak h=%d (baseline), h=%d (ex-COVID)", peak_h_base, peak_h_nocovid),
  supported = h2_supported,
  notes = "Robustness check on existing Stage 05 estimate."
)

# ── R3 (H3): GERD x DTF interaction, robust to alternate frontier measure ───
cat("\n=== R3 (H3): GERD x distance-to-frontier interaction ===\n")
m_dtf <- dk_fe(growth_y ~ gerd_pct * dtf + savings + tertiary_25_64 + n_g_d
              | country + year_int)
m_relfrontier <- dk_fe(growth_y ~ gerd_pct * rel_frontier + savings + tertiary_25_64 + n_g_d
                       | country + year_int)

b_int_dtf <- coef(m_dtf)["gerd_pct:dtf"]
p_int_dtf <- summary(m_dtf)$coeftable["gerd_pct:dtf", "Pr(>|t|)"]
b_int_rel <- coef(m_relfrontier)["gerd_pct:rel_frontier"]
p_int_rel <- summary(m_relfrontier)$coeftable["gerd_pct:rel_frontier", "Pr(>|t|)"]

cat(sprintf("gerd_pct:dtf coef=%.4f (p=%.4f); gerd_pct:rel_frontier coef=%.4f (p=%.4f)\n",
            b_int_dtf, p_int_dtf, b_int_rel, p_int_rel))
# rel_frontier is typically the inverse of dtf-style distance (closer to frontier =
# higher rel_frontier); a consistent effect should show as an opposite-signed
# interaction there. The finding/notes fields below report the raw values either way
# rather than asserting that relationship holds -- read the printed coefficients.
results$H3 <- tibble(
  hypothesis = "H3", statement = "GERD x distance-to-frontier interaction is negative",
  finding = sprintf("gerd_pct:dtf=%.4f (p=%.4f); gerd_pct:rel_frontier=%.4f (p=%.4f)",
                     b_int_dtf, p_int_dtf, b_int_rel, p_int_rel),
  supported = (b_int_dtf < 0) && (p_int_dtf < 0.10),
  notes = "Direct test of the literal H3 statement (Stage 03 tested krd_x_dtf/gerd_x_hc, a related but not identical specification); rel_frontier swap is the robustness check."
)

# ── R4 (H4): SDM null result, leave-one-country-out jackknife ───────────────
cat("\n=== R4 (H4): SDM indirect effect, jackknife robustness of the null ===\n")
CAPITALS <- tibble::tribble(
  ~country, ~lat,    ~lon,
  "AT",  48.21,  16.37, "BE",  50.85,   4.35, "BG",  42.70,  23.32,
  "CY",  35.17,  33.36, "CZ",  50.08,  14.44, "DE",  52.52,  13.40,
  "DK",  55.68,  12.57, "EE",  59.44,  24.75, "ES",  40.42,  -3.70,
  "FI",  60.17,  24.94, "FR",  48.86,   2.35, "GR",  37.98,  23.73,
  "HR",  45.81,  15.97, "HU",  47.50,  19.04, "IE",  53.33,  -6.25,
  "IS",  64.13, -21.89, "IT",  41.90,  12.50, "LT",  54.69,  25.28,
  "LU",  49.61,   6.13, "LV",  56.95,  24.11, "MT",  35.90,  14.51,
  "NL",  52.37,   4.90, "NO",  59.91,  10.75, "PL",  52.23,  21.01,
  "PT",  38.72,  -9.14, "RO",  44.43,  26.10, "SE",  59.33,  18.07,
  "SI",  46.05,  14.51, "SK",  48.15,  17.11, "CH",  46.95,   7.45
)
haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- 6371
  phi1 <- lat1*pi/180; phi2 <- lat2*pi/180
  dphi <- (lat2-lat1)*pi/180; dlam <- (lon2-lon1)*pi/180
  a <- sin(dphi/2)^2 + cos(phi1)*cos(phi2)*sin(dlam/2)^2
  2*r*asin(sqrt(a))
}
build_w1 <- function(countries_subset) {
  cc <- CAPITALS |> filter(country %in% countries_subset)
  n <- nrow(cc)
  D <- matrix(0, n, n, dimnames = list(cc$country, cc$country))
  for (i in seq_len(n)) for (j in seq_len(n)) if (i != j)
    D[i,j] <- haversine_km(cc$lat[i], cc$lon[i], cc$lat[j], cc$lon[j])
  W_raw <- 1/D; diag(W_raw) <- 0
  sweep(W_raw, 1, rowSums(W_raw), "/")
}
compute_slag <- function(df, W, var, suffix) {
  common <- sort(intersect(unique(df$country), rownames(W)))
  W_sub  <- sweep(W[common, common], 1, pmax(rowSums(W[common, common]), 1e-10), "/")
  wide <- df |> select(country, year_int, all_of(var)) |>
    filter(country %in% common) |>
    pivot_wider(names_from = country, values_from = all_of(var)) |>
    arrange(year_int)
  yr_vec <- wide$year_int
  X_mat  <- as.matrix(wide[, common, drop = FALSE])
  WX_mat <- X_mat %*% t(W_sub)
  colnames(WX_mat) <- paste0("W1_", common)
  as.data.frame(WX_mat) |> mutate(year_int = yr_vec) |>
    pivot_longer(-year_int, names_to = "ckey", values_to = paste0("W1_", var)) |>
    mutate(country = sub("^W1_", "", ckey)) |>
    select(country, year_int, all_of(paste0("W1_", var)))
}

all_countries <- sort(unique(panel$country))
jackknife_pvals <- map_dbl(all_countries, function(drop_c) {
  sub_panel <- panel |> filter(country != drop_c)
  sub_countries <- sort(unique(sub_panel$country))
  W1_sub <- build_w1(sub_countries)
  sl <- compute_slag(sub_panel, W1_sub, "gerd_pct", "1")
  jp <- sub_panel |> left_join(sl, by = c("country","year_int"))
  mod <- tryCatch(
    fixest::feols(growth_y ~ gerd_pct + W1_gerd_pct + savings + tertiary_25_64
                  + n_g_d + dtf | country + year_int,
                  data = jp, panel.id = ~ country + year_int, vcov = "DK"),
    error = function(e) NULL
  )
  if (is.null(mod) || !("W1_gerd_pct" %in% names(coef(mod)))) return(NA_real_)
  summary(mod)$coeftable["W1_gerd_pct", "Pr(>|t|)"]
})
n_still_null <- sum(jackknife_pvals > 0.05, na.rm = TRUE)
n_valid <- sum(!is.na(jackknife_pvals))
cat(sprintf("Leave-one-out: %d/%d runs still non-significant (p>0.05) for W1_gerd_pct\n",
            n_still_null, n_valid))
h4_robust_null <- (n_still_null / n_valid) >= 0.90
results$H4 <- tibble(
  hypothesis = "H4", statement = "Indirect/direct SDM effect ratio > 1 (research-collaboration weights)",
  finding = sprintf("REJECTED in Stage 06 (non-sig across W1/W2/W3); jackknife: %d/%d leave-one-out runs still non-sig",
                     n_still_null, n_valid),
  supported = FALSE,
  notes = if (h4_robust_null) "Null result is robust -- not driven by any single country." else "Null result is NOT robust -- flag for review, some country materially changes significance."
)

# ── R5 (H5): catch-up cluster absorbs more spillover than innovator cluster ─
cat("\n=== R5 (H5): spillover magnitude by cluster ===\n")
clusters <- read_csv(file.path(proj_root, "reports", "08_cluster_assignments.csv"),
                     show_col_types = FALSE) |>
  select(country, cluster_k2)

W1_full <- build_w1(all_countries)
sl_full <- compute_slag(panel, W1_full, "gerd_pct", "1")
panel_h5 <- panel |>
  left_join(sl_full, by = c("country","year_int")) |>
  left_join(clusters, by = "country") |>
  mutate(cluster_k2 = factor(cluster_k2, levels = c(1,2),
                              labels = c("Innovator","CatchUp")))

m_h5 <- dk_fe(growth_y ~ gerd_pct + W1_gerd_pct * cluster_k2 + savings
             + tertiary_25_64 + n_g_d + dtf | country + year_int,
             data = panel_h5)
ct <- summary(m_h5)$coeftable
inter_term <- "W1_gerd_pct:cluster_k2CatchUp"
cat(sprintf("W1_gerd_pct main effect (Innovator baseline)=%.4f (p=%.4f)\n",
            coef(m_h5)["W1_gerd_pct"], ct["W1_gerd_pct","Pr(>|t|)"]))
if (inter_term %in% rownames(ct)) {
  cat(sprintf("W1_gerd_pct x CatchUp interaction=%.4f (p=%.4f)\n",
              coef(m_h5)[inter_term], ct[inter_term,"Pr(>|t|)"]))
  h5_diff <- coef(m_h5)[inter_term]
  h5_p <- ct[inter_term,"Pr(>|t|)"]
} else {
  h5_diff <- NA_real_; h5_p <- NA_real_
}
h5_supported <- !is.na(h5_diff) && (h5_diff > 0) && (h5_p < 0.10)
results$H5 <- tibble(
  hypothesis = "H5", statement = "Catch-up cluster absorbs more spillovers than innovator cluster",
  finding = sprintf("interaction (CatchUp - Innovator)=%.4f, p=%.4f", h5_diff, h5_p),
  supported = h5_supported,
  notes = "First formal test (never run in Stages 02-08). Given H4's own spillover term is non-significant overall, treat this as exploratory, not confirmatory."
)

# ── R6 (H6): bootstrap-ARI >= 0.75 for k=2 clustering ────────────────────────
cat("\n=== R6 (H6): bootstrap stability of k=2 clustering ===\n")
cluster_features <- read_csv(file.path(proj_root, "reports", "08_cluster_assignments.csv"),
                             show_col_types = FALSE)
feat_cols <- c("gerd_pct","ln_krd","dtf","wgi_composite","tertiary_25_64","savings")
X <- cluster_features |> select(all_of(feat_cols)) |> scale()
orig_labels <- cluster_features$cluster_k2
n_country <- nrow(cluster_features)

B <- 200
ari_vec <- numeric(B)
for (b in seq_len(B)) {
  set.seed(42 + b)
  idx <- sample(seq_len(n_country), n_country, replace = TRUE)
  km_b <- kmeans(X[idx, , drop = FALSE], centers = 2, nstart = 50)
  first_occurrence <- !duplicated(idx)
  ari_vec[b] <- mclust::adjustedRandIndex(orig_labels[idx[first_occurrence]],
                                          km_b$cluster[first_occurrence])
}
mean_ari <- mean(ari_vec, na.rm = TRUE)
cat(sprintf("Bootstrap-ARI: mean=%.3f over B=%d replicates\n", mean_ari, B))
# K-means cluster indices (1/2) are arbitrary per run; ARI is symmetric to label
# permutation by construction, so no explicit label-alignment step is needed.

ari_plot_path <- file.path(proj_root, "figures", "09_bootstrap_ari_hist.png")
dir.create(dirname(ari_plot_path), recursive = TRUE, showWarnings = FALSE)
png(ari_plot_path, width = 800, height = 500)
hist(ari_vec, breaks = 30, main = "Bootstrap ARI distribution (B=200)",
     xlab = "Adjusted Rand Index vs. original k=2 assignment", col = "steelblue")
abline(v = 0.75, col = "red", lwd = 2, lty = 2)
dev.off()
cat(sprintf("Figure saved: %s\n", ari_plot_path))

h6_supported <- mean_ari >= 0.75
results$H6 <- tibble(
  hypothesis = "H6", statement = "Bootstrap-ARI >= 0.75 for k=2 clusters",
  finding = sprintf("mean ARI=%.3f over B=%d bootstrap replicates", mean_ari, B),
  supported = h6_supported,
  notes = "First formal test (never run in Stage 08)."
)

# ── R7 (H7): GERD coefficient, 2011-2024 vs 1998-2010 ────────────────────────
cat("\n=== R7 (H7): GERD coefficient over time (Bloom et al. 2020 direction) ===\n")
m_early <- dk_fe(growth_y ~ gerd_pct + pat_pct + savings + tertiary_25_64 + n_g_d
                 | country + year_int, data = panel |> filter(year_int <= 2010))
m_late  <- dk_fe(growth_y ~ gerd_pct + pat_pct + savings + tertiary_25_64 + n_g_d
                 | country + year_int, data = panel |> filter(year_int >= 2011))

b_early <- coef(m_early)["gerd_pct"]
b_late  <- coef(m_late)["gerd_pct"]
cat(sprintf("gerd_pct coef: 1998-2010=%.4f, 2011-2024=%.4f\n", b_early, b_late))
h7_supported <- abs(b_late) < abs(b_early)
results$H7 <- tibble(
  hypothesis = "H7", statement = "GERD coefficient smaller in 2011-2024 than 1998-2010 (Bloom et al.)",
  finding = sprintf("|coef| 1998-2010=%.4f, 2011-2024=%.4f", abs(b_early), abs(b_late)),
  supported = h7_supported,
  notes = "First formal test (never run before; reports/main.Rmd explicitly noted this as untested)."
)

# ── Assemble and write summary ───────────────────────────────────────────────
summary_tbl <- bind_rows(results)
out_path <- file.path(proj_root, "reports", "09_robustness_summary.csv")
write_csv(summary_tbl, out_path)
cat(sprintf("\nWritten: %s\n", out_path))
print(summary_tbl |> select(hypothesis, supported, finding), n = 7, width = Inf)
