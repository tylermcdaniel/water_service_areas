################################################################################
## purpose: gather EPA water inorganic contaminant data
## author: tyler mcdaniel 
## date created : 10/27/2026
## date last modified: 
################################################################################
#!/usr/bin/env Rscript
# Estimate inorganic contaminant levels for U.S. community water systems (CWS).
#
# Pipeline:
#   1. Download EPA's SDWIS data (ECHO SDWA bulk download).
#   2. Load CWS service area boundaries.
#   3. Summarize, per system, lead/copper 90th percentile results and
#      inorganic chemical (IOC) violations.
#   4. Join the summaries to the boundaries and write a CSV and a GeoPackage.
#
# Usage:
#   Rscript R/estimate_inorganics.R              # all states
#   Rscript R/estimate_inorganics.R CA NV AZ     # selected states only
#
# Required packages: dplyr, readr, sf, tidyr, stringr

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(sf)
  library(tidyr)
  library(stringr)
})

# ---- Configuration -----------------------------------------------------------

RAW_DIR <- "Test_data_files/data/raw"
OUT_DIR <- "Test_data_files/output"

# ECHO publishes SDWIS as a zip of CSVs, refreshed quarterly.
SDWA_URL <- "https://echo.epa.gov/files/echodownloads/SDWA_latest_downloads.zip"

# CWS service area boundaries. The default is EPA ORD's national layer
# ("Community Water System Service Area Boundaries"), which you download from
# EPA's site or data.gov and save here. Any format sf can read works
# (GeoPackage, shapefile, GeoJSON, file geodatabase). Set BOUNDARY_URL to have
# the script download it, or point WSA_BOUNDARIES at a different file.
BOUNDARY_PATH <- Sys.getenv("WSA_BOUNDARIES", file.path(RAW_DIR, "cws_boundaries.gpkg"))
BOUNDARY_URL <- Sys.getenv("WSA_BOUNDARY_URL", "")

# Only use samples and violations from this many years before today.
LOOKBACK_YEARS <- 10

# Lead and Copper Rule action levels (mg/L), applied to 90th percentile results.
LEAD_ACTION_LEVEL <- 0.015
COPPER_ACTION_LEVEL <- 1.3

# SDWIS contaminant codes for the regulated inorganic chemicals (IOCs).
IOC_CODES <- c(
  "1005" = "arsenic",
  "1010" = "barium",
  "1015" = "cadmium",
  "1020" = "chromium",
  "1024" = "cyanide",
  "1025" = "fluoride",
  "1035" = "mercury",
  "1038" = "nitrate_nitrite",
  "1040" = "nitrate",
  "1041" = "nitrite",
  "1045" = "selenium",
  "1074" = "antimony",
  "1075" = "beryllium",
  "1085" = "thallium",
  "1094" = "asbestos"
)

# ---- Download and read SDWIS ----------------------------------------------------

download_sdwa <- function(raw_dir = RAW_DIR, url = SDWA_URL) {
  dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
  needed <- c("SDWA_PUB_WATER_SYSTEMS.csv", "SDWA_LCR_SAMPLES.csv",
              "SDWA_VIOLATIONS_ENFORCEMENT.csv")
  missing <- needed[!file.exists(file.path(raw_dir, needed))]
  if (length(missing) > 0) {
    zip_path <- file.path(raw_dir, "SDWA_latest_downloads.zip")
    if (!file.exists(zip_path)) {
      message("Downloading SDWIS data from ", url)
      options(timeout = max(3600, getOption("timeout")))
      download.file(url, zip_path, mode = "wb")
    }
    message("Unzipping ", paste(missing, collapse = ", "))
    unzip(zip_path, files = missing, exdir = raw_dir)
  }
  invisible(file.path(raw_dir, needed))
}

# The SDWA files are large (the violations file is several GB), so read them in
# chunks and keep only the rows we need.
read_filtered <- function(path, keep, filter_fn) {
  read_csv_chunked(
    path,
    callback = DataFrameCallback$new(function(chunk, pos) filter_fn(chunk)),
    chunk_size = 500000,
    col_types = do.call(cols_only, setNames(rep(list(col_character()), length(keep)), keep)),
    progress = FALSE
  )
}

# ECHO dates are MM/DD/YYYY; accept ISO dates too.
parse_sdwa_date <- function(x) {
  out <- as.Date(x, format = "%m/%d/%Y")
  iso <- is.na(out) & !is.na(x)
  out[iso] <- as.Date(substr(x[iso], 1, 10), format = "%Y-%m-%d")
  out
}

