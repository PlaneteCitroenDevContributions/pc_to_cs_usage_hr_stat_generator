#! /bin/bash

if [[ -n "${DEBUG_BASH}" ]]
then
    set -x
fi

HERE=$( dirname "$0" )
PGM_BASENAME=$( basename "$0" )

: ${STAT_DATA_DIR:="/var/pc_stats"}

: ${RUN_STATES_DIR:="/var/run_states"}

: ${GELF_UDP_HOST:=''}
: ${GELF_UDP_PORT:=''}
: ${SERVICE_NAME:='_dev_'}

: ${VINDECODER_EU_APIKEY:="_VINDECODER_EU_APIKEY_not_set"}
: ${VINDECODER_EU_SECRET:="_VINDECODER_EU_SECRET_not_set"}


: ${NO_TOUCH:='0'}

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

#
# args
#

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
	--env.SERVICE_NAME )
	    shift
	    SERVICE_NAME="$1"
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
if [[ -z "${GELF_UDP_HOST}" ]]
then
    Usage "GELF_UDP_HOST not specified"
    exit 1
fi

if [[ -z "${GELF_UDP_PORT}" ]]
then
    Usage "GELF_UDP_PORT not specified"
    exit 1
fi



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
# Get all files not teated since last call
#

if [[ -r "${RUN_STATES_DIR}/last_call.status" ]]
then
    all_stat_files=$(
	find "${STAT_DATA_DIR}" -newer "${RUN_STATES_DIR}/last_call.status" -type f -print
		  )
else
    all_stat_files=''
fi    

if [[ -z $( echo "${all_stat_files}" | tr -d '[:blank:]' ) ]]
then
    # We got a empty string => no file matched
    # generate a simple empty file
    touch /tmp/no_rproxy_stats.txt
    all_stat_files=/tmp/no_rproxy_stats.txt
fi
    

url_decode_string ()
{
    url_encoded_escaped_string="$1"
    backslahed_string=$(
	echo "${url_encoded_escaped_string}" | sed -e 's/%\([0-F][0-F]\)/\\x\1/g'
    )
   unescaped_string=$( echo -e "${backslahed_string}" )

    echo "${unescaped_string}"
}

normalize_ldap_login ()
{
    raw_ldap_login="$1"
    normalized_login=$(
	echo "${raw_ldap_login}" | tr '[:upper:]' '[:lower:]'
    )
    echo "${normalized_login}"
}



remember_to_cache_attribute_for_ip ()
{
    real_ip="$1"
    attribute_name_to_cache="$2"
    attribute_value_to_cache="$3"

    echo "${attribute_value_to_cache}" > "${RUN_STATES_DIR}/cache_data_${real_ip}_last_value_for_${attribute_name_to_cache}"
}

guess_from_cache_attribute_for_ip ()
{
    real_ip="$1"
    attribute_name_to_cache="$2"

    if [[ -r "${RUN_STATES_DIR}/cache_data_${real_ip}_last_value_for_${attribute_name_to_cache}" ]]
    then
	attribute_value_from_cache=$( cat "${RUN_STATES_DIR}/cache_data_${real_ip}_last_value_for_${attribute_name_to_cache}" )
    else
	attribute_name_to_cache=''
    fi

    echo "${attribute_value_from_cache}"
}

decode_vin_fields_to_file ()
{
    vin="$1"
    vin_fieldlist_file_name="$2"

    cache_file_name="${RUN_STATES_DIR}/cache_data_vin_${vin}.json"

    if [[ -r "${cache_file_name}" ]]
    then
	cp "${cache_file_name}" /tmp/vin.json
    else

	# try to get VIN

	rm -f /tmp/vin.json

	apiPrefix="https://api.vindecoder.eu/3.2"
	apikey="${VINDECODER_EU_APIKEY}"
	secretkey="${VINDECODER_EU_SECRET}"
	id="decode"

	key="${vin}|${id}|${apikey}|${secretkey}"
	sha1_key=$( echo -n "${key}" | sha1sum )

	controlsum=$( echo "${sha1_key}" | cut -c1-10 )

	url="${apiPrefix}/${apikey}/${controlsum}/${id}/${vin}.json"

	curl_http_code=$( curl -s -o /tmp/vin.json -w "%{http_code}" "${url}" )
	if [ "${curl_http_code}" -eq 200 ]
	then
	    # "Got 200! All done!"
	    # keep result in cache
	    cp /tmp/vin.json "${cache_file_name}"
	else
	    echo "ERROR while fetching url ${url} to decode VIN ${vin}: code ${curl_http_code}" 1>&2
	    return
	fi
    fi

    cat /tmp/vin.json | jq -c '."decode"|.[]' > /tmp/vin_fieldlist.json
    sed \
	-e 's/{"label"://' \
	-e 's/,"value":/:/' \
	-e 's/}//' \
	/tmp/vin_fieldlist.json > "${vin_fieldlist_file_name}"
}

