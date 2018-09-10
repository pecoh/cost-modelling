#! /bin/bash

####################################################################################################
#
# Copyright 2017 Nathanael Hübbe
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
####################################################################################################
#
# batch_cost_analyser.sh <options> <config-file> <sacct-job-selection-options>
#
# This script is a twin of the `job-cost-meter.sh` script which is geared towards efficient analysis
# of large amounts of jobs.
#
# Options are parsed until the first non-option argument is encountered, which is taken to name the
# configuration file, all arguments that follow the configuration file path are passed through
# to `sacct` to control the job selection.
#
#  -q | --quiet
#     Reduced output: Only the column with the total costs is printed.
#
#  -s | --statistics
#     Print the statistics table. This is assumed if no --details option is provided.
#
#  -d | --details
#     Print the table with the results for all jobs. This is assumed if no --statistics option is
#     provided.
#
#  -i | --increment <percentage>
#     Set the quantile increment to use for the statistics table. Default is 25, which provides the
#     min, 25% quantile, mean, 75% quantile, and max value. `-i 5` will output twenty-one quantiles
#     at a 5% resolution instead.
#
#  -m | --max-runtime <seconds>
#     Ignore any job with a runtime larger than the provided maximum.
#     A negative value switches this filter off (default).
#
####################################################################################################

####################################################################################################
# Prolog: Script option parsing ####################################################################
####################################################################################################

verbosity=full
printStatisics=0
printDetails=0
quantileIncrement=25
maxRuntime=-1
while true ; do
	case "$1" in
		(-q|--quiet)
			verbosity=quiet
			shift
			;;
		(-s|--statistics)
			printStatistics=1
			shift
			;;
		(-d|--details)
			printDetails=1
			shift
			;;
		(-i|--increment)
			if (("$2" < 0 || "$2" > 100)) ; then
				echo "fatal error: illegal value '$2' found after $1 option" >&2
				exit 1
			fi
			quantileIncrement="$2"
			shift 2
			;;
		(-m|--max-runtime)
			maxRuntime="$2"
			shift 2
			;;
		(*)
			break
			;;
	esac
done
# If neither --statistics nor --details was given, we assume both (i.e. there's no way to not produce any output)
if ((!printStatistics && !printDetails)) ; then
	printStatistics=1
	printDetails=1
fi
if [[ -f "$1" ]] ; then
	configPath="$1"
	shift
else
	echo "fatal error: no configuration file found at '$1'" >&2
	exit 1
fi

####################################################################################################
# Function definitions #############################################################################
####################################################################################################

# progressMessage <message>
# Print the message to stderr, making arrangements for deleting it again.
# Call `progressMessage` with no arguments to clear the previous progress message.
function progressMessage() {
	echo -n -e "\r$(tr -c "" " " <<< "$progressMessage_oldMessage")\r$*" >&2
	progressMessage_oldMessage="$*"
}

# bypassProgressMessage <message>
# Print the message to stderr in front of the current progress message.
# This will overwrite the current progress message with the given message,
# and then immediately reprint the progress message.
function bypassProgressMessage() {
	local savedMessage="$progressMessage_oldMessage"
	progressMessage
	echo "$*" >&2
	progressMessage "$savedMessage"
}

# errorExit <error-message>
# If <error-message> is not empty, print it to stderr and exit the script with an error status.
# Does not return if <error-message> contains something.
function errorExit() {
	if [[ -n "$1" ]] ; then
		progressMessage
		echo "$1" >&2
		exit 1
	fi
}

# configErrorExit <error-message>
# Like `errorExit`, but expands the error message with a note that the error exists in our configuration file.
function configErrorExit() {
	if [[ -n "$1" ]] ; then
		errorExit "job-cost-meter configuration error: $1"
	fi
}

