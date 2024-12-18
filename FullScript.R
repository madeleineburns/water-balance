library(sf)
library(raster)
library(ggplot2)
library(WaterBalance)
library(dplyr)
library(xts)
library(lubridate)
library(hydroGOF)
library(stringr)
library(terra)
library(glue)
library(tidyverse)
library(climateR)
library(EGRET)
library(daymetr)


### Set path variables and source in files ###
path<- "C:/Users/mcburns/OneDrive - DOI/water-balance"
codePath <- file.path(path, 'Code')
outPath <- file.path(path,"Output")
dataPath <- file.path(path, "Data")

file.sources <- list.files(path=codePath,pattern="*.R")
setwd(codePath)
sapply(file.sources,source,.GlobalEnv)
setwd(path)

# Set Switch variables
PETMethod = "Oudin" 
optimization = FALSE
delayStart = TRUE 
NonZeroDrainInitCoeff = FALSE
incompleteMonths = FALSE
GridMet = TRUE
fillLeapDays = TRUE 
future_analysis = TRUE
userSetJTemp = FALSE
percentRedGrid = 1
make_plots = TRUE
flow_components = 3  # change the number of components that characterize the flow. can be 2 or 3. 2: flow has quick and slow components; 3: flow has quick, slow, and very slow components.
FolderName = "test" 

### consider changing all of these variables for a new location
#No special characters allowed in the Climate Site ID
# location in the Watershed where climate data are obtained
ClimateSiteID = "Wet Beaver Creek" 
lat = 34.7 #watershed location
lon = -111.43 #watershed location

#define stream gauge location
GaugeSiteID <- "09505200"

# Water balance variables
#initial flow conditions
q0 = 0; s0 = 0; v0 = 0
#IHACRES flow A and B coefficients
qa<- 0.2; qb<- 0.3; sa<- 0.3; sb = 0.4; va = 0.2           
vb = (1-(qb/(1-qa)+sb/(1-sa)))*(1-va) #solved for by other variables to conserve mass balance

# Default Water Balance variables (start of optimization)
gw_add=0; vfm = 0.33; jtemp = 1.982841; jrange = 3 ;hock =  4 
hockros = 4; dro = 0; mondro = 0; aspect = 180; slope= 0; shade.coeff= 1


#Define the period for GridMet and Stream Gauge collection. 
#The DayMet period is defined to start one year after this period starts
startY =1979; startM=01; startD=01 
endY = 2023; endM = 6; endD = 24

#optional scaling factors for GridMet time series. 
#If no scaling is desired set slopes to 1 and bias to zero. See guide for more details.
tmmx_slope = 1.013; tmmx_bias = -0.4422
tmmn_slope = 0.9647; tmmn_bias = -0.7425
p_slope = 0.8816; p_bias = 0.055

#Water Balance variables not to be optimized
SWC.Max = 100; Soil.Init = SWC.Max; Snowpack.Init = 0 ;T.Base = 0

#Water Balance lower optimization limits
l_gw_add = 0; l_vfm = 0.25; l_jrange = 2; l_hock = 0; l_hockros = 0
l_dro= 0; l_mondro = 0; l_aspect= 0; l_slope =  0; l_shade.coeff = 0.7

#Water Balance upper optimization limits
u_gw_add = 0.1; u_vfm = 0.4; u_jrange = 4; u_hock =  8; u_hockros = 8
u_dro= 0.5; u_mondro= 0.5; u_aspect= 360; u_slope = 45; u_shade.coeff = 1

######## start of code for Wrapper function ########
### Define variables that do not need to be defined outside of the function ###
if(delayStart){
  cutoffYear = startY+11
}else{cutoffYear = startY} 

if(percentRedGrid<=0| percentRedGrid>1){
  warning("Value must be between 0 and 1, 1 inclusive."); stop()
}

#remove spaces for use in file names later
ClimateSiteID_FileName = gsub(pattern = " ", x = ClimateSiteID, replacement = "")