read_water_systems <- function(path, states = NULL) {
  read_filtered(
    path,
    keep = c("PWSID", "PWS_NAME", "STATE_CODE", "PWS_TYPE_CODE",
             "PWS_ACTIVITY_CODE", "POPULATION_SERVED_COUNT",
             "SERVICE_CONNECTIONS_COUNT", "PRIMARY_SOURCE_CODE",
             "OWNER_TYPE_CODE"),
    filter_fn = function(df) {
      df <- filter(df, PWS_TYPE_CODE == "CWS", PWS_ACTIVITY_CODE == "A")
      if (!is.null(states)) df <- filter(df, STATE_CODE %in% states)
      df
    }
  ) |>
    # The file can list a system once per submission year; keep one row each.
    distinct(PWSID, .keep_all = TRUE) |>
    mutate(
      POPULATION_SERVED_COUNT = as.numeric(POPULATION_SERVED_COUNT),
      SERVICE_CONNECTIONS_COUNT = as.numeric(SERVICE_CONNECTIONS_COUNT)
    ) |>
    select(-PWS_TYPE_CODE, -PWS_ACTIVITY_CODE)
}

# ---- Lead and copper ---------------------------------------------------------------

summarize_lead_copper <- function(path, pwsids, since) {
  samples <- read_filtered(
    path,
    keep = c("PWSID", "SAMPLING_END_DATE", "CONTAMINANT_CODE",
             "SAMPLE_MEASURE", "UNIT_OF_MEASURE"),
    filter_fn = function(df) {
      filter(df, PWSID %in% pwsids, CONTAMINANT_CODE %in% c("PB90", "CU90"))
    }
  ) |>
    mutate(
      date = parse_sdwa_date(SAMPLING_END_DATE),
      value = to_mg_l(as.numeric(SAMPLE_MEASURE), UNIT_OF_MEASURE),
      metal = if_else(CONTAMINANT_CODE == "PB90", "lead", "copper"),
      action_level = if_else(metal == "lead", LEAD_ACTION_LEVEL, COPPER_ACTION_LEVEL)
    ) |>
    filter(!is.na(value), !is.na(date), date >= since)

  # Template so every column exists even if a metal has no samples.
  template <- tibble(
    PWSID = character(),
    lead_n_90th = integer(), lead_latest_date = as.Date(character()),
    lead_latest_90th = numeric(), lead_max_90th = numeric(),
    lead_mean_90th = numeric(), lead_n_ale = integer(),
    copper_n_90th = integer(), copper_latest_date = as.Date(character()),
    copper_latest_90th = numeric(), copper_max_90th = numeric(),
    copper_mean_90th = numeric(), copper_n_ale = integer()
  )
  if (nrow(samples) == 0) return(template)

  summary <- samples |>
    group_by(PWSID, metal) |>
    summarize(
      n_90th = n(),
      latest_date = max(date),
      latest_90th = value[which.max(date)],
      max_90th = max(value),
      mean_90th = mean(value),
      n_ale = sum(value > action_level),
      .groups = "drop"
    ) |>
    pivot_wider(
      names_from = metal,
      values_from = c(n_90th, latest_date, latest_90th, max_90th, mean_90th, n_ale),
      names_glue = "{metal}_{.value}"
    )
  bind_rows(template, summary)
}

# SDWIS reports LCR results in mg/L or ug/L.
to_mg_l <- function(value, unit) {
  unit <- str_to_lower(str_trim(coalesce(unit, "")))
  case_when(
    unit %in% c("mg/l", "") ~ value,
    unit %in% c("ug/l", "µg/l", "ppb") ~ value / 1000,
    TRUE ~ NA_real_
  )
}

# ---- IOC violations --------------------------------------------------------------

summarize_ioc_violations <- function(path, pwsids, since) {
  viols <- read_filtered(
    path,
    keep = c("PWSID", "VIOLATION_ID", "CONTAMINANT_CODE",
             "IS_HEALTH_BASED_IND", "NON_COMPL_PER_BEGIN_DATE"),
    filter_fn = function(df) {
      filter(df, PWSID %in% pwsids, CONTAMINANT_CODE %in% names(IOC_CODES))
    }
  ) |>
    # One violation can appear on several rows (one per enforcement action).
    distinct(PWSID, VIOLATION_ID, .keep_all = TRUE) |>
    mutate(
      date = parse_sdwa_date(NON_COMPL_PER_BEGIN_DATE),
      contaminant = unname(IOC_CODES[CONTAMINANT_CODE]),
      health_based = IS_HEALTH_BASED_IND == "Y"
    ) |>
    filter(!is.na(date), date >= since)

  if (nrow(viols) == 0) {
    return(tibble(PWSID = character(), ioc_violations = integer(),
                  ioc_health_violations = integer(),
                  ioc_last_violation = as.Date(character()),
                  ioc_contaminants = character()))
  }

  totals <- viols |>
    group_by(PWSID) |>
    summarize(
      ioc_violations = n(),
      ioc_health_violations = sum(health_based, na.rm = TRUE),
      ioc_last_violation = max(date),
      ioc_contaminants = paste(sort(unique(contaminant[health_based %in% TRUE])),
                               collapse = ";"),
      .groups = "drop"
    )

  # One column per contaminant: count of health-based violations.
  by_contaminant <- viols |>
    filter(health_based %in% TRUE) |>
    count(PWSID, contaminant) |>
    pivot_wider(names_from = contaminant, values_from = n,
                names_prefix = "hb_", values_fill = 0)

  left_join(totals, by_contaminant, by = "PWSID")
}