# unit2Factor unitString
# Parse the unit string, which must be of the format `<prefix>/<time-unit>`, and return the factor to multiply a value to transform it to the unit `m/a`.
function unit2Factor() {
	case $1 in
		(*/*) ;;
		(*)
			configErrorExit "illegal unit string '$1'"
			;;
	esac
	case ${1%/*} in
		(M) local result=1000000*1000 ;;
		(k) local result=1000*1000 ;;
		(1) local result=1*1000 ;;
		(c) local result=1000/100 ;;
		(m) local result=1000/1000 ;;
		(*) configErrorExit "illegal prefix in unit string '$1'" ;;
	esac
	case ${1#*/} in
		(a) local result=$result*1 ;;
		(mon) local result=$result*12 ;;
		(w) local result=$result*52 ;;
		(d) local result=$result*365 ;;
		(h) local result=$result*365*24 ;;
		(min) local result=$result*365*24*60 ;;
		(s) local result=$result*365*24*3600 ;;
		(*) configErrorExit "illegal time unit in unit string '$1'" ;;
	esac
	bc <<< "$result"	#must use bc for our calculations because `1000000*1000*365*24*3600` definitely exceeds the range that we can safely handle with shell arithmetic
}

# energyUnit2Factor unitString
# Parse the unit string of an energy rate, and return the factor to multiply the value to transform it to the unit `m/kWh`
function energyUnit2Factor() {
	case $1 in
		(M/kWh) echo $((1000000*1000)) ;;
		(k/kWh) echo $((1000*1000)) ;;
		(1/kWh) echo $((1*1000)) ;;
		(c/kWh) echo $((1000/100)) ;;
		(m/kWh) echo $((1000/1000)) ;;
		(*) configErrorExit "illegal energy unit string '$1'" ;;
	esac
}

# expandNodeList <nodelist>
# Write the sorted list of individual node names to stdout.
function expandNodeList() {
	scontrol show hostnames "$1" | sort -u
}

# readConfig <config-path>
# This function parses the config file and sets the global variables accordingly.
function readConfig() {
	local configFile="$1"

	currency=

	configCommands=
	configNames=
	configValues=
	configNodeCounts=
	configCommandCount=0
	while read -r cmd name value unit ; do
		case $cmd in
			(currency)
				if [[ -n "$currency" ]] ; then
					errorMessage="$(echo "$errorMessage"; echo "error: currency command used twice")"
				fi
				if [[ -n "$value$unit" ]] ; then
					errorMessage="$(echo "$errorMessage"; echo "error: extra parameters on currency command")"
				fi
				currency="$name"
				;;
			(*)
				configCommands[configCommandCount]="$cmd"
				configNames[configCommandCount]="$name"
				case $cmd in
					(nodes)
						configValues[configCommandCount]="$(expandNodeList "$value $unit")"
						configNodeCounts[configCommandCount]="$(echo "${configValues[configCommandCount]}" | wc -l)"
						;;
					(rate)
						configValues[configCommandCount]="$(bc <<< "$value*$(unit2Factor $unit)" || echo error)"
						;;
					(energy-rate)
						configValues[configCommandCount]="$(bc <<< "$value*$(energyUnit2Factor $unit)" || echo error)"
						;;
					(*)
						errorMessage="$(echo "$errorMessage"; echo "error: unknown config command '$cmd'")"
						;;
				esac
				((configCommandCount++))
				;;
		esac
	done < <(
		grep -o '^[^#]*' "$configFile" |	#remove all comments
		grep -v '^[[:space:]]*$'	#remove empty lines
	)
	configErrorExit "$errorMessage"

	# set the default currency
	if [[ -z "$currency" ]] ; then
		currency=dollar
	fi
}

# defineTableColumn <spacing> <title> <unit> <precision>
# Simple helper for defineTableColumns
# Expand the column metadata structures by the given column description.
function defineTableColumn() {
	local curColumn=table_columnCount
	table_columnSpacings[curColumn]="$1"
	table_columnHeaders[curColumn]="$2"
	table_columnUnits[curColumn]="$3"
	table_columnPrecisions[curColumn]="$4"
	((table_columnCount++))
}

