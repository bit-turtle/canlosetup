#!/bin/bash
# SystemcorePi CANlosetup image modification tool
ScriptDir="$(dirname "$(realpath "$0")")"
MountPrefix="/mnt/lo"
echo -e "\033[1;32mCANlosetup Systemcore Image Modification Tool\033[0m"
pushd .

# Errors and warnings
function error() {	# $1 = Error Code, $2 = Error Message
	echo -e "\033[1;31mERROR:\033[0m $2"
	# Abort
	popd
	if [ -f ${MountPrefix}* ]; then
		umount -f ${MountPrefix}*
		rm -r ${MountPrefix}*
	fi
	if [ -v OSImage ]; then
		if [ -f "$LosetupMount" ]; then
			losetup -d "$LosetupMount"
		fi
		mv "$LosetupImage" "$SystemcoreImage"
		warning "Systemcore OS image may have been modified incorrectly!"
	fi
	if [ -v LLUpdate ]; then
		if [ -f "$LosetupBoot" ]; then
			losetup -d "$LosetupBoot"
		fi
		if [ -f "$LosetupRootFS" ]; then
			losetup -d "$LosetupRootFS"
		fi
		rm -r "${LLUpdateDir}/"
		info "Systemcore OS update was not modified"
	fi
	echo -e "\033[1;31mFailed to modify $SystemcoreImage!"
	exit $1
}
function error_check() {	# $? = Return Code, $1 = Error Code, $2 = Error Message
	if [ $? -ne 0 ]; then
		error $1 "$2"
	fi
}
function warning() {	# $1 = Warning Message
	echo -e "\033[1;33mWARNING:\033[0m $1"
}
function info() {	# $1 = Info Message
	echo -e "\033[1;34mINFO:\033[0m $1"
}

# Running on Linux?
if [ "$(uname)" != "Linux" ]; then
	error 255 "CANLosetup is only compatible with Linux! Try using a Linux VM"
fi

# Can losetup?
if [[ $EUID -ne 0 ]]; then
   error 1 "Only root can losetup!"
fi

