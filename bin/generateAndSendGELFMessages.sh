#! /bin/bash

HERE=$( dirname "$0" )
PGM_BASENAME=$( basename "$0" )

: ${STAT_DATA_DIR:="/var/pc_stats"}

: ${RUN_STATES_DIR:="/var/run_states"}

: ${GELF_UDP_HOST=''}
: ${GELF_UDP_PORT=''}

#
# check arg = week number
#

Usage ()
{
    msg="$@"
    (
	echo "ERROR:  ${msg}"
	echo "Usage ${PGM_BASENAME} --env.GELF_UDP_HOST <hostname of GELF udp server> --env.GELF_UDP_PORT <UDP port number of GELF server>" 
    ) 1>&2
    exit 1
}


while [[ -n "$1" ]]
do
     case "$1" in
	--env.GELF_UDP_HOST )
	    shift
	    GELF_UDP_HOST="$1"
	    ;;
	--env.GELF_UDP_PORT )
	    shift
	    GELF_UDP_PORT="$1"
	    ;;
	* )
	    Usage "bad arg: $1"
	    exit 1
	    ;;
     esac
     shift
done

echo "NOT YET IMPLEMENTED" 1>&2
exit 1

#
# check if any mandatory arg has been provided
#
if [[ -n "${GELF_UDP_HOST}" ]]
then
    Usage "GELF_UDP_HOST not specified"
    exit 1
fi

if [[ -n "${GELF_UDP_PORT}" ]]
then
    Usage "GELF_UDP_PORT not specified"
    exit 1
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

#
# example file name: stat_Y=2021=Y_M=03=M_D=24=D_d=3=d_W=12=W_156.txt
#
if [[ -n "${week_number_arg}" ]]
then
    all_stat_files=$(
	ls -1 "${STAT_DATA_DIR}/"stat_Y=${STATS_FOR_YEAR}=Y*_W=${week_number}=W_*.txt 2>/dev/null
		  )
fi

if [[ -n "${month_number_arg}" ]]
then
    all_stat_files=$(
	ls -1 "${STAT_DATA_DIR}/"stat_Y=${STATS_FOR_YEAR}=Y*_M=${month_number}=M_*.txt 2>/dev/null
		  )
fi

if [[ -z $( echo "${all_stat_files}" | tr -d '[:blank:]' ) ]]
then
    # We got a empty string => no file matched
    # generate a simple empty file
    touch /tmp/no_rproxy_stats.txt
    all_stat_files=/tmp/no_rproxy_stats.txt
fi
    

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