# defineTableColumns
# Create the data structure for the table, this includes the following global variables:
#     table_columnCount
#     table_columnSpacings
#     table_columnHeaders
#     table_columnUnits
#     table_columnPrecisions
# This metadata will be used by deriveDetailsTable() and deriveStatisticsTable() to format the data in a sensible way.
#
# Requires that `readConfig()` has been called first!
function defineTableColumns() {
	defineTableColumn "  " "Size" "nodes" "0"
	defineTableColumn "  " "Runtime" "h" "4"
	defineTableColumn "  " "Energy" "J" "0"
	for ((curCommand = 0; curCommand < configCommandCount; curCommand++)) ; do
		table_columnHeaders[$((curCommand + 3))]="${configNames[curCommand]}"
		case "${configCommands[curCommand]}" in
			(nodes)
				if ((curCommand)) ; then
					defineTableColumn "  |  " "${configNames[curCommand]}" "nodes" "0"
				else
					defineTableColumn "  ||  " "${configNames[curCommand]}" "nodes" "0"
				fi
				;;
			(*)
				defineTableColumn "  " "${configNames[curCommand]}" "$currency" "2"
				;;
		esac
	done
	case "$verbosity" in
		(full) defineTableColumn "  ||  " "Total" "$currency" "2" ;;
		(quiet) defineTableColumn "" "Total" "$currency" "2" ;;
	esac
}

# addTableLine <job-id> <run-time> <energy> <node-list>
# Add a line with information on a single job to the output table.
function addTableLine() {
	local jobid="$1"
	local runtime="$2"
	local energy="$3"
	local nodelist="$4"
	local curLine="$table_rowCount"

	local days hours minutes seconds
	#FIXME: The documentation says that we must expect any of the three formats d-hh:mm:ss, hh:mm:ss, and mm:ss. While I have not seen the last format comming out of `sacct`, we should add support for this.
	case "$runtime" in
		(*-*)
			read -r days hours minutes seconds <<< "$(tr ":-" "  " <<< "$runtime")"
			local runtimeSeconds="$(bc <<< "$seconds + 60*($minutes + 60*($hours + 24*$days))")"
			;;
		(*)
			read -r hours minutes seconds <<< "$(tr ":" " " <<< "$runtime")"
			local runtimeSeconds="$(bc <<< "$seconds + 60*($minutes + 60*$hours)")"
			;;
	esac
	local explicitNodes="$(expandNodeList "$nodelist")"
	local nodeCount="$(echo "$explicitNodes" | wc -l)"
	local haveEnergy="$(bc <<< "$energy != 0")"

	if ((maxRuntime > 0 && runtimeSeconds > maxRuntime)) ; then
		bypassProgressMessage "warning: dropping long running job: ID = $jobid, runtime = $runtime, energy = $energy, nodelist = '$nodelist'"
		return
	fi

	table[$curLine,0]="$nodeCount"
	table[$curLine,1]="$(bc <<< "scale = 4 ; $runtimeSeconds/3600")"
	if ((haveEnergy)) ; then
		table[$curLine,2]="$energy"
	fi

	local totalCosts="0"
	for ((curCommand = 0; curCommand < configCommandCount; curCommand++)) ; do
		case "${configCommands[curCommand]}" in
			(nodes)
				local totalNodeCount="$(echo -e "$explicitNodes"'\n'"${configValues[curCommand]}" | sort -u | wc -l)"
				local curNodeCount="$((nodeCount + ${configNodeCounts[curCommand]} - totalNodeCount))"
				if ((curNodeCount)) ; then
					table[$curLine,$((curCommand + 3))]="$curNodeCount"
				fi
				;;
			(rate)
				if ((curNodeCount)) ; then
					local curCost="$(bc <<< "scale = 10 ; ${configValues[curCommand]}*$runtimeSeconds*$curNodeCount/(1000*365*24*3600)")"
					table[$curLine,$((curCommand + 3))]="$curCost"
					local totalCosts="$(bc <<< "$totalCosts + $curCost")"
				fi
				;;
			(energy-rate)
				if ((haveEnergy)) ; then
					local curCost="$(bc <<< "scale = 10 ; ${configValues[curCommand]}*$energy/(1000*1000*3600)")"
					table[$curLine,$((curCommand + 3))]="$curCost"
					local totalCosts="$(bc <<< "$totalCosts + $curCost")"
				fi
				;;
			(*)
				errorExit "internal error: unexpected value of \${configCommands[$curCommand]} = '${configCommands[$curCommand]}'"
				;;
		esac
	done
	table[$curLine,$((curCommand + 3))]="$totalCosts"
	table_rowSpacings[curLine]=""

	((table_rowCount++))
}