get_vin_field_value_from_file ()
{
    vin_field_label="$1"
    vin_fieldlist_file_name="$2"

    field_value=''

    field_line=$( sed -n -e '/^"'"${vin_field_label}"'":/p' "${vin_fieldlist_file_name}" )
    if [[ -n "${field_line}" ]]
    then
	field_value=$( cut -d: -f 2 <<< "${field_line}" )
	echo "${field_value}"
	return 0
    else	
	echo ''
	return 1
    fi

}

generateAndSendGELFLog ()
{
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
	    remember_to_cache_attribute_for_ip ${real_ip} "pc_login" "${pc_login}" 
	    ;;

	"documentation" )
	    doc_ref="${param}"
	    pc_login=$( guess_from_cache_attribute_for_ip ${real_ip} "pc_login" )
	    ;;

	"vin" )
	    vin="${param}"
	    pc_login=$( guess_from_cache_attribute_for_ip ${real_ip} "pc_login" )
	    ;;

	*)
	    echo "ERROR: bas action ${action}" 1>&2
	    echo ">>>>> ${line}" 1>&2
	    ;;
    esac
      
    gelf_headers='"version": "1.1",
  "host": "'${HOSTNAME}'",
  "short_message": "generated by '${PGM_BASENAME}' at '$(date)'",
  "full_message": "NA",
  "level": 3,
'
    # generated timestamp
    gelf_headers=${gelf_headers}' "timestamp": '${epoch_time}

    # compute day of week for timestamp
    day_of_week=$( date "--date=@${epoch_time}" '+%u' )
    gelf_headers=${gelf_headers}', "_day_of_week": '${day_of_week}

    # generate each specific field
    gelf_body=$(
	echo -n '"_pc_service": "'${SERVICE_NAME}'"'

	echo -n ', "_action": "'${action}'"'
    
	if [[ -n "${status}" ]]
	then
	    echo -n ', "_status": "'${status}'"'
	fi

	if [[ -n "${pc_login}" ]]
	then
	    url_decoded_pc_login=$( url_decode_string "${pc_login}" )
	    echo -n ', "_pc_login": "'${url_decoded_pc_login}'"'

	    normalized_pc_login=$( normalize_ldap_login "${pc_login}" )
	    echo -n ', "_pc_login_normalized": "'${normalized_pc_login}'"'
	fi

	if [[ -n "${real_ip}" ]]
	then
	    echo -n ', "_real_ip": "'${real_ip}'"'
	fi

	if [[ -n "${user_agent}" ]]
	then
	    echo -n ', "_user_agent": "'${user_agent}'"'
	fi

	if [[ -n "${vin}" ]]
	then
	    echo -n ', "_vin": "'${vin}'"'

	    decode_vin_fields_to_file "XXXDEF1GH23456789" /tmp/vin_fieldlist.txt
	    # TODO: decode provided VIN
	    #!!! decode_vin_fields_to_file "${vin}" /tmp/vin_fieldlist.txt

	    for vin_field_name in "Model" "Production Stopped" "Production Started" "Fuel Type - Primary" "Model Year" "Series" "Transmission" "Engine (full)"
	    do
		if f=$( get_vin_field_value_from_file "${vin_field_name}" /tmp/vin_fieldlist.txt )
		then
		    gelf_field_name="_vin_data_"$( tr '[:blank:]' _ <<< "${vin_field_name}")
		    echo -n ', "'"${gelf_field_name}"'": '"${f}"
		fi
	    done
	fi
	
	if [[ -n "${doc_ref}" ]]
	then
	    echo -n ', "_doc_ref": "'${doc_ref}'"'
	fi
	     )

    gelf_line='{ '${gelf_headers}', '${gelf_body}' }'

    # FIXME: make this log optional
    echo 'vvvvvvvvvvvvvvvvvvvvvvvvvv' 1>&2
    echo "${gelf_line}" 1>&2
    echo '^^^^^^^^^^^^^^^^^^^^^^^^^^' 1>&2

    echo -n "${gelf_line}" | nc -v -w 3 -u "${GELF_UDP_HOST}" "${GELF_UDP_PORT}"
    nc_status=$?

    if [[ ${nc_status} -eq 0 ]]
    then
       echo "${epoch_time}"
       return 0
    else
	echo ''
	return 1
    fi
}

#
# reorder all records in timestamp order
#
sort \
    -n \
    -k 1 \
    -o /tmp/time_ordered_stats.txt \
${all_stat_files}


last_log_generation_timestamp=''
while read -r line
do
    treated_time_stamp=$( generateAndSendGELFLog "${line}" )
    generation_status=$?
    if [[ ${generation_status} -eq 0 ]]
    then
	last_log_generation_timestamp=${treated_time_stamp}
    else
	last_treated_time_stamp=''
	break
	# NOT REACHED
    fi
done < /tmp/time_ordered_stats.txt

if [[ -n "${last_log_generation_timestamp}" && "${NO_TOUCH}" != '1' ]]
then
    last_call_file_timestamp=$(( ${last_log_generation_timestamp} + 1 ))
    touch "--date=@${last_call_file_timestamp}" "${RUN_STATES_DIR}/last_call.status"
fi
