#!/bin/bash

if [ $# -lt 2 ]; then
    echo "# of parameters must be at least 2"
    echo "Usage: $0 [add|del] ip_address [down_speed(Kb/s)|default] [up_speed(Kb/s)]"
    echo -ne "Examples: \n\t $0 add 10.10.10.5 1024 1024 \n\t $0 add 10.10.10.5 default \n\t $0 del 10.10.10.5 \n"
    exit 2
fi

INT_IF="enp0s8"
EXT_IF="enp0s3"

ACTION=$1
HOST=$2
DOWNLOAD_SPEED=$3
UPLOAD_SPEED=$4

DEFAULT_MARK=0x2
MARK=$(echo $HOST|cksum|head -c 4)
#MARK="15"


# add client functionality
if [ $ACTION = "add" ]; then
    if [ -z "$(iptables -t mangle -L QOS --line-numbers | grep $HOST | awk '{print $12}')" ]; then
        ############
        # IPTABLES #
        ############
        iptables -t mangle -I internet 1 -s $HOST -j RETURN
        iptables -A FORWARD -i ${INT_IF} -o ${EXT_IF} -s $HOST -j ACCEPT
        iptables -I FORWARD 1 -s $HOST -j NETFLOW
        iptables -I FORWARD 1 -d $HOST -j NETFLOW
     
        ###########
        # INGRESS #
        ###########
        echo "Setting up INGRESS..."
        # Outgoing traffic from HOST is marked with MARK
        #!!!!! INSERT rule, not APPEND (-I)

        if [ $DOWNLOAD_SPEED = "default" ]; then
            iptables -t mangle -I QOS 2 -s $HOST -m mark --mark 0 -j MARK --set-mark $DEFAULT_MARK
        else
            iptables -t mangle -I QOS 2 -s $HOST -m mark --mark 0 -j MARK --set-mark $MARK
            tc class add dev ifb0 parent 3:3 classid 3:${MARK} htb rate ${DOWNLOAD_SPEED}kbit

            # Packets marked with MARK on IFB flow through class 3:${MARK}. 
            # "prio" option is mandatory, otherwise rule becomes unremovable
            tc filter add dev ifb0 parent 3:0 protocol ip prio 1 handle $MARK fw flowid 3:${MARK}
        fi

        ##########
        # EGRESS #
        ##########
        echo "Setting up EGRESS..."
        if [ -n "$UPLOAD_SPEED" ]; then
            UPLOAD_BURST=$(printf "%.3s" "$(echo "${UPLOAD_SPEED} / 10"|bc -l)")
        fi

        if [ $DOWNLOAD_SPEED = "default" ]; then
            # TODO. why cant we mark packets for further processing with given policy?
            iptables -A PREROUTING -t mangle -i $INT_IF -s $HOST -j MARK --set-mark $DEFAULT_MARK
            # tc filter add dev $EXT_IF protocol ip parent 1: prio 1 handle 1 fw flowid 1:30
        else
            iptables -A FORWARD -t mangle -i $INT_IF -s $HOST -j MARK --set-mark $MARK
            tc class add dev $EXT_IF parent 1:1 classid 1:${MARK} htb rate ${UPLOAD_SPEED}kbit burst ${UPLOAD_BURST}k
            tc qdisc add dev $EXT_IF parent 1:${MARK} handle ${MARK}: sfq perturb 10
            tc filter add dev $EXT_IF protocol ip parent 1: prio 1 handle ${MARK} fw flowid 1:${MARK}
        fi
    else
        echo "Entry for $HOST already exists"
        exit 2
    fi

# remove client functionality    
elif [ $ACTION = "del" ]; then
    if [ -n "$(iptables -t mangle -L QOS --line-numbers | grep $HOST | awk '{print $12}')" ]; then
        TC_HEX_VALUE=$(iptables -t mangle -L QOS --line-numbers | grep $HOST | awk '{print $12}')
        TC_DEC_VALUE=$(printf "%d" $TC_HEX_VALUE)
        iptables -t mangle -D internet -s $HOST -j RETURN
        iptables -t mangle -D FORWARD $(iptables -t mangle -L FORWARD --line-numbers | grep $HOST | awk '{print $1}') 2> /dev/null > /dev/null
        iptables -t mangle -D QOS $(iptables -t mangle -L QOS --line-numbers | grep $HOST | awk '{print $1}')

        # remove NETFLOW rules
        iptables -D FORWARD -s $HOST -j NETFLOW
        iptables -D FORWARD -d $HOST -j NETFLOW
        iptables -D FORWARD -i ${INT_IF} -o ${EXT_IF} -s $HOST -j ACCEPT
        
        # if BW is not default 
        if [ $TC_HEX_VALUE != $DEFAULT_MARK ]; then
            tc filter del dev ifb0 parent 3: protocol ip prio 1 handle $TC_DEC_VALUE fw flowid 3:${TC_DEC_VALUE}
            tc filter del dev $EXT_IF parent 1: protocol ip prio 1 handle $TC_DEC_VALUE fw flowid 1:${TC_DEC_VALUE}
            tc class del dev ifb0 parent 3:3 classid 3:${TC_DEC_VALUE}
            tc class del dev $EXT_IF parent 1:1 classid 1:${TC_DEC_VALUE}
        fi
    else
        echo "Nothing to remove"
        exit 2
    fi
else
    echo "Allowed actions are [add|del]"
    exit 2

fi

exit 0