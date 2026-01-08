# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

library(pdftools)
library(stringr)

# Define New York data directory
ny_dir_path <- here("data", "raw", "ny")

# PDF extract function 
extract_school_tables_fixed_width <- function(text_page) {
  lines <- strsplit(text_page, "\n")[[1]]
  
  # Find header line
  header_idx <- which(str_detect(lines, "District/School Name"))
  if(length(header_idx) == 0) return(list())
  
  # Find data lines (exclude headers, county names, page numbers)
  data_lines <- c()
  for(i in (header_idx[1] + 2):length(lines)) {
    line <- lines[i]
    if(nchar(str_trim(line)) > 20 && 
       !str_detect(line, "^[A-Z\\s]+COUNTY\\s*$") &&
       !str_detect(line, "^\\s*\\d+\\s*$") &&
       str_detect(line, "NY\\s+\\d{5}")) {
      data_lines <- c(data_lines, i)
    }
  }
  
  if(length(data_lines) == 0) return(list())
  
  # Parse each data line
  parsed_data <- list()
  current_county <- ""
  
  for(i in data_lines) {
    line <- lines[i]
    
    # Find current county
    county_lines_above <- which(str_detect(lines[1:i], "^[A-Z\\s]+COUNTY\\s*$|^[A-Z\\s]+CSD\\s*$"))
    if(length(county_lines_above) > 0) {
      current_county <- str_trim(lines[max(county_lines_above)])
    }
    
    # Extract phone number first (it's at the end)
    phone_match <- str_extract(line, "\\(\\d{3}\\)\\d{3}-\\d{4}")
    if(is.na(phone_match)) {
      phone_match <- str_extract(line, "\\d{3}-\\d{3}-\\d{4}")
    }
    
    # Extract NY and zip
    ny_zip_match <- str_extract(line, "NY\\s+(\\d{5})")
    zip_code <- str_extract(ny_zip_match, "\\d{5}")
    
    # Remove phone and NY zip from end to isolate the rest
    line_trimmed <- str_replace(line, "\\s+NY\\s+\\d{5}\\s+.*$", "")
    
    # Split remaining parts by multiple spaces
    parts <- str_trim(strsplit(line_trimmed, "\\s{3,}")[[1]])
    parts <- parts[parts != ""]
    
    if(length(parts) >= 4) {
      school_name <- parts[1]
      administrator <- parts[2]
      address <- parts[3]
      city <- parts[4]
      
      parsed_data[[length(parsed_data) + 1]] <- data.frame(
        County = current_county,
        District_School_Name = school_name,
        Administrator = administrator,
        Address = address,
        City = city,
        State = "NY",
        Zip_Code = zip_code,
        Telephone = phone_match,
        stringsAsFactors = FALSE
      )
    }
  }
  
  if(length(parsed_data) > 0) {
    result_df <- do.call(rbind, parsed_data)
    return(list(result_df))
  } else {
    return(list())
  }
}

# Extract tables and save them
files <- list.files(ny_dir_path, pattern = "*.pdf")

for(f in files) {
  print(f)
  file_path <- file.path(ny_dir_path, f)
  
  # Get number of pages
  pages <- pdf_info(file_path)$pages
  
  for(p in 1:pages) {
    print(paste("Processing page", p))
    
    # Extract text from specific page
    text_content <- pdf_text(file_path)[p]
    
    # Try the fixed-width parser first (usually works better for this format)
    table_list <- extract_school_tables_fixed_width(text_content)
    
    # Create output directory if it doesn't exist
    tables_dir <- file.path(ny_dir_path, "Tables_new")
    if(!dir.exists(tables_dir)) {
      dir.create(tables_dir, recursive = TRUE)
    }
    
    # Save extracted tables
    save(table_list, file = file.path(tables_dir, paste0(f, "_", p, "_tables.Rda")))
    
    if(length(table_list) > 0 && nrow(table_list[[1]]) > 0) {
      print(paste("Found", length(table_list), "table(s) with", nrow(table_list[[1]]), "rows"))
      print("First row of first table:")
      print(table_list[[1]][1,])
    } else {
      print(paste("No tables found on page", p))
    }
    
    gc()
    Sys.sleep(1)
  }
}
    
    
##############################################################################

