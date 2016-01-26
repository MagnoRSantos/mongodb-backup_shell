#!/bin/bash

#
# This script is a hacked up version of automongodbbackup 
# (https://github.com/micahwedemeyer/automongobackup)
# which is itself a hacked up copy of mysqlautobackup
# (http://sourceforge.net/projects/automysqlbackup/).
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

PROGNAME=$(basename "$0" | cut -d. -f1)

# Read config files 
for file in /etc/default/$PROGNAME /etc/sysconfig/$PROGNAME; do
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

command -v mail >/dev/null 2>&1 || { echo >&2 "mail command required but it's not installed.  Aborting."; exit 1; }


shellout () {
    if [ -n "$1" ]; then
        echo $1
        exit 1
    fi
    exit 0
}


#=====================================================================
currentDate=`date +%s`
PATH=/usr/local/bin:/usr/bin:/bin
DATE=`date +%Y-%m-%d_%Hh%Mm`                      # Datestamp e.g 2002-09-21
DOW=`date +%A`                                    # Day of the week e.g. Monday
DNOW=`date +%u`                                   # Day number of the week 1 to 7 where 1 represents Monday
DOM=`date +%d`                                    # Date of the Month e.g. 27
M=`date +%B`                                      # Month e.g January
W=`date +%V`                                      # Week Number e.g 37
LOGFILE=$BACKUPDIR/$DBHOST-`date +%H%M`.log       # Logfile Name
LOGERR=$BACKUPDIR/ERRORS_$DBHOST-`date +%H%M`.log # Logfile Name
BACKUPFILES=""

# Do we use oplog for point-in-time snapshotting?
if [ "$OPLOG" = "yes" ]; then
    OPT="$OPT --oplog"
fi

# Do we need to backup only a specific database?
if [ "$DBNAME" ]; then
  OPT="$OPT -d $DBNAME"
fi

# Do we need to backup only a specific database?
if [ "$DBNAME" ]; then
  OPT="$OPT -d $DBNAME"
fi

# Create required directories
mkdir -p $BACKUPDIR/{daily,weekly,monthly} || shellout 'failed to create directories'

if [ "$LATEST" = "yes" ]; then
    rm -rf "$BACKUPDIR/latest"
    mkdir -p "$BACKUPDIR/latest" || shellout 'failed to create directory'
fi

# Check for correct sed usage
if [ $(uname -s) = 'Darwin' -o $(uname -s) = 'FreeBSD' ]; then
    SED="sed -i ''"
else
    SED="sed -i"
fi

# IO redirection for logging.
# Redirect STDERR to STDOUT
exec &> >(tee -a "$LOGFILE")
#exec 2>&1

#touch $LOGFILE
#exec 6>&1           # Link file descriptor #6 with stdout.
                    # Saves stdout.
#exec > $LOGFILE     # stdout replaced with file $LOGFILE.


#touch $LOGERR
#exec 7>&2           # Link file descriptor #7 with stderr.
                    # Saves stderr.
#exec 2> $LOGERR     # stderr replaced with file $LOGERR.

# When a desire is to receive log via e-mail then we close stdout and stderr.
#[ "x$MAILCONTENT" == "xlog" ] && exec 6>&- # 7>&-

# Functions

# Database dump function
dbdump () {
    if [[ -z $1 ]]; then
        echo "FATAL: Output path not defined, check configuration"
        cleanupAndExit 1
    fi
    echo "Starting mongodump for $DBHOST:$DBPORT to $1"
    $mongodump --version
    $mongodump --host=$DBHOST:$DBPORT --out=$1 $OPT
    resultcode=$?
    echo "mongodump result: $resultcode"
    if [[ $resultcode != 0 ]]; then
      echo "ERROR mongodump exited with code $resultcode"
    else
      echo $currentDate > $lastBackupTimestampFile
    fi
    return $resultcode
}


# Compression function plus latest copy
compression () {
    SUFFIX=""
    dir=$(dirname $1)
    file=$(basename $1)
    if [ -n "$COMP" ]; then
        [ "$COMP" = "gzip" ] && SUFFIX=".tgz"
        [ "$COMP" = "bzip2" ] && SUFFIX=".tar.bz2"
        if [ "$COMP" = "mongo" ]; then
            SUFFIX=".tar"
            cd "$dir" && tar -cvf "$file$SUFFIX" $file
        else
            echo Tar and $COMP to "$file$SUFFIX"
            cd "$dir" && tar -cf - "$file" | $COMP -c > "$file$SUFFIX"
            cd - >/dev/null || return 1
        fi
    else
        echo "No compression option set, check advanced settings"
    fi

    if [ "$LATEST" = "yes" ]; then
        if [ "$LATESTLINK" = "yes" ];then
            COPY="ln"
        else
            COPY="cp"
        fi
        $COPY "$1$SUFFIX" "$BACKUPDIR/latest/"
    fi

    if [ "$CLEANUP" = "yes" ]; then
        echo Cleaning up folder at "$1"
        rm -rf "$1"
    fi

    return 0
}

