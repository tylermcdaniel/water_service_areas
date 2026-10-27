# water_service_areas
This repo contains code to produce inorganic materials estimates for community water systems (CWS) in the United States.

## What it does

`R/estimate_inorganics.R` builds a per-system table of inorganic contaminant indicators for every active CWS:

- **Lead and copper**: number of 90th percentile results, the latest and maximum values (mg/L), how many results exceeded the action level (lead 0.015 mg/L, copper 1.3 mg/L), and the trend in mg/L per year (`*_trend_per_year`, a least-squares slope; needs results on at least 3 dates).
- **Inorganic chemicals (IOCs)**: number of violations and health-based violations for arsenic, nitrate/nitrite, fluoride, barium and the other regulated IOCs, with one count column per contaminant (`hb_*`).
- **Service area**: each system's area (km²) and whether it matched a boundary polygon.

Only samples and violations from the last 10 years are used. To look further back, set `WSA_LOOKBACK_YEARS`, e.g. `WSA_LOOKBACK_YEARS=30 Rscript R/estimate_inorganics.R`.

### Changes over time

`output/cws_inorganics_by_year.csv` has one row per system per calendar year, covering every year in the lookback window:

- `lead_*` / `copper_*`: number of 90th percentile results, the highest result, and action level exceedances that year. These are blank (NA) in years the system didn't report, which is common because many systems only sample every three years, so a blank year means "no data", not "no lead".
- `ioc_violations` / `ioc_health_violations`: violations that began that year (0 if none).

Things to keep in mind when comparing years:

- Only systems that are active today are included, so systems that closed or merged drop out of earlier years.
- Rules change over time. For example, the arsenic limit dropped from 0.05 to 0.01 mg/L in 2006, so violation counts aren't comparable across that change.
- The boundary layer is a single snapshot, so service areas don't change across years.

## Data

| Source | How it's obtained |
|---|---|
| [ECHO SDWA bulk download](https://echo.epa.gov/tools/data-downloads) (SDWIS): water systems, LCR samples, violations | Downloaded automatically to `data/raw/` |
| EPA's Community Water System Service Area Boundaries | Download it yourself and save it as `data/raw/cws_boundaries.gpkg`, or set `WSA_BOUNDARIES` to a local file or `WSA_BOUNDARY_URL` to a download link. Any format `sf` can read works, as long as it has a PWSID column. |

## Usage

Install the packages: `install.packages(c("dplyr", "readr", "sf", "tidyr", "stringr"))`

Then run the script from the repo root:

```sh
Rscript R/estimate_inorganics.R           # all states
Rscript R/estimate_inorganics.R CA NV     # selected states
```

Outputs are written to `output/`:

- `cws_inorganics.csv`: one row per system, including systems without a boundary.
- `cws_inorganics_by_year.csv`: one row per system per year (see above).
- `cws_inorganics.gpkg`: the same data joined to the service area polygons.
