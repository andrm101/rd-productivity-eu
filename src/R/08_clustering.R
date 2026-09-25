# Stage 08 — K-means Country Typology
#
# Extends the thesis k=2 binary split (high/low R&D) to a richer
# taxonomy using six features:
#   gerd_pct, ln_krd, dtf, wgi_composite, tertiary_25_64, savings
#
# Protocol:
#   1. Collapse panel to N=29 country means
#   2. Z-standardise all features (Euclidean distance meaningful)
#   3. k=2..6: K-means, nstart=50, set.seed(42)
#   4. Optimal k: silhouette (Kaufman & Rousseeuw 1990, Chapter 2)
#                + elbow (total WCSS)
#                + gap statistic (Tibshirani et al. 2001, JRSS-B 63:411-423)
#   5. Cluster profiles: mean z-scores + raw statistics
#   6. Linkage to Stages 05-07:
#      a. CATE distribution by cluster (Stage 07)
#      b. Frontier regime overlap (Stage 03 dtf split)
#      c. LP peak effects by cluster (Stage 05)
#   7. Thesis replication: do k=2 clusters reproduce thesis assignment?
#
# Figures: 08_elbow_silhouette.png, 08_cluster_profiles.png,
#          08_scatter_dtf_krd.png, 08_cate_by_cluster.png

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(purrr)
})

if (!requireNamespace("cluster", quietly = TRUE))
  install.packages("cluster", repos = "https://cloud.r-project.org", type = "binary")
library(cluster)

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

figs_dir    <- file.path(proj_root, "figures")
reports_dir <- file.path(proj_root, "reports")
dir.create(figs_dir,    recursive = TRUE, showWarnings = FALSE)
dir.create(reports_dir, recursive = TRUE, showWarnings = FALSE)

# ── Load panel and compute country means ──────────────────────────────────────
panel <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(savings = savings_pct / 100, year_int = as.integer(year))

FEATURES <- c("gerd_pct","ln_krd","dtf","wgi_composite","tertiary_25_64","savings")

country_means <- panel |>
  group_by(country) |>
  summarise(across(all_of(FEATURES), \(x) mean(x, na.rm = TRUE)),
            n_obs = n(), .groups = "drop") |>
  filter(rowSums(is.na(across(all_of(FEATURES)))) == 0) |>
  arrange(country)

cat(sprintf("Countries with complete feature set: %d\n", nrow(country_means)))
cat("Countries: ", paste(country_means$country, collapse = " "), "\n\n")

# Z-standardise
Z <- scale(country_means[, FEATURES])
rownames(Z) <- country_means$country

# ── k=2..6: K-means + diagnostics ────────────────────────────────────────────
set.seed(42)
K_MAX <- 6L

km_list <- map(2:K_MAX, function(k) {
  kmeans(Z, centers = k, nstart = 50, iter.max = 100)
})
names(km_list) <- paste0("k", 2:K_MAX)

# Total within-cluster sum of squares (elbow)
wcss <- map_dbl(km_list, "tot.withinss")

# Average silhouette width
avg_sil <- map_dbl(km_list, function(km) {
  sil <- cluster::silhouette(km$cluster, dist(Z))
  mean(sil[, "sil_width"])
})

diag_df <- tibble(k = 2:K_MAX, wcss = wcss, avg_silhouette = avg_sil)

cat("── K-means diagnostics ──\n")
print(diag_df, digits = 4)

# Gap statistic (B=100 bootstrap reference distributions)
set.seed(42)
gap_obj <- cluster::clusGap(Z, FUN = kmeans, K.max = K_MAX,
                             nstart = 50, B = 100, verbose = FALSE)
gap_tbl <- as.data.frame(gap_obj$Tab) |>
  tibble::rownames_to_column("k_str") |>
  mutate(k = as.integer(k_str)) |>
  filter(k >= 2) |>
  select(k, gap, SE.sim)

cat("\nGap statistic:\n")
print(gap_tbl, digits = 4)

k_opt_sil <- diag_df$k[which.max(diag_df$avg_silhouette)]
k_opt_gap <- gap_tbl$k[which.max(gap_tbl$gap)]
cat(sprintf("\nOptimal k (silhouette): %d\nOptimal k (gap):        %d\n",
            k_opt_sil, k_opt_gap))

# Use silhouette-optimal k as primary; k=2 for thesis comparison
k_primary <- k_opt_sil

# ── Elbow + silhouette figure ─────────────────────────────────────────────────
p_elbow <- ggplot(diag_df, aes(x = k)) +
  geom_line(aes(y = wcss), colour = "#2166ac", linewidth = 0.8) +
  geom_point(aes(y = wcss), colour = "#2166ac", size = 2.5) +
  geom_vline(xintercept = k_primary, linetype = "dashed", colour = "#d6604d") +
  scale_y_continuous(name = "Total WCSS") +
  scale_x_continuous(breaks = 2:K_MAX) +
  labs(title = "Elbow: within-cluster sum of squares",
       subtitle = sprintf("Dashed = silhouette-optimal k=%d", k_primary),
       x = "Number of clusters k") +
  theme_pub()

