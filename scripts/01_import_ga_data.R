# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Georgia data directory
ga_dir_path <- here("data", "raw", "ga")


########################################################
# Part I: Create dataframe 1999-2022 (without salary)
########################################################

# Import Georgia raw data 

ga_files <- list.files(
  path = ga_dir_path,
  pattern = "^cpi\\d{4}-1_superintendent-detail-roster\\.xlsx$",
  full.names = TRUE
)

read_ga_file <- function(file_path) {
  year <- str_extract(basename(file_path), "\\d{4}") %>% as.numeric()
  df <- read_xlsx(file_path, skip = 4)
  if (year < 2010) {
    df <- df %>%
      select(
        year       = FISCAL_YEAR,
        dist_name  = SYSTEM_NAME,
        full_name  = FULL_NAME
      )
  } else {
    df <- df %>%
      select(
        year       = FISCAL_YEAR,
        dist_name  = SYSTEM_NAME,
        first_name = FIRST_NAME,
        last_name  = LAST_NAME
      ) %>%
      mutate(full_name = paste(first_name, last_name, sep = " ")) %>%
      select(year, dist_name, full_name)
  }
  df <- df %>%
    mutate(year = ifelse(is.na(year), year, year))
  return(df)
}

ga_raw <- map_dfr(ga_files, read_ga_file)
ga_raw$year <- as.numeric(ga_raw$year)
ga_raw$year <- ga_raw$year - 1 # adjust fiscal year to fall year

ga_nces <- read_csv(file.path(dist_chars_path, "ccd_lea_029_2324_w_1a_073124.csv")) %>% select(LEAID, LEA_NAME, ST)
ga_nces <- ga_nces[ga_nces$ST=="GA",]
names(ga_nces) <- tolower(names(ga_nces))
ga_nces <- ga_nces %>% rename(dist_name = lea_name)
ga_raw <- left_join(ga_raw, ga_nces, by = "dist_name")
ga_raw$leaid <- as.numeric(ga_raw$leaid)

# Manually fix unrecognized LEAIDs
ga_raw <- ga_raw %>%
  mutate(dist_name = str_remove_all(dist_name, "^State Charter Schools- |^State Charter Schools II- |^Commission Charter Schools- |^State Schools- "))
