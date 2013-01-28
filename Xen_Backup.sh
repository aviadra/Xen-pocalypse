#!/bin/bash
#logging to syslog

logger_xen()
{
if [[ -n "$1" ]]; then
DATE="$( date +%D-%T )"
[[ "$2" = "expose" || $DEBUG != "0" ]] && logger -s -p local0.notice -t Xen_funcy_backup_script "	  $1" && Email_func "$1" #usaful for manual runs, but not for Cron ones.
logger -p local0.notice -t Xen_funcy_backup_script "	  $1"
Email_VAR="$Email_VAR $DATE:	  $1 \n"
else
	#logger -s -p local0.notice -t Xen_funcy_backup_script " " #usaful for manual runs, but not for Cron ones.
	logger -p local0.notice -t Xen_funcy_backup_script " "
	Email_VAR="$Email_VAR \n"
fi
}
Email_func()
{
	MSG="$1"
	[[ ! -e $SendEmail_location && $DEBUG = "0" ]] && logger_xen "You are missing the SendEmail perl"
	[[ -z "$2" ]] && EMAIL_SUB="Report" || EMAIL_SUB="$2"
	#[[ $2 =~ .*Exception.* ]] && MSG="$MSG \n\n The VM list was obtained using $LIST_METHOD \n"
	[[ $2 =~ .*Exception.* ]] && MSG="$MSG \n\n The VM list was obtained using $LIST_METHOD \n" && if [[ $LIST_METHOD = "FILE" ]]; then echo 1; fi
	[[ $DEBUG = "0" ]] && [[ -e $SendEmail_location ]] && $SendEmail_location -f "$EMAIL_FROM" -t "$EMAIL_TO" -u "Xen_backup - $EMAIL_SUB" -s "$EMAIL_SMART_HOST" -q -m "$MSG"
} 
xen_xe_cmd()
{
	xencmd="/opt/xensource/bin/xe"
	case $2 in
		name_2_uuid)
			export VM_UUID="$( $xencmd vm-list name-label=$1 | grep uuid | awk '{ print $5 }' )"
			[[ $DEBUG = "10" ]] && logger_xen "VM_UUID for $1 has been set to $VM_UUID"
			;;
		state)
			POWERSTATE="$( $xencmd vm-param-get param-name=power-state uuid=$VM_UUID )"
			[[ $DEBUG = "1" ]] && logger_xen "POWERSTATE for $1 has been set to $POWERSTATE"
			;;
		export)
			if [[ $ENABLE_COMPRESSION = "yes" ]]; then
					export_cmd="$xencmd vm-export compress=true name-label=$1 filename=$BackupLocation/$1.xva"
				else
					export_cmd="$xencmd vm-export name-label=$1 filename=$BackupLocation/$1.xva"
			fi
			if [[ $DEBUG = "0" ]]; then
				$export_cmd
				if [[ "`echo $?`" -eq 0 ]]; then
					EXPORT="OK"
					logger_xen "Successfully exported $1 :)"
					logger_xen "Will now wait for 5s, to let $1 time to cool-down"
					sleep 5
				else
					EXPORT="FAILED"
					logger_xen "Failed to export :\ " "expose"
					#Email_func "Failed to export $1" "Exception!!"
					#continue
				fi
			else
				logger_xen "Export CMD was: $export_cmd"
				EXPORT="OK"
				logger_xen "Debug is turned on, skipped actually exporting to save time."
			fi
			;;
		vm_properties)
			[[ $DEBUG = "1" ]] && logger_xen "vm_properties for $1 has been invoked"
			if [[ -z "$( $xencmd vm-list name-label=$1 )" ]]; then
				logger_xen "The VM $1 is in the backup list, but does not exist?" "expose"
				#Email_func "The VM $1 is in the backup list, but does not exist?" "Exception!!"
				continue
			else
				xen_xe_cmd "$1" "name_2_uuid"
				xen_xe_cmd "$1" "deps_state_custom"
			fi
			;;
		start)
			$xencmd vm-start name-label="$1"
			if [[ "`echo $?`" -eq 0 ]] ; then
				logger_xen "Successfully started $1"
			else
				logger_xen "FAILED to start $1"
				logger_xen "Waiting for 10s and retrying to start VM $1"
				sleep 10
				$xencmd vm-start name-label="$1"
				if [[ "`echo $?`" -eq 0 ]] ;then
					logger_xen "Retry to start VM $1 was successful"
				else
					logger_xen "FAILED again to start $1. Will sleep for $WARM_UP_DELAY seconds and try a third and final time"
					sleep $WARM_UP_DELAY
					$xencmd vm-start name-label="$1"
					if [[ "`echo $?`" -eq 0 ]] ;then
						logger_xen "Retry to start VM $1 was successful"
					else
						logger_xen "FAILED twice to start $1" "Exception!!" "expose"
						#Email_func "FAILED twice to start $1" "Exception!!"
						continue
					fi
					 
				fi
			fi
			;;
		org_state)
			xen_xe_cmd "$1" "state"
			ORG_STATE=$POWERSTATE
			logger_xen "ORG_STATE for $1 as been set to $ORG_STATE"
			;;
		shutdown)
			xen_xe_cmd "$1" "state"
			if [[ $POWERSTATE != "halted" ]] ; then
				[[ $DEBUG = "1" ]] && logger_xen "About to: $xencmd vm-shutdown name-label=$1"
				$xencmd vm-shutdown name-label="$1"
				if [[ "`echo $?`" -eq 0 ]] ;then
					logger_xen "Successfully shutdown VM $1"
					logger_xen "Will now wait for 5s, to let $1 time to cool-down"
					sleep 5
				else
					logger_xen "Something went wrong when shutting down the VM $1" "expose"
					#Email_func "Something went wrong when shutting down the VM $1" "Exception!!"
					continue
				fi
			fi
			xen_xe_cmd "$1" "state"
			;;
		deps_state_custom)
			xen_xe_cmd "$1" "name_2_uuid"
			#reset state
			DEP_STATE="null"
			CHILDREN_LIST="null"
			PARENT="null"
			CHILDREN_LIST="$( $xencmd vm-param-get uuid=$VM_UUID param-name=other-config param-key=XenCenter.CustomFields.Children 2> /dev/null )"
			if [[ "`echo $?`" -eq 0 ]] ; then
				logger_xen "VM has children. They are: $CHILDREN_LIST"
				DEP_STATE="dep_parent"
			else
				[[ $DEBUG = "1" ]] && logger_xen "No Children were found for $1. looking for a PARENT."
				PARENT="$( $xencmd vm-param-get uuid=$VM_UUID param-name=other-config param-key=XenCenter.CustomFields.Parent 2> /dev/null )"
				if [[ "`echo $?`" -eq 0 ]] ; then
					logger_xen "VM has a Parent. It is: $PARENT"
					DEP_STATE="dep_child"
				else
					[[ $DEBUG = "1" ]] &&  logger_xen "No Parent was found for $1."
				fi
			fi
			[[ $DEBUG = "1" ]] &&  logger_xen "DEP_STATE has been set to: $DEP_STATE. the current CHILDREN_LIST is: $CHILDREN_LIST and the PARENT is: $PARENT."
			;;

		space_for_backup_check)
			DISKS_SIZE=0
			for DISK in $( xe vm-disk-list vm=$1 | grep virtual-size | awk '{print $4}' ); do 
				logger_xen "Disk with the size of $DISK, was found for VM $1"
				DISKS_SIZE=$(( $DISKS_SIZE + $DISK ))
			done
			logger_xen "Total disks size is $DISKS_SIZE"
			FREE_SPACE="$( df $BackupLocation | grep $BackupLocation | awk '{print $3}' )"
			[[ $DEBUG = "1" ]] && logger_xen "FREE_SPACE="$( df $BackupLocation | grep $BackupLocation | awk '{print $3}' )""
			[[ $DEBUG = "1" ]] && logger_xen "BackupLocation is: $BackupLocation"
			FREE_SPACE_IN_BYTES=$(( $FREE_SPACE * 1024 ))
			if [[ $(( $FREE_SPACE_IN_BYTES - $DISKS_SIZE * 2 )) -le "1000000000" ]]; then
				logger_xen "Disqualified VM $1 for export, because the VM aggregate disk size is $(( $DISKS_SIZE / 1000000000 ))G and had we continued with this export, less than 10G would be left on the backup location." "expose"
				#Email_func "Disqualified VM $1 for export, because the VM aggregate disk size is $(( $DISKS_SIZE / 1000000000 ))G and had we continued with this export, less than 10G would be left on the backup location." "Exception - Disqualification"
				logger_xen "" # log formatting
				continue
			else
				[[ $DEBUG = "1" ]] && logger_xen "There was enough space for the backup :)"
				logger_xen "" # log formatting
			fi
		;;
		 
		*) logger_xen "Incorrect use of xe func"
	esac
}
backup_func()
{
	xen_xe_cmd "$1" "vm_properties"
	xen_xe_cmd "$1" "space_for_backup_check"
	xen_xe_cmd "$1" "org_state"
	[[ -e $BackupLocation/$1.xva ]] && mv -v $BackupLocation/$1.xva $BackupLocation/$1.xva.org && logger_xen "Moved old backup to temp location"
	[[ $POWERSTATE = "running" ]] && xen_xe_cmd "$1" "shutdown"
	logger_xen "Now exporting $1"
	xen_xe_cmd "$1" "export"
	[[ $ORG_STATE = "running" ]] && [[ "$2" != "child" ]] && logger_xen "Now starting up $1, because ORG_STATE was $ORG_STATE" && xen_xe_cmd "$1" "start" && logger_xen "Giving $WARM_UP_DELAY seconds so that $1 finishes warming up" && sleep $WARM_UP_DELAY
	[[ $2 = "child" ]] && logger_xen "This VM is a CHILD, will not start it until PARENT is done."
	[[ $EXPORT = "OK" ]] && rm -iv $BackupLocation/$1.xva.org -f && logger_xen "Deleted old backup as new one is OK"
}
##################ENGINE#############################################
logger_xen "Welcome to the funcky xen backup script that uses functions."
logger_xen "" # log formatting