p_sil <- ggplot(diag_df, aes(x = k, y = avg_silhouette)) +
  geom_line(colour = "#2166ac", linewidth = 0.8) +
  geom_point(colour = "#2166ac", size = 2.5) +
  geom_point(data = filter(diag_df, k == k_primary),
             colour = "#d6604d", size = 4) +
  scale_x_continuous(breaks = 2:K_MAX) +
  labs(title = "Average silhouette width by k",
       x = "Number of clusters k", y = "Mean silhouette width",
       caption = "Kaufman & Rousseeuw (1990). Higher = better separation.") +
  theme_pub()

if (requireNamespace("patchwork", quietly = TRUE)) {
  library(patchwork)
  p_combo <- p_elbow / p_sil
  ggsave(file.path(figs_dir, "08_elbow_silhouette.png"), p_combo,
         width = 9, height = 8, dpi = 300)
} else {
  ggsave(file.path(figs_dir, "08_elbow.png"),      p_elbow, width=9, height=4, dpi=300)
  ggsave(file.path(figs_dir, "08_silhouette.png"), p_sil,   width=9, height=4, dpi=300)
}
cat("\n  Saved: 08_elbow_silhouette.png\n")

# ── Primary clustering: k=k_primary ──────────────────────────────────────────
km_prim <- km_list[[paste0("k", k_primary)]]
km_2    <- km_list[["k2"]]

country_means <- country_means |>
  mutate(cluster    = km_prim$cluster,
         cluster_k2 = km_2$cluster)

cat(sprintf("\n── k=%d cluster assignments ──\n", k_primary))
for (cl in sort(unique(country_means$cluster))) {
  members <- country_means$country[country_means$cluster == cl]
  cat(sprintf("  Cluster %d (%d countries): %s\n",
              cl, length(members), paste(members, collapse = ", ")))
}

cat("\n── k=2 (thesis) cluster assignments ──\n")
for (cl in sort(unique(country_means$cluster_k2))) {
  members <- country_means$country[country_means$cluster_k2 == cl]
  cat(sprintf("  Cluster %d (%d countries): %s\n",
              cl, length(members), paste(members, collapse = ", ")))
}

# ── Cluster profiles (mean raw values) ───────────────────────────────────────
profile_raw <- country_means |>
  group_by(cluster) |>
  summarise(across(all_of(FEATURES), mean), n = n(), .groups = "drop") |>
  mutate(across(where(is.numeric), \(x) round(x, 3)))

cat(sprintf("\n── Cluster profiles (raw means, k=%d) ──\n", k_primary))
print(profile_raw)

# Z-score profiles for plotting
profile_z <- as.data.frame(Z) |>
  mutate(country = rownames(Z),
         cluster = factor(km_prim$cluster)) |>
  pivot_longer(all_of(FEATURES), names_to = "feature", values_to = "z") |>
  group_by(cluster, feature) |>
  summarise(mean_z = mean(z), .groups = "drop")

# Heatmap-style profile bar chart
cluster_labels <- paste0("Cluster ", levels(factor(km_prim$cluster)))
p_profile <- ggplot(profile_z, aes(x = feature, y = mean_z, fill = cluster)) +
  geom_col(position = position_dodge(0.8), width = 0.7) +
  geom_hline(yintercept = 0, linewidth = 0.4) +
  scale_fill_brewer(palette = "Set1", name = "Cluster") +
  coord_flip() +
  labs(
    title    = sprintf("Cluster profiles: mean z-scores (k=%d)", k_primary),
    subtitle = "Features: GERD intensity, knowledge stock, frontier distance, institutions, human capital, savings",
    x        = NULL, y        = "Mean standardised score (z)",
    caption  = "K-means, nstart=50, set.seed(42). Silhouette-optimal k."
  ) +
  theme_pub()

ggsave(file.path(figs_dir, "08_cluster_profiles.png"), p_profile,
       width = 10, height = 5, dpi = 300)
cat("  Saved: 08_cluster_profiles.png\n")

# ── Scatter: dtf vs ln_krd coloured by cluster ───────────────────────────────
p_scatter <- ggplot(country_means,
                    aes(x = dtf, y = ln_krd, colour = factor(cluster),
                        label = country)) +
  geom_point(size = 3) +
  ggrepel::geom_text_repel(size = 2.8, max.overlaps = 30) +
  scale_colour_brewer(palette = "Set1", name = "Cluster") +
  labs(
    title    = sprintf("Country clusters in (DTF, ln_krd) space (k=%d)", k_primary),
    subtitle = "K-means on 6 features: GERD, knowledge stock, DTF, institutions, HC, savings",
    x        = "Distance to frontier (mean)",
    y        = "Log knowledge stock (mean)",
    caption  = "Country means, 1998-2024."
  ) +
  theme_pub()

