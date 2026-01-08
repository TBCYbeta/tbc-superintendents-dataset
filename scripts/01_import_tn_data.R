# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define data directory
tn_dir_path <- here("data", "raw", "tn")
files <- list.files(tn_dir_path, pattern = "\\.xlsx$", full.names = TRUE)
files <- files[!grepl("^~\\$", basename(files))]
files <- files[file.info(files)$size > 0]

yrs <- str_extract(basename(files), "\\d{4}")
o <- order(as.integer(yrs))
files <- files[o]
yrs <- yrs[o]
objs <- paste0("tn_", yrs)

#lst <- lapply(files, function(x) read_xlsx(x, skip = 2, col_names = TRUE))
lst <- mapply(function(x, y) {
  if (y %in% as.character(2012:2020)) read_xlsx(x, col_names = TRUE)
  else read_xlsx(x, skip = 2, col_names = TRUE)
}, files, yrs, SIMPLIFY = FALSE)

tn_raw <- bind_rows(lst, .id = "source")
tn_raw$year <- str_extract(tn_raw$source, "\\d{4}")
tn_raw <- tn_raw %>% select(-source)
tn_raw$District <- str_to_title(tn_raw$District)
tn_raw$District <- str_trim(str_replace_all(tn_raw$District, "[^[:alnum:]\\s]+$", ""))
tn_raw$District <- tn_raw$District %>%
  str_replace_all("\\b(Schools|District|Public)\\b", "") %>%
  str_squish()
tn_raw$Superintendent <- str_trim(str_replace_all(tn_raw$Superintendent, "[^[:alnum:]\\s]+$", ""))
names(tn_raw) <- tolower(names(tn_raw))
tn_raw$district <- tolower(tn_raw$district)

tn_nces <- read_csv(file.path(dist_chars_path, "ccd_lea_029_2324_w_1a_073124.csv")) %>% select(LEAID, LEA_NAME, ST)
tn_nces <- tn_nces[tn_nces$ST=="TN",]
names(tn_nces) <- tolower(names(tn_nces))
tn_nces <- tn_nces %>% rename(district = lea_name)
tn_nces$district <- tolower(tn_nces$district)

tn_raw <- left_join(tn_raw, tn_nces, by = "district")
tn_raw$st <- "TN"
tn_raw$leaid <- as.numeric(tn_raw$leaid)
tn_raw <- tn_raw %>%
  mutate(leaid = case_when(
    district == "fayette county"                 ~ 4701240,
    district == "franklin city"                  ~ 4701260,
    district == "gibson co. special"             ~ 4701400,
    district == "gibson county"                  ~ 4701400,
    district == "hardeman county"                ~ 4701650,
    district == "hollow rock-bruceton"           ~ 4701890,
    district == "humboldt"                       ~ 4701950,
    district == "huntingdon"                     ~ 4702010,
    district == "madison co"                     ~ 4702580,
    district == "memphis"                        ~ 4700148,
    district == "shelby county"                  ~ 4700148,
    district == "west carroll"                   ~ 4704490,
    district == "arlington community"            ~ 4700152,
    district == "asd (achievement school"        ~ 4700147,
    district == "bartlett city"                  ~ 4700153,
    district == "germantown municipal"           ~ 4700151,
    district == "lakeland municipal"             ~ 4700154,
    district == "millington municipal"           ~ 4700150,
    district == "achievement school"             ~ 4700147,
    district == "alamo city"                     ~ 4700030,
    district == "alcoa city"                     ~ 4700060,
    district == "alvin c. york institute"        ~ 4700144,
    district == "athens city"                    ~ 4700120,
    district == "bells city"                     ~ 4700210,
    district == "bradford special school system" ~ 4701390,
    district == "bristol city"                   ~ 4700360,
    district == "clarksville-montgomery county"  ~ 4703030,
    district == "cleveland city"                 ~ 4700690,
    district == "clinton city"                   ~ 4700720,
    district == "dayton city"                    ~ 4700930,
    district == "dyersburg city"                 ~ 4701080,
    district == "elizabethton city"              ~ 4701110,
    district == "etowah city"                    ~ 4701140,
    district == "fayetteville city"              ~ 4701200,
    district == "franklin special school"        ~ 4701260,
    district == "gibson county ssd"              ~ 4701400,
    district == "greeneveille city"              ~ 4701500,
    district == "hollow rock-bruceton ssd"       ~ 4701890,
    district == "humboldt city"                  ~ 4701950,
    district == "huntingdon special school"      ~ 4702010,
    district == "jackson-madison county"         ~ 4702580,
    district == "kingsport city"                 ~ 4702190,
    district == "lebanon special school"         ~ 4702370,
    district == "lexington city"                 ~ 4702460,
    district == "luaderdale county"              ~ 4702310,
    district == "manchester city"                ~ 4702610,
    district == "maryville city"                 ~ 4702700,
    district == "mckenzie special school"        ~ 4702790,
    district == "metro nashville"                ~ 4703180,
    district == "milan special school"           ~ 4702970,
    district == "murfreesboro city"              ~ 4703150,
    district == "newport city"                   ~ 4703210,
    district == "oak ridge city"                 ~ 4703240,
    district == "oneida special school"          ~ 4703300,
    district == "paris special school"           ~ 4703360,
    district == "rogersville city"               ~ 4703660,
    district == "south carroll ssd"              ~ 4703900,
    district == "sweetwater city"                ~ 4704050,
    district == "tn school for the blind"        ~ 4700145,
    district == "tn school for the death"        ~ 4700146,
    district == "trenton special school"         ~ 4704100,
    district == "tullahoma city"                 ~ 4704200,
    district == "west carroll special school"    ~ 4704490,
    district == "memphis-shelby county"          ~ 4700148,
    TRUE                                   ~ leaid
  ))