#get elevation from DayMet data. This happens regardless or whether you use DayMet or GridMet climate data
elev = get_elev_DayMet(lat = lat, lon = lon, startY = startY, endY = endY, ClimateSiteID_FileName = ClimateSiteID_FileName)

#get j_temp
if(!userSetJTemp){
  j.raster = raster(file.path(dataPath, "merged_jennings.tif"))
  jtemp = get_jtemp(lat = lat, lon= lon, j.raster = j.raster) 
}

#make lower and upper boundaries for water balance variable optimization
lower = data.frame(l_gw_add, l_vfm, l_jrange, l_hock,l_hockros,
                   l_dro, l_mondro, l_aspect, l_slope, l_shade.coeff)
upper = data.frame(u_gw_add, u_vfm, u_jrange, u_hock,u_hockros, 
                   u_dro,u_mondro,u_aspect, u_slope, u_shade.coeff)

#define lower and upper boundaries for jtemp
lower = data.frame(lower, jtemp = jtemp-0.5) 
upper = data.frame(upper, jtemp= jtemp+0.5)

### Scrape and format USGS stream gauge data and GridMet or DayMet data ###
#create start and end date objects of data collection. DayMet will start one year after the year listed here
startDate<- ymd(paste(startY, startM, startD))
endDate<-  ymd(paste(endY, endM, endD))

#in the code below, if meteorological data file does not exist, the data is scraped, saved as a csv, and read in
if(GridMet){
  if(!file.exists(file.path(dataPath, paste0(paste("GridMet",ClimateSiteID_FileName,startY, endY, sep = "_" ), ".csv")))){
    point <- data.frame(lon = lon, lat = lat) %>%
      vect(geom = c("lon", "lat"), crs = "EPSG:4326")
    gridMet_vars <- c("pr", "srad","tmmn", "tmmx", "vpd", "vs")
    DailyClimData <- getGridMET(point,varname = gridMet_vars,startDate = startDate, 
                                endDate = endDate,verbose = TRUE)
    write.csv(DailyClimData, file.path(dataPath, paste0(paste("GridMet",ClimateSiteID_FileName,startY, endY, sep = "_" ), ".csv")), row.names = FALSE) 
  }else{
    DailyClimData = read.csv(file.path(dataPath, paste0(paste("GridMet",ClimateSiteID_FileName,startY, endY, sep = "_" ), ".csv")))
  }
}else{if(!file.exists(file.path(dataPath, paste0(paste("DayMet", ClimateSiteID_FileName, startY+1,endY, sep = "_"), ".csv")))){
  daymetr::download_daymet_batch(file_location = file.path(dataPath,paste0("SiteFile", ClimateSiteID_FileName, ".csv")),
                                 start = startY+1,
                                 end = endY,
                                 internal = FALSE,
                                 path=dataPath)
  DailyClimData<- read.csv(file.path(dataPath, paste0(paste("DayMet", ClimateSiteID_FileName, startY+1,endY, sep = "_"), ".csv")), skip = 6, header = TRUE, sep = ",")
}else{
  DailyClimData<- read.csv(file.path(dataPath, paste0(paste("DayMet", ClimateSiteID_FileName, startY+1,endY, sep = "_"), ".csv")), skip = 6, header = TRUE, sep = ",")
}}

# scrape stream gauge data
#If local file does not exist, the data is scraped, saved as a csv, and read in
if(!file.exists(file.path(dataPath, paste0(paste("USGS_Gauge",GaugeSiteID, startY+1,endY, sep = "_"), ".csv")))){
  DailyStream <- EGRET::readNWISDaily(siteNumber = GaugeSiteID, parameterCd = "00060", 
                                      startDate = startDate, endDate = endDate) |>
    dplyr::filter(grepl('A', Qualifier)) |> #this filters for any Qualifier that has an A. It will return A and A:E
    dplyr::mutate(CFS = Q*35.314666212661) #converts Q to flow cfs
  write.csv(DailyStream, file.path(dataPath, paste0(paste("USGS_Gauge",GaugeSiteID, startY+1,endY, sep = "_"), ".csv")))
}else{DailyStream<- read.csv(file.path(dataPath, paste0(paste("USGS_Gauge",GaugeSiteID, startY+1,endY, sep = "_"), ".csv")))}

