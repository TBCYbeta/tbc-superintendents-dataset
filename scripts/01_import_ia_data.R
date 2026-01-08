# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Iowa data directory
ia_dir_path <- here("data", "raw", "ia")

ia_2004 <- read_xls(file.path(ia_dir_path, "0405_pre_pub_dist_directory.xls"), skip = 4) %>% select(Co = County, AEA, Dist = District, `District Name`, Administrator = Superintendent)
ia_2004$Title <- "Superintendent"
ia_2005 <- read_xls(file.path(ia_dir_path, "0506_pre_pub_dist_directory.xls"), skip = 5) %>% select(Co = County, AEA, Dist = District, `District Name`, Administrator, Title = `Administrator Title`)
ia_2006 <- read_xls(file.path(ia_dir_path, "0607_pre_pub_dist_directory.xls"), skip = 5) %>% select(Co = County, AEA, Dist = District, `District Name`, Administrator, Title = `Administrator Title`)
ia_2007 <- read_xls(file.path(ia_dir_path, "0708_pre_pub_dist_directory.2.xls"), skip = 5) %>% select(Co = County, AEA, Dist = District, `District Name`, Administrator, Title = `Administrator Title`)
ia_2008 <- read_xls(file.path(ia_dir_path, "0809_pre_pub_dist_directory.1.xls"), skip = 5) %>% select(Co, AEA, Dist, `District Name`, Administrator, Title)
ia_2009 <- read_xls(file.path(ia_dir_path, "0910_pre_pub_dist_directory.1_1.xls"), skip = 5) %>% select(Co, AEA, Dist, `District Name`, Administrator, Title)
ia_2010 <- read_xls(file.path(ia_dir_path, "1011_pre_pub_dist_directory.2.XLS"), skip = 5) %>% select(Co, AEA, Dist, `District Name`, Administrator, Title)
ia_2011 <- read_xls(file.path(ia_dir_path, "2011-2012 Iowa Public School District Directory v2.XLS"), skip = 5) %>% select(Co, AEA, Dist, `District Name`, Administrator, Title)
ia_2012 <- read_xls(file.path(ia_dir_path, "2012-2013 Iowa Public School District Directory(4).XLS"), skip = 5) %>% select(Co, AEA, Dist, `District Name`, Administrator, Title)
ia_2013 <- read_xlsx(file.path(ia_dir_path, "2013-2014 Public District Directory.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2014 <- read_xlsx(file.path(ia_dir_path, "2014-2014 Iowa Public District Directory 20141124.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2015 <- read_xlsx(file.path(ia_dir_path, "2015-2016 Iowa Public District Directory 102715.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2016 <- read_xlsx(file.path(ia_dir_path, "2016-2017_Iowa_Public_School District_Directory.xlsx"), skip = 4) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2017 <- read_xlsx(file.path(ia_dir_path, "2017-2018 Iowa Public School District Directory_0.xlsx"), skip = 4) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2018 <- read_xlsx(file.path(ia_dir_path, "2018-2019 Iowa Public School District Directory.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2019 <- read_xlsx(file.path(ia_dir_path, "2019-2020 Iowa Public School District Directory.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2020 <- read_xlsx(file.path(ia_dir_path, "PublicDistrictDirectory091120.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2023 <- read_xlsx(file.path(ia_dir_path, "Iowa Public School District Directory_23.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)
ia_2024 <- read_xlsx(file.path(ia_dir_path, "2024-25PublicDistrictDirectory7-29-24.xlsx"), skip = 5) %>% select(Co, AEA, Dist = District, `District Name`, Administrator, Title)

years <- c(2004:2020, 2023:2024)
df_names <- paste0("ia_", years)
df_list <- mget(df_names)
ia_raw <- bind_rows(
  Map(function(df, yr) {
    df %>%
      mutate(
        year = yr,
        Co = as.numeric(Co),
        AEA = as.numeric(AEA),
        Dist = as.numeric(Dist)
      )
  }, df_list, years)
)

summary(as.factor(ia_raw$year))

ia_raw <- ia_raw %>% filter(Title=="Superintendent")

summary(as.factor(ia_raw$year))

# Map district IDs to LEAIDs
# Initialize an empty data frame
ia_distids <- data.frame()

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Iowa") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid))
  
  ia_distids <- bind_rows(ia_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

ia_distids$state_leaid_clean <- str_remove_all(str_remove_all(ia_distids$state_leaid, "IA"),"-")
ia_distids$state_leaid_clean <- str_remove(ia_distids$state_leaid_clean, " 000$")
ia_distids$state_leaid_clean <- as.numeric(ia_distids$state_leaid_clean)

ia_raw$state_leaid_clean <- ia_raw$Co*10000+ia_raw$Dist

ia_lea <- left_join(ia_raw, ia_distids, by = c("state_leaid_clean","year"))

# Fill in leaid values that weren't merged
ia_lea$leaid <- ifelse(ia_lea$`District Name`=="Albert City-Truesdale" & is.na(ia_lea$leaid),1900031,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`=="CAL Comm School District" & is.na(ia_lea$leaid),1905970,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`%in%c("IKM","IKMComm School District","IKM-Manning Comm School District") & is.na(ia_lea$leaid),1914880,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`=="Nashua-Plainfield Comm School District" & is.na(ia_lea$leaid),1920190,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`%in%c("Gladbrook-Reinbeck","Gladbrook-ReinbeckComm School District") & is.na(ia_lea$leaid),1912660,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`=="Alden" & is.na(ia_lea$leaid),1900032,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`%in%c("Mormon Trail","Mormon Trail Comm School District","Mormon TrailComm School District") & is.na(ia_lea$leaid),1919740,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`%in%c("Starmont","StarmontComm School District") & is.na(ia_lea$leaid),1927270,ia_lea$leaid)
ia_lea$leaid <- ifelse(ia_lea$`District Name`%in%c("Turkey Valley","Turkey Valley Comm School District","Turkey ValleyComm School District") & is.na(ia_lea$leaid),1928110,ia_lea$leaid)

ia_clean <- ia_lea %>% select(dist_name=`District Name`, leaid, year, administrator = Administrator, agency_charter_indicator) %>% 
  distinct()

ia_clean <- ia_clean %>% group_by(leaid) %>% mutate(n = n())
table(ia_clean$n)


duplicates <- ia_clean %>%
  group_by(year, leaid) %>%
  filter(n() > 1) %>%
  arrange(year, leaid)

duplicates

# 3 LEAs have two rows in 2009
# Remove them manually (confirmed  by web search on 11/3/2025): 
ia_clean$drop <- 0
ia_clean$drop <- ifelse(ia_clean$dist_name=="Van Buren Comm School District" & 
                          ia_clean$leaid==1928980 & 
                          ia_clean$year==2009 & 
                          ia_clean$administrator=="Dr. Karen Stinson",1,ia_clean$drop)
ia_clean$drop <- ifelse(ia_clean$dist_name=="North Kossuth Comm School District" & 
                          ia_clean$leaid==1920830 & 
                          ia_clean$year==2009 & 
                          ia_clean$administrator=="Mike  Landstrum",1,ia_clean$drop)
ia_clean$drop <- ifelse(ia_clean$dist_name=="Atlantic Comm School District" & 
                          ia_clean$leaid==1903930 & 
                          ia_clean$year==2009 & 
                          ia_clean$administrator=="Wendy Prigge",1,ia_clean$drop)

ia_clean <- ia_clean %>% filter(drop==0) %>% select(-drop)

ia_clean$name_raw <- ia_clean$administrator

ia_clean$name_clean <- clean_names(ia_clean$name_raw)

ia_clean$state <- "IA"
ia_clean <- ia_clean %>% distinct(leaid, year, name_clean, agency_charter_indicator,.keep_all = TRUE)
ia_clean <- ia_clean %>% arrange(leaid, year)
ia_clean$id <- paste0("ia",str_pad(1:nrow(ia_clean), width = 5, side = "left", pad = "0"))
ia_clean <- ia_clean %>% rename(charter = agency_charter_indicator)

#Create table with names, district IDs, and years
all_supers <- ia_clean %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# drop missing name obs and duplicates 
all_supers <- all_supers %>% filter(name_clean!="vacant") %>%
                             filter(!is.na(leaid))


# save
save(all_supers, file = file.path(clean_path, "all_supers_ia.Rda"))

# data checks 
data_checks(all_supers)
