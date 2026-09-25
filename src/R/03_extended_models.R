# Stage 03 — Extended models: knowledge stock, frontier distance,
# absorptive capacity interactions, Driscoll-Kraay throughout.
#
# Model progression (all FE two-way, DK SEs unless noted):
#   M0   Baseline thesis spec (savings/100, n_g_d levels) — reference
#   M1   Replace gerd_pct with ln_krd (knowledge stock)
#   M2   M1 + dtf (distance to frontier)
#   M3   M2 + gerd_x_hc (Nelson-Phelps absorptive capacity)
#   M4   M3 + krd_x_dtf interaction (imitation vs innovation margin)
#   M5   M4 + wgi_composite (institutional quality)
#   M6   M3, split by frontier regime: dtf < median vs dtf >= median

suppressPackageStartupMessages({
  library(plm)
  library(fixest)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
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

# ── Load full N=29 primary panel ──────────────────────────────────────────────
panel <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(
    savings  = savings_pct / 100,
    year_int = as.integer(year)
  )

cat(sprintf("Panel: %d countries, %d years, %d obs\n",
            n_distinct(panel$country), n_distinct(panel$year), nrow(panel)))

# Sanity-check new columns
cat("krd_pct range:  ", paste(round(range(panel$krd_pct,  na.rm=TRUE), 2), collapse=" – "), "\n")
cat("dtf range:      ", paste(round(range(panel$dtf,      na.rm=TRUE), 3), collapse=" – "), "\n")
cat("gerd_x_hc range:", paste(round(range(panel$gerd_x_hc,na.rm=TRUE), 3), collapse=" – "), "\n")

# ── DK helper: two-way FE with Driscoll-Kraay SEs ────────────────────────────
dk_fe <- function(fml, data = panel) {
  fixest::feols(
    fml,
    data     = data |> mutate(year = as.integer(year)),
    panel.id = ~ country + year,
    vcov     = "DK"
  )
}

# ── Model sequence ────────────────────────────────────────────────────────────
# M0: thesis baseline, full N=29 (reference)
m0 <- dk_fe(growth_y ~ gerd_pct + pat_pct + savings + tertiary_25_64 + n_g_d
            | country + year)

# M1: knowledge stock replaces GERD flow
m1 <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
            | country + year)

# M2: + distance to frontier
m2 <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d + dtf
            | country + year)

# M3: + Nelson-Phelps absorptive capacity interaction
m3 <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
            + dtf + gerd_x_hc
            | country + year)

# M4: + krd x dtf interaction (imitation vs innovation margin)
m4 <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
            + dtf + gerd_x_hc + krd_x_dtf
            | country + year)

# M5: + institutional quality composite
m5 <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
            + dtf + gerd_x_hc + krd_x_dtf + wgi_composite
            | country + year)

# ── Print comparison table ────────────────────────────────────────────────────
cat("\n═══ Extended model sequence (DK SEs, two-way FE) ═══\n")
fixest::etable(m0, m1, m2, m3, m4, m5,
               keep = c("gerd_pct","ln_krd","dtf","gerd_x_hc","krd_x_dtf",
                        "wgi_composite","savings","n_g_d","tertiary_25_64"),
               headers = c("M0 baseline","M1 krd","M2 +dtf",
                           "M3 +AC","M4 +int","M5 +inst"))

# ── M6: split-sample by frontier proximity ───────────────────────────────────
dtf_med <- median(panel$dtf, na.rm = TRUE)
cat(sprintf("\nDTF median: %.3f (frontier = 95th pct ln_y_pc)\n", dtf_med))

panel_close <- panel |> filter(dtf <= dtf_med)   # close to frontier
panel_far   <- panel |> filter(dtf >  dtf_med)   # catch-up economies

m6_close <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
                  + gerd_x_hc | country + year,
                  data = panel_close)
m6_far   <- dk_fe(growth_y ~ ln_krd + pat_pct + savings + tertiary_25_64 + n_g_d
                  + gerd_x_hc | country + year,
                  data = panel_far)

