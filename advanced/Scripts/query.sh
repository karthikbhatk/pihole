#!/usr/bin/env bash
# shellcheck disable=SC1090

# Pi-hole: A black hole for Internet advertisements
# (c) 2018 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Query Domain Lists
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# Globals
piholeDir="/etc/pihole"
GRAVITYDB="${piholeDir}/gravity.db"
DBFILE="${piholeDir}/pihole-FTL.db"
options="$*"
all=""
exact=""
blockpage=""
matchType="match"
# Source pihole-FTL from install script
pihole_FTL="${piholeDir}/pihole-FTL.conf"
if [[ -f "${pihole_FTL}" ]]; then
  source "${pihole_FTL}"
fi

# Set this only after sourcing pihole-FTL.conf as the gravity database path may
# have changed
gravityDBfile="${GRAVITYDB}"
gravityOLDfile="$(dirname -- "${gravityDBfile}")/gravity_old.db"
ftlDBfile="${DBFILE}"

colfile="/opt/pihole/COL_TABLE"
source "${colfile}"

# Scan an array of files for matching strings
scanList(){
    # Escape full stops
    local domain="${1}" esc_domain="${1//./\\.}" lists="${2}" type="${3:-}"

    # Prevent grep from printing file path
    cd "$piholeDir" || exit 1

    # Prevent grep -i matching slowly: https://bit.ly/2xFXtUX
    export LC_CTYPE=C

    # /dev/null forces filename to be printed when only one list has been generated
    case "${type}" in
        "exact" ) grep -i -E -l "(^|(?<!#)\\s)${esc_domain}($|\\s|#)" ${lists} /dev/null 2>/dev/null;;
        # Iterate through each regexp and check whether it matches the domainQuery
        # If it does, print the matching regexp and continue looping
        # Input 1 - regexps | Input 2 - domainQuery
        "regex" ) 
            for list in ${lists}; do
                if [[ "${domain}" =~ ${list} ]]; then
                    printf "%b\n" "${list}";
                fi
            done;;
        *       ) grep -i "${esc_domain}" ${lists} /dev/null 2>/dev/null;;
    esac
}

# function to count new domain entries since last gravity run
CountNewDomains() {
  printf %s "  ${INFO} Running query, please be patient..."
  # store query result (count) in variable
  newdomainentries="$(
    sqlite3 "${gravityDBfile}" << EOSQL
      ATTACH '${gravityOLDfile}' AS old;
      SELECT count(DISTINCT domain) FROM gravity WHERE domain NOT IN (SELECT domain FROM old.gravity);
EOSQL
      )"
  printf '\r%s\n' "$(tput el)  ${INFO} ${newdomainentries} new domain(s) found."
  exit 0
}

# function to list new domain entries since last gravity run
ListNewDomains() {
  if [ -z "${all}" ]; then
    QueryLimit="Limit 100"
  fi
  printf %s "  ${INFO} Running query, please be patient..."
  # store query result (list) in array
  # order by adlist.address makes the query slower, but the result is more useful
  mapfile -t newdomainarray < <( sqlite3 "${gravityDBfile}" << EOSQL
      ATTACH '${gravityOLDfile}' AS old;
      SELECT domain, '' || adlist.address || '' FROM gravity
      JOIN adlist ON adlist.id = gravity.adlist_id
      WHERE domain NOT IN (SELECT domain FROM old.gravity)
      ORDER BY adlist.address ${QueryLimit};
EOSQL
      )
  if [ "${#newdomainarray[*]}" -eq 0 ]; then
    printf '\r%s\n' "$(tput el)  ${INFO} No new domains have been found."
    exit 0
  else
    printf '\r%s\n' "$(tput el)  ${INFO} ${#newdomainarray[*]} new domain(s) found."
  fi
  for (( j=0; j<"${#newdomainarray[@]}"; j++ )); do
    IFS='|'
    read -r domain urllist <<< "${newdomainarray[j]}"
    echo -e "  ${domain} (${COL_GREEN}${urllist}${COL_NC})"
  done
  if [[ -z "${all}" ]] && [[ "${#newdomainarray[*]}" -ge 100 ]]; then
    echo -e "  ${INFO} Over 100 new domains found.
        This can be overridden using the -all option"
  fi
  exit 0
}

