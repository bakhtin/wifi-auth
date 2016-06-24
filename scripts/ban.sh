#!/bin/bash
# requires iptables comment module, bind-utils
if [ $# -lt 2 ]; then
    echo "# of parameters must be at least 2"
    echo "Usage: $0 [ban|unban] URL"
    echo -ne "Examples: \n\t $0 ban vk.com \n\t $0 unban vk.com \n"
    exit 2
fi

URL=$2

if [ $1 = "ban" ]; then
	IPS=$(dig +short $URL)
	IFS=' ' read -ra LIST_IPS <<< $IPS
	for IP in "${LIST_IPS[@]}"; do
		iptables -I FORWARD -d $IP -j DROP -m comment --comment "$URL"
	done

elif [ $1 = "unban" ]; then
	IPS=$(iptables -nL --line-numbers | grep $URL | awk '{print $1}')
	IFS=' ' read -ra LIST_IPS <<< $IPS
	for (( i=${#LIST_IPS[@]}-1 ; i>=0 ; i-- )); do
    	iptables -D FORWARD ${LIST_IPS[i]}
	done
else
    echo "Allowed actions are [ban|unban]"
    exit 2
fi
exit 0
