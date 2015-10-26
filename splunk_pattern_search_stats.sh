#!/bin/sh

usage() {
    echo ""
    echo ""
    echo "  ================================= USAGE OPTIONS =================================="
    echo "  `basename $0` " 1>&2
    echo "      [-h |--help <Display help or usage for the script>]" 1>&2
    echo "      [-u |--user <SSO Username>]" 1>&2
    echo "      [-p |--password <SSO password>]" 1>&2
    echo "      [-s |--start <startTime example 07/01/2015:00:00:00>]" 1>&2
    echo "      [-e |--end <endTime example 07/03/2015:00:00:00>]" 1>&2
    echo "      [-f |--patternfile <file with all patterns to be searched>]" 1>&2
    echo "      [-i |--instance <instance name exampe cs14>]" 1>&2
    echo "      [-dc|--dc <instance level or dc level stats (true for dc level stats)>]" 1>&2
    echo "      [-v |--var <low variance or high variance analysis. low for normal functions like flush, split, compaction and high for error/exceptions>]" 1>&2
    echo ""
    echo "  ================================== EXAMPLE ========================================"
    echo "  ./splunk_pattern_search_stats.sh -u <SSO Username> -p <SSO password> " 
    echo "                                       -s <startTime (ex: 07/01/2015:00:00:00)> "
    echo "                                       -e <endTime (ex: 07/03/2015:00:00:00)> "
    echo "                                       -f <file with all patterns to be searched>"
    echo "                                       -i <instance name (ex: cs14)>"
    echo "                                       -v <high variance (ex: high)>"
    echo "                                       -dc <dc level stats (ex: true)>"
    echo ""
}


getCountStats() {
    pattern="$1"
    search_pattern="\"${pattern}\""
    count_query_instance=' | eval host=mvindex(split(mvindex(split(host, "-"),3), "."),0) | timechart span="15m" count  by host useother=0 limit=35 '
    count_query_dc=' | eval dc=mvindex(split(mvindex(split(host, "-"),3), "."),0) | timechart span="15m" count  by dc useother=0 limit=35 '
    if [ ${dc} = 'false' ];
    then
        count_query=${query_prefix}${search_pattern}${count_query_instance}
    else
        count_query=${query_prefix}${search_pattern}${count_query_dc}
    fi
    #count_query=${query_prefix}${count_query1}
    #echo "$count_query" 
    ####################################### Add Splunk rest url here ################################
    curl -s -k -u "${USER}:${password}" --data-urlencode search="${count_query}" -d "output_mode=csv" "###https://<splunk url>###" > "${HOME_DIR}/splunk_data/${pattern}.result"
}


getQueryInstanceInterval() {
    if [ -z ${instance+x} ]
    then
       query_instance="host!=abc* host=*-*net*"
    else
       query_instance="host!=abc* host=${instance}-*net*"
    fi
    
    if [ -z ${start+x} ] || [ -z ${end+x} ]
    then
        #echo "Start and end times were not specified for the query, running for the default 24 hour"
        query_prefix="search (index=prod OR index=distapps) sourcetype=hbase* sourcetype!=hbase*Monitoring* ${query_instance} earliest=-1d "
    else 
        query_prefix="search (index=prod OR index=distapps) sourcetype=hbase* sourcetype!=hbase*Monitoring* ${query_instance} earliest=${start} latest=${end} "
    fi
    #echo "${query}""\n"
}

countFilePatterns() {
    while read line;do
        getCountStats "$line" 
        #echo "Splunking $line ......"
    done < $FILE
}


summarizeFilePatternStats() {
    rare_patterns=""
    save_found_patterns_file
    while read line;do
        #echo "processing "${HOME_DIR}/splunk_data/${line}.result" ... "
        printf "========\n "${line}" \n========\n" > "${HOME_DIR}/splunk_data/${line}.stats"
        num_col=`cat "${HOME_DIR}/splunk_data/${line}.result" | head -1 | awk -F, '{print NF}'`
        instance_hdr=`head -1 "${HOME_DIR}/splunk_data/${line}.result"`
        instance_hdr="STATS,""${instance_hdr}" 
        echo ${instance_hdr} >> "${HOME_DIR}/splunk_data/${line}.stats"
        # remove _time and span columns
        if [ ${num_col} ]
        then 
            num_col=$(( $num_col-2 )) 
            if [ ${num_col} -lt 5 ] && [ ${num_col} -gt 0 ]
            then 
                rare_pattern_instances=`echo ${instance_hdr} | awk -F, '{$1 = ""; $NF = ""; $(NF-1) = ""; print}'`
                rare_patterns="${rare_patterns}\n \"${line}\" found in [${rare_pattern_instances}]"
            fi
            if [ ${num_col} -gt 0 ]
            then
                echo "${line}" >> "${HOME_DIR}/splunk_data/pattern.today"
            fi
            generateAwkCommand "${num_col}"
            awk "${stats_awk_cmd}" "${HOME_DIR}/splunk_data/${line}.result" >>  "${HOME_DIR}/splunk_data/${line}.stats"
            cat "${HOME_DIR}/splunk_data/${line}.result" >>  "${HOME_DIR}/splunk_data/${line}.stats"
        fi
    done < $FILE
    printf "\n======\nFollowing patterns seem to be occuring only in few clusters\n======\n"
    printf "${rare_patterns}"
}