# deriveDetailsColumn <table-column> <detailsTable-column>
# Helper for deriveDetailsTable()
# Derive the visual output for a single table column.
function deriveDetailsColumn() {
	local inColumn="$1"
	local outColumn="$2"
	local precision="${table_columnPrecisions[inColumn]}"
	local unit="${table_columnUnits[inColumn]}"

	detailsTable[0,$outColumn]="${table_columnHeaders[inColumn]}"
	detailsTable_columnSpacings[outColumn]="${table_columnSpacings[inColumn]}"
	for ((curRow = 0; curRow < table_rowCount; curRow++)) ; do
		local curValue="${table[$curRow,$inColumn]}"
		if [[ -n "$curValue" ]] ; then
			detailsTable[$((curRow + 1)),$outColumn]="$(printf "%.${precision}f %s" "$curValue" "$unit")"
		fi
	done
}

# deriveDetailsTable
# Create the data structure detailsTable_* from the information found in table_*.
# detailsTable must be declared as an associative array at global scope.
function deriveDetailsTable() {
	detailsTable_rowSpacings[0]="-"	#the first row contains the column headers
	case "$verbosity" in
		(full)
			for ((curColumn = 0; curColumn < table_columnCount; curColumn++)) ; do
				deriveDetailsColumn "$curColumn" "$curColumn"
			done
			detailsTable_columnCount=table_columnCount
			;;
		(quiet)
			deriveDetailsColumn "$((table_columnCount - 1))" "0"
			detailsTable_columnCount=1
	esac
	((detailsTable_rowCount = table_rowCount + 1))
}

