#!/bin/bash

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -c|--config)
    CONFIGFILE="$2"
    shift # past argument
    shift # past value
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [[ -z $CONFIGFILE ]]
then
	echo "Missing Config."
	exit 1
fi

lock_file='/tmp/zfs-repl-lock/'$CONFIGFILE'.lock'
ps_id=$$

if [[ -f "$lock_file" ]]
then
	PID=$(cat "$lock_file" 2> /dev/null)
	if kill -0 $PID 2> /dev/null
	then
		echo "Already running, exiting"
		exit 1
	else
		echo "Not running, removing lock and continuing"
		rm -f "$lock_file"
		echo -n $ps_id > "$lock_file"
	fi
else
	echo -n $ps_id > "$lock_file"
fi

ZFS="/sbin/zfs"

SourceFileSystem="$(cat $CONFIGFILE | grep ^'SourceFS=' | awk -F'=' '{print $2}' | tr -d '"')"
TargetFileSystem="$(cat $CONFIGFILE | grep ^'TargetFS=' | awk -F'=' '{print $2}' | tr -d '"')"
SourceRetention="$(cat $CONFIGFILE | grep ^'SourceRetention=' | awk -F'=' '{print $2}' | tr -d '"')"
TargetRetention="$(cat $CONFIGFILE | grep ^'TargetRetention=' | awk -F'=' '{print $2}' | tr -d '"')"
Local="$(cat $CONFIGFILE | grep ^'TargetFS=' | awk -F'=' '{print $2}' | tr -d '"')"
if [[ ! "$Local" == 0 ]]
then
	echo "Sending to Remote Pool..."
	TargetHost="$(cat $CONFIGFILE | grep ^'TargetHost=' | awk -F '=' '{print $2}' | tr -d '"' )"
	TargetUser="$(cat $CONFIGFILE | grep ^'TargetUser=' | awk -F '=' '{print $2}' | tr -d '"')"
	echo "Target Host: $TargetHost"
	echo "Target User: $TargetUser"
else
	echo "Sending to Local Pool..."
fi
if [[ -z $SourceFileSystem ]] || [[ -z $TargetFileSystem ]] || [[ -z $SourceRetention ]] || [[ -z $TargetRetention ]]
then
	echo "Missing parameters in config file"
	rm -f "$lock_file"
	exit 1
fi

echo "Source File System: $SourceFileSystem"
echo "Target File System: $TargetFileSystem"
echo "Source Snapshot Retention: $SourceRetention"
echo "Target Snapshot Retention: $TargetRetention"

echo "Sanity Checks..."

if [[ ! "$Local" == 0 ]]
then
        if ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" 'exit 0' > /dev/null
        then
                echo "Checking SSH to Target Host...OK"
        else
                echo "Checking SSH to Target Host...Failed"
        fi
fi

if $ZFS list $SourceFileSystem > /dev/null
then
	echo "Checking Source File System...OK"
else
	echo "Checking Source File System...Failed"
	rm -f "$lock_file"
	exit 2
fi

if [[ ! "$Local" == 0 ]]
then
	if ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs list $TargetFileSystem" > /dev/null
	then
		echo "Checking Target File System...OK"
	else
		echo "Checking Target File System...Failed"
		rm -f "$lock_file"
		exit 2
	fi
else
	if $ZFS list $TargetFileSystem > /dev/null
	then
	        echo "Checking Source File System...OK"
	else
	        echo "Checking Source File System...Failed"
		rm -f "$lock_file"
        	exit 2
	fi
fi

DATE="$(date '+%Y%m%d%H%M%S')"
if $ZFS snap "$SourceFileSystem"@'Repl_'$DATE
then
	echo "Taking Snapshot...Successful"
else
	echo "Taking Snapshot...Failed"
	rm -f "$lock_file"
	exit 2
fi

