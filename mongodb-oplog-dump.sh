#!/bin/bash

PROGNAME=$(basename "$0" | cut -d. -f1)
BACKUPPROG="mongodb-backup"

# Read config files, use the same config files as the backup script
for file in /etc/default/$BACKUPPROG /etc/sysconfig/$BACKUPPROG ./$BACKUPPROG; do
  if [ -f "$file" ]; then
      echo "Reading config file $file"
      source $file
  fi
done

# Include extra config file if specified on commandline, e.g. for backuping several remote dbs from central server
if [ ! -z "$1" ] && [ -f "$1" ]; then
    echo "Reading extra commandline config file $1"
    source ${1}
fi

mongodump="${BINPATH}mongodump"
mongo="${BINPATH}mongo"

## Functions
############################################################

oplogdump () {
    if [[ -z $1 ]]; then
        echo "FATAL: Output path not defined, check configuration"
        cleanupAndExit 1
    fi
    echo "Starting mongodump for $DBHOST:$DBPORT to $1"
    $mongodump --version
    $mongodump --host=$DBHOST:$DBPORT -d local -c oplog.rs --out=$1 $OPT
    resultcode=$?
    echo "mongodump result: $resultcode"
    if [[ $resultcode != 0 ]]; then
      echo "ERROR mongodump exited with code $resultcode"
    else
      echo $currentDate > $lastOplogTimestampFile
    fi
    return $resultcode
}

max_number() {
    printf "%s\n" "$@" | sort -g | tail -n1
}

############################################################

mkdir -p $BACKUPDIR/oplog

if [ -e "$lastBackupTimestampFile" ]; then
    lastBackupTimestamp=$(<"$lastBackupTimestampFile")
fi

if [ -e "$lastOplogTimestampFile" ]; then
    lastOplogTimestamp=$(<"$lastOplogTimestampFile")
fi

maxTimestamp="$(max_number $lastBackupTimestamp $lastOplogTimestamp)"

if [ -n "$maxTimestamp" ]; then
    OPT="$OPT -q '{ts:{\$gte:Timestamp($maxTimestamp,1)}}'"
fi
echo "$OPT"

currentDate=`date +%s`

echo "currentDate is $currentDate"
echo "lastBackupTimestamp is $lastBackupTimestamp"
echo "lastOplogTimestamp is $lastOplogTimestamp"
echo "maxTimestamp is $maxTimestamp"

FILE="$BACKUPDIR/oplog/$currentDate"

oplogdump $FILE




