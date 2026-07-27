#!/bin/bash
# CANLosetup CAN Bringup

# Load VCAN kernel module
modprobe vcan
if [ $? -ne 0 ]; then
	echo "VCAN Kernel module failed to load!"
	return 1
fi

# Common Functions

# Create VCAN
# $1 = CAN name (ex. can_s0)
vcan() {
	ip link add dev "$1" type vcan
	ip link set "$1" mtu 72
	ip link set up "$1"
	echo "Brought up $1 as VCAN"
}

# Create SPI CAN (ex. CAN HAT)
# $1 = CAN name
# $2 = SPI name
# $3 = Optional Bitrate (Default: 1000000)
# $4 = Optional Restart ms (Default: 1000)
# $5 = Optional Timeout (Default: 16)
# $6 = Optional txqueuelen (Default: 1000)
spican() {
	local canname="$1"
	local spiname="$2"
	local bitrate="${3:-1000000}"
	local restart_ms="${4:-1000}"
	local timeout="${5:-16}"
	local txqueuelen="${6:-1000}"
	# Wait for the SPI CAN Network Device
	local device="/sys/bus/spi/devices/$spiname/net"
	if [ ! -d "$device" ]; then
	       echo "Waiting for $spiname CAN Network Device..."
	fi	       
	while [ ! -d "$device" ] && [ $timeout -gt 0 ]; do
		sleep 1 && : $((timeout--))
	done
	# Fallback to VCAN if it times out
	if [ $timeout -eq 0 ]; then
		echo "Timed out while waiting for $spiname CAN Network Device!"
		echo "Falling back to VCAN!"
		vcan $canname
		return 1
	fi
	# Bring up CAN interface
	local can="$(ls "$device")"
	echo "Located $spiname CAN Network Device $can"
	ip link set "$(ls "$device")" name "$canname" type can bitrate $bitrate restart-ms $restart_ms
	ifconfig "$canname" txqueuelen "$txqueuelen"
	ip link set "$canname" up
	echo "Brought up $canname as SPI CAN on $spiname"
}

# CAN HAT Configuration

