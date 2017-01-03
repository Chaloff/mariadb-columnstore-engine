#! /bin/sh
# MCSVolumeCmds.sh
# describe, detach and attach Volume Storage from a Cloud environment
#
# 1. Amazon EC2

prefix=/home/mariadb-user

#check command
if [ "$1" = "" ]; then
	echo "Enter Command Name: {create|describe|detach|attach|delete|createTag}"
	exit 1
fi

if [ "$1" = "create" ]; then
	if [ "$2" = "" ]; then
		echo "Enter size of the volume, in GiB (1-1024)"
		exit 1
	fi
	volumeSize="$2"

	#get module-type
	if [ "$3" = "" ]; then
		echo "Enter Module Type"
		exit 1
	fi
	moduleType="$3"
fi

if [ "$1" = "describe" ]; then
	if [ "$2" = "" ]; then
		echo "Enter Volume Name"
		exit 1
	fi
	volumeName="$2"
fi

if [ "$1" = "detach" ]; then
	if [ "$2" = "" ]; then
		echo "Enter Volume Name"
		exit 1
	fi
	volumeName="$2"
fi

if [ "$1" = "attach" ]; then
	if [ "$2" = "" ]; then
		echo "Enter Volume Name"
		exit 1
	fi
	volumeName="$2"

	#get instance-name and device-name
	if [ "$3" = "" ]; then
		echo "Enter Instance Name"
		exit 1
	fi
	instanceName="$3"

	if [ "$4" = "" ]; then
		echo "Enter Device Name"
		exit 1
	fi
	deviceName="$4"
fi

if [ "$1" = "delete" ]; then
	if [ "$2" = "" ]; then
		echo "Enter Volume Name"
		exit 1
	fi
	volumeName="$2"
fi

if [ "$1" = "createTag" ]; then
	if [ "$2" = "" ]; then
		echo "Enter Resource Name"
		exit 1
	fi
	resourceName="$2"

	if [ "$3" = "" ]; then
		echo "Enter Tag Name"
		exit 1
	fi
	tagName="$3"

	if [ "$4" = "" ]; then
		echo "Enter Tag Value"
		exit 1
	fi
	tagValue="$4"
fi


test -f $prefix/mariadb/columnstore/post/functions && . $prefix/mariadb/columnstore/post/functions

AWSCLI="aws ec2 "

checkInfostatus() {
	#check if attached
	cat /tmp/volumeInfo_$volumeName | grep attached > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="attached"
		RETVAL=0
		return
	fi
	#check if available
	cat /tmp/volumeInfo_$volumeName | grep available > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="available"
		RETVAL=0
		return
	fi
	#check if detaching
	cat /tmp/volumeInfo_$volumeName | grep detaching > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="detaching"
		RETVAL=0
		return
	fi
	#check if attaching
	cat /tmp/volumeInfo_$volumeName | grep attaching > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="attaching"
		RETVAL=0
		return
	fi
	#check if doesn't exist
	cat /tmp/volumeInfo_$volumeName | grep "does not exist" > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="does-not-exist"
		RETVAL=1
		return
	fi
	#check if reports already attached from attach command
	cat /tmp/volumeInfo_$volumeName | grep "already attached" > /tmp/volumeStatus_$volumeName
	if [ `cat /tmp/volumeStatus_$volumeName | wc -c` -ne 0 ]; then
		STATUS="already-attached"
		RETVAL=1
		return
	fi
	#any other, unknown error
	STATUS="unknown"
	RETVAL=1
	return
}

