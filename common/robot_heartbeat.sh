
# Load robot_heartbeat kernel module
modprobe robot_heartbeat
if [ $? -ne 0 ]; then
	echo "Failed to load robot_heartbeat!"
	exit 1
fi
echo "Successfully loaded robot_heartbeat"
exit 0