if [[ -z "$@" ]]; then
	logger_xen "You must pass first argument settings file and second argument backup TAG or file to work on." "expose"
fi

SETTINGS_FILE="$1"
[[ ! -e $SETTINGS_FILE ]] && logger_xen "Settings file, $SETTINGS_FILE not found" && exit 2
if [[ -n $( head -1 $SETTINGS_FILE | grep "settings file for the funcky" ) ]]; then 
	source $SETTINGS_FILE && logger_xen "Settings file header found in $SETTINGS_FILE, so it was sourced."
else
	logger_xen "The appropriate header, was NOT found in the designated settings file. The so called settings file $SETTINGS_FILE was NOT sourced and Xen-pocalypse will now exit." "expose" && exit 2
fi
logger_xen "" # log formatting
Email_func "$Email_VAR" "Started"

if [[ $DEBUG = "0" ]]; then WARM_UP_DELAY=60; else WARM_UP_DELAY=5 ; fi

#massaging BackupLocation, so that it doesn't have trailing slashes
BackupLocation=${BackupLocation%/}; [[ $DEBUG = "1" ]] && logger_xen "BackupLocation trailing slash have been removed"


#VM list arbitrator
if [[ $LIST_METHOD = "FILE" ]]; then
	logger_xen "VM List method in the settigns file was $LIST_METHOD, so Xen-pocalypse will now treat the second argument $2 as a file."
	FILELIST="$2"
	[[ ! -e $FILELIST ]] && logger_xen "Filelist $FILELIST not found. Make sure the file is accessible." "expose" && exit 2
	[[ -z "$( cat $FILELIST )" ]] && logger_xen "Filelist $1 Cannot be empty!" "expose" && exit 2
	[[ -n $( head -1 $FILELIST | grep "settings file for the funcky" ) ]] && logger_xen "You are trying to use the settings file as the Filelist. Stop it...\n First argument is the settings file, second is the file list." "expose" && exit 2
	logger_xen "VM List $FILELIST found and had content. Will now process VM list from $FILELIST."; logger_xen "" # log formatting"
	VM_LIST="$( cat $FILELIST )"

