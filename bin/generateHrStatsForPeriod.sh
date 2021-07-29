#! /bin/bash

HERE=$( dirname "$0" )
PGM_BASENAME=$( basename "$0" )

: ${STAT_DATA_DIR:="/var/pc_stats"}

: ${CSV_SEPARATOR:=','}

#
# check arg = week number
#

Usage ()
{
    msg="$@"
    (
	echo "ERROR: ${msg}"
	echo "Usage ${PGM_BASENAME} [-w|--week <week number>] [-o|--out <output csv name>]"
	echo "	If week number is a negative integer, specifies a relative week number to current week number"
    ) 1>&2
    exit 1
}


while [[ -n "$1" ]]
do
     case "$1" in
	-w | --week )
	    shift
	    week_number_arg="$1"
	    ;;
	-o | --out )
	    shift
	    outfile_arg="$1"
	    ;;
	* )
	    Usage "bad arg: $1"
	    exit 1
	    ;;
     esac
     shift
done

#
# check if any mandatory arg has been provided
#
if [[ -z "${week_number_arg}" ]]
then
    Usage "missing args"
    exit 1
fi

#
# check arg consistency
#

if expr "${week_number_arg}" + 0 1>/dev/null 2>/dev/null
then
    :
else
    Usage "week number argument should be an integer"
    #NOT REACHED
fi

if [[ ${week_number_arg} -lt 0 ]]
then
    # compute a relative week number
    current_week_number=$( date '+%V' )
    abs_week_number=$(( ${current_week_number} + ${week_number_arg} ))
    if [[ ${abs_week_number} -lt 1 ]]
    then
	Usage "relative week number ${week_number_arg} is too large"
	#NOT REACHED
    else
	week_number=${abs_week_number}
    fi
else
    # its an absolute week number in [1..53]
    if [[ ${week_number_arg} -le 53 ]]
    then
	week_number=${week_number_arg}
    else
	Usage "week number should be in range [1..53]"
	#NOT REACHED
    fi
fi

: ${STATS_FOR_YEAR:=$( date '+%Y' )}

#
# Check the folder containing the stats
# =====================================

if [[ -d "${STAT_DATA_DIR}" ]] # && [[ -r "${STAT_DATA_DIR}" ]]
then
    :
else
    Usage "could not acces stat folder \"${STAT_DATA_DIR}\""
    exit 1
    #NOT REACHED
fi

#
# Get all files of the week
#

# example file name: stat_Y=2021=Y_M=03=M_D=24=D_d=3=d_W=12=W_156.txt
all_stat_files=$(
    ls -1 "${STAT_DATA_DIR}/"stat_Y=${STATS_FOR_YEAR}=Y*W=${week_number}=W*.txt 2>/dev/null
)

generateCSVStatLine ()
{
    # sample line:
    # "1616779865" "bernhara" "login" "success" "90.8.128.173" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36"
    
    line="$@"
    # echo ">>>>>>>>>>>>>>>>>>>>>${line}<<<<<<<<<<<<<<<<<<<<<"

    protected_line=$(
	echo "${line}" | \
	    sed \
		-e "s/^\"/'/" \
		-e "s/\" \"/' '/g" \
		-e "s/\"$/'/"
   )
    
    # echo ">>>>>>>>>>>>>>>>>>>>>${protected_line}<<<<<<<<<<<<<<<<<<<<<"

    # FIXME: eval should ne be required
    eval declare -a tab=( "${protected_line}" )

    epoch_time=${tab[0]}
    action=${tab[1]}
    param=${tab[2]}
    status=${tab[3]}
    real_ip=${tab[4]}
    user_agent=${tab[5]}

    pc_login=''
    doc_ref=''
    vin=''

    case "${action}" in

	"login" )
	    pc_login="${param}"
	    ;;

	"documentation" )
	    doc_ref="${param}"
	    ;;

	"vin" )
	    vin="${param}"
	    ;;

	*)
	    echo "ERROR: bas action ${action}" 1>&2
	    echo ">>>>> ${line}" 1>&2
	    ;;
    esac
      

    csv_date=$( date --date "@${epoch_time}" '+%d/%m/%Y %T' )
    echo "\"${csv_date}\"${CSV_SEPARATOR}\"${action}\"${CSV_SEPARATOR}\"${status}\"${CSV_SEPARATOR}\"${pc_login}\"${CSV_SEPARATOR}\"${doc_ref}\"${CSV_SEPARATOR}\"${vin}\"${CSV_SEPARATOR}\"${real_ip}\"${CSV_SEPARATOR}\"${user_agent}\""

}

#
# generate CSV file
#

rm -f /tmp/stats.csv
(
    echo "\"Date\"${CSV_SEPARATOR}\"Action\"${CSV_SEPARATOR}\"Status\"${CSV_SEPARATOR}\"login PC\"${CSV_SEPARATOR}\"Reference Document\"${CSV_SEPARATOR}\"VIN\"${CSV_SEPARATOR}\"Adresse IP\"${CSV_SEPARATOR}\"Navigateur\""

    sort \
	-n \
	-k 1 \
	-o /tmp/stats_sorted.txt \
	${all_stat_files}

    cat /tmp/stats_sorted.txt | \
	while read -r line
	do
	    generateCSVStatLine "${line}"
	done
) > /tmp/stats.csv

ssconvert --verbose '--import-type=Gnumeric_stf:stf_csvtab' '--export-type=Gnumeric_Excel:xlsx2' /tmp/stats.csv /tmp/stats.xlsx

# if outfile arg is provided, redirect output
if [[ -n "${outfile_arg}" ]]
then
    cp /tmp/stats.xlsx "${outfile_arg}"
else
    cat /tmp/stats.xlsx
fi
