################################################################################
#                                                                              #
#   /etc/virtctl.d/functions.sh                                                #
#                                                                              #
#   https://github.com/dehesselle/virtctl                                      #
#                                                                              #
################################################################################

#
# notes:
#   - UPPERCASE variables are global variables set by the virtctl service
#   - functions prefixed with "virtctl_" get called by the service
#

### FUNCTIONS ##################################################################

function get_domain_interface
{
  local domain=$1

  # returns the first interface only!
  echo $(virsh domiflist $domain | sed -n '3p' | awk '{ print $1 }')
}

# NAT only: get domain's internal IP address
function get_domain_ip
{
  local domain=$1
  local interface=$2   # argument is optional

  # set the first interface
  [ -z $interface ] && interface=$(get_domain_interface $domain)

  local seconds=0
  while [ $seconds -lt 60 ]; do
    if [ $((seconds%5)) -eq 0 ]; then   # every 5 seconds
      # This is what happens:
      #   - get output form domifaddr command
      #   - only keep the third line (lines 1-2: header)
      #   - only keep the fourth argument (ip/mask)
      #   - only keep the first argument (ip)
      #
      # In case of error, domain_ip will be left empty.
      local domain_ip=$(virsh domifaddr $domain $interface |
        sed -n '3p' |
        awk '{ print $4 }' |
        awk -F "/" ' { print $1 }')

      [ ! -z $domain_ip ] && break   # we got the IP address
    fi
      sleep 1
      ((seconds++))
   done

   [ $seconds -eq 60 ] && echo "$FUNCNAME error" >&2

   echo $domain_ip
}

# NAT only: forward port from host to guest
function forward_port
{
  local host_port=$1
  local guest_port=$2
  local guest_interface=$3   # argument is optional

  local guest_ip=$(get_domain_ip $DOMAIN $guest_interface)

  [ -z $host_port  ] && (echo "$FUNCNAME: host_port missing"  && return 1)
  [ -z $guest_port ] && (echo "$FUNCNAME: guest_port missing" && return 1)
  [ -z $guest_ip   ] && (echo "$FUNCNAME: guest_ip missing"   && return 1)

  iptables -t nat -A PREROUTING -p tcp --dport "$host_port" -j DNAT --to "$guest_ip:$guest_port"
  iptables -I FORWARD -d "$guest_ip/32" -p tcp -m state --state NEW -m tcp --dport "$guest_port" -j ACCEPT
}

# NAT only: remove all forwarded ports
function remove_all_forwardings
{
  local guest_interface=$1   # argument is optional

  local guest_ip=$(get_domain_ip $DOMAIN $guest_interface)

  for rule in $(iptables -t nat -L PREROUTING --line-numbers | grep $guest_ip | awk '{ print $1 }' | sort -nr); do
    iptables -t nat -D PREROUTING $rule
  done

  for rule in $(iptables -L FORWARD --line-numbers | grep $guest_ip | awk '{ print $1 }' | sort -nr); do
    iptables -D FORWARD $rule
  done
}

# This function gets called by the service's first ExexStop command.
function virtctl_stoppre
{
  remove_all_forwardings
}

### MAIN #######################################################################

COMMAND=$1   # ExecStartPost, ExecStopPre, ExecStopPost

ETC_DIR=$(dirname $(readlink -f ${BASH_SOURCE[0]}))   # this file's directory

# Source instance specific functions if available. This provides a way
# to separate global from instance-specific functionality.
INSTANCE_FUNCTIONS=$ETC_DIR/$DOMAIN.sh
if [ -f $INSTANCE_FUNCTIONS ]; then
  echo "sourcing $INSTANCE_FUNCTIONS"
  source $INSTANCE_FUNCTIONS
fi

# Run startpost/stoppost actions if available.
case $COMMAND in
  ExecStartPost) COMMAND=startpost ;;
  ExecStopPost)  COMMAND=stoppost  ;;
  ExecStopPre)   COMMAND=stoppre   ;;    # undocumented on purpose!
esac

# Files in DOMAIN_DIR take precedence over files in ETC_DIR.
if   [ -f $DOMAIN_DIR/${DOMAIN}_$COMMAND ]; then
  echo "sourcing $DOMAIN_DIR/${DOMAIN}_$COMMAND"
  source $DOMAIN_DIR/${DOMAIN}_$COMMAND
elif [ -f $ETC_DIR/${DOMAIN}_$COMMAND ]; then
  echo "sourcing $ETC_DIR/${DOMAIN}_$COMMAND"
  source $ETC_DIR/${DOMAIN}_$COMMAND
fi