ga_raw <- ga_raw %>%
  mutate(leaid = case_when(
    dist_name == "Chatham County" ~ 1301020,
    dist_name == "Spalding County" ~ 1302520,
    dist_name == "Dalton City" ~ 1301620,
    dist_name == "Decatur City" ~ 1301680,
    dist_name == "Atlanta City" ~ 1300120,
    dist_name == "CCAT" ~ 1300005,
    dist_name == "Odyssey" ~ 1300023,
    dist_name == "KidsPeace" ~ 1300840,
    dist_name == "Mountain Education Center" ~ 1300214,
    dist_name == "Ivy Prep" ~ 1300226,
    dist_name == "Scholars Academy" ~ 1301230,
    dist_name == "Mountain Education Center School" ~ 1300214,
    dist_name == "Odyssey School" ~ 1300023,
    dist_name == "Scholars Academy School" ~ 1301230,
    dist_name == "CCAT School" ~ 1300005,
    dist_name == "Ivy Preparatory Academy School" ~ 1300226,
    dist_name == "Scholars Academy Charter School" ~ 1301230,
    dist_name == "Peachtree Hope Charter School" ~ 1300219,
    dist_name == "Pataula Charter Academy" ~ 1300218,
    dist_name == "Fulton Leadership Academy" ~ 1300217,
    dist_name == "Atlanta Heights Charter School" ~ 1300221,
    dist_name == "Museum School Avondale Estates" ~ 1301740,
    dist_name == "Coweta Charter Academy" ~ 1300222,
    dist_name == "Cherokee Charter Academy" ~ 1300230,
    dist_name == "Heritage Preparatory Academy School" ~ 1300228,
    dist_name == "Georgia Connections Academy" ~ 1300227,
    dist_name == "Ivy Preparatory Young Men's Leadership Academy School" ~ 1300226,
    dist_name == "Ivy Prep Academy at Kirkwood for Girls School" ~ 1300226,
    dist_name == "Provost Academy Georgia" ~ 1300231,
    dist_name == "Atlanta Area School for the Deaf" ~ 1300254,
    dist_name == "Georgia Academy for the Blind" ~ 1300254,
    dist_name == "Georgia School for the Deaf" ~ 1300254,
    dist_name == "Mountain Education Charter High School" ~ 1300214,
    dist_name == "Georgia Cyber Academy" ~ 1300232,
    dist_name == "Utopian Academy for the Arts Charter School" ~ 1300233,
    dist_name == "Graduation Achievement Center Charter High School" ~ 1300231, #note renamed from Provost Academy Georgia
    dist_name == "Ivy Preparatory Young Men's Leadership Academy, Inc." ~ 1300226,
    dist_name == "Ivy Preparatory Academy, Inc" ~ 1300226,
    dist_name == "Foothills Charter High School" ~ 1300235,
    dist_name == "International Charter School of Atlanta" ~ 1300234,
    dist_name == "Scintilla Charter Academy" ~ 1300236,
    dist_name == "Georgia School for Innovation and the Classics" ~ 1300238,
    dist_name == "Dubois Integrity Academy I" ~ 1300237,
    dist_name == "Ivy Preparatory Academy At Gwinnett, Inc." ~ 1300226,
    dist_name == "Dubois Integrity Academy" ~ 1300237,
    dist_name == "Statesboro STEAM Academy" ~ 1300005,
    dist_name == "Cirrus Charter Academy" ~ 1300239,
    dist_name == "Southwest Georgia S.T.E.M. Charter Academy" ~ 1300243,
    dist_name == "Brookhaven Innovation Academy" ~ 1300242,
    dist_name == "Liberty Tech Charter Academy" ~ 1300241,
    dist_name == "Odyssey Charter School" ~ 1300023,
    dist_name == "Foothills Charter High School (Central Office - Madison)" ~ 1300235,
    dist_name == "Coastal Plains Charter High School - Candler Campus" ~ 1300246,
    dist_name == "Ivy Preparatory Academy At Gwinnett" ~ 1300226,
    dist_name == "Genesis Innovation Academy for Boys" ~ 1300248,
    dist_name == "Genesis Innovation Academy for Girls" ~ 1300244,
    dist_name == "Resurgence Hall Charter School" ~ 1300247,
    dist_name == "SAIL Charter Academy - School for Arts-Infused Learning" ~ 1300245,
    dist_name == "International Academy of Smyrna" ~ 1300249,
    dist_name == "International Charter Academy of Georgia" ~ 1300250,
    dist_name == "SLAM Academy of Atlanta" ~ 1300251,
    dist_name == "Foothills Charter High School (Central Office - Athens)" ~ 1300235,
    dist_name == "Academy For Classical Education" ~ 1300252,
    dist_name == "Spring Creek Charter Academy" ~ 1300253,
    dist_name == "Ethos Classical Charter School" ~ 1300255,
    dist_name == "Baconton Community Charter School" ~ 1300256,
    dist_name == "Yi Hwang Academy of Language Excellence" ~ 1300257,
    dist_name == "Furlow Charter School" ~ 1300258,
    dist_name == "Harriet Tubman School of Science & Technology" ~ 1300260,
    dist_name == "Atlanta Unbound Academy" ~ 1300261,
    dist_name == "D.E.L.T.A. STEAM Academy" ~ 1300262,
    dist_name == "Georgia Fugees Academy Charter School" ~ 1300263,
    dist_name == "Atlanta SMART Academy" ~ 1300259,
    dist_name == "Northwest Classical Academy" ~ 1300264,
    dist_name == "Coastal Plains Charter High School" ~ 1300246,
    dist_name == "DeKalb Brilliance Academy" ~ 1305851,
    dist_name == "Resurgence Hall Middle Academy" ~ 1305852,
    dist_name == "Amana Academy West Atlanta" ~ 1300265,
    TRUE ~ leaid
  ))

#write.csv(ga_raw, "ga_raw.csv")
ga_raw$st <- "GA"

ga_distids <- data.frame()
years <- 2000:2022