ny_out <- data.frame()
for(f in files){
  print(f)
  pages <- pdf_info(file.path(ny_dir_path, f))$pages
  for(p in 1:pages){
    load(file.path(paste0(ny_dir_path,"/Tables_new"), paste0(f,"_",p,"_tables.Rda")))
    for(i in 1:length(table_list)){
      df <- data.frame(table_list[[i]])
      df$file <- f
      df$page <- p
      ny_out <- bind_rows(ny_out, df)
    }
    
    if(length(table_list)==0){
      print(paste0("No table on page ", p, " of ", pages))
    }
  }
}
##############################################################################

ny_clean <- ny_out %>% rename(dist_name = District_School_Name,
                              administrator = Administrator)
# Map district IDs to SEDs based on names
dist_map <- read_xlsx(file.path(ny_dir_path, "NY_District_Map.xlsx"))

ny_seds <- inner_join(ny_clean, dist_map) 

ny_seds$sed <- as.numeric(ny_seds$sed)

summary(as.factor(ny_seds$file))
summary(as.factor(ny_out$file))

#Import one file that was reported 
ny_2016 <- read_xlsx(file.path(ny_dir_path, "2016_12_02_SchoolDirectory.xlsx"))
ny_2016$administrator <- paste0(str_trim(ny_2016$`CEO FIRST NAME`), " ", str_trim(ny_2016$`CEO LAST NAME`))
ny_2016 <- ny_2016 %>% select(sed = `SED CODE`, 
                              dist_name = `LEGAL NAME`, 
                              administrator)
ny_2016$sed <- as.numeric(ny_2016$sed)
ny_2016$file <- "2016_12_02_SchoolDirectory.xlsx"

#Stack all data
all_ny <- bind_rows(ny_seds, ny_2016)

summary(as.factor(all_ny$file))

# drop schools from 2016 data (keep only school districts)
all_ny <- all_ny %>%
  group_by(sed) %>%
  filter(n() > 1) %>%
  ungroup()

#Add years
fileyears <- data.frame(year = 2010:2017, 
                        file = c("PubSchDir1011_101117.pdf", 
                                 "PubSchDir1112_101117.pdf", 
                                 "PubSchDir1213_101117.pdf", 
                                 "PubSchDir1314_101117.pdf", 
                                 "PubSchDir1415_101117.pdf", 
                                 "PubSchDir1516_101117.pdf", 
                                 "2016_12_02_SchoolDirectory.xlsx",
                                 "PubSchDir1718_101117.pdf"))

all_ny_years <- left_join(all_ny, fileyears, by = "file")

# clean district name 
all_ny_years <- all_ny_years %>%
  mutate(dist_name = str_replace_all(dist_name, "CENTRAL SCHOOL DISTRICT", "CSD")) %>%
  mutate(dist_name = str_replace_all(dist_name, "UNION FREE SCHOOL DISTRICT", "UFSD")) %>%
  mutate(dist_name = str_replace_all(dist_name, "HIGH SCHOOL", "HS")) %>%
  mutate(dist_name = str_replace_all(dist_name, "SCHOOL DISTRICT", "SD")) 


# # 
sed_name_check <- all_ny_years %>%
  group_by(sed) %>%
  summarise(
    unique_names = n_distinct(dist_name),
    name_list = paste(unique(dist_name), collapse = " | "),
    .groups = 'drop'
  ) %>%
  filter(unique_names > 1)

print(sed_name_check)
# # 

##############################################################################
# read and clean scraped data for 2018-2025

ny_scraped <- read_csv("data/raw/ny/ny_scraped_supers.csv")

ny_scraped_clean <- ny_scraped %>%
                    rename(dist_name = district_name,
                           administrator = superintendent,
                           file = snapshot_url) %>%
                    select(dist_name, administrator, file, year) %>%
  mutate(dist_name = str_replace_all(dist_name, "CENTRAL SCHOOL DISTRICT", "CSD")) %>%
  mutate(dist_name = str_replace_all(dist_name, "UNION FREE SCHOOL DISTRICT", "UFSD")) %>%
  mutate(dist_name = str_replace_all(dist_name, "HIGH SCHOOL", "HS")) %>%
  mutate(dist_name = str_replace_all(dist_name, "SCHOOL DISTRICT", "SD")) 


# append new years 
all_ny_years_full <- bind_rows(all_ny_years, ny_scraped_clean)