# function to find blocked entries in the FTL database,
# present (new) in the latest (active) gravity database,
# and NOT present in the old gravity database.
FindNewBlockedDomains() {
  # Check if the OLD database exists.
  if [[ ! -f "${gravityOLDfile}" ]]; then
    echo -e "  ${CROSS}  Old database ${gravityOLDfile} doesn't exist."
    exit 1
  else
    # Check if the current database is more recent.
    if [[ $(sqlite3 "${gravityOLDfile}" "SELECT value FROM info \
              WHERE property IS 'updated';") \
        > \
          $(sqlite3 "${gravityDBfile}" "SELECT value FROM info \
              WHERE property IS 'updated';") ]]; then
      echo -e "  ${CROSS}  Old database ${gravityOLDfile} is more recent."
      exit 1
    fi
    # Run the queries
    printf %s "  ${INFO} Running queries, please be patient..."
    # Find the status 1 queries first
    mapfile -t domainarray < <( sqlite3 "${ftlDBfile}" << EOSQL
      ATTACH '${gravityDBfile}' AS new;
      ATTACH '${gravityOLDfile}' AS old;
      SELECT DISTINCT queries.domain, '' || adlist.address || '' FROM queries
      JOIN gravity ON new.gravity.domain = queries.domain
      JOIN adlist ON adlist.id = new.gravity.adlist_id
      WHERE queries.domain NOT IN (SELECT domain FROM old.gravity)
      AND queries.domain IN (SELECT domain FROM new.gravity)
      AND queries.status IN (1)
      AND timestamp > (SELECT value FROM new.info WHERE property = 'updated');
EOSQL
      )
    if [ ! "${#domainarray[@]}" -eq 0 ]; then
      for (( j=0; j<"${#domainarray[@]}"; j++ )); do
        IFS='|'
        read -r domain urllist <<< "${domainarray[j]}"
        printf '\r%s\n' "$(tput el)  ${INFO} Blocked: ${domain} (${COL_GREEN}${urllist}${COL_NC})"
      done
    fi
    # Now find the CNAME matches (status 9)
    mapfile -t cnamearray < <( sqlite3 "${ftlDBfile}" << EOSQL
      ATTACH '${gravityDBfile}' AS new;
      ATTACH '${gravityOLDfile}' AS old;
      SELECT DISTINCT queries.domain, '' || adlist.address || '', queries.additional_info FROM queries
      JOIN gravity ON new.gravity.domain = queries.additional_info
      JOIN adlist ON adlist.id = new.gravity.adlist_id
      WHERE queries.additional_info NOT IN (SELECT domain FROM old.gravity)
      AND queries.additional_info IN (SELECT domain FROM new.gravity)
      AND queries.status IN (9)
      AND timestamp > (SELECT value FROM new.info WHERE property = 'updated');
EOSQL
      )
    if [ ! "${#cnamearray[@]}" -eq 0 ]; then
      for (( j=0; j<"${#cnamearray[@]}"; j++ )); do
        IFS='|'
        read -r domain urllist additional_info <<< "${cnamearray[j]}"
        printf '\r%s\n' "$(tput el)  ${INFO} Blocked: ${domain}. (${COL_BLUE}CNAME${COL_NC})"
        echo -e "        Domain: ${additional_info} (${COL_GREEN}${urllist}${COL_NC})"
      done
    fi
    if [[ "${#domainarray[@]}" -eq 0 && "${#cnamearray[@]}" -eq 0 ]]; then
      printf '\r%s\n' "$(tput el)  ${INFO} No new domains have been blocked yet."
    fi
  fi
  exit 0
}

if [[ "${options}" == "-h" ]] || [[ "${options}" == "--help" ]]; then
    echo "Usage: pihole -q [option] <domain>
Example: 'pihole -q -exact domain.com'
Query the adlists for a specified domain

Options:
  -blocked            List blocked domains since last gravity run
  -countnew           Count new domain enties since last gravity run
  -listnew            List new domain entries since last gravity run
  -exact              Search the block lists for exact domain matches
  -all                Return all query matches within a block list
  -h, --help          Show this help dialog"
  exit 0