cleanupAndExit () {
    STATUS=$1

    # Clean up IO redirection if we plan not to deliver log via e-mail.
    #[ ! "x$MAILCONTENT" == "xlog" ] && exec 1>&6 2>&7 6>&- 7>&-
    
    if [ "$MAILCONTENT" = "log" ]; then
    
        if [[ $dbdumpresult != 0 ]]; then
            cat "$LOGFILE" | mail -s "MongoDB Backup ERRORS REPORTED: Backup log for $HOST - $DATE" $MAILADDR
        else
            cat "$LOGFILE" | mail -s "MongoDB Backup Log for $HOST - $DATE" $MAILADDR
        fi
    else
        cat "$LOGFILE"
    fi
    
    # Clean up Logfile
    rm -f "$LOGFILE" "$LOGERR"
    
    exit $STATUS
}

# Run command before we begin
if [ "$PREBACKUP" ]; then
    echo ======================================================================
    echo "Prebackup command output."
    echo
    eval $PREBACKUP
    echo
    echo ======================================================================
    echo
fi


secondary=`$mongo --quiet <<\EOF
  var primary=rs.isMaster().primary;
  if (primary == null) quit();
  var hosts=rs.isMaster().hosts || [];
  var secondaries = [];
  hosts.forEach(function(e){if (e!== primary) {secondaries.push(e)}});
  print(secondaries[0]);
EOF`

if [ -n "$secondary" ]; then
    DBHOST=${secondary%%:*}
    DBPORT=${secondary##*:}
else
    SECONDARY_WARNING="WARNING: No suitable Secondary found in the Replica Sets.  Falling back to ${DBHOST}."
fi



echo ======================================================================
echo MongoDB Backup Report

if [ ! -z "$SECONDARY_WARNING" ]; then
    echo
    echo "$SECONDARY_WARNING"
fi

echo
echo Backup of Database Server - $HOST on $DBHOST
echo ======================================================================

echo Backup Start `date`
echo ======================================================================
# Monthly Full Backup of all Databases
if [[ $DOM = "01" ]] && [[ $DOMONTHLY = "yes" ]]; then
    echo Monthly Full Backup
    echo
    # Delete old monthly backups while respecting the set rentention policy.
    if [[ $MONTHLYRETENTION -ge 0 ]] ; then
        NUM_OLD_FILES=`find $BACKUPDIR/monthly -depth -not -newermt "$MONTHLYRETENTION month ago" -type f | wc -l`
        if [[ $NUM_OLD_FILES -gt 0 ]] ; then
            echo Deleting "$NUM_OLD_FILES" global setting backup file\(s\) older than "$MONTHLYRETENTION" month\(s\) old.
	    find $BACKUPDIR/monthly -not -newermt "$MONTHLYRETENTION month ago" -type f -delete
        fi
    fi
    FILE="$BACKUPDIR/monthly/$DATE.$M"

# Weekly Backup
elif [[ $DNOW = $WEEKLYDAY ]] && [[ $DOWEEKLY = "yes" ]] ; then
    echo Weekly Backup
    echo
    if [[ $WEEKLYRETENTION -ge 0 ]] ; then
        # Delete old weekly backups while respecting the set rentention policy.
        NUM_OLD_FILES=`find $BACKUPDIR/weekly -depth -not -newermt "$WEEKLYRETENTION week ago" -type f | wc -l`
        if [[ $NUM_OLD_FILES -gt 0 ]] ; then
            echo Deleting $NUM_OLD_FILES global setting backup file\(s\) older than "$WEEKLYRETENTION" week\(s\) old.
            find $BACKUPDIR/weekly -not -newermt "$WEEKLYRETENTION week ago" -type f -delete
        fi
    fi
    FILE="$BACKUPDIR/weekly/week.$W.$DATE"

# Daily Backup
elif [[ $DODAILY = "yes" ]] ; then
    echo Daily Backup of Databases
    echo
    # Delete old daily backups while respecting the set rentention policy.
    if [[ $DAILYRETENTION -ge 0 ]] ; then
        NUM_OLD_FILES=`find $BACKUPDIR/daily -depth -name "*.$DOW.*" -not -newermt "$DAILYRETENTION week ago" -type f | wc -l`
        if [[ $NUM_OLD_FILES > 0 ]] ; then
            echo Deleting $NUM_OLD_FILES global setting backup file\(s\) made in previous weeks.
            find $BACKUPDIR/daily -name "*.$DOW.*" -not -newermt "$DAILYRETENTION week ago" -type f -delete		
        fi
    fi
    FILE="$BACKUPDIR/daily/$DATE.$DOW"

fi

dbdump $FILE 
dbdumpresult=$?

echo dbdumpresult $dbdumpresult

if [[ $dbdumpresult = 0 ]]; then
    compression $FILE
fi



echo ----------------------------------------------------------------------
echo Backup End Time `date`
echo ======================================================================

echo Total disk space used for backup storage..
echo Size - Location
echo `du -hs "$BACKUPDIR"`
echo
echo ======================================================================

# Run command when we're done
if [ "$POSTBACKUP" ]; then
    echo ======================================================================
    echo "Postbackup command output."
    echo
    eval $POSTBACKUP
    echo
    echo ======================================================================
fi

cleanupAndExit $dbdumpresult