# deriveStatisticsColumn <table-column> <statisticsTable-column>
# Helper for deriveStatisticsTable()
# Derive the statistics of a single column.
function deriveStatisticsColumn() {
	local inColumn="$1"
	local outColumn="$2"
	local unit="${table_columnUnits[inColumn]}"
	local precision="${table_columnPrecisions[inColumn]}"

	# set the column header
	statisticsTable_columnSpacings[outColumn]="${table_columnSpacings[inColumn]}"
	statisticsTable[0,$outColumn]="${table_columnHeaders[inColumn]}"

	# extract the data from the current column and stored it in a sorted 1D array
	local sortedData
	mapfile -t sortedData < <(
		for ((curLine = 0; curLine < table_rowCount; curLine++)) ; do
			echo "${table[$curLine,$inColumn]}"
		done | sort -n
	)
	local dataCount="${#sortedData[*]}"
	if ((dataCount != table_rowCount)) ; then
		errorExit "assertion failed: sorted data array has wrong size $dataCount, expected $table_rowCount))"
	fi

	# compute the general statistics
	local partialSums sum=0 squareSum=0 nonzeroCount=0
	for ((i = 0; i < dataCount; i++)) ; do
		local curValue="${sortedData[i]}"
		if [[ -n "$curValue" ]] ; then
			local sum="$(bc <<< "$sum + $curValue")"
			local partialSums[i]="$sum"
			local squareSum="$(bc <<< "$squareSum + $curValue*$curValue")"
			((nonzeroCount++))
		fi
	done

	# fill the quantile table
	local lastLine="$((dataCount - 1))"
	for ((i = 0; i < statisticsTable_quantileRowCount; i++)) ; do
		local lineIndex="$((lastLine * i*quantileIncrement / 100))"
		if [[ -n "${sortedData[lineIndex]}" ]] ; then
			local quantileValue="${sortedData[lineIndex]}"
			local aggregatedPercentage="$(bc <<< "scale = 5 ; ${partialSums[lineIndex]}*100/$sum")"
			statisticsTable[$((i+1)),$outColumn]="$(printf "%.${precision}f %s (%5.1f%%)" "$quantileValue" "$unit" "$aggregatedPercentage")"
		fi
	done

	if ((nonzeroCount)) ; then
		local mean="$(bc <<< "scale = 20 ; $sum/$nonzeroCount")"
		local deviation="0"
		local variance="$(bc <<< "scale = 20 ; $squareSum/$nonzeroCount - $mean*$mean")"
		if (($(bc <<< "$variance != 0") )) ; then
			local deviation="$(bc -l <<< "scale = 2 ; e(l($variance)/2)")"
		fi

		local totalMean="$(bc <<< "scale = 20 ; $sum/$table_rowCount")"
		local totalDeviation="0"
		local totalVariance="$(bc <<< "scale = 20 ; $squareSum/$table_rowCount - $totalMean*$totalMean")"
		if (($(bc <<< "$totalVariance != 0") )) ; then
			local totalDeviation="$(bc -l <<< "scale = 20 ; e(l($totalVariance)/2)")"
		fi

		statisticsTable[$statisticsTable_sumRow,$outColumn]="$(printf "%.${precision}f %s" "$sum" "$unit")"
		statisticsTable[$statisticsTable_countRow,$outColumn]="$(printf "%d" "$nonzeroCount")"
		statisticsTable[$statisticsTable_totalCountRow,$outColumn]="$(printf "%d" "$dataCount")"
		statisticsTable[$statisticsTable_meanRow,$outColumn]="$(printf "%.${precision}f %s" "$mean" "$unit")"
		statisticsTable[$statisticsTable_deviationRow,$outColumn]="$(printf "%.${precision}f %s" "$deviation" "$unit")"
		statisticsTable[$statisticsTable_totalMeanRow,$outColumn]="$(printf "%.${precision}f %s" "$totalMean" "$unit")"
		statisticsTable[$statisticsTable_totalDeviationRow,$outColumn]="$(printf "%.${precision}f %s" "$totalDeviation" "$unit")"
	fi
}

# deriveStatisticsTable
# Take the info in the table_* variables and compute a table that provides some statistics on each column.
function deriveStatisticsTable() {
	progressMessage "computing statistics..."

	statisticsTable_rowCount=0

	# initialize the row header column
	statisticsTable[0,0]="statistics"
	statisticsTable_columnSpacings[0]=""
	statisticsTable_rowSpacings[0]="="
	((statisticsTable_rowCount++))

	for ((i = 0; i*quantileIncrement <= 100; i++)) ; do
		statisticsTable[$statisticsTable_rowCount,0]="$((i*quantileIncrement))%"
		((statisticsTable_rowCount++))
	done

	statisticsTable_quantileRowCount="$((statisticsTable_rowCount - 1))"
	statisticsTable_rowSpacings[statisticsTable_rowCount-1]="-"
	statisticsTable[$statisticsTable_rowCount,0]="sum"
	statisticsTable_sumRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="count"
	statisticsTable_countRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="total count"
	statisticsTable_totalCountRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="mean"
	statisticsTable_meanRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="std-dev"
	statisticsTable_deviationRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="total mean"
	statisticsTable_totalMeanRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))
	statisticsTable[$statisticsTable_rowCount,0]="total dev"
	statisticsTable_totalDeviationRow="$statisticsTable_rowCount"
	((statisticsTable_rowCount++))

	# compute the statistics
	case "$verbosity" in
		(full)
			statisticsTable_columnCount="$((table_columnCount + 1))"
			for ((curColumn = 1; curColumn < statisticsTable_columnCount; curColumn++)) ; do
				progressMessage "computing statistics of column $curColumn/$((statisticsTable_columnCount - 1))"
				deriveStatisticsColumn "$((curColumn-1))" "$curColumn"
			done
			;;
		(quiet)
			statisticsTable_columnCount=2
			deriveStatisticsColumn "$((table_columnCount-1))" 1
			;;
	esac

	# we need a different spacing for the first data column
	case "$verbosity" in
		(full) statisticsTable_columnSpacings[1]="  ||  " ;;
		(quiet) statisticsTable_columnSpacings[1]="  |  " ;;
	esac

	progressMessage
}