fi

# Handle valid options
if [[ "${options}" == *"-bp"* ]]; then
    exact="exact"; blockpage=true
else
    [[ "${options}" == *"-all"* ]] && all=true
    if [[ "${options}" == *"-exact"* ]]; then
        exact="exact"; matchType="exact ${matchType}"
    fi
    # Count new domain enties since last gravity run
    [[ "${options}" == *"-countnew"* ]] && CountNewDomains
    # List new domain enties since last gravity run
    [[ "${options}" == *"-listnew"* ]] && ListNewDomains
    # List blocked domains since last gravity run
    [[ "${options}" == *"-blocked"* ]] && FindNewBlockedDomains
fi

# Strip valid options, leaving only the domain and invalid options
# This allows users to place the options before or after the domain
options=$(sed -E 's/ ?-(bp|adlists?|all|exact) ?//g' <<< "${options}")

# Handle remaining options
# If $options contain non ASCII characters, convert to punycode
case "${options}" in
    ""             ) str="No domain specified";;
    *" "*          ) str="Unknown query option specified";;
    *[![:ascii:]]* ) domainQuery=$(idn2 "${options}");;
    *              ) domainQuery="${options}";;
esac

if [[ -n "${str:-}" ]]; then
    echo -e "${str}${COL_NC}\\nTry 'pihole -q --help' for more information."
    exit 1
fi

scanDatabaseTable() {
    local domain table type querystr result extra
    domain="$(printf "%q" "${1}")"
    table="${2}"
    type="${3:-}"

    # As underscores are legitimate parts of domains, we escape them when using the LIKE operator.
    # Underscores are SQLite wildcards matching exactly one character. We obviously want to suppress this
    # behavior. The "ESCAPE '\'" clause specifies that an underscore preceded by an '\' should be matched
    # as a literal underscore character. We pretreat the $domain variable accordingly to escape underscores.
    if [[ "${table}" == "gravity" ]]; then
      case "${exact}" in
          "exact" ) querystr="SELECT gravity.domain,adlist.address,adlist.enabled FROM gravity LEFT JOIN adlist ON adlist.id = gravity.adlist_id WHERE domain = '${domain}'";;
          *       ) querystr="SELECT gravity.domain,adlist.address,adlist.enabled FROM gravity LEFT JOIN adlist ON adlist.id = gravity.adlist_id WHERE domain LIKE '%${domain//_/\\_}%' ESCAPE '\\'";;
      esac
    else
      case "${exact}" in
          "exact" ) querystr="SELECT domain,enabled FROM domainlist WHERE type = '${type}' AND domain = '${domain}'";;
          *       ) querystr="SELECT domain,enabled FROM domainlist WHERE type = '${type}' AND domain LIKE '%${domain//_/\\_}%' ESCAPE '\\'";;
      esac
    fi

    # Send prepared query to gravity database
    result="$(sqlite3 "${gravityDBfile}" "${querystr}")" 2> /dev/null
    if [[ -z "${result}" ]]; then
        # Return early when there are no matches in this table
        return
    fi

    if [[ "${table}" == "gravity" ]]; then
      echo "${result}"
      return
    fi

    # Mark domain as having been white-/blacklist matched (global variable)
    wbMatch=true

    # Print table name
    if [[ -z "${blockpage}" ]]; then
        echo " ${matchType^} found in ${COL_BOLD}exact ${table}${COL_NC}"
    fi

    # Loop over results and print them
    mapfile -t results <<< "${result}"
    for result in "${results[@]}"; do
        if [[ -n "${blockpage}" ]]; then
            echo "π ${result}"
            exit 0
        fi
        domain="${result/|*}"
        if [[ "${result#*|}" == "0" ]]; then
            extra=" (disabled)"
        else
            extra=""
        fi
        echo "   ${domain}${extra}"
    done
}

