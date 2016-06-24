#!/bin/bash

##kernel >=3.19, iproute2>=4.1, bc
# Set this value to 90-95% of max inet uplink bandwidth to prevent queueing (mbit/s)
UPLINKBW=95

# speed to be assigned when nothing provided
DEFAULT_DL_SPEED=2048
DEFAULT_UP_SPEED=2048

# iface facing Inet
EXTDEV=enp0s3
INTDEV=enp0s8
HOST_EXT_IP=192.168.1.123
LOCAL_NET_ADDRESS=10.10.10.0
LOCAL_NET_MASK=24

# comma delimeted DNS servers client is allowed to lookup address with
DNS_SERVERS=8.8.8.8,8.8.4.4

#set burst to 10% of total bw
BURST=$(printf "%.3s" "$(echo "${UPLINKBW} / 10"|bc -l)")

#captive portal ip
PORTAL_IP="10.10.10.2"
PORTAL_PORT=80

#########################################################
#                    SETUP INGRESS                      #
#########################################################
echo "Setting up INGRESS"
# Load IFB, all other modules all loaded automatically
modprobe ifb
ip link set dev ifb0 down

# Clear old queuing disciplines (qdisc) on the interfaces and the MANGLE table
tc qdisc del dev $EXTDEV root    2> /dev/null > /dev/null
tc qdisc del dev $EXTDEV ingress 2> /dev/null > /dev/null
tc qdisc del dev ifb0 root       2> /dev/null > /dev/null
tc qdisc del dev ifb0 ingress    2> /dev/null > /dev/null

# Clear iptables
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -t mangle -F
iptables -t nat -F
iptables -t filter -F
iptables -t mangle -X QOS
iptables -t mangle -X internet

ip link set dev ifb0 up

# HTB classes on IFB with rate limiting
tc qdisc add dev ifb0 root handle 3: htb default 3
tc class add dev ifb0 parent 3: classid 3:3 htb rate ${DEFAULT_UP_SPEED}kbit

# Forward all ingress traffic on internet interface to the IFB device
tc qdisc add dev $EXTDEV ingress handle ffff:
tc filter add dev $EXTDEV parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev ifb0 \
        flowid ffff:1


##################
# IPTABLES RULES #
##################
echo "Setting up IPTABLES RULES"

# set default policy to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# allow local traffic
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# allow SeSeHa
iptables -A INPUT -d $HOST_EXT_IP -p tcp -m tcp --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -s $HOST_EXT_IP -p tcp -m tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# allow LAN traffic on gw
iptables -A INPUT -d ${LOCAL_NET_ADDRESS}/${LOCAL_NET_MASK} -j ACCEPT
iptables -A OUTPUT -s ${LOCAL_NET_ADDRESS}/${LOCAL_NET_MASK} -j ACCEPT

# allow LAN traffic forwarding
iptables -A FORWARD -s ${LOCAL_NET_ADDRESS}/${LOCAL_NET_MASK} -d ${LOCAL_NET_ADDRESS}/${LOCAL_NET_MASK} -j ACCEPT

# allow everything on gw from/to external iface
iptables -A INPUT -i $EXTDEV -j ACCEPT
iptables -A OUTPUT -o $EXTDEV -j ACCEPT


iptables -N internet -t mangle
iptables -t mangle -A PREROUTING -j internet


#iptables -t mangle -A internet -m mac --mac-source "$1" -j RETURN
#mark non-authorized IPs for future processing
iptables -t mangle -A internet -j MARK --set-mark 42

#redirect to captive portal
iptables -t nat -A PREROUTING -m mark --mark 42 -p tcp -m multiport --dports 80,443 -j DNAT --to-destination ${PORTAL_IP}:${PORTAL_PORT}


##########################
# INGRESS-IPTABLES SETUP #
##########################

iptables -t mangle -N QOS
iptables -t mangle -A FORWARD -o $EXTDEV -j QOS
iptables -t mangle -A OUTPUT -o $EXTDEV -j QOS
iptables -t mangle -A QOS -j CONNMARK --restore-mark
iptables -t mangle -A QOS -j CONNMARK --save-mark


# perform bridging
iptables -A FORWARD -i ${EXTDEV} -o ${INTDEV} -m state --state ESTABLISHED,RELATED -j ACCEPT

# allow dns lookups
IFS=',' read -ra ADDR <<< "$DNS_SERVERS"
for DNS_SERVER in "${ADDR[@]}"; do
    iptables -A FORWARD -i $INTDEV -o $EXTDEV -d $DNS_SERVER -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i $INTDEV -o $EXTDEV -d $DNS_SERVER -p udp --dport 53 -j ACCEPT
done

iptables -t nat -A POSTROUTING -o ${EXTDEV} -j MASQUERADE


################
# EGRESS SETUP #
################

echo "Setting up EGRESS policies..."

#set policies
tc qdisc add dev ${EXTDEV} root handle 1: htb default 30
#tc class add dev ${EXTDEV} parent 1: classid 1:1 htb rate ${UPLINKBW}mbit burst ${BURST}mbit

#set default policy bw
tc class add dev ${EXTDEV} parent 1:1 classid 1:30 htb rate ${DEFAULT_UP_SPEED}kbit burst 10k
tc qdisc add dev ${EXTDEV} parent 1:30 handle 30: sfq perturb 10

exit 0