# ---- Boundaries -------------------------------------------------------------------

read_boundaries <- function(path = BOUNDARY_PATH, url = BOUNDARY_URL, states = NULL) {
  if (!file.exists(path)) {
    if (nzchar(url)) {
      message("Downloading boundaries from ", url)
      dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
      download.file(url, path, mode = "wb")
    } else {
      stop(
        "No CWS boundary file at '", path, "'. Download EPA's Community Water ",
        "System Service Area Boundaries layer and save it there, or set the ",
        "WSA_BOUNDARIES (local file) or WSA_BOUNDARY_URL environment variable.",
        call. = FALSE
      )
    }
  }
  
  sf_use_s2(FALSE) # temporarily suppress spherical checks
  
  bnd <- st_read(path, quiet = TRUE)
  
  # make valid
  bnd %<>%
    st_make_valid()

  # Layers name the ID column differently (PWSID, pwsid, PWS_ID, ...).
  id_col <- grep("^pws_?id$", names(bnd), ignore.case = TRUE, value = TRUE)[1]
  if (is.na(id_col)) stop("No PWSID column found in ", path, call. = FALSE)

  bnd <- bnd |>
    transmute(PWSID = str_to_upper(str_trim(as.character(.data[[id_col]])))) |>
    filter(!is.na(PWSID))
  # PWSIDs start with the two-letter state or tribal region code.
  if (!is.null(states)) bnd <- filter(bnd, substr(PWSID, 1, 2) %in% states)

  # Some systems have several polygons; dissolve to one feature per system.
  bnd <- bnd |>
    st_make_valid() |>
    group_by(PWSID) |>
    summarize(.groups = "drop")

  bnd$area_km2 <- as.numeric(st_area(bnd)) / 1e6
  bnd
}

# ---- Main ---------------------------------------------------------------------------

estimate_inorganics <- function(states = NULL) {
  since <- seq(Sys.Date(), by = paste0("-", LOOKBACK_YEARS, " years"), length.out = 2)[2]
  paths <- download_sdwa()

  message("Reading water systems")
  systems <- read_water_systems(paths[1], states)
  message("  ", nrow(systems), " active community water systems")

  message("Summarizing lead and copper 90th percentiles since ", since)
  lcr <- summarize_lead_copper(paths[2], systems$PWSID, since)

  message("Summarizing IOC violations since ", since)
  ioc <- summarize_ioc_violations(paths[3], systems$PWSID, since)

  estimates <- systems |>
    left_join(lcr, by = "PWSID") |>
    left_join(ioc, by = "PWSID") |>
    mutate(
      across(c(starts_with("ioc_violations"), starts_with("ioc_health"),
               starts_with("hb_")),
             ~ coalesce(.x, 0L)),
      lead_exceeds_al = coalesce(lead_latest_90th > LEAD_ACTION_LEVEL, FALSE),
      copper_exceeds_al = coalesce(copper_latest_90th > COPPER_ACTION_LEVEL, FALSE)
    )

  message("Reading service area boundaries")
  boundaries <- read_boundaries(states = states)

  estimates <- estimates |>
    left_join(st_drop_geometry(boundaries), by = "PWSID") |>
    mutate(has_boundary = !is.na(area_km2))
  message("  ", sum(estimates$has_boundary), " of ", nrow(estimates),
          " systems matched to a boundary")

  dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
  csv_path <- file.path(OUT_DIR, "cws_inorganics.csv")
  gpkg_path <- file.path(OUT_DIR, "cws_inorganics.gpkg")
  write_csv(estimates, csv_path)
  boundaries |>
    select(PWSID) |>
    inner_join(select(estimates, -area_km2), by = "PWSID") |>
    st_write(gpkg_path, layer = "cws_inorganics", delete_dsn = TRUE, quiet = TRUE)
  message("Wrote ", csv_path, " and ", gpkg_path)

  invisible(estimates)
}

if (sys.nframe() == 0) {
  args <- str_to_upper(commandArgs(trailingOnly = TRUE))
  estimate_inorganics(states = if (length(args) > 0) args else NULL)
}