summary(as.factor(ny_scraped_clean$year))
summary(is.na(all_ny_years$sed))
summary(is.na(all_ny_years_full$sed))

# carryforward SED to new years by district name 
all_ny_years_full <- all_ny_years_full %>%
  arrange(dist_name, year) %>%  # Sort by dist_name and year (or other relevant order)
  group_by(dist_name) %>%
  fill(sed, .direction = "down") %>%  # Fill down missing values
  ungroup()

# manual fill 
all_ny_years_full <- all_ny_years_full %>%
  mutate(sed = case_when(
    dist_name == "BOQUET VALLEY CSD" ~ 151801040000,
    dist_name == "GATES CHILI CSD" ~ 260401060000,
    dist_name == "OTSELIC VALLEY CSD" ~ 081401040000,
    dist_name == "ST JOHNSVILLE CSD" ~ 271201040000,
    dist_name == "NYC SPEC SCHOOLS - DIST 75" ~ 307500010000,
    TRUE ~ sed  # Keep existing values for all other cases
  ))

# fix 2017 year duplicate issue 
all_ny_years_full <- all_ny_years_full %>% 
  mutate(year = if_else(file == "PubSchDir1718_101117.pdf", 2018, year))

all_ny_years_full <- all_ny_years_full %>% 
  filter(!(year == 2018 & file != "PubSchDir1718_101117.pdf"))

summary(as.factor(all_ny_years_full$year))

# fix name trimming issue from scraped years 

# drop interim tag 
all_ny_years_full <- all_ny_years_full %>%
  mutate(administrator = str_remove(administrator, "^ERIM "))

# Step 1: Create the prev_administrator column
all_ny_years_full <- all_ny_years_full %>%
  arrange(sed, year) %>%
  group_by(sed) %>%
  mutate(prev_administrator = lag(administrator)) %>%
  ungroup()

# Step 2: Apply the logic iteratively using a loop or a more elegant approach
all_ny_years_full <- all_ny_years_full %>%
  arrange(sed, year) %>%
  group_by(sed) %>%
  mutate(administrator = {
    admin_vec <- administrator
    for(i in 2:length(admin_vec)) {
      if(!is.na(admin_vec[i-1]) && 
         str_detect(str_to_lower(admin_vec[i-1]), str_to_lower(admin_vec[i]))) {
        admin_vec[i] <- admin_vec[i-1]
      }
    }
    admin_vec
  }) %>%
  ungroup() %>%
  select(-prev_administrator)

summary(is.na(all_ny_years_full$sed))

##############################################################################
# ex. str_detect(str_to_lower("DAD"), str_to_lower("aD"))

# Map district IDs to LEAIDs
# Initialize an empty data frame
ny_distids <- data.frame()
years <- 2009:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "New York") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid))
  
  ny_distids <- bind_rows(ny_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

ny_distids$state_leaid_n <- as.numeric(str_remove_all(ny_distids$state_leaid, "NY-"))

ny_distids <- ny_distids %>% filter(is.na(state_leaid_n)==0)

##
all_ny_lea <- inner_join(all_ny_years_full, ny_distids, by = c("sed" = "state_leaid_n", "year"))

# Check unmatched
unmatched <- anti_join(all_ny_years_full, ny_distids, by = c("sed" = "state_leaid_n", "year"))
table(unmatched$year)

all_ny_lea$name_raw <- all_ny_lea$administrator
all_ny_lea$name_clean <- clean_names(all_ny_lea$name_raw)
all_ny_lea$state <- "NY"
all_ny_lea <- all_ny_lea %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
all_ny_lea <- all_ny_lea %>% arrange(leaid, year)
all_ny_lea$id <- paste0("ny",str_pad(1:nrow(all_ny_lea), width = 5, side = "left", pad = "0"))
all_ny_lea <- all_ny_lea %>% rename(charter = agency_charter_indicator)

#Create table with names, district IDs, and years
all_supers <- all_ny_lea %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)
summary(as.factor(all_supers$year))

# drop missing 
all_supers <- all_supers %>% filter(!is.na(name_clean)) %>%
  filter(name_clean!="")

# drop duplicate year leaids 
all_supers <- all_supers %>% filter(id!="ny03970") %>%
                              filter(id!="n0y3972")


# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_ny.Rda"))

# data checks
data_checks(all_supers)
