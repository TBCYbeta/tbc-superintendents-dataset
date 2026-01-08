# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Virginia data directory
va_dir_path <- here("data", "raw", "va")

va_combined <- data.frame()
for(y in 2010:2025){
  print(y)
  df <- read_xlsx(file.path(va_dir_path,"VA_Superintendents.xlsx"), sheet = as.character(y))
  colnames(df) <- c("division","name","add","ph", "date")
  df <- df[, !names(df) %in% "date"]
  df <- df[, !names(df) %in% "add"]
  df$year <- y
  va_combined <- bind_rows(va_combined, df)
}

# Map district IDs to LEAIDs
# Initialize an empty data frame
va_distids <- data.frame()
years <- 2010:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Virginia") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid))
  
  va_distids <- bind_rows(va_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

va_distids$state_leaid_clean <- str_remove_all(str_remove_all(va_distids$state_leaid, "VA"),"-")
va_distids$state_leaid_clean <- as.numeric(va_distids$state_leaid_clean)
va_distids$nces_lea_name_clean <- str_remove_all(va_distids$nces_lea_name, "CITY PBLC SCHS")
va_distids$nces_lea_name_clean <- str_remove_all(va_distids$nces_lea_name_clean, "CTY PBLC SCHS")
va_distids$nces_lea_name_clean <- str_replace_all(va_distids$nces_lea_name_clean, "CO PBLC SCHS", "COUNTY")
va_distids$nces_lea_name_clean <- str_remove_all(va_distids$nces_lea_name_clean, "PBLC SCHS")
va_distids$nces_lea_name_clean <- str_replace_all(va_distids$nces_lea_name_clean, "KING GEO", "KING GEORGE")
va_distids$nces_lea_name_clean <- str_replace_all(va_distids$nces_lea_name_clean, "VA BEACH", "VIRGINIA BEACH")
va_distids$nces_lea_name_clean <- str_replace_all(va_distids$nces_lea_name_clean, "WILLIAMSBURG-JAMES", "WILLIAMSBURG-JAMES CITY COUNTY")

va_combined$name_lower <- str_trim(tolower(va_combined$division))
va_distids$name_lower <- str_trim(tolower(va_distids$nces_lea_name_clean))

summary(as.factor(va_distids$year))

# standardize dist name for later years 
va_distids <- va_distids %>%
  group_by(leaid) %>%
  mutate(
    name_lower = ifelse(year >= 2022, 
                        name_lower[year == 2021][1], 
                        name_lower)
  ) %>%
  ungroup()

va_clean <- inner_join(va_combined, va_distids, by = c("name_lower","year"))

table(is.na(va_clean$leaid))

va_clean$state <- "VA"
va_clean <- va_clean %>% distinct(leaid, year, name_lower, .keep_all = TRUE)
va_clean <- va_clean %>% arrange(leaid, year)
va_clean$id <- paste0("va", str_pad(1:nrow(va_clean), width = 5, side = "left", pad = "0"))

va_clean$name_raw <- va_clean$name
va_clean$name_clean <- str_to_title(clean_names(va_clean$name_raw))
va_clean <- va_clean %>% rename(charter = agency_charter_indicator)


# Create table with names, district IDs, and years
all_supers <- va_clean %>% filter(name_raw!="Position Vacant", 
                                  name_raw!="Superintendent", 
                                  is.na(leaid)==0) %>% 
  select(id, state, leaid, leaid_name = nces_lea_name_clean, name_raw, name_clean, year, leaid, charter) %>% ungroup()
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# drop missing 
all_supers <- all_supers %>% filter(!is.na(name_clean)) %>%
  filter(name_clean!="")

write.csv(all_supers, "allsupersva.csv")

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_va.Rda"))

# data checks
data_checks(all_supers)

