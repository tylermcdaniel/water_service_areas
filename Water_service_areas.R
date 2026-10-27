########################################################
## created: 8/28/2026  
## author: tyler mcdaniel
## purpose: load and clean water service area files
## last modified: 10/16/2026
########################################################


library(ncdf4)
library(sf)
library(tidycensus)
library(magrittr)
library(readr)
library(dplyr)
library(purrr)
library(readxl)
library(dataRetrieval)
library(jsonlite)
library(arcgislayers)
library(haven)
library(ggplot2)
library(stringr)

setwd("/Users/tylermcdaniel/Library/CloudStorage/GoogleDrive-tylermc@stanford.edu/My Drive/ARPA-H/")


# water service areas
#wsa <- st_read("Test_data_files/WSA_v1/WSA_v1.shp")

service_areas <- st_read("Test_data_files/Water_quality/3_0/Service_Areas_V_3_0.gpkg")

missing_cws <- read_csv("Test_data_files/Water_quality/3_0/Missing_CWS_V_3_0.csv")


blocks <- read_csv("Test_data_files/Water_quality/3_0/Census_Tables/Blocks_V_3_0.csv")

# map water service areas
#ggplot(service_areas)+
#  geom_sf()


# clean missing cws data
missing_cws_clean <- missing_cws %>%
  select(-`...1`) %>%
  rename("pwsid" = "PWS ID",
         "pws_name" = "PWS Name",
         "primacy_agency" = "Primacy Agency",
         "pop_served_count" = "Population Served Count",
         "service_connections_count" = "Service Connections Count")


# clean service areas data
service_areas_clean <- service_areas %>%
  rename("orig_data_provider" = "Original_Data_Provider",
         "data_provider" = "Data_Provider_Type",
         "data_source" = "Data_Source",
         "pwsid" = "PWSID",
         "pws_name" = "PWS_Name",
         "primacy_agency" = "Primacy_Agency",
         "pop_cat_5" = "Pop_Cat_5",
         "pop_served_count" = "Population_Served_Count",
         "service_connections_count" = "Service_Connections_Count",
         "model_method" = "Model_Method",
         "service_area_type" = "Service_Area_Type",
         "symbology_field" = "Symbology_Field",
         "modification_method" = "Modification_Method",
         "method_details" = "Method_Details",
         "verification_status" = "Verification_Status",
         "detailed_facility_report" = "Detailed_Facility_Report",
         "confirmed" = "Confirmed",
         "pwsid1" = "PWSID_1",
         "shape_length" = "Shape_Length",
         "shape_area" = "Shape_Area",
         "date_create" = "Date_Create",
         "geometry" = "geom")

# remove unneeded cols
service_areas_clean %<>%
  select(-pwsid1)


# join missing and non-missing pws data
pws_df <- full_join(service_areas_clean, 
                    missing_cws_clean)



# how many wsids are linked to information on inorganic contaminants?

# join with anne nigra's data
ravali_2021 <- read_xlsx("Test_data_files/Water_quality/Ravalli_2021_datasets_and_codebook.xlsx",
                         sheet = "CWSLevel")

# clean to match other datasets
ravali_2021 %<>%
  rename_with(~ str_replace_all(tolower(.), "\\.", "_"))


# join with water data
pws_df %<>%
  left_join(ravali_2021)


# how many are missing?
table(is.na(pws_df$asavg20082011)) # arsenic data for 33,267 water systems

# how much population does this cover?
sum(pws_df$adjusted_total_population_served[!is.na(pws_df$asavg20062011)], na.rm = T) # arsenic data for roughly 258674721 people 

# what pct of total population is represented by boundary data?

# what pct of total population is represented by boundary and inorganic contaminants data?