elif [[ $LIST_METHOD = "TAGs" ]]; then
	logger_xen "VM List method in the settigns file was $LIST_METHOD, so Xen-pocalypse will now treat the second argument $2 as a TAG."
	TAG="$2"
	VM_LIST="$( xe vm-list other-config:XenCenter.CustomFields.backupTAG=$TAG params=uuid | grep uuid| awk '{print $5}' )"
else
	logger_xen "No recognized LIST_METHOD was given. The options are: FILE or TAGs. Please configure the settings file correctly and try again." 
fi

#The work.
for VM in $VM_LIST; do
	logger_xen "Working on $VM"
	xen_xe_cmd "$VM" "vm_properties"
	if [[ $DEP_STATE = "dep_parent" ]]; then
		logger_xen "Found that $VM is a Parent for $CHILDREN_LIST. Will now backup the children."
		for CHILD in $CHILDREN_LIST; do
			logger_xen "Backing up CHILD $CHILD for PARENT $VM"
			backup_func "$CHILD" "child"
			logger_xen "" # log formatting
		done
		logger_xen "Done backing-up the children and will now backup the PARENT $VM"
		backup_func "$VM"
		logger_xen "Now that PARENT $PARENT has been backed-up, will now start children $CHILDREN_LIST"
		for CHILD in $CHILDREN_LIST; do
			xen_xe_cmd "$CHILD" "start"
		done
		logger_xen "Done starting all children for $VM"
		logger_xen "" # log formatting
	elif [[ $DEP_STATE = "dep_child" ]]; then
			logger_xen "Found this VM $VM to be a CHILD of $PARENT, so skipping it for now."
			logger_xen "" # log formatting
	fi
	[[ $DEP_STATE = "null" ]] && backup_func "$VM"
	logger_xen "" # log formatting
done
 
#Yey Done
logger_xen "Backup script has finished its run and will now Email the report."
Email_func "$Email_VAR"