# fetchJobInfos <info-field> <<< "<job-list>"
# If job-list is "1\n2\n3", this is equivalent to `sacct -P -n -j "1,2,3" -o <info-field>`.
# The advantage of this function is, that it takes the job list from stdin, so it's not subject to any command line length limit that might be in effect.
# May split the request into several calls to `sacct`.
function fetchJobInfos() {
	local allJobs="$(cat)"

	# Split the list of job ids into batches, ensuring that no batch begins with a job step.
	local curJob curBatchSize=128 minBatchSize=128 curBatch=-1	#the first thing that the loop should do is to start a new batch
	while read -r curJob ; do
		case "$curJob" in
			(*.*)
				# curJob is a job step, so we must append it to the current batch
				if ((curBatch < 0)) ; then
					errorExit "internal error: first job id is a job step id"
				fi
				local batches[curBatch]="${batches[curBatch]},$curJob"
				((curBatchSize++))
				;;
			(*)
				# curJob is a job, not a job step, so check whether we want to start a new batch
				if ((curBatchSize < minBatchSize)) ; then
					local batches[curBatch]="${batches[curBatch]},$curJob"
					((curBatchSize++))
				else
					((curBatch++))
					local batches[curBatch]="$curJob"
					((curBatchSize = 1))
				fi
				;;
		esac
	done <<< "$allJobs"
	((batchCount = curBatch + 1))

	for ((curBatch = 0 ; curBatch < batchCount ; curBatch++)) ; do
		sacct -P -n -o "$1" -j "${batches[curBatch]}"
	done
}

# createTable <sacct-job-selection-options>
# Call `sacct` and parse its output into a global table `outputTable` according to the instructions found in the global `config*` arrays.
# Requires that `readConfig()` has been called first!
function createTable() {
	# precondition check
	if [[ -z "$currency" ]] ; then
		errorExit "internal error: createTable() seems to have been called without calling readConfig() first"
	fi

	# fetch our input from `sacct`
	progressMessage "fetching job list..."
	local jobList="$(sacct -P -n -o jobid "$@")"
	local jobList="$(fetchJobInfos jobid <<< "$jobList")"	# for some reason, this may add further .batch job steps
	mapfile -t jobIds <<< "$jobList"
	local jobCount="${#jobIds[*]}"
	progressMessage "fetching runtimes..."
	mapfile -t runtimes <<< "$(fetchJobInfos elapsed <<< "$jobList")"
	local count="${#runtimes[*]}"
	if ((count != jobCount)) ; then
		errorExit "internal error: runtime count ($count) does not match job count ($jobCount)"
	fi
	progressMessage "fetching energies..."
	mapfile -t consumedEnergies <<< "$(fetchJobInfos consumedEnergyRaw <<< "$jobList")"
	local count="${#consumedEnergies[*]}"
	if ((count != jobCount)) ; then
		errorExit "internal error: energy count ($count) does not match job count ($jobCount)"
	fi
	progressMessage "fetching nodelists..."
	mapfile -t nodelists <<< "$(fetchJobInfos nodelist <<< "$jobList")"
	local count="${#nodelists[*]}"
	if ((count != jobCount)) ; then
		errorExit "internal error: nodelist count ($count) does not match job count ($jobCount)"
	fi
	progressMessage
	echo "done fetching information ($jobCount jobs and jobsteps)" >&2

	# Walk the arrays read above, and create a single table line for each job, aggregating the information from the different job steps.
	curJobId=
	curJobEnergy=0
	curJobRuntime=
	curJobNodes=
	table_rowCount=0
	defineTableColumns
	for ((i = 0; i <= jobCount; i++)) ; do	# The <= is on purpose: It guarantees that we will actually create a table line for the last job.
		case "${jobIds[i]}" in
			($curJobId.*)
				# Check if a valid energy has been recorded for this job step. Two cases are excluded:
				# 1. no measurement, which results in an empty energy string, and 2. counter wrap-around, which results in a huge energy being recorded.
				if [[ -n "${consumedEnergies[i]}" ]] && (($(bc <<< "${consumedEnergies[i]} < 1000*1000*1000*1000*1000*1000") )) ; then
					curJobEnergy="$(bc <<< "$curJobEnergy + ${consumedEnergies[i]}")"
				fi
				;;
			(*)
				if [[ -n "$curJobId" ]] && [[ "$curJobNodes" != "None assigned" ]] ; then
					addTableLine "$curJobId" "$curJobRuntime" "$curJobEnergy" "$curJobNodes"
				fi
				curJobId="${jobIds[i]}"
				curJobEnergy=0
				curJobRuntime="${runtimes[i]}"
				curJobNodes="${nodelists[i]}"
				;;
		esac
		progressMessage "analysing job steps: $i/$jobCount"
	done
	progressMessage
	echo -e "analysed $table_rowCount jobs\n" >&2
}

