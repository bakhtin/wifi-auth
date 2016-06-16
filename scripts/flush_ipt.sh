#!/bin/bash
iptables -F
iptables -X
iptables -F -t nat
iptables -F -t mangle