if(!GridMet){
  #DayMet data does not have Leap Days in it while the stream gauge data and GridMet data does
  #This can be handled in two ways, and is set by the user with the switch "fillLeapDays"
  #If filled, the leap days are filled with the values of the Daymet Data from the day before
  #If removed, the leap days are removed from the Stream gauge data
  DailyStream$Date<- ymd(DailyStream$Date)
  HasLeapDays <- data.frame(Date = as.Date(seq(0, (nrow(DailyClimData)-1), 1),
                                             origin = ymd(paste(startY+1, startM, startD))))
  NoLeapDays<- HasLeapDays[!(format(HasLeapDays$Date,"%m") == "02" & format(HasLeapDays$Date, "%d") == "29"), , drop = FALSE]
  DifRows = nrow(HasLeapDays)-nrow(NoLeapDays)
  LastDate = NoLeapDays[nrow(NoLeapDays),]
  LostDates <- data.frame(Date = as.Date(seq(1, DifRows, 1),
                                           origin = LastDate))
  NoLeapDays<- rbind(NoLeapDays, LostDates)
  row.names(NoLeapDays)<- NULL
  DailyClimData$date<- ymd(NoLeapDays$Date)
    
  if(fillLeapDays){
    DateSeq <- rbind(HasLeapDays, LostDates)
    colnames(DateSeq)<- "date"
    DailyClimData = dplyr::full_join(DateSeq, DailyClimData, by = join_by("date"))
    na_rows <- as.numeric(rownames(DailyClimData[!complete.cases(DailyClimData), ]))
    dateColNumber = which(colnames(DailyClimData)=="date")
    for(i in na_rows){
      DailyClimData[i,-dateColNumber]<- DailyClimData[i-1,-dateColNumber]
    }
  }else{
    DailyStream <- DailyStream[!(format(DailyStream$Date,"%m") == "02" & format(DailyStream$Date, "%d") == "29"), , drop = FALSE]
  }

  #add month column
  DailyClimData$month<- as.numeric(format(as.Date(DailyClimData$date, format="%Y-%m-%d"),"%m"))
  #DayMet automatically includes the whole year of data, whereas GridMet lets you filter by month and day. This will ensure the end date is the same
  DailyClimData<- subset(DailyClimData, DailyClimData$date<=endDate)
  DailyClimData$year<- NULL
  DailyClimData$yday<- NULL
  DailyClimData$swe..kg.m.2.<- NULL
  #rename columns to match format needed of Gridmet Data
  if(fillLeapDays){ #order of columns was changed because of merging 
    colnames(DailyClimData)<- c("date", "dayl..s." , "pr","srad" ,"tmmx", "tmmn", "vp..Pa.", "month")
  }else{colnames(DailyClimData)<- c("dayl..s." , "pr","srad" ,"tmmx", "tmmn", "vp..Pa." ,"date", "month")}
}

#extract square mileage of the watershed from the EGRET package
obj = readNWISInfo(siteNumber = GaugeSiteID, parameterCd = "00060", interactive = FALSE)
sqmi = obj$drain_area_va

if(GridMet){  #these conversions won't have to be made if you run Daymet data
  #convert the temperatures from Kelvin to Celcius
  DailyClimData$tmmn<- kelvin_to_celcius(DailyClimData$tmmn)
  DailyClimData$tmmx<- kelvin_to_celcius(DailyClimData$tmmx)
  
  #adjust for bias in the temperature 
  DailyClimData$tmmn = get_slope_bias_adj(orig = DailyClimData$tmmn, bias = tmmn_bias, slopeadj = tmmn_slope)
  DailyClimData$tmmx = get_slope_bias_adj(orig = DailyClimData$tmmx, bias = tmmx_bias, slopeadj = tmmx_slope)
  
  #adjust for bias in the precip 
  for(i in 1:nrow(DailyClimData)){
    DailyClimData$pr[i] = if (DailyClimData$pr[i] == 0) {
      0
    }else{DailyClimData$pr[i] = get_slope_bias_adj(orig = DailyClimData$pr[i], bias = p_bias, slopeadj = p_slope)}
  }
}  

