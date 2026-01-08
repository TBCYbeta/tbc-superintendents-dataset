# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Florida data directory
fl_dir_path <- here("data", "raw", "fl")

fl_2010 <- read_xlsx(file.path(fl_dir_path, "PERA1959u_ExcludesExempt_Staff Data_1011_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`)
fl_2011 <- read_xlsx(file.path(fl_dir_path, "PERA1959u_ExcludesExempt_Staff Data_1112_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`)
fl_2012 <- read_xlsx(file.path(fl_dir_path, "PERA1959u_ExcludesExempt_Staff Data_1213_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`)
fl_2013 <- read_xlsx(file.path(fl_dir_path, "PERA1959u-ExcludesExempt_Staff Data_1314_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`)
fl_2014 <- read_xlsx(file.path(fl_dir_path, "PERA1959l_ExcludesExempt_Staff Data_1415_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2015 <- read_xlsx(file.path(fl_dir_path, "PERA1959l_ExcludesExempt_Staff Data_1516_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2016 <- read_xlsx(file.path(fl_dir_path, "PERA1959l_ExcludesExempt_Staff Data_1617_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2017 <- read_xlsx(file.path(fl_dir_path, "PERA1959l_ExcludesExempt_Staff Data_1718_John Singleton.xlsx"), skip = 3) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2018 <- read_xlsx(file.path(fl_dir_path, "PERA1959f_ExcludesExempt_Staff Data_1819_John Singleton.xlsx"), skip = 4) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2019 <- read_xlsx(file.path(fl_dir_path, "PERA1959i_ExcludesExempt_Staff Data_1920_John Singleton.xlsx"), skip = 4) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2020 <- read_xlsx(file.path(fl_dir_path, "PERA1959m_ExcludesExempt_Staff Data_2021_John Singleton.xlsx"), skip = 4) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2021 <- read_xlsx(file.path(fl_dir_path, "PERA1959o_ExcludesExempt_Staff Data_2122_John Singleton.xlsx"), skip = 4) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)
fl_2022 <- read_xlsx(file.path(fl_dir_path, "PERA1959r_ExcludesExempt_Staff Data_2223_John Singleton.xlsx"), skip = 4) %>% select(Dist = 1, `District Name`, `Last Name`, `First Name`, `Job Title`, `ANNUAL SALARY`)

# Salary data is not available before 2014-2015
fl_2010$`ANNUAL SALARY`<- NA
fl_2011$`ANNUAL SALARY`<- NA
fl_2012$`ANNUAL SALARY`<- NA
fl_2013$`ANNUAL SALARY`<- NA

years <- c(2010:2022)
df_names <- paste0("fl_", years)
df_list <- mget(df_names)
fl_raw <- bind_rows(
  Map(function(df, yr) {
    df %>%
      mutate(
        year = yr,
        Dist = as.numeric(Dist),
      )
  }, df_list, years)
)
summary(as.factor(fl_raw$year))
fl_raw <- fl_raw %>% filter(`Job Title`=="DISTRICT SUPERINTENDENT")
summary(as.factor(fl_raw$year))
fl_raw <- fl_raw %>%
  select(-`Job Title`)
names(fl_raw)[names(fl_raw) == "District Name"] <- "name"


# Map district IDs to LEAIDs

fl_nces <- read_xlsx(file.path(fl_dir_path, "EDGE_GEOCODE_PUBLICLEA_2324.xlsx")) %>% select(LEAID, NAME, STATE)
fl_nces <- fl_nces[fl_nces$STATE=="FL",]
fl_nces <- fl_nces %>%
  select(-STATE)
names(fl_nces) <- tolower(names(fl_nces))

fl_raw <- left_join(fl_raw, fl_nces, by = "name")
fl_raw$leaid[fl_raw$name == "IDEA PUB SCH"] <- 1200084


# Initialize an empty data frame
fl_distids <- data.frame()
years <- 2010:2022

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Florida") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid))
  
  fl_distids <- bind_rows(fl_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

fl_lea <- left_join(fl_raw, fl_distids, by = c("leaid","year"))
fl_lea$name_raw <- paste(fl_lea$`Last Name`, ", ", fl_lea$`First Name`, sep = "")
fl_lea$name_clean <- clean_names(fl_lea$name_raw)
fl_lea$state <- "fl"

#Create table with names, district IDs, and years
all_supers <- fl_lea %>% select(id=Dist, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, leaid, salary="ANNUAL SALARY", agency_charter_indicator)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)


# drop missing name obs and duplicates 
all_supers <- all_supers %>% filter(name_clean!="vacant") %>%
                             filter(!is.na(leaid))


# Remove duplicate superintendents in a year-leaid observation
all_supers$drop <- 0

# LEAID 1200090 (Bay County): william hussfelt was the superintendent over the period https://en.wikipedia.org/wiki/Bay_District_Schools
# https://www.mypanhandle.com/news/local-news/bay-county/bay-superintendent-bill-husfelt-announces-retirement/
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2011, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2013, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2014, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200090 & 
                            all_supers$name_clean=="timothy kitts" & 
                            all_supers$year==2015, 1, all_supers$drop)

# Drop ones that were there later (inferred based on previous and/or next year-leaid observations)
all_supers$drop <- ifelse(all_supers$leaid==1200180 & 
                            all_supers$name_clean=="carmella morton" & 
                            all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200180 & 
                            all_supers$name_clean=="robert haag" & 
                            all_supers$year==2011, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1200180 & 
                            all_supers$name_clean=="olivia hilton" & 
                            all_supers$year==2013, 1, all_supers$drop)

# The data is missing a superintendent for Broward County (1200180) from 2014-2020. But there are reports that Robert Runcie was the superintendent over this period, who made over $300k per year and resigned in 2021 while under investigation. There are even names of alleged co-conspirators in the data (e.g. former district administrator Tony Hunter). It almost seems like all records of Robert Runcie were intentionally deleted from the data. I confirmed this by searching and looking through the raw data. The data picks right up with the next superintendent in 2021. https://www.nbcmiami.com/news/local/embattled-broward-county-school-superintendent-offers-to-resign/2438679/#:~:text=Runcie%2C%[…]%20aside.%E2%80%9D

# Lee County: Lawrence Tihen 2010-2011, Dr. Joseph Burke 2011- https://www.lehighacrescitizen.com/2011/07/02/school-district-of-lee-county-remains-an-a-district/

all_supers$drop <- ifelse(all_supers$leaid==1201080 & 
                            all_supers$name_clean=="lee bush" & 
                            all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201080 & 
                            all_supers$name_clean=="lee bush" & 
                            all_supers$year==2011, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201080 & 
                            all_supers$name_clean=="lee bush" & 
                            all_supers$year==2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201080 & 
                            all_supers$name_clean=="nancy graham" & 
                            all_supers$year==2013, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201080 & 
                            all_supers$name_clean=="nancy graham" & 
                            all_supers$year==2015, 1, all_supers$drop)

# LEAID 1201590 (Polk County): Sherrie Nickell was superintendent from 2010-2012 https://www.theledger.com/story/news/2014/08/09/a-conversation-with-sherrie-nickell/26978081007/
# In 2011, FL made Lake Wales its own school district for charter schools separate from Polk County. Jesse Jackson was the superintendent. https://www.theledger.com/story/news/education/2020/12/17/lake-wales-charter-school-district-leadership-changes-superintendent-chairman-leaving/3884612001/?gnt-cfr=1&gca-cat=p&gca-uir=true&gca-epti=z116045e005600v116045b0060xxd006065&gca-ft=211&gca-ds=sophi
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="gail mckinzie" & 
                            all_supers$year==2010, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2011, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2013, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2014, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid==1201590 & 
                            all_supers$name_clean=="jesse jackson" & 
                            all_supers$year==2015, 1, all_supers$drop)

all_supers$drop <- ifelse(all_supers$leaid== 1201560 & 
                            all_supers$name_clean=="michael grego" & 
                            all_supers$year==2012, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid== 1201470 & 
                            all_supers$name_clean=="melba luciano" & 
                            all_supers$year==2012, 1, all_supers$drop)
# Hillsborough County (1200870) superintendent was Jeff Eakins from 2015 to 2019.  https://baynews9.com/fl/tampa/news/2019/06/10/hillsborough-county-superintendent-jeff-eakins-to-retire-next-year#:~:text=%2D%2D%20Hillsborough%20County%20Public%20Schools%20Superintendent%20Jeff%20Eakins%20has%20announced%20plans%20to%20retire.
all_supers$drop <- ifelse(all_supers$leaid== 1200870 & 
                            all_supers$name_clean=="cametra edwards" & 
                            all_supers$year==2015, 1, all_supers$drop)

# 2015 can de-duplicate by taking highest salary
all_supers$drop <- ifelse(all_supers$leaid== 1201230 & 
                            all_supers$name_clean=="diana greene" & 
                            all_supers$year==2015, 1, all_supers$drop)
all_supers$drop <- ifelse(all_supers$leaid== 1202013 & 
                            all_supers$name_clean=="lynn wicker" & 
                            all_supers$year==2015, 1, all_supers$drop)

all_supers <- all_supers %>% filter(drop==0) %>% select(-drop)
all_supers$state <- toupper(all_supers$state)
all_supers <- all_supers %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
all_supers <- all_supers %>% arrange(leaid, year)
all_supers$id <- paste0("fl", str_pad(1:nrow(all_supers), width = 5, side = "left", pad = "0"))
all_supers <- all_supers %>% rename(charter = agency_charter_indicator)

# save
save(all_supers, file = file.path(clean_path, "all_supers_fl.Rda"))

# data checks 
data_checks(all_supers)