scanRegexDatabaseTable() {
    local domain list
    domain="${1}"
    list="${2}"
    type="${3:-}"

    # Query all regex from the corresponding database tables
    mapfile -t regexList < <(sqlite3 "${gravityDBfile}" "SELECT domain FROM domainlist WHERE type = ${type}" 2> /dev/null)

    # If we have regexps to process
    if [[ "${#regexList[@]}" -ne 0 ]]; then
        # Split regexps over a new line
        str_regexList=$(printf '%s\n' "${regexList[@]}")
        # Check domain against regexps
        mapfile -t regexMatches < <(scanList "${domain}" "${str_regexList}" "regex")
        # If there were regex matches
        if [[  "${#regexMatches[@]}" -ne 0 ]]; then
            # Split matching regexps over a new line
            str_regexMatches=$(printf '%s\n' "${regexMatches[@]}")
            # Form a "matched" message
            str_message="${matchType^} found in ${COL_BOLD}regex ${list}${COL_NC}"
            # Form a "results" message
            str_result="${COL_BOLD}${str_regexMatches}${COL_NC}"
            # If we are displaying more than just the source of the block
            if [[ -z "${blockpage}" ]]; then
                # Set the wildcard match flag
                wcMatch=true
                # Echo the "matched" message, indented by one space
                echo " ${str_message}"
                # Echo the "results" message, each line indented by three spaces
                # shellcheck disable=SC2001
                echo "${str_result}" | sed 's/^/   /'
            else
                echo "π .wildcard"
                exit 0
            fi
        fi
    fi
}

# Scan Whitelist and Blacklist
scanDatabaseTable "${domainQuery}" "whitelist" "0"
scanDatabaseTable "${domainQuery}" "blacklist" "1"

# Scan Regex table
scanRegexDatabaseTable "${domainQuery}" "whitelist" "2"
scanRegexDatabaseTable "${domainQuery}" "blacklist" "3"

# Query block lists
mapfile -t results <<< "$(scanDatabaseTable "${domainQuery}" "gravity")"

# Handle notices
if [[ -z "${wbMatch:-}" ]] && [[ -z "${wcMatch:-}" ]] && [[ -z "${results[*]}" ]]; then
    echo -e "  ${INFO} No ${exact/t/t }results found for ${COL_BOLD}${domainQuery}${COL_NC} within the block lists"
    exit 0
elif [[ -z "${results[*]}" ]]; then
    # Result found in WL/BL/Wildcards
    exit 0
elif [[ -z "${all}" ]] && [[ "${#results[*]}" -ge 100 ]]; then
    echo -e "  ${INFO} Over 100 ${exact/t/t }results found for ${COL_BOLD}${domainQuery}${COL_NC}
        This can be overridden using the -all option"
    exit 0
fi

# Print "Exact matches for" title
if [[ -n "${exact}" ]] && [[ -z "${blockpage}" ]]; then
    plural=""; [[ "${#results[*]}" -gt 1 ]] && plural="es"
    echo " ${matchType^}${plural} for ${COL_BOLD}${domainQuery}${COL_NC} found in:"
fi

for result in "${results[@]}"; do
    match="${result/|*/}"
    extra="${result#*|}"
    adlistAddress="${extra/|*/}"
    extra="${extra#*|}"
    if [[ "${extra}" == "0" ]]; then
      extra="(disabled)"
    else
      extra=""
    fi

    if [[ -n "${blockpage}" ]]; then
        echo "0 ${adlistAddress}"
    elif [[ -n "${exact}" ]]; then
        echo "  - ${adlistAddress} ${extra}"
    else
        if [[ ! "${adlistAddress}" == "${adlistAddress_prev:-}" ]]; then
            count=""
            echo " ${matchType^} found in ${COL_BOLD}${adlistAddress}${COL_NC}:"
            adlistAddress_prev="${adlistAddress}"
        fi
        : $((count++))

        # Print matching domain if $max_count has not been reached
        [[ -z "${all}" ]] && max_count="50"
        if [[ -z "${all}" ]] && [[ "${count}" -ge "${max_count}" ]]; then
            [[ "${count}" -gt "${max_count}" ]] && continue
            echo "   ${COL_GRAY}Over ${count} results found, skipping rest of file${COL_NC}"
        else
            echo "   ${match} ${extra}"
        fi
    fi
done

exit 0
