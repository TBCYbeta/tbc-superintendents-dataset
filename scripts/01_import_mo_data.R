# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Missouri data directory
mo_dir_path <- here("data", "raw", "mo")

mo_raw <- read_xlsx(file.path(mo_dir_path,"Superintendent Salaries.xlsx"))
summary(as.factor(mo_raw$YEAR))

# mo_raw_og <- read_xlsx(file.path(mo_dir_path,"MO_Superintendents.xlsx"))
# summary(as.factor(mo_raw$year))

# modify mo_raw to adhere to previous dataset variable names
mo_raw <- mo_raw %>%
  rename(year = YEAR) %>%
  rename(dist_name = NAME) %>%
  rename(salary = SALARY) %>%
  rename(dist_code_num = COUNTY_DISTRICT_CODE) %>%  # First rename
  mutate(dist_code_num = as.numeric(dist_code_num)) %>%  # Then convert to numeric
  mutate(administrator = paste(FIRST_NAME, LAST_NAME)) %>%
  mutate(salary = salary/FTE)


summary(as.factor(mo_raw$FTE))
#In cases with >1 superintendent per district per year, take the observation with the highest salary
mo_raw <- mo_raw %>% group_by(year, dist_code_num) %>%
  mutate(rank_sal = rank(-salary)) %>%
  filter(rank_sal == 1) %>%
  select(-rank_sal)

summary(as.factor(mo_raw$FTE))

# Map district IDs to LEAIDs
# Initialize an empty data frame
mo_distids <- data.frame()
years <- 2003:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Missouri") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = if(is.character(leaid)) parse_number(leaid) else as.numeric(leaid))
  
  mo_distids <- bind_rows(mo_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

mo_distids$state_leaid_clean <- str_remove_all(str_remove_all(mo_distids$state_leaid, "MO"),"-")
mo_distids$state_leaid_clean <- as.numeric(mo_distids$state_leaid_clean)

mo_lea <- left_join(mo_raw, mo_distids, by = c("dist_code_num"="state_leaid_clean","year"))

mo_clean <- mo_lea %>% select(dist_name, leaid, year, administrator, salary, agency_charter_indicator)


mo_clean$name_raw <- mo_clean$administrator
mo_clean$name_interm <- mo_clean$administrator
suffixes_to_remove <- paste0(c("Mrs","Ms","Dr","Mr","Miss"),".")
for(s in suffixes_to_remove){
  print(s)
  mo_clean$name_interm <- ifelse(endsWith(mo_clean$name_interm, s), 
                                 str_sub(mo_clean$name_interm, 1, nchar(mo_clean$name_interm) - nchar(s) - 1), 
                                 mo_clean$name_interm)
}

mo_clean$name_clean <- clean_names(mo_clean$name_interm)
mo_clean$state <- "MO"
mo_clean <- mo_clean %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
mo_clean <- mo_clean %>% arrange(leaid, year)
mo_clean$id <- paste0("mo",str_pad(1:nrow(mo_clean), width = 5, side = "left", pad = "0"))
mo_clean <- mo_clean %>% rename(charter = agency_charter_indicator)


#Create table with names, district IDs, and years
all_supers <- mo_clean %>% 
              ungroup() %>%
              select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, leaid, salary, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# drop NA rows 
all_supers <- all_supers %>% filter(!is.na(leaid))

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_mo.Rda"))

# data checks
data_checks(all_supers)