tryCatch({
  if (!requireNamespace("ggrepel", quietly = TRUE)) stop("no ggrepel")
  ggsave(file.path(figs_dir, "08_scatter_dtf_krd.png"), p_scatter,
         width = 10, height = 7, dpi = 300)
  cat("  Saved: 08_scatter_dtf_krd.png\n")
}, error = function(e) cat("  Scatter skipped (ggrepel):", conditionMessage(e), "\n"))

# ── Link to Stage 07 CATE ─────────────────────────────────────────────────────
cate_path <- file.path(proj_root, "reports", "07_cate_panel.csv")
if (file.exists(cate_path)) {
  cate_panel <- read.csv(cate_path) |>
    left_join(country_means |> select(country, cluster), by = "country")

  cate_by_cluster <- cate_panel |>
    group_by(cluster) |>
    summarise(mean_cate = mean(tau_hat, na.rm = TRUE),
              sd_cate   = sd(tau_hat,   na.rm = TRUE),
              n         = n(), .groups = "drop")

  cat("\n── Stage 07 CATE by cluster ──\n")
  print(cate_by_cluster)

  p_cate_cl <- ggplot(cate_panel |> filter(!is.na(cluster)),
                      aes(x = factor(cluster), y = tau_hat,
                          fill = factor(cluster))) +
    geom_boxplot(alpha = 0.7, outlier.size = 1) +
    geom_hline(yintercept = 0, linetype = "dashed", colour = "grey40") +
    scale_fill_brewer(palette = "Set1", guide = "none") +
    labs(
      title    = "CATE distribution by cluster",
      subtitle = "Causal forest estimates (Stage 07) grouped by K-means cluster (Stage 08)",
      x        = "Cluster", y = "Estimated CATE tau(X)",
      caption  = "CATE: causal effect of +1pp GERD on annual growth. Zero = no effect."
    ) +
    theme_pub()

  ggsave(file.path(figs_dir, "08_cate_by_cluster.png"), p_cate_cl,
         width = 9, height = 5, dpi = 300)
  cat("  Saved: 08_cate_by_cluster.png\n")
}

# ── Silhouette plot (per-observation) ────────────────────────────────────────
sil_obj <- cluster::silhouette(km_prim$cluster, dist(Z))
sil_df  <- as.data.frame(sil_obj) |>
  tibble::rownames_to_column("idx") |>
  mutate(country = country_means$country,
         cluster = factor(cluster)) |>
  arrange(cluster, sil_width)

p_sil_obs <- ggplot(sil_df, aes(x = reorder(country, sil_width),
                                y = sil_width, fill = cluster)) +
  geom_col(width = 0.8) +
  geom_hline(yintercept = mean(sil_df$sil_width), linetype = "dashed",
             colour = "grey30") +
  scale_fill_brewer(palette = "Set1", name = "Cluster") +
  coord_flip() +
  labs(
    title   = sprintf("Silhouette plot (k=%d)", k_primary),
    x       = NULL, y = "Silhouette width",
    caption = sprintf("Mean silhouette = %.3f. Dashed = mean.", mean(sil_df$sil_width))
  ) +
  theme_pub()

ggsave(file.path(figs_dir, "08_silhouette_obs.png"), p_sil_obs,
       width = 9, height = 7, dpi = 300)
cat("  Saved: 08_silhouette_obs.png\n")

# ── Export ────────────────────────────────────────────────────────────────────
write.csv(
  country_means |>
    select(country, cluster, cluster_k2, all_of(FEATURES)) |>
    mutate(across(where(is.numeric), \(x) round(x, 4))),
  file.path(reports_dir, "08_cluster_assignments.csv"),
  row.names = FALSE
)
write.csv(
  profile_raw,
  file.path(reports_dir, "08_cluster_profiles.csv"),
  row.names = FALSE
)
write.csv(
  diag_df,
  file.path(reports_dir, "08_kmeans_diagnostics.csv"),
  row.names = FALSE
)

cat("\n  Cluster assignments -> reports/08_cluster_assignments.csv\n")
cat("  Cluster profiles   -> reports/08_cluster_profiles.csv\n")
cat("  K-means diagnostics-> reports/08_kmeans_diagnostics.csv\n")

# ── Final summary ─────────────────────────────────────────────────────────────
cat(sprintf("\n═══ Stage 08 summary ═══\n"))
cat(sprintf("  Silhouette-optimal k: %d  (avg sil=%.3f)\n",
            k_opt_sil, max(diag_df$avg_silhouette)))
cat(sprintf("  Gap-optimal k:        %d\n", k_opt_gap))
cat(sprintf("  k=2 (thesis):  avg silhouette=%.3f\n",
            diag_df$avg_silhouette[diag_df$k == 2]))
cat(sprintf("  k=%d (primary): avg silhouette=%.3f\n",
            k_primary, diag_df$avg_silhouette[diag_df$k == k_primary]))
cat("  CATE homogeneity across clusters: see 08_cate_by_cluster.png\n")
