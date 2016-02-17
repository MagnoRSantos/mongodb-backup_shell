#!/bin/bash

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

lastBackupTimestampFile=$BACKUPDIR/backup-lastTimestamp
lastOplogTimestampFile=$BACKUPDIR/oplog-lastTimestamp

OPT=""                                            # OPT string for use with mongodump

# Do we need to use a username/password?
if [ "$DBUSERNAME" ]; then
    OPT="$OPT --username=$DBUSERNAME --password=$DBPASSWORD"
    if [ "$REQUIREDBAUTHDB" = "yes" ]; then
        OPT="$OPT --authenticationDatabase=$DBAUTHDB"
    fi
    AUTH_OPT="$OPT"
fi

# Use mongodump built-in compression? (available only in 3.2+) 
if [ "$COMP" = "mongo" ]; then
    OPT="$OPT --gzip"
fi


# Hostname for LOG information
if [ "$DBHOST" = "localhost" -o "$DBHOST" = "127.0.0.1" ]; then
    HOST=`hostname`
    if [ "$SOCKET" ]; then
        OPT="$OPT --socket=$SOCKET"
    fi
else
    HOST=$DBHOST
fi

LOGFILE=$BACKUPDIR/$DBHOST-`date +%Y-%m-%d_%H%M.$$`.log       # Logfile Name
mkdir -p $BACKUPDIR
# IO redirection for logging.
# Redirect STDERR to STDOUT
exec &> >(tee -a "$LOGFILE")

echo "LOGFILE $LOGFILE"

##########################################################################
# Functions
##########################################################################

lock () {
    lock=`$mongo --quiet $AUTH_OPT $primary/mongodb-backup <<-EOF
    var u = db.$LOCKNAME.update(
        {_id: "$setName", lock:false},
        {\\\$set:{
            lock:true,
            lockedBy: "$$"
        }},
        { upsert: true}
    );
    printjson(u);
	EOF`

    lockCheck=`echo $lock | grep -e "\"nUpserted\" : 1" -e "\"nModified\" : 1"`

    authFail=`echo $lock | grep -e "Authentication fail"`
    if [ -n "$authFail" ]; then
        echo "ERROR: Authentication failure, check credentials."
        cleanupAndExit 1
    fi

    if [ -z "$lockCheck" ]; then
        echo "$LOCKNAME is being held, another backup process is running. $lock"
        echo "Exiting"
        exit 0
    else
        echo "$LOCKNAME taken: $lock"
    fi
}

unlock () {
    unlock=`$mongo --quiet $AUTH_OPT $primary/mongodb-backup <<-EOF
    db.$LOCKNAME.findAndModify({
        query: {_id: "$setName", lock:true, lockedBy:"$$"},
        new: true,
        update: {\\\$set:{
            lock: false
        }, \\\$unset:{lockedBy:1}}
    })
	EOF`
    echo "unlock: $unlock"
}

cleanupAndExit () {
    STATUS=$1
    echo "cleanup STATUS=$STATUS, dbdumpresult=$dbdumpresult"
    unlock

    # Clean up IO redirection if we plan not to deliver log via e-mail.
    #[ ! "x$MAILCONTENT" == "xlog" ] && exec 1>&6 2>&7 6>&- 7>&-
    if [ "$MAILCONTENT" = "log" ]; then
        echo "Mailing log to $MAILADDR"    
        if [[ "$dbdumpresult" != "0" || "$STATUS" != "0" ]]; then
            echo "ERROR: Backup exiting with errors."
            cat "$LOGFILE" | mail -s "MongoDB Backup ERRORS REPORTED: Backup log for $HOST - $DATE" $MAILADDR
        elif [[ "$sendSuccessEmail" = "yes" ]]; then
            cat "$LOGFILE" | mail -s "MongoDB Backup Log for $HOST - $DATE" $MAILADDR
        fi
    else
        cat "$LOGFILE"
    fi


    # Clean up Logfile
    #rm -f "$LOGFILE" "$LOGERR"

    exit $STATUS
}


#
# TODO - this needs to be updated to be more intelligent about selecting a secondary
#
rsInfo=`$mongo --quiet <<\EOF
  var primary=rs.isMaster().primary;
  if (primary == null) quit();
  var hosts=rs.isMaster().hosts || [];
  var secondaries = [];
  hosts.forEach(function(e){if (e!== primary) {secondaries.push(e)}});
  var setName=rs.isMaster().setName;
  print(secondaries[0]);
  print(setName);
  print(primary);
EOF`

if [ "$?" -ne "0" ]; then
  echo "Error checking isMaster via mongo shell $rsInfo" 
  cleanupAndExit 1
fi

secondary=`echo $rsInfo | awk '{print $1}'`
setName=`echo $rsInfo | awk '{print $2}'`
primary=`echo $rsInfo | awk '{print $3}'`

if [ -n "$secondary" ]; then
    DBHOST=${secondary%%:*}
    DBPORT=${secondary##*:}
else
    SECONDARY_WARNING="WARNING: No suitable Secondary found in the Replica Sets.  Falling back to ${DBHOST}."
fi