head(tn_raw)

tn_distids <- data.frame()
years <- 2011:2022

# Loop through years to load and process data
for(y in years){
  print(y)

  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Tennessee") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = if(is.character(leaid)) {
             parse_number(leaid)
           } else {
             as.numeric(leaid)  # If already numeric, just ensure it's numeric
           }, 
           state_leaid_n = as.numeric(str_remove_all(state_leaid, "TN-")))
  
  tn_distids <- bind_rows(tn_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Merge with `tn_raw`
tn_raw$year <- as.numeric(tn_raw$year)
tn_lea <- left_join(tn_raw, tn_distids, by = c("leaid","year"))
tn_lea <- tn_lea %>%
  filter(!is.na(superintendent) & superintendent != "")

# Add state and ID fields
tn_lea <- tn_lea %>% distinct(leaid, year, superintendent, .keep_all = TRUE)

tn_lea <- tn_lea %>% arrange(leaid, year)
tn_lea <- tn_lea %>%
  mutate(
    superintendent = str_remove_all(superintendent, regex("\\b(Ms\\.|Mr\\.|Mrs\\.|Dr\\.|Miss)\\b", ignore_case = TRUE)),
  )
tn_lea <- tn_lea %>%
  mutate(state = "tn",
         id = paste0("tn", str_pad(1:nrow(tn_lea), width = 5, side = "left", pad = "0")),
         name_raw = superintendent,
         name_clean = clean_names(name_raw))

tn_lea <- tn_lea %>% rename(charter = agency_charter_indicator)

# Create table with relevant columns
all_supers <- tn_lea %>% select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# Kriner Cash was superintendent of the Memphis City Schools (Tennessee) from 2008 until his resignation in 2013. It appears that John Aitken was involved in the subsequent merger/transition of Memphis and Shelby County schools after Cash’s departure. 
all_supers <- all_supers %>%
  filter(!(leaid == 4700148 & name_clean == "john aitken" & year %in% c(2011, 2012)))


# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_tn.Rda"))

# data checks 
data_checks(all_supers)

duplicates <- all_supers %>%
  group_by(year, leaid) %>%
  filter(n() > 1) %>%
  arrange(year, leaid)
write.csv(all_supers, "all_supers_tn.csv")
#write.csv(duplicates, "duplicates.csv")