echo "Comparing Snapshots on Source vs Target..."
Count=1
for LocalSnapshot in $($ZFS list -Ht snapshot -o name -s name -d 1 $SourceFileSystem)
do
	echo "############################################################################################################"
	Snap="$(echo $LocalSnapshot | awk -F'@' '{print $2}')"
	TargetSnapshot="$(echo $TargetFileSystem'@'$Snap)"
	if [[ "$Local" == 0 ]]
	then
		if $ZFS get name $TargetSnapshot > /dev/null
		then
			echo "Checking...$TargetSnapshot...OK"
		else
			echo "Checking...$TargetSnapshot...Need to Send to Target"
			if [[ $Count == 1 ]]
			then
				if $ZFS send -v $LocalSnapshot | $ZFS receive -v -F -u $TargetFileSystem
				then
					echo "Sending first Snapshot to Target File System...Successful"
				else
					echo "Sending first Snapshot to Target File System...Failed"
					rm -f "$lock_file"
					exit 2
				fi
			else
				echo "Snapshot 1:" $PerviousLocalSnapshot
				echo "Snapshot 2:" $LocalSnapshot
				if $ZFS send -v -i $PerviousLocalSnapshot $LocalSnapshot | $ZFS receive -v -F -u $TargetFileSystem
				then
					echo "Sending incremental Snapshot to Target File System...Successful"
				else
					echo "Sending incremental Snapshot to Target File System...Failed"
                                        rm -f "$lock_file"
					exit 2
				fi
			fi
		fi
	else
		if ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs get name $TargetSnapshot" > /dev/null
		then
                        echo "Checking...$TargetSnapshot...OK"
                else
                        echo "Checking...$TargetSnapshot...Need to Send to Target"
                        if [[ $Count == 1 ]]
                        then
                                if $ZFS send -v $LocalSnapshot | ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs receive -v -F -u $TargetFileSystem"
                                then
                                        echo "Sending first Snapshot to Target File System...Successful"
                                else
                                        echo "Sending first Snapshot to Target File System...Failed"
                                        rm -f "$lock_file"
                                        exit 2
                                fi
                        else
                                echo "Snapshot 1:" $PerviousLocalSnapshot
                                echo "Snapshot 2:" $LocalSnapshot
                                if $ZFS send -v -i $PerviousLocalSnapshot $LocalSnapshot | ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs receive -v -F -u $TargetFileSystem"
                                then
                                        echo "Sending incremental Snapshot to Target File System...Successful"
                                else
                                        echo "Sending incremental Snapshot to Target File System...Failed"
                                        rm -f "$lock_file"
                                        exit 2
                                fi
                        fi
                fi
	fi
	Count=$((Count+1))
	PerviousLocalSnapshot=$LocalSnapshot
	echo "############################################################################################################"
done

echo "Starting Cleanup of Source Snapshots..."
for LocalSnapshot in $($ZFS list -Ht snapshot -o name -s name -d 1 $SourceFileSystem | head -n-"$SourceRetention")
do
	if [[ -z $LocalSnapshot ]]
	then
		echo "Stopping due to empty Snapshot name"
		rm -f "$lock_file"
		exit 2
	fi
	if $ZFS destroy $LocalSnapshot
	then
		echo "Removing...$LocalSnapshot...Successful"
	else
		echo "Removing...$LocalSnapshot...Failed"
                rm -f "$lock_file"
		exit 2
	fi
done

echo "Starting Cleanup of Target Snapshots..."
if [[ "$Local" == 0 ]]
then
	for TargetSnapshot in $($ZFS list -Ht snapshot -o name -s name -d 1 $TargetFileSystem | head -n-"$TargetRetention")
	do
		if [[ -z $TargetSnapshot ]]
		then
			echo "Stopping due to empty Snapshot name"
			rm -f "$lock_file"
			exit 2
		fi
		if $ZFS destroy $TargetSnapshot
                then
                        echo "Removing...$TargetSnapshot...Successful"
                else
                        echo "Removing...$TargetSnapshot...Failed"
			rm -f "$lock_file"
                        exit 2
                fi
	done
else
        for TargetSnapshot in $(ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs list -Ht snapshot -o name -s name -d 1 $TargetFileSystem | head -n-"$TargetRetention"")
        do
                if [[ -z $TargetSnapshot ]]
                then
                        echo "Stopping due to empty Snapshot name"
			rm -f "$lock_file"
                        exit 2
                fi
		if ssh -q -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" "$TargetUser"@"$TargetHost" "zfs destroy $TargetSnapshot"
		then
			echo "Removing...$TargetSnapshot...Successful"
		else
			echo "Removing...$TargetSnapshot...Failed"
			rm -f "$lock_file"
			exit 2
		fi
        done
fi

rm -f "$lock_file"
exit 0