createvolume() {
	# get zone
	zone=`$prefix/mariadb/columnstore/bin/MCSInstanceCmds.sh getZone`

	if [ $moduleType == "um" ]; then
		# get type
		volumeType=`$prefix/mariadb/columnstore/bin/getConfig Installation UMVolumeType`
		if [ $volumeType == "io1" ]; then
			# get IOPS
			volumeIOPS=`$prefix/mariadb/columnstore/bin/getConfig Installation UMVolumeIOPS`
		fi
	else	# pm
		# get type
		volumeType=`$prefix/mariadb/columnstore/bin/getConfig Installation PMVolumeType`
		if [ $volumeType == "io1" ]; then
			# get IOPS
			volumeIOPS=`$prefix/mariadb/columnstore/bin/getConfig Installation PMVolumeIOPS`
		fi
	fi

	#create volume
	if [ $volumeType == "io1" ]; then
		volume=`$AWSCLI create-volume   --availability-zone $zone --size $volumeSize --volume-type $volumeType -iops $volumeIOPS --output text --query VolumeId`
	else
		volume=`$AWSCLI create-volume   --availability-zone $zone --size $volumeSize --volume-type $volumeType --output text --query VolumeId`
	fi

	echo $volume
	return
}

describevolume() {
	#describe volume
	$AWSCLI describe-volumes --volume-ids  $volumeName > /tmp/volumeInfo_$volumeName 2>&1

	checkInfostatus
	echo $STATUS
	return
}

detachvolume() {
	#detach volume
	$AWSCLI detach-volume --volume-id  $volumeName > /tmp/volumeInfo_$volumeName 2>&1

	checkInfostatus
	if [ $STATUS == "detaching" ]; then
		retries=1
		while [ $retries -ne 60 ]; do
			#retry until it's attached
			$AWSCLI detach-volume --volume-id  $volumeName > /tmp/volumeInfo_$volumeName 2>&1
		
			checkInfostatus
			if [ $STATUS == "available" ]; then
				echo "available"
				exit 0
			fi
			((retries++))
			sleep 1
		done
		test -f /usr/local/mariadb/columnstore/post/functions && . /usr/local/mariadb/columnstore/post/functions
		$prefix/mariadb/columnstore/bin/cplogger -w 100 "detachvolume failed: $STATUS"
		echo "failed"
		exit 1
	fi

	if [ $STATUS == "available" ]; then
		echo "available"
		exit 0
	fi

	test -f /usr/local/mariadb/columnstore/post/functions && . /usr/local/mariadb/columnstore/post/functions
	$prefix/mariadb/columnstore/bin/cplogger -w 100 "detachvolume failed status: $STATUS"
	echo $STATUS
	exit 1
}

attachvolume() {

	#detach volume
	$AWSCLI attach-volume --volume-id  $volumeName --instance-id $instanceName --device $deviceName > /tmp/volumeInfo_$volumeName 2>&1

	checkInfostatus
	if [ $STATUS == "attaching" -o $STATUS == "already-attached" ]; then
		retries=1
		while [ $retries -ne 60 ]; do
			#check status until it's attached
			describevolume
			if [ $STATUS == "attached" ]; then
				echo "attached"
				exit 0
			fi
			((retries++))
			sleep 1
		done
		test -f /usr/local/mariadb/columnstore/post/functions && . /usr/local/mariadb/columnstore/post/functions
		$prefix/mariadb/columnstore/bin/cplogger -w 100 "attachvolume failed: $STATUS"
		echo "failed"
		exit 1
	fi

	if [ $STATUS == "attached" ]; then
		echo "attached"
		exit 0
	fi

	test -f /usr/local/mariadb/columnstore/post/functions && . /usr/local/mariadb/columnstore/post/functions
	$prefix/mariadb/columnstore/bin/cplogger -w 100 "attachvolume failed: $STATUS"
	echo $STATUS
	exit 1
}

deletevolume() {
	#delete volume
	$AWSCLI delete-volume --volume-id  $volumeName > /tmp/deletevolume_$volumeName 2>&1
	return
}

createTag() {
	#create tag
	$AWSCLI create-tags --resources  $resourceName --tags Key=$tagName,Value=$tagValue > /tmp/createTag_$volumeName 2>&1
	return
}

case "$1" in
  create)
  	createvolume
	;;
  describe)
  	describevolume
	;;
  detach)
  	detachvolume
	;;
  attach)
  	attachvolume
	;;
  delete)
  	deletevolume
	;;
  createTag)
  	createTag
	;;
  *)
	echo $"Usage: $0 {create|describe|detach|attach|delete|}"
	exit 1
esac

exit $?
