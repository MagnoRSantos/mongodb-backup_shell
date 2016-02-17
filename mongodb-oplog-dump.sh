#!/bin/bash

#
# Script for periodic dump and rotation of the MongoDB replication
# oplog to facilitate incremental backup/recovery.
# This script is intended to be schedudled via cron to run on some
# interval, e.g. hourly.
#
# TODO:
#  - validate that we didn't "fall off" the oplog
#  - verify that the previous dump is not still running
#  - which node do we dump from?
#  - output redirection / email
#

PROGNAME=$(basename "$0" | cut -d. -f1)
BACKUPPROG="mongodb-backup"
LOCKNAME="oplogDump"
sendSuccessEmail="no"

source common.sh

lock

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

mkdir -p "$BACKUPDIR/oplog"

if [ -e "$lastBackupTimestampFile" ]; then
    lastBackupTimestamp=$(<"$lastBackupTimestampFile")
fi

if [ -e "$lastOplogTimestampFile" ]; then
    lastOplogTimestamp=$(<"$lastOplogTimestampFile")
fi

maxTimestamp="$(max_number $lastBackupTimestamp $lastOplogTimestamp)"

if [ -n "$maxTimestamp" ]; then
    OPT="$OPT -q \"{ts:{\$gte:Timestamp($maxTimestamp,1)}}\""
fi

# Use mongodump built-in compression? (available only in 3.2+) 
if [ "$COMP" = "mongo" ]; then
    OPT="$OPT --gzip"
fi


DATE=`date +%Y-%m-%d_%H:%M:%S`
FILE="$BACKUPDIR/oplog/$DATE-$maxTimestamp"
mkdir -p "$FILE"


currentDate=`date +%s`

echo "currentDate is $currentDate"
echo "lastBackupTimestamp is $lastBackupTimestamp"
echo "lastOplogTimestamp is $lastOplogTimestamp"
echo "maxTimestamp is $maxTimestamp"


oplogdump $FILE
dbdumpresult=$?

deletedFiles=$(find $BACKUPDIR/oplog  -mindepth 1 -maxdepth 1 -not -newermt "$OPLOG_DAYS_RETENTION day ago" -type d -print -exec rm -rf {} \;)

if [ -n "$deletedFiles" ]; then
    echo "Deleted files older then $OPLOG_DAYS_RETENTION days: $deletedFiles"
fi

cleanupAndExit $dbdumpresult