### Aggregate Gauge Discharge data monthly ###
Meas<- DailyStream[,c("Date", "CFS")]

#convert from CFS to MM and create an XTS object
Meas$MeasMM<- Meas$CFS*28316847*86400/(2590000000000 * sqmi) # measured mm of flow
Meas_xts<- xts(Meas$MeasMM, order.by = ymd(Meas$Date))

#add year-month column for aggregating by month and year combination
#The incompleteMonths switch is used here.

Meas$YrMon<- format(as.Date(Meas$Date, format="%Y-%m-%d"),"%Y-%m")
if(incompleteMonths){
  #sum all months of Measured Discharge, including incomplete months
  MeasAgg<- aggregate(Meas$MeasMM, by=list(Meas$YrMon), FUN=sum)
  colnames(MeasAgg)<- c("YrMon", "MeasMM")
}else{
  #sum only the complete months of Measured Discharge
  Dates<- data.frame(Date = DailyClimData$date)
  MeasFullDates<- dplyr::left_join(Dates,Meas[,c("MeasMM", "Date")],by = join_by("Date"))
  MeasFullDates$YrMon<- format(as.Date(MeasFullDates$Date, format="%Y-%m-%d"),"%Y-%m")
  #aggregate monthly by anyNA()
  MeasInCompleteMonths<- aggregate(MeasFullDates$MeasMM, by=list(MeasFullDates$YrMon), FUN=anyNA)
  #aggregate monthly by sum
  MeasAgg<- aggregate(Meas$MeasMM, by=list(Meas$YrMon), FUN=sum)
  #merge the incomplete months with the summed months
  MeasCM <- merge(MeasInCompleteMonths, MeasAgg, by = "Group.1", all = TRUE)
  #subset by only complete months
  MeasAgg = subset(MeasCM, MeasCM$x.x == FALSE)
  MeasAgg = MeasAgg[, c("Group.1","x.y")]
  colnames(MeasAgg)<- c("YrMon", "MeasMM")
}

### Set Updated Initial Flow Conditions if desired ###
#This is where the NonZeroDrainInitCoeff switch is used
if(NonZeroDrainInitCoeff){
  InitCond<- get_Init_Drain_Coef(DailyClimData = DailyClimData, gw_add = gw_add , 
                  vfm = vfm , jrange = jrange ,hock = hock ,hockros = hockros,
                  dro = dro,mondro = mondro , aspect = aspect,slope = slope, 
                  shade.coeff = shade.coeff, jtemp = jtemp ,SWC.Max = SWC.Max, 
                  Soil.Init = Soil.Init,Snowpack.Init = Snowpack.Init, T.Base = T.Base,
                  DailyWB = DailyWB, q0 = q0, qa = qa, qb = qb, s0 = s0, sa = sa, 
                  sb = sb, v0 = v0, va = va, vb = vb, PETMethod = PETMethod,
                  lat = lat, lon = lon, cutoffYear= cutoffYear)
  
  q0 = InitCond[["Quick"]]
  s0= InitCond[["Slow"]]
  v0 = InitCond[["Very_Slow"]]
}

results<- data.frame(ClimateSiteID = ClimateSiteID, start = startDate, end = endDate, PETMethod = PETMethod, optimization = optimization,
                     GridMet = GridMet, lon = lon, lat = lat,
                     startY = startY, startM = startM, startD = startD, endY = endY, endM = endM, endD = endD,
                     cutoffYear = cutoffYear, NonZeroDrainInitCoeff = NonZeroDrainInitCoeff, incompleteMonths = incompleteMonths)