# Loop through years to load and process data
for(y in years){
  print(y)
 
# Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
# Process the data
temp <- df %>% 
    filter(fips == "Georgia") %>% 
   select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
   mutate(leaid = if(is.character(leaid)) {
     parse_number(leaid)
} else {
      as.numeric(leaid)  # If already numeric, just ensure it's numeric
    }, 
   state_leaid_n = as.numeric(str_remove_all(state_leaid, "GA-")))
  
  ga_distids <- bind_rows(ga_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Merge with `ga_raw`
ga_lea <- left_join(ga_raw, ga_distids, by = c("leaid","year"))

ga_lea <- ga_raw

# Add state and ID fields
ga_lea <- ga_lea %>%
  mutate(state = "GA",
         id = paste0("ga", 1:nrow(ga_lea)),
         name_raw = full_name,
         name_clean = clean_names(name_raw))

# Create table with relevant columns
all_supers <- ga_lea %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)



# Remove duplicates by comparing previous and subsequent years and inferring who was there first/primarily
all_supers <- all_supers %>%
  distinct(leaid, name_clean, year,.keep_all = TRUE)
all_supers$drop <- 0
all_supers$drop <- ifelse(all_supers$leaid == 1304590 & all_supers$name_clean == "bettye ray" & all_supers$year==1999, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301500 & all_supers$name_clean == "jennifer roth" & all_supers$year==2000, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1302190 & all_supers$name_clean == "kelly henson" & all_supers$year==2001, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1303750 & all_supers$name_clean == "dale clark" & all_supers$year==2001, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300840 & all_supers$name_clean == "michael merritt" & all_supers$year==2004, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300840 & all_supers$name_clean == "patricia swint" & all_supers$year == 2005, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300840 & all_supers$name_clean == "patricia swint" & all_supers$year == 2006, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300090 & all_supers$name_clean == "lehman donnel spence" & all_supers$year == 2007, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300780 & all_supers$name_clean == "william hardin" & all_supers$year == 2007, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300840 & all_supers$name_clean == "patricia swint" & all_supers$year == 2007, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "elsa celestine" & all_supers$year == 2008, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1305310 & all_supers$name_clean == "william cason" & all_supers$year == 2008, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300210 & all_supers$name_clean == "geneva braziel" & all_supers$year == 2009, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "edmond heatley" & all_supers$year == 2009, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "carlotta blatch" & all_supers$year == 2011, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300254 & all_supers$name_clean == "kenneth moore" & all_supers$year == 2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "luvenia jackson" & all_supers$year == 2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300480 & all_supers$name_clean == "harry smith" & all_supers$year == 2013, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300226 & all_supers$name_clean == "alisha morgan" & all_supers$year == 2015, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300254 & all_supers$name_clean == "vanessa robisch" & all_supers$year == 2016, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300420 & all_supers$name_clean == "laura perkins" & all_supers$year == 2016, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300254 & all_supers$name_clean == "john serrano" & all_supers$year == 2017, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300001 & all_supers$name_clean == "roy nichols" & all_supers$year == 2018, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300246 & all_supers$name_clean == "david mccurry" & all_supers$year == 2019, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301740 & all_supers$name_clean == "maury wills" & all_supers$year == 2019, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301740 & all_supers$name_clean == "christi elliot earby" & all_supers$year == 2021, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1305460 & all_supers$name_clean == "christopher harris" & all_supers$year == 2021, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301740 & all_supers$name_clean == "vasanne tinsley" & all_supers$year == 2022, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300840 & all_supers$name_clean == "patricia swint" & all_supers$year==2008, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "edmond heatley" & all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301230 & all_supers$name_clean == "luvenia jackson" & all_supers$year==2013, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300254 & all_supers$name_clean == "kenneth moore" & all_supers$year==2018, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1301740 & all_supers$name_clean == "wanda brooks long" & all_supers$year==2022, 1, all_supers$drop)

# Confirmed by searching web
all_supers$drop <- ifelse(all_supers$leaid == 1301740 & all_supers$name_clean == "katherine kelbaugh" & all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1305220 & all_supers$name_clean == "carolyn faulk brown" & all_supers$year==2006, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid == 1300226 & all_supers$name_clean == "stacey foney" & all_supers$year==2015, 1, all_supers$drop)

all_supers <- all_supers %>% filter(drop==0) %>% select(-drop)
all_supers$state <- toupper(all_supers$state)

########################################################
# Part II: Create dataframe 2015-2023 (with salary; note 2023 new)
########################################################

ga_salary <- read_delim(
  file.path(ga_dir_path, "SalaryTravelDataExportAllYears.txt"), 
  delim = ",",
  quote = "'"  
)

## Append the data frames and remove duplicates
#ga_raw <- bind_rows(ga_raw1, ga_raw2) %>%
#  distinct()

ga_salary <- ga_salary %>% 
  select(name_raw = NAME, position_raw = TITLE, salary = SALARY, 
         year = FISCAL_YEAR, organization = ORGANIZATION) %>% 
  mutate(state = "GA")

# From: https://gbpi.org/georgia-revenue-primer-for-state-fiscal-year-2022/
# "Georgia's 2022 fiscal year runs from July 1, 2021 through June 30, 2022."
# So, fiscal years in my data (e.g. FY 2013) correspond to school year of the prior year (e.g. school year 2012)
ga_salary$year <- ga_salary$year - 1

ga_salary <- ga_salary %>% select(state, year, organization, name_raw, position_raw, salary)

# Restrict to superintendents
ga_salary <- ga_salary %>% filter(position_raw == "SUPERINTENDENT")

#In cases with >1 superintendent per district per year, take the observation with the highest salary
ga_salary <- ga_salary %>% group_by(year, organization) %>% 
  mutate(rank_sal = rank(-salary)) %>% 
  filter(rank_sal == 1) %>% 
  select(-rank_sal)

# Map district IDs to LEAIDs
# Initialize an empty data frame
ga_distids <- data.frame()
years <- 2009:2023

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Georgia") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(leaid))
  
  ga_distids <- bind_rows(ga_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

ga_distids$state_leaid_clean <- str_remove_all(str_remove_all(ga_distids$state_leaid, "GA"),"-")
ga_distids$state_leaid_clean <- as.numeric(ga_distids$state_leaid_clean)

ga_distids$dist_name <- tolower(ga_distids$nces_lea_name)
ga_distids$dist_name<- str_remove_all(ga_distids$dist_name, "state charter schools- ")
ga_distids$dist_name<- str_remove_all(ga_distids$dist_name, "commission charter schools- ")
ga_distids$dist_name <- ifelse(ga_distids$dist_name=="dalton public schools",
                               "dalton city", ga_distids$dist_name)

ga_salary$city <- ifelse(str_sub(ga_salary$organization, 1, 4)=="CITY",1,0)
ga_salary$dist_name <- str_remove_all(ga_salary$organization, " BOARD OF EDUCATION")
ga_salary$dist_name <- str_remove_all(ga_salary$dist_name, " SCHOOL DISTRICT")
ga_salary$dist_name <- str_remove_all(ga_salary$dist_name, "CITY OF ")
ga_salary$dist_name <- tolower(ga_salary$dist_name)
ga_salary$dist_name <- ifelse(ga_salary$city, 
                              paste0(ga_salary$dist_name, " city"), 
                              ga_salary$dist_name)
ga_salary$dist_name <- ifelse(ga_salary$dist_name=="atlanta independent school system", 
                              "atlanta public schools", ga_salary$dist_name)
ga_salary$dist_name <- ifelse(ga_salary$dist_name=="polk", 
                              "polk county", ga_salary$dist_name)
ga_salary$dist_name <- ifelse(ga_salary$dist_name=="thomaston - upson county", 
                              "thomaston-upson county", ga_salary$dist_name)

ga_salary <- left_join(ga_salary, ga_distids, by = c("dist_name","year"))

ga_salary$leaid <- ifelse(ga_salary$dist_name=="atlanta heights charter school",1300221,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="decatur city",1301680,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="griffin - spalding county",1302520,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="ivy prep academy at kirkwood for girls school",1300226,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="ivy preparatory young men's leadership academy school",1300229,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="mountain education center",1300214,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="provost academy of georgia",1300231,ga_salary$leaid)
ga_salary$leaid <- ifelse(ga_salary$dist_name=="savannah-chatham county",1301020,ga_salary$leaid)

# Clean names
ga_salary$name_clean <- clean_names(ga_salary$name_raw)

# Create table with names, district IDs, and years
ga_salary <- ga_salary %>% 
  filter(!is.na(leaid)) %>% 
  ungroup() %>% select(state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, salary, agency_charter_indicator)

ga_salary$leaid_name <- str_to_title(ga_salary$leaid_name)


########################################################
# Part III: Merge
########################################################

all_supers <- bind_rows(all_supers, ga_salary)
all_supers <- all_supers %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
all_supers <- all_supers %>% arrange(leaid, year)

# Deduplicate 2014-2022 by keeping observations with salary data available 
all_supers <- all_supers %>%
  mutate(leaid = as.integer(leaid),
         year  = as.integer(year)) %>%
  group_by(year, leaid) %>%
  arrange(is.na(salary), .by_group = TRUE) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  arrange(is.na(leaid), leaid, year)   

all_supers$id <- paste0("ga", str_pad(1:nrow(all_supers), width = 5, side = "left", pad = "0"))
all_supers <- all_supers %>% rename(charter = agency_charter_indicator)

# Clean names
all_supers$name_clean <- all_supers$name_clean %>%
  str_remove("\\s+jr\\b") %>%
  str_remove("\\s+sr\\b") %>%
  str_remove("\\s+iii\\b") %>%
  str_squish() %>%
  sapply(function(x) {
    parts <- unlist(str_split(x, " "))
    if (length(parts) > 2) paste(parts[c(1, length(parts))], collapse = " ")
    else x
  }) %>% as.character()

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_ga.Rda"))

# data checks 
data_checks(all_supers)


#duplicates <- all_supers %>%
#  group_by(year, leaid) %>%
#  filter(n() > 1) %>%
#  arrange(year, leaid)
write.csv(all_supers, "all_supers_ga.csv")
#write.csv(duplicates, "duplicates.csv")