cat("\n═══ M6: split by frontier proximity ═══\n")
cat(sprintf("  Close-to-frontier: %d obs (%d countries)\n",
            nrow(panel_close), n_distinct(panel_close$country)))
cat(sprintf("  Catch-up (far):    %d obs (%d countries)\n",
            nrow(panel_far),   n_distinct(panel_far$country)))
fixest::etable(m6_close, m6_far,
               keep = c("ln_krd","gerd_x_hc","savings","n_g_d"),
               headers = c("Close (frontier)","Far (catch-up)"))

# ── Wald test: krd_x_dtf coefficient = 0 (M4 vs M3) ─────────────────────────
cat("\n── Wald test: krd_x_dtf = 0 (M4) ──\n")
tryCatch(print(fixest::wald(m4, "krd_x_dtf")), error = function(e) cat("Wald:", conditionMessage(e), "\n"))

# ── Coefficient plot: M3 (main spec) ─────────────────────────────────────────
coef_df <- as.data.frame(summary(m3)$coeftable) |>
  tibble::rownames_to_column("term") |>
  rename(est = Estimate, se = `Std. Error`, tval = `t value`, pval = `Pr(>|t|)`) |>
  mutate(
    ci_lo = est - 1.96 * se,
    ci_hi = est + 1.96 * se,
    sig   = cut(pval, c(-Inf, 0.01, 0.05, 0.1, Inf),
                labels = c("p<0.01","p<0.05","p<0.10","n.s."))
  )

p_coef <- ggplot(coef_df, aes(x = reorder(term, est), y = est,
                               colour = sig, ymin = ci_lo, ymax = ci_hi)) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey60") +
  geom_pointrange(size = 0.6) +
  scale_colour_manual(
    values = c("p<0.01"="#1a1a2e","p<0.05"="#16213e","p<0.10"="#0f3460","n.s."="#a8a8b3"),
    name = NULL) +
  coord_flip() +
  labs(title = "M3 coefficients with 95% Driscoll-Kraay CIs",
       subtitle = "FE two-way, N=29 primary panel, 1998-2024",
       x = NULL, y = "Coefficient",
       caption = "DK SEs robust to cross-sectional dependence and serial correlation.") +
  theme_pub()

figs_dir <- file.path(proj_root, "figures")
dir.create(figs_dir, recursive = TRUE, showWarnings = FALSE)
ggsave(file.path(figs_dir, "03_coef_plot_m3.png"), p_coef,
       width = 10, height = 6, dpi = 300)
cat("\nCoefficient plot saved.\n")

# ── DTF-growth scatter (descriptive) ─────────────────────────────────────────
p_dtf <- panel |>
  filter(!is.na(dtf), !is.na(growth_y)) |>
  group_by(country) |>
  summarise(mean_dtf = mean(dtf, na.rm=TRUE),
            mean_growth = mean(growth_y, na.rm=TRUE), .groups="drop") |>
  ggplot(aes(mean_dtf, mean_growth, label = country)) +
  geom_point(colour = "#16213e", size = 2.5) +
  ggrepel::geom_text_repel(size = 3, colour = "grey40",
                            max.overlaps = 20) +
  geom_smooth(method = "lm", se = TRUE, colour = "#d62839", linewidth = 0.7) +
  labs(title = "Distance to frontier vs mean annual growth",
       subtitle = "Country means, 1998-2024. Positive slope = conditional convergence.",
       x = "Mean distance to frontier (ln units)",
       y = "Mean annual Δln(GDP per capita)",
       caption = "Frontier = 95th pct of primary panel. Source: Eurostat nama_10_pc.") +
  theme_pub()

tryCatch({
  if (!requireNamespace("ggrepel", quietly = TRUE)) stop("ggrepel not installed")
  ggsave(file.path(figs_dir, "03_dtf_scatter.png"), p_dtf,
         width = 10, height = 7, dpi = 300)
  cat("DTF scatter saved.\n")
}, error = function(e) {
  cat("DTF scatter skipped (ggrepel not installed — install with install.packages('ggrepel')).\n")
})