# printTable <table-var>
# Dump the table contents to stdout, padding all fields as appropriate to provide proper formatting.
# The table is passed as the name of a global variable, which must be an associative array.
# There must also be global variables of the forms
#     <table-var>_columnCount
#     <table-var>_rowCount
#     <table-var>_columnSpacings
#     <table-var>_rowSpacings
# which provide the table dimensions and strings that are inserted between the rows/columns.
function printTable() {
	local tableVar="$1"
	eval "local columnCount="'"'"\$${tableVar}_columnCount"'"'""
	eval "local rowCount="'"'"\$${tableVar}_rowCount"'"'""

	# compute the maximum widths of all columns
	local -a columnWidths
	for ((column = 0; column < columnCount; column++)) ; do
		columnWidths[column]=0
		for ((row = 0; row < rowCount; row++)) ; do
			eval "local curWidth="'"'"\${#$tableVar[$row,$column]}"'"'""
			((${columnWidths[column]} >= $curWidth)) || columnWidths[column]="$curWidth"
		done
	done

	# construct a line with empty strings, this will be used as the template for the horizontal spacers
	local spacerLine="$(
		for ((column = 0; column < columnCount; column++)) ; do
			eval "printf '%s%*s' "'"'"\${${tableVar}_columnSpacings[$column]}"'"'" '${columnWidths[column]}' ''"
		done
	)"

	# dump the table itself
	for ((row = 0; row < rowCount; row++)) ; do
		for ((column = 0; column < columnCount; column++)) ; do
			eval "local curValue="'"'"\${$tableVar[$row,$column]}"'"'""
			eval "local curSpacing="'"'"\${${tableVar}_columnSpacings[$column]}"'"'""
			printf '%s%*s' "$curSpacing" "${columnWidths[column]}" "$curValue"
		done
		eval "echo "'"'"\${${tableVar}_columnSpacings[$column]}"'"'""
		eval "spacing="'"'"\${${tableVar}_rowSpacings[$row]}"'"'""
		if [[ -n "$spacing" ]] ; then
			echo "$(tr -c "|" "$spacing" <<< "$spacerLine")"
		fi
	done
}

####################################################################################################
# The main code ####################################################################################
####################################################################################################

readConfig "$configPath"
declare -A table detailsTable statisticsTable
createTable "$@"
if ((printDetails)) ; then
	deriveDetailsTable
	printTable detailsTable
fi
if ((printStatistics && printDetails)) ; then
	# insert a blank line between the two tables
	echo
fi
if ((printStatistics)) ; then
	deriveStatisticsTable
	printTable statisticsTable
fi