# Can help?
if [ $# -lt 3 ] || [ $# -gt 4 ]; then
	info "Usage: $0 <Systemcore Image Type> <Systemcore Image> [CAN HAT Type] [Team Number]"
	error 2 "Missing arguments, read the README for a list of valid options"
fi

# Process Arguments
SystemcoreImageType="$1"
if [ "$SystemcoreImageType" == "osimage" ]; then
	OSImage=1
elif [ "$SystemcoreImageType" == "llupdate" ]; then
	LLUpdate=1
	command -v jq
	if [ $? -ne 0 ]; then
		error 51 "jq is required to modify LLUpdate images!"
	fi
	command -v zstd
	if [ $? -ne 0 ]; then
		error 52 "zstd is required to modify LLUpdate images!"
	fi
	command -v wc
	if [ $? -ne 0 ]; then
		error 53 "wc is required to modify LLUpdate images!"
	fi
	command -v cut
	if [ $? -ne 0 ]; then
		error 54 "cut is required to modify LLUpdate images!"
	fi
	command -v sha256sum
	if [ $? -ne 0 ]; then
		error 55 "sha256sum is required to modify LLUpdate images!"
	fi
else
	error 5 "Unknown Systemcore image type $SystemcoreImageType! Valid types are \"osimage\" and \"llupdate\"."
fi
SystemcoreImage="$2"
# Can find image?
if [ ! -f "$SystemcoreImage" ]; then
	error 6 "Missing Systemcore image $SystemcoreImage!"
	exit 4
fi
CANHAT="$3"
if [ "$CANHAT" == "none" ]; then
	NoCANHAT=1
	info "Not including CAN HAT support"
# Does CANHAT config exist?
elif [ ! -f "${ScriptDir}/config/${CANHAT}.txt" ] || [ ! -f "${ScriptDir}/service/${CANHAT}.sh" ]; then
	error 7 "CAN HAT ${CANHAT} is not supported, check out CONTRIBUTING.md to learn how to add support"
else
	command -v sed
	if [ $? -ne 0 ]; then
		error 50 "sed is required to create CAN HAT systemd service"
	fi
fi
TeamNumber="$4"

# Mount losetup
if [ -v OSImage ]; then
	LosetupImage="${SystemcoreImage}.losetup.img"
	mv "$SystemcoreImage" "$LosetupImage"
	info "Losetup image..."
	LosetupMount=$(losetup -Pf --show "$LosetupImage")
	error_check 8 "Failed to losetup OSImage!"
	info "Losetup on $LosetupMount"
	sleep 1	# Wait for losetup
elif [ -v LLUpdate ]; then
	LLUpdateDir="${SystemcoreImage}.losetup.dir"
	mkdir "$LLUpdateDir"
	info "Unpacking LLUpdate image..."
	tar -xf "$SystemcoreImage" -C "$LLUpdateDir"
	error_check 70 "Failed to unpack LLUpdate image!"
	cd "$LLUpdateDir"
	info "Decompressing Boot image..."
	zstd -d boot.img.zst
	error_check 9 "Failed to decompress Boot image!"
	rm boot.img.zst
	info "Decompressing RootFS image..."
	zstd -d rootfs.img.zst
	error_check 10 "Failed to decompress Root image!"
	rm rootfs.img.zst
	info "Losetup images..."
	LosetupBoot=$(losetup -Pf --show "boot.img")
	error_check 11 "Failed to losetup Boot image!"
	LosetupRootFS=$(losetup -Pf --show "rootfs.img")
	error_check 12 "Failed to losetup Root image!"
	info "Losetup on $LosetupBoot and $LosetupRootFS"
fi

# Modify Systemcore image
lo() { # $1 = Partition name
	echo "${MountPrefix}$1"
}
lomount() { # $1 = Parition Name, $2 = Partition ID
	mkdir "$(lo $1)"
	if [ -v OSImage ]; then
		mount "${LosetupMount}$2" "$(lo $1)" 2>/dev/null
		if [ $? -ne 0 ]; then
			warning "Failed to mount OSImage partition $2"
			rmdir "$(lo $1)"
			return 1
		fi
	elif [ -v LLUpdate ]; then
		if [ $2 == "boot" ]; then
			mount "${LosetupBoot}" "$(lo $1)"
		elif [ $2 == "rootfs" ]; then
			mount "${LosetupRootFS}" "$(lo $1)"
		else
			error 13 "Invalid LLUpdate mount $2! Valid mounts are \"boot\" and \"rootfs\"."
		fi
	fi
	info "Mounted $1"
}
loumount() { # $1 = Partition name
	umount "$(lo $1)"
	rmdir "$(lo $1)"
	info "Unmounted $1"
}

# Mount Partitions
canlosetup_modified_message() { # $1 = Partition name
	if [ ! -f "$(lo $1)/canlosetup.txt" ]; then
		echo "This Systemcore image was modified using the CANlosetup tool" > "$(lo $1)/canlosetup.txt"
		echo "Inserted Feature History: (Lower entries override higher entries)" >> "$(lo $1)/canlosetup.txt"
	fi
}
backup_config() { # $1 = Partition name
	if [ ! -f "$(lo $1)/config.txt.old" ]; then
		info "Backing up $1 config..."
		cp "$(lo $1)/config.txt" "$(lo $1)/config.txt.old"
		error_check 15 "Failed to back up $1 config!"
	else
		warning "Partition $1 previously modified by canlosetup!"
		info "Restoring $1 config..."
		cp "$(lo $1)/config.txt.old" "$(lo $1)/config.txt"
		error_check 16 "Failed to restore $1 config!"
	fi
}
if [ -v OSImage ]; then
	lomount Boot0 p1
	error_check 21 "Failed to mount Boot0!"
	lomount BootA p2
	error_check 22 "Failed to mount BootA!"
	lomount BootB p3
	error_check 23 "Failed to mount BootB!"
	lomount RootA p5
	error_check 24 "Failed to mount RootA!"
	lomount RootB p6
	if [ $? -ne 0 ]; then
		NoRootB=1
		info "RootB is not present on this image"
	else
		unset NoRootB
	fi
	canlosetup_modified_message Boot0
	backup_config BootA
	canlosetup_modified_message BootA
	backup_config BootB
	canlosetup_modified_message BootB
	lolog() {
		echo "$1" >> "$(lo Boot0)/canlosetup.txt"
		error_check 17 "Failed to write log to Boot0!"
		echo "$1" >> "$(lo BootA)/canlosetup.txt"
		error_check 18 "Failed to write log to BootA!"
		echo "$1" >> "$(lo BootB)/canlosetup.txt"
		error_check 19 "Failed to write log to BootB!"
	}
elif [ -v LLUpdate ]; then
	lomount Boot boot
	error_check 25 "Failed to mount Boot!"
	lomount Root rootfs
	error_check 26 "Failed to mount RootFS!"
	backup_config Boot
	canlosetup_modified_message Boot
	lolog() {
		echo "$1" >> "$(lo Boot)/canlosetup.txt"
		error_check 20 "Failed to write log to Boot!"
	}
fi

# Insert CAN HAT config
CANHATConfig="$ScriptDir/config/$CANHAT.txt"
if [ -v NoCANHAT ]; then
	warning "No CAN HAT config included"
	lolog "CAN HAT Config: NONE"
else
	locanconf() { # $1 = Partition name
		# Append CAN HAT config
		cat "$CANHATConfig" >> "$(lo $1)/config.txt"
		info "Added CAN HAT config to $1"
	}
	if [ -v OSImage ]; then
		locanconf BootA
		locanconf BootB
	elif [ -v LLUpdate ]; then
		locanconf Boot
	fi
	lolog "CAN HAT Config: $CANHAT"
fi

# Insert CAN HAT service
CANHATService="$ScriptDir/service/$CANHAT.sh"
if [ -v NoCANHAT ]; then
	warning "No CAN HAT service included"
	lolog "CAN HAT Service: NONE"
else
	locanservice() { # $1 = Partition name
		# Copy base service script
		mkdir -p "$(lo $1)/usr/local/sbin/"
		cp "$ScriptDir/common/canlosetup.sh" "$(lo $1)/usr/local/sbin/canlosetup.sh"
		chmod +x $(lo $1)"/usr/local/sbin/canlosetup.sh"
		# Add CAN HAT specific script to service
		cat "$CANHATService" >> "$(lo $1)/usr/local/sbin/canlosetup.sh"
		# Add robot_heartbeat module load script to service
		cat "$ScriptDir/common/robot_heartbeat.sh" >> "$(lo $1)/usr/local/sbin/canlosetup.sh"
		# Remove robot_heartbeat module autoload
		rm -f "$(lo $1)/etc/modules-load.d/robot_heartbeat.conf"
		# Create systemd service file
		cp "$ScriptDir/common/canlosetup.service" "$(lo $1)/etc/systemd/system/canlosetup.service"
		sed -i "s/@CAN_HAT_TYPE/$CANHAT/" "$(lo $1)/etc/systemd/system/canlosetup.service"
		# Enable systemd service
		ln -sfn "/etc/systemd/system/canlosetup.service" "$(lo $1)/etc/systemd/system/multi-user.target.wants/canlosetup.service"
		# Disable default CAN service
		rm -f "$(lo $1)/etc/systemd/system/default.target.wants/limelight_canbusprocess.service"
		info "Added CAN HAT service to $1"
	}
	if [ -v OSImage ]; then
		locanservice RootA
		if [ ! -v NoRootB ]; then
			locanservice RootB
		fi
		lolog "CAN HAT Service: $CANHAT"
	elif [ -v LLUpdate ]; then
		locanservice Root
	fi
fi

# Insert Team Number
if [[ ! $TeamNumber =~ ^[0-9]+$ ]]; then
	warning "Invalid or no team number provided, keeping default team number"
	lolog "Team Number: DEFAULT"
else
	function embed_team_number() { # $1 = Partition name
		echo "$TeamNumber" > "$(lo $1)/etc/team_number.txt"
		echo "Added team number $TeamNumber to $1"
	}
	if [ -v OSImage ]; then
		embed_team_number RootA
		if [ ! -v NoRootB ]; then
			embed_team_number RootB
		fi
	elif [ -v LLUpdate ]; then
		embed_team_number Root
	fi
	lolog "Team Number: $TeamNumber"
fi

# Done!
if [ -v OSImage ]; then
	loumount Boot0
	loumount BootA
	loumount BootB
	loumount RootA
	if [ ! -v NoRootB ]; then
		loumount RootB
	fi
	losetup -d "$LosetupMount"
	mv "$LosetupImage" "$SystemcoreImage"
elif [ -v LLUpdate ]; then
	loumount Boot
	loumount Root
	losetup -d "$LosetupBoot"
	losetup -d "$LosetupRootFS"
	info "Compressing Boot image..."
	zstd boot.img
	error_check 60 "Failed to compress Boot image!"
	info "Compressing RootFS image..."
	zstd rootfs.img
	error_check 61 "Failed to compress RootFS image!"
	info "Updating LLUpdate manifest..."
	bootSize=$(wc -c < boot.img) rootfsSize=$(wc -c < rootfs.img)
	bootCompressedSize=$(wc -c < boot.img.zst) rootfsCompressedSize=$(wc -c < rootfs.img.zst)
	boot256=$(sha256sum boot.img | cut -d' ' -f1) rootfs256=$(sha256sum rootfs.img | cut -d' ' -f1)
	rm boot.img rootfs.img
	edit_manifest() { # $1 = Key, $2 = Value
		echo $(jq "$1 = $2" manifest.json) > manifest.json
		error_check 62 "Failed to update manifest!"
	}
	manifest_format=$(jq ".format" manifest.json)
	case "$manifest_format" in
		1)
			edit_manifest ".boot.compressed_size" "$bootCompressedSize"
			edit_manifest ".boot.uncompressed_size" "$bootSize"
			edit_manifest ".boot.sha256" "\"$boot256\""
			edit_manifest ".rootfs.compressed_size" "$rootfsCompressedSize"
			edit_manifest ".rootfs.uncompressed_size" "$rootfsSize"
			edit_manifest ".rootfs.sha256" "\"$rootfs256\""
			;;
		*)
			warning "Unknown manifest format $manifest_format!"
			info "Check out the new structure:"
			echo "-------- manifest.json --------"
			cat manifest.json
			echo "-------- manifest.json --------"
			info "Add suport for the new structure at $1!"
			error 30 "Unknown manifest format!"
			;;
	esac
	info "Repackaging LLUpdate..."
	cd ..
	tar -cvf "$SystemcoreImage" --owner="runner" --group="runner" --mode="644" -C "$LLUpdateDir" manifest.json boot.img.zst rootfs.img.zst
	error_check 31 "Failed to repackage llupdate!"
	rm -r "$LLUpdateDir"
fi
popd
unset OSImage LLUpdate
echo -e "\033[1;32mSucessfully modified $SystemcoreImage!\033[0m"
