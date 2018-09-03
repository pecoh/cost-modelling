#! /bin/bash

####################################################################################################
# job-cost-meter <config-file>
#                [-(q|s|v) | --(quiet|short|verbose)]
#                [-(p|r) | --(post-mortem|redirect)]
#                [(-j | --job) <job-ID>]
#                [(-n | --nodes) <nodelist>]
####################################################################################################
# This script is meant to be called from a job epilog (currently, only SLURM is supported), to
# provide an estimate of the monetary costs the job has caused.
#
# <config-file> is a path to a configuration file that contains the cost rates which are used to
# calculate the cost estimate.  See Section CONFIGURATION below for details.
#
#
# OPTIONS:
#
#  -q | --quiet
#     Quiet mode. Outputs only the raw number for easy parsing.
#
#  -s | --short
#     Short output. Outputs only a single line of the format "job cost estimate: <total> <unit>".
#
#  -v | --verbose
#     Full output. All individual non-zero rates are listed along a total and some fancy formatting.
#     This is the default.
#
#  -o | --json
#     Full output in json format.
#
#  -p | --post-mortem
#     Switch off redirection of the script's output to the job's output file.  This switch is
#     implied when --job or --nodes is used.
#
#  -r | --redirect
#     Undo the effect of a previous implicit or explicit --post-mortem switch.
#
# (-j | --job) <job-ID>
#     Sets the job ID to use instead of the value in $SLURM_JOB_ID.  Make sure to also use the
#     --nodes option when using this option.  Implies --post-mortem.
#
# (-n | --nodes) <nodelist>
#     Sets the list of nodes to use instead of the value in $SLURM_NODELIST.  Make sure to also use
#     the --job option when using this option.  Implies --post-mortem.
#
#
# EXAMPLES:
#
#     Inside a SLURM job epilog script, you would typically call the script with
#
#         job-cost-meter.sh path/to/config-file
#
#     However, to test the results of a newly written config file, one would typically use an
#     invocation like this:
#
#         job-cost-meter.sh path/to/config-file --job 42 --nodes machine[7-23,1075]
#
#     As both of the --job and --nodes options imply --post-mortem, this will print the scripts
#     output directly to stdout for easy testing.
#
#
# CONFIGURATION:
#
#     The syntax of this file is as follows:
#
#       * There is no quoting, and all #-characters immediately start a line end comment.
#
#       * The syntax is command based, with each command occupying a single line.
#
#       * Non-linebreaking whitespace is equivalent, and lengths of whitespace runs are irrelevant.
#
#       * Commands are:
#
#           * currency <name>
#             The name of the currency to use.  This is a global setting that defaults to dollar.
#             It is an error to give more than one `currency` command.
#
#           * nodes <name> <nodelist>
#             The following commands apply to the given node set.  With SLURM, the <nodelist>
#             string may contain ranges like machine[6-7,42] (any valid input for `scontrol show
#             hostnames`).  The <name> is just an arbitrary word to identify a given node set in
#             the verbose output.  A `nodes` command must be given before the first `rate` command.
#
#           * rate <name> <value> <unit>
#             Must not be given before the first `nodes` command.
#             <name> is just an arbitrary name associated with the rate. It must be a single word
#             (no whitespace allowed).
#             <value> gives the numeric value of the rate.
#             <unit> gives the time unit to which the value is relative.
#                    The format is `(M|k|1|c|m)/(a|m|d|h)`.
#                    The letter before the `/` is a multiplicator, legal values are
#                      * M = 1000000
#                      * k = 1000
#                      * 1 = 1
#                      * c = 1/100	(cents)
#                      * m = 1/1000.
#                    This multiplicator is applied to the base currency unit that was set using the
#                    currency command. The letter after the `/` gives the time unit that the rate
#                    is relative to, legal values are
#                      * a = anno
#                      * mon = month
#                      * w = week
#                      * d = day
#                      * h = hour
#                      * min = minute
#                      * s = second
#                    So, `rate Investment 1000 1/a` means that the investment costs of a node are
#                    1000 Euro/dollar/whatever per year.  Likewise, `rate Cooling 4 c/h` means that
#                    colling costs four Euro/dollar/whatever cents per hour.
#
#           * energy-rate <name> <value> <unit>
#             Must not be given before the first `nodes` command.
#             <name> is just an arbitrary name associated with the rate. It must be a single word
#             (no whitespace allowed).
#             <value> gives the numeric value of the rate.
#             <unit> gives the energy unit to which the value is relative.
#                    The format is `(M|k|1|c|m)/kWh`.
#                    The letter before the `/` is the same multiplicator that is used for the
#                    `rate` command, the part behind the `/` has to be `kWh`.
#
#       * An example configuration could look like this:
#
#             # Example job-cost-meter configuration
#             currency Euro	#We are in Europe.
#
#                 # empty lines are ignored.
#
#             nodes Base machine[0-999]
#                 rate Procurement 1000 1/a
#                 rate Cooling 4 c/h
#                 rate Energy 500 1/a
#
#             nodes GPU machine[500-699]    #these are added to the generic costs above
#                 rate Procurement-GPU 200 1/a
#                 rate Cooling 3 c/h
#                 rate Energy 375 1/a
#
#             #our fat memory nodes, note that some of these are also GPU nodes
#             nodes Extra-memory machine[600-999]
#                 rate Extra-Memory 10 1/a
#
####################################################################################################



