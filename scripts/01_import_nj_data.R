# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define New Jersey data directory
nj_dir_path <- here("data", "raw", "nj")

df_2011 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2012.01.15.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2011)
df_2012 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2012.11.06.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2012)
df_2013 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2013.06.29.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2013)
df_2014 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2014.12.25.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2014)
df_2015 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2015.11.13.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2015)
df_2016 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2016.11.16.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2016)
df_2017 <- read_delim(file = file.path(nj_dir_path,"NJPubSchoolDistricts_2017.09.10.csv"), 
                      delim=",", skip = 2) %>% mutate(year=2017)
df_2019 <- read_delim(file = file.path(nj_dir_path,"employees20.csv"), 
                      delim=",") %>% mutate(year=2019) %>% rename_all(tolower) %>% rename(district_id = emp_district_id)
df_2020 <- read_delim(file = file.path(nj_dir_path,"employees21.csv"), 
                      delim=",") %>% mutate(year=2020)  %>% rename_all(tolower)
df_2021 <- read_delim(file = file.path(nj_dir_path,"employees22.csv"), 
                      delim=",") %>% mutate(year=2021)  %>% rename_all(tolower)
df_2022 <- read_delim(file = file.path(nj_dir_path,"employees23.csv"), 
                      delim=",") %>% mutate(year=2022)  %>% rename_all(tolower)
df_2023 <- read_delim(file = file.path(nj_dir_path,"employees24.csv"), 
                      delim=",") %>% mutate(year=2023)  %>% rename_all(tolower)
df_2024 <- read_delim(file = file.path(nj_dir_path,"employees25_minus_1.csv"), 
                      delim=",") %>% mutate(year=2024)  %>% rename_all(tolower)

# keep if job title contains superintendent 
for (yr in 2019:2024) {
  assign(paste0("df_", yr), 
         get(paste0("df_", yr)) %>%
           filter(str_detect(tolower(emp_job_title), "superintendent")) %>%
           mutate(salary = as.numeric(gsub("[,$]", "", emp_base_salary)) / emp_fte) %>%
           mutate(dist_raw = paste0(county_id, district_id))
         )
}

# clean and combine years 
nj_raw <- bind_rows(mget(paste0("df_",2011:2017)))

nj_raw$dist_raw <- paste0(str_sub(nj_raw$`County Code`,3,4), 
                           str_sub(nj_raw$` District Code`,3,6))
nj_raw$administrator <- paste0(nj_raw$` Supt. First Name`, " ", nj_raw$` Supt. Last Name`)
nj_raw$administrator <- ifelse(nj_raw$administrator=="NA NA", NA, nj_raw$administrator)

nj_raw <- nj_raw %>% 
  rename(dist_name = ` District Name`, 
         administrator = administrator) %>% 
  select(year, dist_raw, dist_name, administrator) %>% 
  filter(is.na(administrator)==0)

# same as above but for newer years (2019-2024)
nj_raw2 <- bind_rows(mget(paste0("df_",2019:2024)))

nj_raw2 <- nj_raw2 %>%
              rename(administrator = emp_name) %>%
              filter(!str_detect(tolower(administrator), "share")) %>%
              filter(!str_detect(tolower(administrator), "n/a")) %>%
              filter(!(tolower(administrator)=="superintendent")) %>%
              filter(!(tolower(administrator)=="tbd")) %>%
              rename(dist_name = distname) %>%
              filter((tolower(emp_job_title)=="superintendent")) %>%
              mutate(salary = as.numeric(gsub("[,$]", "", emp_base_salary)) / emp_fte) %>%
              select(year, dist_raw, dist_name, administrator, salary, emp_job_title, emp_job_title_2)

# deal with duplicates by district year 
nj_raw2 <- nj_raw2 %>%
  group_by(dist_raw, year) %>%
  filter(
    # Step 1: If only one observation exists, keep it
    if (n() == 1) {
      TRUE
      # Step 2: Otherwise, order by salary and keep highest salary obs
    } else {
      salary == max(salary, na.rm = TRUE)
    }
  ) %>%
  ungroup() %>%
  select(year, dist_raw, dist_name, administrator, salary)
  

# combine two sets of years 
nj_raw <- bind_rows(nj_raw, nj_raw2)


# Map district IDs to LEAIDs
# Initialize an empty data frame
nj_distids <- data.frame()
years <- c(2011:2017, 2019:2024)

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "New Jersey") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(as.character(leaid)))
  
  nj_distids <- bind_rows(nj_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

nj_distids$state_leaid_clean <- str_remove_all(str_remove_all(nj_distids$state_leaid, "NJ-"),"-")

all_nj_lea <- inner_join(nj_raw, nj_distids, by = c("dist_raw" = "state_leaid_clean", "year"))

# Inspect unmatched districts
unmatched <- anti_join(nj_raw, nj_distids, by = c("dist_raw" = "state_leaid_clean", "year"))

all_nj_lea$state <- "NJ"
all_nj_lea <- all_nj_lea %>% distinct(leaid, year, administrator, .keep_all = TRUE)
all_nj_lea <- all_nj_lea %>% arrange(leaid, year)
all_nj_lea$id <- paste0("nj",str_pad(1:nrow(all_nj_lea), width = 5, side = "left", pad = "0"))
all_nj_lea$name_raw <- all_nj_lea$administrator
all_nj_lea$name_clean <- clean_names(all_nj_lea$name_raw)
all_nj_lea <- all_nj_lea %>% rename(charter = agency_charter_indicator)

#Create table with names, district IDs, and years
all_supers <- all_nj_lea %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

summary(as.factor(all_supers$year))

# drop vacant names 
all_supers <- all_supers %>%
              filter(name_clean!="vacancy") %>%
              filter(name_clean!="vacant") %>%
              filter(name_clean!="interim") %>%
              filter(name_clean!="abc abc") %>%
              filter(name_clean!="none non op district") %>%
              filter(name_clean!="none none")  %>%
              filter(name_clean!="non op non op")  %>%
              filter(name_clean!="not applicable non operating")
  

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_nj.Rda"))

# data checks
data_checks(all_supers)