### Optimize Water Balance variables according to the NSE of monthly summed measured versus modeled stream flow ###
if(optimization){
  parms<- c(gw_add = gw_add, vfm = vfm, jrange = jrange,hock =  hock, hockros = hockros,dro = dro, mondro = mondro,
            aspect = aspect,slope= slope, shade.coeff= shade.coeff, jtemp = jtemp)
  
  #run the optimization routine
  strtTimeM <-Sys.time()
  set.seed(123) #this ensures reproducibility each time
  WBcoeffs <- tibble()
  optMonth <- optim(par = parms, fn = WB_Optim, method = "L-BFGS-B",
                    lower = lower, upper = upper,control = list(fnscale = -1, factr = '1e-6')
                    #these are carried through to WB_optim
                    ,Meas_xts = Meas_xts, cutoffYear = cutoffYear, q0=q0, s0=s0, v0=v0,
                    qa=qa, qb=qb, sa=sa, sb=sb,va=va, Soil.Init = Soil.Init, 
                    SWC.Max = SWC.Max, Snowpack.Init = Snowpack.Init,T.Base = T.Base, 
                    DailyClimData = DailyClimData, PETMethod= PETMethod, lat=lat, 
                    lon=lon, MeasAgg = MeasAgg)
  elpTimeM <- Sys.time() - strtTimeM
  
  #collect variables and outcome of best run
  optValuesM<- data.frame(nseM = optMonth$value, t(as.matrix(optMonth$par)))
  
  #redefine the water balance variables from the best run
  gw_add = optValuesM$gw_add;vfm = optValuesM$vfm; jrange = optValuesM$jrange; hock = optValuesM$hock
  hockros = optValuesM$hockros;dro = optValuesM$dro;mondro = optValuesM$mondro; aspect = optValuesM$aspect
  slope = optValuesM$slope;shade.coeff = optValuesM$shade.coeff;jtemp = optValuesM$jtemp
  
  results = data.frame(results, optValuesM,elpTimeM = elpTimeM)
}

### Run the model and save the results with initial/non optimized variables for when not optimizing ###
if(!optimization){
  DailyWB<- WB(DailyClimData = DailyClimData, gw_add = gw_add, vfm = vfm, jrange = jrange,
               hock = hock, hockros = hockros, dro = dro, mondro = mondro, aspect = aspect, slope = slope,
               shade.coeff = shade.coeff, jtemp = jtemp,SWC.Max = SWC.Max, 
               Soil.Init = Soil.Init, Snowpack.Init = Snowpack.Init, T.Base = T.Base, 
               PETMethod = PETMethod,lat = lat, lon = lon)
  DailyDrain <- Drain(DailyWB = DailyWB, q0 = q0, qa = qa, qb = qb, s0 = s0, sa = sa, sb = sb, v0 = v0, va = va, vb = vb)
  MeasMod<- MeasModWB(DailyDrain = DailyDrain, MeasAgg = MeasAgg,cutoffYear = cutoffYear)
  x<- MeasMod$Mod
  y<- MeasMod$Meas
  nseM = NSE(sim = x, obs = y)
  results = data.frame(results, nseM =nseM, gw_add = gw_add, vfm =vfm,jrange =jrange,hock = hock, hockros =hockros,
                       dro =dro, mondro = mondro, aspect = aspect, slope = slope,
                       shade.coeff = shade.coeff, jtemp =jtemp, elpTimeM = NA)
}