#####################
# profiling support #
#####################

if ((doProfiling)) ; then
	# These two functions take a single argument which is the name of an zero initialized variable that is used to accumulate the time.
	function startTime() {
		eval $1="'${!1} - $(date +"%s.%N")'"
	}

	function stopTime() {
		local endTime="$(date +"%s.%N")"
		eval $1="$(bc <<< "${!1} + $endTime")"
	}

	totalTime=0
		argParseTime=0
		informationCollectionTime=0
		configReadTime=0
		rateCalculationTime=0
			groupMatchTime=0
		outputTime=0
else
	# Turn the profiling calls into noops.
	function startTime() { true ; }
	function stopTime() { true ; }
fi



#########################################################
# Prolog: Default parameters and argument list parsing. #
#########################################################

startTime totalTime

# default parameters
verbosity=verbose
redirection=1
jobId="$SLURM_JOB_ID"
nodelist="$SLURM_NODELIST"
isNodelistSet=0

startTime argParseTime

# parse our argument list
if (( !$# )) ; then
	echo "fatal error: $0 must be called with at least one argument giving the path to its configuration file" 1>&2
	exit 1
fi
configFile="$1"
shift

while (( $# )) ; do
	case "$1" in
		(-q|--quiet) verbosity=quiet ;;
		(-s|--short) verbosity=short ;;
		(-v|--verbose) verbosity=verbose ;;
		(-o|--json) verbosity=json ;;
		(-p|--post-mortem) redirection=0 ;;
		(-r|--redirect) redirection=1 ;;
		(-j|--job)
			jobId="$2"
			shift
			redirection=0
			;;
		(-n|--nodes)
			nodelist="$2"
			shift
			redirection=0
			isNodelistSet=1
			;;
		(*)
			echo "fatal error: '$1' is not a valid option for $0" 1>&2
			exit 1
			;;
	esac
	if (( !$# )) ; then
		echo "fatal error: illegal argument list: argument to --job or --nodes is missing" 1>&2
		exit 1
	fi
	shift
done

stopTime argParseTime
startTime informationCollectionTime

# inquire more information about the job
if ((redirection)) ; then
	user="$(scontrol show job-username $jobId)"
	export jobWorkDir="$(scontrol show job-workdir $jobId)"
	export stdout="$(scontrol show job-stdout $jobId)"
	export stderr="$(scontrol show job-stderr $jobId)"
	runtime="$(scontrol show job-runtime $jobId)"
	nodelistFromSlurm="$SLURM_NODELIST"
else
	read -r runtime nodelistFromSlurm <<< "$(sacct -n -X -P -o elapsed,nodelist -j $jobId | tr "|" " ")"
fi

if ((!isNodelistSet)) ; then
	nodelist="$nodelistFromSlurm"
fi

# fetch the energies for all jobsteps and sum them up
mapfile -t energies <<< "$(sacct -n -P -o consumedEnergyRaw -j ${jobId} | grep -v '^$')"
consumedEnergy="$(IFS=+ ; echo "${energies[*]}" | bc)"

stopTime informationCollectionTime



#########################
# Function definitions. #
#########################

# errorExit <error-message>
# If <error-message> is not empty, print it to stderr (along with the note to inform the sysadmin) and exit the script with an error status.
# Does not return if <error-message> contains something.
function errorExit() {
	if [[ -n "$1" ]] ; then
		echo "$1" >&2
		echo please inform your system administrator about this >&2
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

# readConfig <config-path>
# This function parses the config file and sets the global variables accordingly.
function readConfig() {
	startTime configReadTime

	local configFile="$1"
	# Check preconditions
	# This is rather defensive, considering that typical usage will have this script run as root. We don't want no nasty surprises.
	local errorMessage=
	if [[ -O "$configFile" && -G "$configFile" ]] ; then
		if [[ "$configFile" = "$(find "$configFile" -perm /022 2>/dev/null)" ]] ; then
			local errorMessage="config file must not be writable by other users"
		fi
	else
		local errorMessage="config file must be owned by the user executing this script"
	fi
	configErrorExit "$errorMessage"

	export currency=

	export nodeSetNames=
	export nodeSets=
	export nodeSetsCount=0
	local curNodeSet=

	export rateNames=
	export rateValues=
	export rateTypes=
	export rateNodeSets=
	export rateCount=0
	while read -r cmd arguments ; do
		case $cmd in
			(currency)
				if [[ -n "$currency" ]] ; then
					errorMessage="$(echo "$errorMessage"; echo "error: currency command used twice")"
				fi
				currency="$arguments"
				;;
			(nodes)
				read -r name nodes <<< "$arguments"
				curNodeSet=$nodeSetsCount
				nodeSetNames[curNodeSet]="$name"
				nodeSets[curNodeSet]="$nodes"
				((nodeSetsCount++))
				;;
			(rate)
				if [[ -z "$curNodeSet" ]] ; then
					errorMessage="$(echo "$errorMessage"; echo "error: 'rate' command used before the first 'nodes' command")"
				fi

				read -r name value unit <<< "$arguments"
				rateNames[rateCount]="$name"
				rateNodeSets[rateCount]="$curNodeSet"

				rateValues[rateCount]="$value*$(unit2Factor $unit)"
				rateValues[rateCount]="$(bc <<< "${rateValues[rateCount]}" || echo error)"
				if [[ ${rateValues[rateCount]} = error ]] ; then
					errorExit "job-cost-meter internal error: bc call failed"
				fi
				rateTypes[rateCount]="time"

				((rateCount++))
				;;
			(energy-rate)
				if [[ -z "$curNodeSet" ]] ; then
					errorMessage="$(echo "$errorMessage"; echo "error: 'energy-rate' command used before the first 'nodes' command")"
				fi

				read -r name value unit <<< "$arguments"
				rateNames[rateCount]="$name"
				rateNodeSets[rateCount]="$curNodeSet"

				rateValues[rateCount]="$value*$(energyUnit2Factor $unit)"
				rateValues[rateCount]="$(bc <<< "${rateValues[rateCount]}" || echo error)"
				if [[ ${rateValues[rateCount]} = error ]] ; then
					errorExit "job-cost-meter internal error: bc call failed"
				fi
				rateTypes[rateCount]="energy"

				((rateCount++))
				;;
			(*)
				errorMessage="$(echo "$errorMessage"; echo "error: unknown command '$cmd'")"
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

	stopTime configReadTime
}

# expandNodeList <nodelist>
# Write the sorted list of individual node names to stdout.
function expandNodeList() {
	scontrol show hostnames "$1" | sort -u
}

# countMatchingMachines <nodelist1-var> <nodelist1-count> <nodelist2>
# This function takes three arguments: The first is the name of a variable that contains an expanded host list, the second argument gives the count of nodes in that list,
# the third is any SLURM-style node list against which the list contained in the variable passed as the first argument is matched.
# Returns the count of nodes which are part of both lists.
#
# The heavy lifting here is done exclusively by `sort -u` and `wc -l`.
# This is over 200 times faster than assigning the two lists to shell arrays, and doing the counting with shell code.
function countMatchingMachines() {
	local hostnames2="$(expandNodeList "$3")"

	local hostnames1Count="$(wc -l <<< "${!1}")"
	local hostnames2Count="$(wc -l <<< "$hostnames2")"
	local totalHostnameCount="$((cat <<< "${!1}" ; cat <<< "$hostnames2") | sort -u | wc -l)"

	echo $(( hostnames1Count + hostnames2Count - totalHostnameCount))
}

# printCostEstimate
# Estimate the total cost of the current job and print a human readable description of that to stdout.
#
# Requires that `readConfig` has been called first!
function printCostEstimate() {
	startTime rateCalculationTime

	local runtimeHours runtimeMinutes runtimeSeconds
	read runtimeHours runtimeMinutes runtimeSeconds <<< "${runtime//:/ }"
	local runtimeSeconds="$((${runtimeSeconds#0} + 60*(${runtimeMinutes#0} + 60*(${runtimeHours#0}))))"	#strip leading zeros to stop bash from interpreting our numbers as octal!
	unset -v runtimeHours runtimeMinutes

	local outputType= outputField1= outputField2=
	export outputLineCount=0
	local totalCost=0
	local lastNodeSet=-1
	expandedNodeList="$(expandNodeList "$nodelist")"
	nodeCount="$(wc -l <<< "$expandedNodeList")"
	for ((i = 0; i < rateCount; i++)) ; do
		local curNodeSet="${rateNodeSets[i]}"

		startTime groupMatchTime
		local curNodeCount="$(countMatchingMachines expandedNodeList "$nodeCount" "${nodeSets[curNodeSet]}")"
		stopTime groupMatchTime

		if ((curNodeCount)) ; then
			if ((curNodeSet != lastNodeSet)) ; then
				if ((outputLineCount)) && [[ "${outputType[outputLineCount-1]}" == nodeset ]] ; then
					#there were no valid rates in the last nodeset, delete it
					((outputLineCount--))
				fi
				local lastNodeSet="$curNodeSet"
				outputType[outputLineCount]=nodeset
				outputField1[outputLineCount]="${nodeSetNames[curNodeSet]}"
				outputField2[outputLineCount]="$curNodeCount"
				((outputLineCount++))
			fi

			case "${rateTypes[i]}" in
				(time)
					#the division rescales the unit from m/a to 1/s
					outputType[outputLineCount]=rate
					outputField1[outputLineCount]="${rateNames[i]}"
					outputField2[outputLineCount]="$(bc <<< "scale=10; ${rateValues[i]}*$curNodeCount*$runtimeSeconds/(1000*3600*24*365)")"
					local totalCost="$totalCost + ${outputField2[outputLineCount]}"
					((outputLineCount++))
					;;
				(energy)
					if [[ "$consumedEnergy" != 0.000000 ]] ; then	#only print this if energy was actually measured
						#the division rescales the unit from m/kWh to 1/Ws
						outputType[outputLineCount]=rate
						outputField1[outputLineCount]="${rateNames[i]}"
						outputField2[outputLineCount]="$(bc <<< "scale=10; ${rateValues[i]}*$consumedEnergy/(1000*1000*3600)")"
						local totalCost="$totalCost + ${outputField2[outputLineCount]}"
						((outputLineCount++))
					fi
					;;
				(*) errorExit "job-cost-meter internal error: unexpected value of \${rateType[i]}: '${rateType[i]}'" ;;
			esac
		fi
	done
	local totalCost="$(bc <<< "scale=10; $totalCost")"

	stopTime rateCalculationTime
	startTime outputTime

	#If we perform redirection, we need to drop priviledges first to avoid non-priviledged users playing tricks with root.
	if ((redirection)) ; then
		subshell="su -s $SHELL $user"
	else
		subshell="$SHELL"
	fi
	$subshell <<- EOF
		if (($redirection)) ; then
			exec 1>>"$stdout" 2>>"$stderr"
		fi
		cd "$jobWorkDir"

		#import the array variables into the subshell
		outputType=(${outputType[*]})
		outputField1=(${outputField1[*]})
		outputField2=(${outputField2[*]})

		widthColumn1=0
		for ((i = 0; i < outputLineCount; i++)) ; do
			field1="\${outputField1[i]}"
			length=\${#field1}
			if ((length > widthColumn1)) ; then
				widthColumn1=\$length
			fi
		done

		case "$verbosity" in
			(quiet)
				printf "%.2f\n" "$totalCost"
				;;

			(short)
				printf "job cost estimate: %.2f %s\n" "$totalCost" "$currency"
				;;

			(verbose)
				totalWidth=\$((4 + widthColumn1 + 2 + 12 + 1 + ${#currency}))
				bar="\$(printf "%*s" \$totalWidth "")"
				bar="\${bar// /=}"
				title="job cost estimate"
				titleLength=\${#title}

				echo
				echo "\$bar"
				printf "%*s\n" "\$(( (totalWidth + titleLength)/2 ))" "\$title"
				echo "\$bar"
				echo
				echo "($(scontrol show hostnames "$nodelist" | sort -u | wc -l) nodes total)"
				for ((i = 0; i < outputLineCount; i++)) ; do
					field1="\${outputField1[i]}" field2="\${outputField2[i]}"
					case "\${outputType[i]}" in
						(rate)
							printf "    %s: %*s%12.2f %s\n" "\$field1" \$((widthColumn1 - \${#field1})) "" "\$field2" "$currency"
							;;
						(nodeset)
							printf "%s (%s nodes):\n" "\$field1" "\$field2"
							;;
						(*) errorExit "job-cost-meter internal error: unexpected value of \\\${outputType[i]}: '\${outputType[i]}'" ;;
					esac
				done
				printf "%*s       -------------%s\n" "\$((4 + widthColumn1 + 2 - 7))" "" ${currency//?/-}
				printf "total:%*s %12.2f %s\n" "\$((4 + widthColumn1 + 2 - 7))" "" "$totalCost" "$currency"
				echo
				echo "\$bar"
				echo
				;;

			(json)
				echo -e '['
				for ((i = 0; i < outputLineCount; i++)) ; do
					field1="\${outputField1[i]}" field2="\${outputField2[i]}"
					case "\${outputType[i]}" in
						(rate)
							if [[ "\$firstRate" == false ]] ; then
								echo ,
							fi
							printf '\t\t\t{ "rate" : "%s", "cost" : %.2f }' "\$field1" "\$field2"
							firstRate="false"
							;;
						(nodeset)
							if ((i)) ; then
								echo
								echo -e '\t\t]'
								echo -e '\t},'
							fi
							echo -e "\t{"
							echo -e '\t\t"nodeset" : "'"\$field1"'",'
							echo -e '\t\t"rates" : ['
							firstRate="true"
							;;
						(*) errorExit "job-cost-meter internal error: unexpected value of \\\${outputType[i]}: '\${outputType[i]}'" ;;
					esac
				done
				echo
				echo -e '\t\t]'
				echo -e '\t}'
				echo -e ']'
				;;
			(*) errorExit "job-cost-meter internal error: unexpected value of \\\$verbosity: '$verbosity'" ;;
		esac
	EOF

	stopTime outputTime
}



#################################
# The main() code, so to speak. #
#################################

if readConfig "$configFile" ; then
	printCostEstimate
fi

stopTime totalTime

if ((doProfiling && !redirection)) ; then
	cat >&2 <<- EOF
		total time: $totalTime seconds
		    time to parse script arguments: $argParseTime seconds
		    time to collect job information: $informationCollectionTime seconds
		    time to read configuration: $configReadTime seconds
		    time to calculate rates: $rateCalculationTime seconds
		        time for nodelist matching = $groupMatchTime seconds
		    time for output = $outputTime seconds
	EOF
fi
