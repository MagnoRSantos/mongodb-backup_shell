# mongodb-backup
Shell script for automating MongoDB backups

The backup directory should contain the following entries:

```
# ls -lha
total 8.0K
drwxr-xr-x 7 root root 123 Jan 26 16:46 .
drwxr-xr-x 3 root root  20 Jan 26 00:30 ..
-rw-r--r-- 1 root root  11 Jan 26 16:46 backup-lastTimestamp
drwxr-xr-x 2 root root  78 Jan 26 16:46 daily
drwxr-xr-x 2 root root  42 Jan 26 16:46 latest
drwxr-xr-x 2 root root   6 Jan 26 00:30 monthly
drwxr-xr-x 5 root root 117 Jan 26 17:21 oplog
-rw-r--r-- 1 root root  11 Jan 26 17:22 oplog-lastTimestamp
drwxr-xr-x 2 root root   6 Jan 26 00:30 weekly
```

# Restoring a backup

1. Locate the archive file to be restored. Depending on which compression option is configured for the backup, this will be a `tar`, `tgz`, or `.tar.bz2` file.
1. Extract the archive file, for example:

    ```
    tar xvf 2016-01-26_16h46m.Tuesday.tar
    ```
1. Change directory to the backup directory that was extracted:

    ```
    cd 2016-01-26_16h46m.Tuesday
    ```
1. Execute `mongorestore` with the appropriate arguments:

    ```
    mongorestore -u admin -p admin --authenticationDatabase admin --oplogReplay --drop --gzip .
    ```
1. Optionally, replay the oplog


# Replaying the oplog

Depending on the recovery secnario, there are 2 possible scenarios when replaying the oplog

* Replaying an entire oplog file or files
* Partially replaying an oplog file up until a specific point in time or operation

## Replaying entire oplog file(s)

1. In the `oplog` directory identify the sub-directories that contain the oplog(s) to be restored. Each directory corresponds to an individual incremental dump of the oplog. The timestamp of these directories indicate the start time of the oplog dump. Within each of these directories there will be a `local` directory, corresponding to the `local` database which is where the `oplog.rs` collection resides.
1. If necessary, use the `bsondump` utility to verify the contents of a particular dump file.
1. Change to the `local` directory for the oplog to be restored:

    ```
    cd 2016-01-26_16:52:14-1453826769/local
    ```
1. Unzip the `oplog.rs.bson.gz` file and rename `oplog.rs.bson` to `oplog.bson`

    ```
    gunzip oplog.rs.bson.gz
    mv oplog.rs.bson oplog.bson
    ```
1. mongorestore -u admin -p admin --authenticationDatabase admin --oplogReplay .