### Perform the second optimization. 
# The IHACRES A and B coefficients are optimized according to the NSE of Daily total historic stream flow and daily historic modeled stream flow
if(optimization){
  #Re run the Water Balance model as an input for the second optimization with the optimized water balance variables
  DailyWB<- WB(DailyClimData = DailyClimData, gw_add = gw_add, vfm = vfm, jrange = jrange,
               hock = hock, hockros = hockros, dro = dro, mondro = mondro, aspect = aspect, slope = slope,
               shade.coeff = shade.coeff, jtemp = jtemp,SWC.Max = SWC.Max, Soil.Init = Soil.Init, Snowpack.Init = Snowpack.Init, T.Base = T.Base, PETMethod = PETMethod,lat = lat, lon = lon)
  strtTimeD <-Sys.time()
  
  #set.seed() ensures reproducibility
  set.seed(123)
  
  
  
  #create an empty tibble object for the result of the run to be stored in
  IHcoeffs = tibble()
  
  #create a grid of values to search from. NSE Daily is calculated at each point in the grid unless told otherwise 
  #the highest NSE is and setting of variables that created it are saved
  if(flow_components == 3){
    grid = data.frame(expand.grid(qa = seq(0.15, 0.25, 0.01), qb = seq(0.25, 0.35, 0.01),sa = seq(0.25, 0.35, 0.01),
                                  sb = seq(0.35, 0.45, 0.01), va = seq(0.15, 0.25, 0.01)))
    #The percentRedGrid variable is used here to decide how much of the grid to be searched. 
    samp = floor(nrow(grid)*percentRedGrid)
    redGrid = grid[c(sample(x = 1:nrow(grid), size = samp)),]
    IHcoeffs<- data.frame(qa = rep(NA, nrow(redGrid)), qb = rep(NA, nrow(redGrid)),
                          sa = rep(NA, nrow(redGrid)), sb = rep(NA, nrow(redGrid)), 
                          va = rep(NA, nrow(redGrid)), vb = rep(NA, nrow(redGrid)), 
                          nseD = rep(NA, nrow(redGrid)))
    for(i in 1:nrow(redGrid)){
      # EDITED THIS FOR QA AND QB
      IHcoeffs[i,] = IHACRESFlow(q0=q0,s0=s0,v0=v0, qa = redGrid[i,"qa"], qb = redGrid[i,"qb"], 
                                 sa = redGrid[i,"sa"], sb = redGrid[i,"sb"], 
                                 va = redGrid[i,"va"], DailyWB = DailyWB,
                                 Meas_xts = Meas_xts, cutoffYear = cutoffYear)
      print(i)
    }
  } else if (flow_components == 2){
    grid = data.frame(expand.grid(sa = seq(0, 1, 0.05), sb = seq(0, 1, 0.05), va = seq(0, 1, 0.05)))
    #The percentRedGrid variable is used here to decide how much of the grid to be searched. 
    samp = floor(nrow(grid)*percentRedGrid)
    redGrid = grid[c(sample(x = 1:nrow(grid), size = samp)),]
    IHcoeffs<- data.frame(sa = rep(NA, nrow(redGrid)), sb = rep(NA, nrow(redGrid)), 
                          va = rep(NA, nrow(redGrid)), vb = rep(NA, nrow(redGrid)), 
                          nseD = rep(NA, nrow(redGrid)))
    for(i in 1:nrow(redGrid)){
      # EDITED THIS FOR QA AND QB
      IHcoeffs[i,] = IHACRESFlow(q0=q0,s0=s0,v0=v0, qa = 0, qb = 0, sa = redGrid[i,"sa"],
                                 sb = redGrid[i,"sb"], va = redGrid[i,"va"],DailyWB = DailyWB,
                                 Meas_xts = Meas_xts, cutoffYear = cutoffYear)
      print(i)
    }
  }
  elpTimeD <- Sys.time() - strtTimeD
  
  #remove rows of NA's created when the value of very slow B was below 0
  IHcoeffs = IHcoeffs[complete.cases(IHcoeffs),]
  row.names(IHcoeffs)<- NULL
  row = which.max(IHcoeffs$nseD)
  best = IHcoeffs[row,]
  qa = best$qa;qb = best$qb; sa = best$sa; sb=best$sb;va=best$va;nseD=best$nseD
  vb = (1-(qb/(1-qa)+sb/(1-sa)))*(1-va)
  
  #store the results of the run
  results<- data.frame(results,qa=qa, qb=qb, sa=sa,sb=sb,va=va,vb=vb,nseD=nseD,elpTimeD=elpTimeD)
}

