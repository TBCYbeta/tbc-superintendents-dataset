# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define NC data directory
nc_dir_path <- here("data", "raw", "nc")

# Import nc raw data
xlsx_files <- list.files(nc_dir_path, pattern = "^NC\\s\\d{4}-\\d{2}\\.xlsx$", full.names = TRUE)
csv_file   <- file.path(nc_dir_path, "NC 2022-23.csv")
read_nc_xlsx <- function(path) {
  year <- str_extract(basename(path), "\\d{4}") %>% as.numeric()
  read_xlsx(path, .name_repair = "minimal") %>%
    select(1:2) %>%                                 # keep first two columns
    setNames(c("dist_name", "full_name")) %>%       # rename
    mutate(year = year)
}

nc_2009_2021 <- map_dfr(xlsx_files, read_nc_xlsx)
nc_2022 <- read_csv(csv_file, show_col_types = FALSE) %>%
  select(
    dist_name = `Name ---------------------------------------------`,
    full_name = `Superintendent -------------------`
  ) %>%
  mutate(year = 2022)
nc_raw <- bind_rows(nc_2009_2021, nc_2022) %>%
  mutate(state = "NC")

nc_nces <- read_csv(file.path(dist_chars_path, "ccd_lea_029_2324_w_1a_073124.csv")) %>% select(LEAID, LEA_NAME, ST)
nc_nces <- nc_nces[nc_nces$ST=="NC",]
names(nc_nces) <- tolower(names(nc_nces))
nc_nces <- nc_nces %>% rename(dist_name = lea_name)
nc_raw <- left_join(nc_raw, nc_nces, by = "dist_name")
nc_raw$leaid <- as.numeric(nc_raw$leaid)

# Manually fix unrecognized LEAIDs
nc_raw <- nc_raw %>%
  mutate(leaid = case_when(
    dist_name == "Craven County Schools" ~ 3703310,
    dist_name %in% c("DPS Education Services (fka Div Prisons)", "DAC Education Services (fka Div Prisons)") ~ 3700167,
    dist_name %in% c("Edgecomb County Public Schools", "Edgecombe County Public Schools") ~ 3701320,
    dist_name %in% c("Nash County Public School", "Nash County Public Schools") ~ 3703270,
    dist_name %in% c("New Hanover County School", "New Hanover County Schools") ~ 3703330,
    dist_name %in% c("Robeson County Public Schools", "Public Schools of Robeson County") ~ 3703930,
    dist_name %in% c("Winston Salem/Forsyth County Schools", "Winston Salem / Forsyth County Schools", "Winston-Salem/Forsyth County Schools") ~ 3701500,
    dist_name %in% c("Governor's Teacher Network","Governorís Teacher Network") ~ 3700000,
    dist_name == "NC Virtual Public School" ~ 3700998,
    dist_name == "Innovative School District" ~ 3700999,
    dist_name == "Northeast Regional School - Biotech/Agri" ~ 3700338,
    TRUE ~ leaid
  ))


#write.csv(nc_raw, "nc_raw.csv")

# Drop Deaf and Blind Schools (3700320) missing superintendent in 2022
nc_raw <- nc_raw %>%
  filter(!(dist_name == "Deaf and Blind Schools" & year == 2022))

nc_distids <- data.frame()
years <- 2009:2022

# Loop through years to load and process data
for(y in years){
  print(y)

  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "North Carolina") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = if(is.character(leaid)) {
             parse_number(leaid)
           } else {
             as.numeric(leaid)  # If already numeric, just ensure it's numeric
           }, 
           state_leaid_n = as.numeric(str_remove_all(state_leaid, "NC-")))
  
  nc_distids <- bind_rows(nc_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Merge with `nc_raw`
nc_lea <- left_join(nc_raw, nc_distids, by = c("leaid","year"))
nc_lea <- nc_lea %>% rename(charter = agency_charter_indicator)


# Add state and ID fields
nc_lea <- nc_lea %>% distinct(leaid, year, full_name, .keep_all = TRUE)
nc_lea <- nc_lea %>% arrange(leaid, year)
nc_lea <- nc_lea %>%
  mutate(state = "NC",
         id = paste0("nc", str_pad(1:nrow(nc_lea), width = 5, side = "left", pad = "0")),
         name_raw = full_name,
         name_clean = clean_names(name_raw))

# Create table with relevant columns
all_supers <- nc_lea %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_nc.Rda"))

# data checks 
data_checks(all_supers)
