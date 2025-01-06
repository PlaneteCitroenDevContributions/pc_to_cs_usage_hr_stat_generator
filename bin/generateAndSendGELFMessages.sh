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


# FIXME: this function may be removed
normalize_ldap_login ()
{
    raw_ldap_login="$1"
    normalized_login=$(
	echo "${raw_ldap_login}" | tr '[:upper:]' '[:lower:]'
    )
    echo "${normalized_login}"
}



# FIXME: this function may be removed
remember_to_cache_attribute_for_ip ()
{
    real_ip="$1"
    attribute_name_to_cache="$2"
    attribute_value_to_cache="$3"

    echo "${attribute_value_to_cache}" > "${RUN_STATES_DIR}/cache_data_${real_ip}_last_value_for_${attribute_name_to_cache}"
}

# FIXME: this function may be removed
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
	    if grep -q '"error":true' /tmp/vin.json
	    then
		# resulting json mentions an error
		# TODO: manage these errors
		echo "ERROR while fetching url ${url} to decode VIN ${vin}: result $( cat /tmp/vin.json )" 1>&2
		return 1
		# NOT REACHED
	    else
		cp /tmp/vin.json "${cache_file_name}"
	    fi
	else
	    echo "ERROR while fetching url ${url} to decode VIN ${vin}: code ${curl_http_code}" 1>&2
	    return 1
	    # NOT REACHED
	fi
    fi

    cat /tmp/vin.json | jq -c '."decode"|.[]' > "${vin_fieldlist_file_name}"
}

map_vin_json_field_name_to_gelf_attribute ()
{
    json_field_name="$1"

    case "${json_field_name}" in
	"XXVehicle ID")
	    gelf_attribute="VehicleID_TTTT"
	    ;;
	*)
	    gelf_attribute_suffix=$( tr '[:blank:]' _ <<< "${vin_field_name}")
	    ;;
    esac

    echo "_vin_data_${gelf_attribute_suffix}"
}

get_vin_field_value_from_file ()
{
    # TODO: this should be replaced be a simple "jq" expression
    
    vin_field_label="$1"
    vin_fieldlist_file_name="$2"

    field_value=''

    field_line=$( grep --max-count=1 --fixed-strings '"label":"'"${vin_field_label}"'"' "${vin_fieldlist_file_name}" )
    if [[ -n "${field_line}" ]]
    then
	field_value=$( echo "${field_line}" | jq '.value' )
	echo "${field_value}"
	return 0
    else	
	echo ''
	return 1
    fi
}

generateAndSendGELFLog ()
{
    # FIXME: this example is no more relevant
    #!!! 1736156446 bernhara login raphael.bernhard@orange.fr success 86.241.57.40 Mozilla/5.0\ \(Windows\ NT\ 10.0\;\ Win64\;\ x64\)\ AppleWebKit/537.36\ \(KHTML\,\ like\ Gecko\)\ Chrome/131.0.0.0\ Safari/537.36
    # '1616779865' 'bernhara' 'login' 'success' '90.8.128.173' 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36'
    
    escaped_fields_line="$@"
    for i in "$@"
    do
	echo "XXXX${i}XXXX" 1>&2
    done
    
    # echo ">>>>>>>>>>>>>>>>>>>>>${protected_line}<<<<<<<<<<<<<<<<<<<<<"

    eval declare -a escaped_strings_table=( ${escaped_fields_line} )

    epoch_time="${escaped_strings_table[0]}"
    user="${escaped_strings_table[1]}"
    action="${escaped_strings_table[2]}"
    param="${escaped_strings_table[3]}"
    status="${escaped_strings_table[4]}"
    real_ip="${escaped_strings_table[5]}"
    eval user_agent=${escaped_strings_table[6]}

    doc_ref=''
    vin=''

    case "${action}" in

	"login" )
	    normalized_pc_login="${param}"
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

	if [[ -n "${user}" ]]
	then
	    echo -n ', "_pc_login": "'${user}'"'
	fi

	if [[ -n "${normalized_pc_login}" ]]
	then
	    #FIXME: normalized_pc_login is still used since old logs have been generated with that field
	    # but it should be "remote_user"
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
	    normalized_vin=$( tr '[:lower:]' '[:upper:]' <<< "${vin}" )

	    echo -n ', "_vin": "'${normalized_vin}'"'

	    # TODO:
	    # decode_vin_fields_to_file should return a status to check if decoding has been performed
	    # will replace the check of the existance of the file
	    rm -f /tmp/vin_fieldlist.json
	    decode_vin_fields_to_file "${normalized_vin}" /tmp/vin_fieldlist.json
	    #!! FOR TEST: decode_vin_fields_to_file "XXXDEF1GH23456789" /tmp/vin_fieldlist.json

	    if [ -r /tmp/vin_fieldlist.json ]
	    then
		# decoding worked since we could generate the file containing the fields

		for vin_field_name in \
		    "Vehicle ID" \
			"Make" \
			"Model" \
			"Model Year" \
			"Series" \
			"Vehicle Specification" \
			"Engine Displacement (ccm)" \
			"Fuel Type - Primary" \
			"Engine Power (HP)" \
			"Engine Code" \
			"Transmission" \
			"Number of Gears" \
			"Emission Standard" \
			"Suspension" \
			"Production Stopped" \
			"Production Started" \
			"Engine (full)"
		do
		    if f=$( get_vin_field_value_from_file "${vin_field_name}" /tmp/vin_fieldlist.json )
		    then
			gelf_field_name=$( map_vin_json_field_name_to_gelf_attribute "${vin_field_name}" )
			echo -n ', "'"${gelf_field_name}"'": '"${f}"
		    fi
		done
	    fi
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
    set -- ${line}
    treated_time_stamp=$( generateAndSendGELFLog "$@" )
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