### Store the results if not optimizing
if(!optimization){
  IHcoeffs = data.frame(qa=NA, qb= NA, sa=NA, sb =NA, va=NA, vb  =NA, nseD = NA)
  IHVars <-  IHACRESFlow(q0 = q0, s0 = s0, v0 = v0, qa = qa, qb = qb, sa = sa, sb = sb,
                         va = va, DailyWB = DailyWB,Meas_xts = Meas_xts, cutoffYear = cutoffYear)
  results<- data.frame(results,IHVars,elpTimeD=NA)
}

##### Historic flow plots #####
#create the necessary directories and directory variables
dir.create(file.path(outPath, ClimateSiteID_FileName))
locationPath = file.path(outPath, ClimateSiteID_FileName)
dir.create(file.path(locationPath, FolderName))
outLocationPath = file.path(locationPath, FolderName)

#rerun the Water Balance model and drainage model with optimal Water Balance variables and drainage variables
DailyWB<- WB(DailyClimData = DailyClimData, gw_add = gw_add, vfm = vfm, jrange = jrange,
             hock = hock, hockros = hockros, dro = dro, mondro = mondro, aspect = aspect,
             slope = slope,shade.coeff = shade.coeff, jtemp = jtemp,SWC.Max = SWC.Max, 
             Soil.Init = Soil.Init, Snowpack.Init = Snowpack.Init, T.Base = T.Base, 
             PETMethod = PETMethod,lat = lat, lon = lon)
DailyDrain <- Drain(DailyWB = DailyWB, q0 = q0, qa = qa, qb = qb, 
                    s0 = s0, sa = sa, sb = sb, v0 = v0, va = va, vb = vb)

#create DailyHistFlow, which will have the Adjusted Runoff, Quick, Slow, and Very Slow Flows, and Total/stream flow
DailyHistFlow = data.frame(model = "Historic", date =ymd(DailyDrain$date))
#add the yr_mo and yr columns to DailyHistFlow
DailyHistFlow$yr<-format(as.Date(DailyHistFlow$date),"%Y")
DailyHistFlow$mo<-format(as.Date(DailyHistFlow$date),"%m")
DailyHistFlow$yr_mo<-format(as.Date(DailyHistFlow$date),"%Y-%m")
DailyHistFlow = cbind(DailyHistFlow, adj_runoff = DailyDrain$adj_runoff,
                      quick = DailyDrain$Quick, slow = DailyDrain$Slow,
                      veryslow = DailyDrain$Very_Slow, total = DailyDrain$total)

### Create plots comparing Measured to Modeled Flow on a monthly time-step ###
#Create Measured Modeled Object
MeasMod<- MeasModWB(DailyDrain = DailyDrain, MeasAgg = MeasAgg,cutoffYear = cutoffYear)
x<- MeasMod$Mod
y<- MeasMod$Meas

#make Monthly Historic Measured vs Modeled Stream Flow Scatter Plot and save as pdf
#There are two trend lines because in the scatter plot. 
#For one, the intercept is set to 0, and in the other, it is allowed to vary
if(make_plots){
  #scatter plot
  pdf(file=paste0(outLocationPath, "/", "Monthly_Historic_Measured_Modeled_Scatter.pdf"))
  par(mfrow = c(1,1))
  plot(x,y, main ="Monthly Historic Measured vs Modeled Stream Flow Scatter Plot", xlab = "Modeled Stream Flow", ylab = "Measured Stream Flow")
  abline(lm(y ~ 0 + x), col= "red")
  abline(lm(y ~ x), col= "red")
  dev.off()
}

