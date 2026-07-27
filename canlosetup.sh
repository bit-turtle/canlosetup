#!/bin/bash
# SystemcorePi CANlosetup image modification tool
ScriptDir="$(dirname "$(realpath "$0")")"
MountPrefix="/mnt/lo"
pushd .

# Can losetup?
if [[ $EUID -ne 0 ]]; then
   echo "Only root can losetup!" 
   exit 1
fi

# Can help?
if [ $# -lt 2 ] || [ $# -gt 4 ]; then
	echo "Usage: $0 <Systemcore Image Type> <Systemcore Image> [CAN HAT Type] [Team Number]"
	exit 2
fi

# Process Arguments
SystemcoreImageType="$1"
if [ "$SystemcoreImageType" == "osimage" ]; then
	OSImage=1
elif [ "$SystemcoreImageType" == "llupdate" ]; then
	LLUpdate=1
	command -v jq
	if [ $? -ne 0 ]; then
		echo "jq is required to modify LLUpdate images!"
		exit 2
	fi
else
	echo "Unknown Systemcore image type $SystemcoreImageType! Valid types are \"osimage\" and \"llupdate\"."
	exit 3
fi
SystemcoreImage="$2"
CANHAT="$3"
TeamNumber="$4"

# Can image?
if [ ! -f "$SystemcoreImage" ]; then
	echo "Missing Systemcore image $SystemcoreImage!"
	exit 4
fi

# Mount losetup
if [ -v OSImage ]; then
	LosetupImage="${SystemcoreImage}.losetup.img"
	mv "$SystemcoreImage" "$LosetupImage"
	echo "Losetup image..."
	LosetupMount=$(losetup -Pf --show "$LosetupImage")
	echo "Losetup on $LosetupMount"
	sleep 1	# Wait for losetup
elif [ -v LLUpdate ]; then
	LLUpdateDir="${SystemcoreImage}.losetup.dir"
	mkdir "$LLUpdateDir"
	echo "Unpacking LLUpdate image..."
	tar -xf "$SystemcoreImage" -C "$LLUpdateDir"
	cd "$LLUpdateDir"
	echo "Decompressing Boot image..."
	zstd -d boot.img.zst
	rm boot.img.zst
	echo "Decompressing RootFS image..."
	zstd -d rootfs.img.zst
	rm rootfs.img.zst
	echo "Losetup images..."
	LosetupBoot=$(losetup -Pf --show "boot.img")
	LosetupRootFS=$(losetup -Pf --show "rootfs.img")
	echo "Losetup on $LosetupBoot and $LosetupRootFS"
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
			echo "Failed to mount OSImage partition $2"
			return 1
		fi
	elif [ -v LLUpdate ]; then
		if [ $2 == "boot" ]; then
			mount "${LosetupBoot}" "$(lo $1)"
		elif [ $2 == "rootfs" ]; then
			mount "${LosetupRootFS}" "$(lo $1)"
		else
			echo "Invalid LLUpdate mount $2! Valid mounts are \"boot\" and \"rootfs\"."
			exit 5
		fi
	fi
	echo "Mounted $1"
}
loumount() { # $1 = Partition name
	umount "$(lo $1)"
	rmdir "$(lo $1)"
	echo "Unmounted $1"
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
		echo "Backing up $1 config..."
		cp "$(lo $1)/config.txt" "$(lo $1)/config.txt.old"
	else
		echo "Partition $1 previously modified by canlosetup!"
		echo "Restoring $1 config..."
		cp "$(lo $1)/config.txt.old" "$(lo $1)/config.txt"
	fi
}
if [ -v OSImage ]; then
	lomount Boot0 p1
	lomount BootA p2
	lomount BootB p3
	lomount RootA p5
	lomount RootB p6
	if [ $? -ne 0 ]; then
		NoRootB=1
		echo "RootB is not present on this image"
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
		echo "$1" >> "$(lo BootA)/canlosetup.txt"
		if [ ! -v NoRootB ]; then
			echo "$1" >> "$(lo BootB)/canlosetup.txt"
		fi
	}
elif [ -v LLUpdate ]; then
	lomount Boot boot
	lomount Root rootfs
	backup_config Boot
	canlosetup_modified_message Boot
	lolog() {
		echo "$1" >> "$(lo Boot)/canlosetup.txt"
	}
fi

# Insert CAN HAT config
CANHATConfig="$ScriptDir/config/$CANHAT.txt"
if [ ! -f "$CANHATConfig" ]; then
	echo "No CAN HAT config for $CANHAT!"
	echo "Add a config at $CANHATConfig!"
	lolog "CAN HAT Config: NONE"
else
	locanconf() { # $1 = Partition name
		# Append CAN HAT config
		cat "$CANHATConfig" >> "$(lo $1)/config.txt"
		echo "Added CAN HAT config to $1"
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
if [ ! -f "$CANHATService" ]; then
	echo "No CAN HAT service for $CANHAT!"
	echo "Add a service at $CANHATService!"
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
		echo "Added CAN HAT service to $1"
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
	echo "Invalid or no team number provided!"
	echo "Using default team number!"
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
	echo "Compressing Boot image..."
	zstd boot.img
	echo "Compressing RootFS image..."
	zstd rootfs.img
	echo "Updating LLUpdate manifest..."
	bootSize=$(wc -c < boot.img) rootfsSize=$(wc -c < rootfs.img)
	bootCompressedSize=$(wc -c < boot.img.zst) rootfsCompressedSize=$(wc -c < rootfs.img.zst)
	boot256=$(sha256sum boot.img | cut -d' ' -f1) rootfs256=$(sha256sum rootfs.img | cut -d' ' -f1)
	rm boot.img rootfs.img
	edit_manifest() { # $1 = Key, $2 = Value
		echo $(jq "$1 = $2" manifest.json) > manifest.json
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
			echo "Unknown manifest format $manifest_format!"
			echo "Check out the new structure:"
			echo "-------- manifest.json --------"
			cat manifest.json
			echo "-------- manifest.json --------"
			echo "Add suport for the new structure at $1!"
			echo "Skipping LLUpdate manifest update!"
			echo "LLUpdate will most likely be invalid!"
			;;
	esac
	echo "Repackaging LLUpdate..."
	cd ..
	tar -cvf "$SystemcoreImage" --owner="runner" --group="runner" --mode="644" -C "$LLUpdateDir" manifest.json boot.img.zst rootfs.img.zst
	rm -r "$LLUpdateDir"
fi
popd
unset OSImage LLUpdate
echo "Modified $SystemcoreImage!"