save_found_patterns_file() {
    cp "${HOME_DIR}/splunk_data/pattern.today" "${HOME_DIR}/splunk_data/pattern.old"
    echo "" > "${HOME_DIR}/splunk_data/pattern.today"
}

get_new_patterns_today() {
    printf "\n\n========\nPatterns found today but not yesterday\n========\n" 
    new_patterns_today=`diff "${HOME_DIR}/splunk_data/pattern.old" "${HOME_DIR}/splunk_data/pattern.today" | grep '>'`
    printf "${new_patterns_today}"
}

generateAwkCommand() {
    num_columns=$1
    stats_awk_cmd=""
    sum_cmd=""
    print_ctr=""
    print_sum=""
    print_avg=""
    print_min=""
    print_max=""
    init_cmd='BEGIN{FS=","; OFS=","; ' 
    i=1
    while [ $i -le $num_columns ]
    do
        init_cmd="${init_cmd} min$i=999999; max$i=0;"
        i=$(( $i+1 ))
    done
    init_cmd="${init_cmd}}"
    init_cmd="${init_cmd}/time/{next}{ctr=ctr+1}"
    i=1
    while [ $i -le $num_columns ]
    do
        sum_cmd="${sum_cmd}{sum$i=sum$i+\$$i}{if(min$i>\$$i) min$i=\$$i}{if(max$i<\$$i) max$i=\$$i}"
        i=$(( $i+1 ))
    done
    #BEGIN{FS=","; min1=999999; min2=999999; min3=999999; min4=999999; min5=999999; }
    #print commands
    #echo "${init_cmd}${sum_cmd}"
    i=1
    print_ctr='END{print "Total Samples: "ctr}'
    print_sum='END{print "SUM, " '
    print_avg='END{print "AVG, " '
    print_min='END{print "MIN, " '
    print_max='END{print "MAX, " '

    while [ $i -le $num_columns ]
    do
        print_sum=${print_sum}"sum${i},"
        print_avg=${print_avg}"sum${i}/ctr,"
        print_min=${print_min}"min${i},"
        print_max=${print_max}"max${i},"
        i=$(( $i+1 ))
    done
    print_sum=${print_sum}'""}'
    print_avg=${print_avg}'""}'
    print_min=${print_min}'""}'
    print_max=${print_max}'""}'
        
    stats_awk_cmd="${init_cmd}${sum_cmd}${print_sum}${print_avg}${print_min}${print_max}"
    #echo "$stats_awk_cmd"
}

summarizeDataVariance() {
    while read line;do
        #echo "processing "${HOME_DIR}/splunk_data/${line}.stats" ... "
        printf "========\n "${line}" \n========\n" > "${HOME_DIR}/splunk_data/${line}.var"
        num_col=`cat "${HOME_DIR}/splunk_data/${line}.result" | head -1 | awk -F, '{print NF}'`
        instance_hdr=`head -1 "${HOME_DIR}/splunk_data/${line}.result"`
        echo ${instance_hdr} >> "${HOME_DIR}/splunk_data/${line}.var"
        # remove _time and span columns
        if [ ${num_col} ]
        then
            num_col=$(( $num_col-2 ))
            generateVarianceAwkCommand "${num_col}"
            #generateAverageVarianceAwkCommand "${num_col}"
            var_output=`awk "${var_awk_cmd}" "${HOME_DIR}/splunk_data/${line}.stats"`
            var_avg_output=`grep AVG "${HOME_DIR}/splunk_data/${line}.stats"`
            echo "VAR,"${var_output} >>  "${HOME_DIR}/splunk_data/${line}.var"
            echo ${var_avg_output} >>  "${HOME_DIR}/splunk_data/${line}.var"
            cat "${HOME_DIR}/splunk_data/${line}.result" >>  "${HOME_DIR}/splunk_data/${line}.var"
        fi
    done < $FILE

}