#make Monthly Historic Measured vs Modeled Stream Flow xts plot and save as pdf
MeasMod_xts<- xts(MeasMod[,c("Meas", "Mod")], order.by = ym(MeasMod$YrMon))
if(make_plots){
  pdf(file=paste0(outLocationPath, "/", "Monthly_Measured_and_Modeled_Flow.pdf"))
  par(mfrow = c(2,1))
  print(plot.xts(x = MeasMod_xts$Meas, main = "Monthly Measured Stream Flow"))
  print(plot.xts(x = MeasMod_xts$Mod, main = "Monthly Modeled Stream Flow"))
  dev.off()
}

### Plot historical Modeled Flow on a monthly and yearly time-step ###
#create hist_flow, which is an xts object with needed columns
modeled_xts<- xts(with(DailyHistFlow, cbind(adj_runoff, quick, slow, veryslow, total)), order.by = DailyHistFlow$date)
hist_flow<- merge.xts(modeled_xts, Meas_xts)
hist_flow<- hist_flow[complete.cases(hist_flow),]

#make Daily Historic Measured vs Modeled Stream Flow xts plot and save as pdf
if(make_plots){
  name = "Measured vs Modeled Historic Daily Stream Flow"
  nameReduce = gsub(pattern = " ",replacement = "_", x = name)
  pdf(file=paste0(outLocationPath, "/", nameReduce, ".pdf"))
  par(mfrow = c(1,1))
  plot(hist_flow$total,type="l",col="red", main = name)
  lines(hist_flow$Meas_xts,col="black")
  print(xts::addLegend("topleft", legend.names = c("Modeled", "Measured"), lty=1, col= c("red", "black")))
  dev.off()
}

#use xts functionality to summarize monthly and annual periodicity
#monthly
hist_flow_mon<-as.data.frame(matrix(NA, nrow = nrow(apply.monthly(hist_flow[,"adj_runoff"], sum)),
                                    ncol = ncol(hist_flow),dimnames = list(c(), colnames(hist_flow))))
for(i in 1:ncol(hist_flow)){
  hist_flow_mon[,i]<- apply.monthly(hist_flow[,i], sum)
}

#annually
hist_flow_ann<-as.data.frame(matrix(NA, nrow = nrow(apply.yearly(hist_flow[,"adj_runoff"], sum)),
                                    ncol = ncol(hist_flow),dimnames = list(c(), colnames(hist_flow))))
for(i in 1:ncol(hist_flow)){
  hist_flow_ann[,i]<- apply.yearly(hist_flow[,i], sum)
}

#make Monthly Historic Stream Flow xts plot and save as pdf
if(make_plots){
  name = "Monthly Historic Stream Flow"
  nameReduce = gsub(pattern = " ",replacement = "_", x = name)
  pdf(file=paste0(outLocationPath, "/", nameReduce, ".pdf"))
  par(mfrow = c(1,1))
  print(plot(hist_flow_mon$total, type = "l", main =name ))
  dev.off()
}

#make Annual Historic Stream Flow xts plot and save as pdf
if(make_plots){
  name = "Annual Historic Stream Flow"
  nameReduce = gsub(pattern = " ",replacement = "_", x = name)
  pdf(file=paste0(outLocationPath, "/", nameReduce, ".pdf"))
  par(mfrow = c(1,1))
  print(plot(hist_flow_ann$total, type = "l", main =name))
  dev.off()
}

### Read in future flow from Mike Tercek, use the optimized IHACRES flow coefficients to obtain projected stream flow ###
# projected future runoff from water balance model using CMIP5 climate projections #
if(future_analysis){
  source('Future_Analysis.R')
}
  
### Save optimization data frames and results as RDS files ###
if(optimization){
  saveRDS(IHcoeffs, file = paste0(outLocationPath, "/IHcoeffs.rds"))
  saveRDS(WBcoeffs, file = paste0(outLocationPath, "/WBcoeffs.rds"))
}
saveRDS(results, file = paste0(outLocationPath, "/results.rds"))

######## end of code for Wrapper function ########