generateVarianceAwkCommand() {
    num_columns=$1
    var_awk_cmd=""
    avg_cmd="/AVG/{"
    mean_sq_cmd="/GMT/{"
    sum_cmd="/GMT/{"
    print_ctr=""
    print_var="END {print "
    init_cmd='BEGIN{FS=","; OFS=","; var_ctr=0}/time/{next}{var_ctr=var_ctr+1}'

    i=1
    j=2
    while [ $i -le $num_columns ]
    do
        avg_cmd="${avg_cmd} var_avg$i=\$$j;"
        i=$(( $i+1 ))
        j=$(( $j+1 ))
    done
    avg_cmd=${avg_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        mean_sq_cmd="${mean_sq_cmd} sq${i}=(\$${i}-var_avg${i})*(\$${i}-var_avg${i});"
        i=$(( $i+1 ))
    done
    mean_sq_cmd=${mean_sq_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        sum_cmd="${sum_cmd} var_sum${i}=var_sum${i}+sq${i};"
        i=$(( $i+1 ))
    done
    sum_cmd=${sum_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        print_var=${print_var}" sqrt(var_sum${i}/var_ctr),"
        i=$(( $i+1 ))
    done
    print_var=${print_var}'""}'

    var_awk_cmd="${init_cmd}${avg_cmd}${mean_sq_cmd}${sum_cmd}${print_var}"
    #echo "${var_awk_cmd}"
    
}

generateAverageVarianceAwkCommand() {
    reset_ctr=10
    num_columns=$1
    var_awk_cmd=""
    avg_cmd="/AVG/{"
    mean_sq_cmd="/GMT/{"
    avg_mean_sq_cmd="/GMT/{if(var_ctr==$reset_ctr) var_ctr=0; if(var_ctr==$reset_ctr) avg_ctr=avg_ctr+1; "
    end_mean_sq_cmd="END {avg_ctr=avg_ctr+1; "
    sum_cmd="/GMT/{"
    print_var="END {print "
    init_cmd='BEGIN{FS=","; OFS=","; var_ctr=0; avg_ctr=0; reset_ctr=10}/time/{next}{var_ctr=var_ctr+1}'

    i=1
    j=2
    while [ $i -le $num_columns ]
    do
        avg_cmd="${avg_cmd} var_avg$i=\$$j;"
        i=$(( $i+1 ))
        j=$(( $j+1 ))
    done
    avg_cmd=${avg_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        mean_sq_cmd="${mean_sq_cmd} sq${i}=(\$${i}-var_avg${i})*(\$${i}-var_avg${i});"
        i=$(( $i+1 ))
    done
    mean_sq_cmd=${mean_sq_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        sum_cmd="${sum_cmd} var_sum${i}=var_sum${i}+sq${i};"
        i=$(( $i+1 ))
    done
    sum_cmd=${sum_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        avg_mean_sq_cmd="${avg_mean_sq_cmd} if(var_ctr==$reset_ctr) avg_mean_sq${i}=avg_mean_sq${i}+sqrt(var_sum${i}/reset_ctr); if(var_ctr==$reset_ctr) var_sum${i}=0;"
        i=$(( $i+1 ))
    done
    avg_mean_sq_cmd=${avg_mean_sq_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        end_mean_sq_cmd="${end_mean_sq_cmd} avg_mean_sq${i}=avg_mean_sq${i}+sqrt(var_sum${i}/var_ctr);var_sum${i}=0;"
        i=$(( $i+1 ))
    done
    end_mean_sq_cmd=${end_mean_sq_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        print_var=${print_var}" avg_mean_sq${i}/avg_ctr,"
        i=$(( $i+1 ))
    done
    print_var=${print_var}'""}'

    var_awk_cmd="${init_cmd}${avg_cmd}${mean_sq_cmd}${sum_cmd}${avg_mean_sq_cmd}${end_mean_sq_cmd}${print_var}"
    #echo "${var_awk_cmd}"

}

summarizeOutlierStats() {
    echo "" > ${HOME_DIR}/splunk_data/summary.log
    while read line;do
        #echo "processing "${HOME_DIR}/splunk_data/${line}.result" ... "
        num_col=`cat "${HOME_DIR}/splunk_data/${line}.result" | head -1 | awk -F, '{print NF}'`
        instance_hdr=`head -1 "${HOME_DIR}/splunk_data/${line}.result"`
        # remove _time and span columns
        if [ ${num_col} ]
        then
            num_col=$(( $num_col-2 ))
            if `echo ${line} | egrep "${high_variance_patterns}" 1>/dev/null 2>&1`
            then 
                generateOutlierAwkCommand "${num_col}" "${high_variance_multiple}"
            else
                generateOutlierAwkCommand "${num_col}" "${low_variance_multiple}"
            fi
            printf "\n======\n Looking for \"${line}\" outliers \n======\n" 
            #echo "${outlier_awk_cmd}"
            awk "${outlier_awk_cmd}" "${HOME_DIR}/splunk_data/${line}.var" | tee -a "${HOME_DIR}/splunk_data/summary.log"
        fi
    done < $FILE
}

generateOutlierAwkCommand() {
    num_columns=$1
    var_multiple=$2
    outlier_awk_cmd=""
    var_cmd="/VAR/{"
    avg_cmd="/AVG/{"
    compare_cmd="/GMT/{"
    instance_cmd="/_span/{"
    init_cmd='BEGIN{FS=","; OFS=","}'

    i=1
    j=2
    while [ $i -le $num_columns ]
    do
        var_cmd="${var_cmd} std${i}=\$${j};"
        instance_cmd="${instance_cmd} inst${i}=\$${i};"
        i=$(( $i+1 ))
        j=$(( $j+1 ))
    done
    var_cmd=${var_cmd}'""}'
    instance_cmd=${instance_cmd}'""}'
    
    i=1
    j=2
    while [ $i -le $num_columns ]
    do
        avg_cmd="${avg_cmd} avg${i}=\$${j};"
        i=$(( $i+1 ))
        j=$(( $j+1 ))
    done
    avg_cmd=${avg_cmd}'""}'

    i=1
    while [ $i -le $num_columns ]
    do
        if [ ${var} = 'high' ]
        then
            compare_cmd="${compare_cmd} if (\$${i} > 1200 && \$${i} > 7*avg${i} && \$${i} > 10*std${i}) ultrahigh=\"--> \" ; else ultrahigh=\"\";  if (\$${i} > 150 && \$${i} > ${var_multiple}*std${i} && \$${i} > 2*avg${i}) print ultrahigh \"High count \"\$${i}\" std dev[\" std${i} \"] instance[\" inst${i} \"] at \" \$(NF-1);"
        else 
            compare_cmd="${compare_cmd} if (\$${i} > 100 && \$${i} > 5*avg${i} && \$${i} > 5*std${i}) ultrahigh=\"--> \" ; else ultrahigh=\"\";  if (\$${i} > 30 && \$${i} > ${var_multiple}*std${i} && \$${i} > 2*avg${i}) print ultrahigh \"High count \"\$${i}\" std dev[\" std${i} \"] instance[\" inst${i} \"] at \" \$(NF-1);"
        fi
        i=$(( $i+1 ))
    done
    compare_cmd=${compare_cmd}'""}'
    outlier_awk_cmd="${init_cmd}${var_cmd}${avg_cmd}${instance_cmd}${compare_cmd}"
    #echo "$outlier_awk_cmd"
}

get_hot_timestamps() {
    printf "\n======\n Top hotspot timestamps \n======\n" 
    hot_timestamps=`cat "${HOME_DIR}/splunk_data/summary.log"  | awk '/High/{ts=$(NF-2)" "$(NF-1)"\"" ; cnt[ts]+=$3}END{for (x in cnt){print x,cnt[x]}}' | sort -n -r -k3 | head -10`
    printf "${hot_timestamps}"
}

get_hot_instance_timestamps() {
    printf "\n======\n Top hotspot instance timestamps \n======\n" 
    hot_instance_timestamps=`cat "${HOME_DIR}/splunk_data/summary.log" | sed 's/"//g' | sed 's/\[/ /g' | sed 's/\]/ /g' | awk '/High/{ts=$(NF-4)" "$(NF-2)" "$(NF-1); cnt[ts]+=$3}END{for (x in cnt){print x,cnt[x]}}' | sort -n -r -k4 | head -10`
     printf "${hot_instance_timestamps}"
}

USER='vikas'
#dc level(true) or instance level(false) stats
dc='true'
#low variance(low used for function like compaction, flush, etc) or high variance(high used for error exceptions) stats
var='high'

while [ $# -gt 0 ]
do
key="$1"
case $key in
    -h|--help)
    usage
    exit 
    ;;
    -u|--user)
    user="$2"
    shift 
    ;;
    -p|--password)
    password="$2"
    shift 
    ;;
    -s|--start)
    start="$2"
    shift 
    ;;
    -e|--end)
    end="$2"
    shift 
    ;;
    -dc|--dc)
    dc="$2"
    shift 
    ;;
    -i|--instance)
    instance="$2"
    shift 
    ;;
    -f|--patternfile)
    FILE="$2"
    shift 
    ;;
    -v|--var)
    var="$2"
    shift 
    ;;
    *)
    usage   # unknown option
    exit 
    ;;
esac
shift # past argument or value 
done
HOME_DIR="/home/vikas/projects/git/logpatternanalyzer/"
mkdir -p "${HOME_DIR}/splunk_data"
#rm -rf "${HOME_DIR}/splunk_data/*"
low_variance_multiple=3
high_variance_multiple=5
high_variance_patterns="end of stream|IOException|SaslException|ConnectException|Connection reset"
getQueryInstanceInterval
countFilePatterns
summarizeFilePatternStats
get_new_patterns_today
summarizeDataVariance
summarizeOutlierStats
get_hot_timestamps
get_hot_instance_timestamps
printf "\n"
