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
# Locking

The backup will attempt to hold a lock which is a document in the ``mongodb-backup`` database. If multiple backup scripts are executed at the same time, only the first process that obtains the lock will succeed. This is intented to provide the ability to have multiple machines attempt a backup at the same time to avoid missing backups in the event of a server outage.

Failure to obtain the lock is not treated as an error condition. The output would appear as follows in the event of not obtaining the lock:

	```javascript	
	{
	    "ts" : Timestamp(1454968730, 1),
	    "t" : NumberLong(3),
	    "h" : NumberLong("1729104610031904583"),
	    "v" : 2,
	    "op" : "c",
	    "ns" : "test.$cmd",
	    "o" : { "dropDatabase" : 1 }
	}
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
1. Execute `mongorestore` with the appropriate arguments. The `oplogReplay` option should normally be used here to include any oplog entries added while the backup was being taken.

    ```
    mongorestore -u admin -p admin --authenticationDatabase admin --oplogReplay --drop --gzip .
    ```
1. Optionally, replay the oplog


# Replaying the oplog

Depending on the recovery secnario, there are 2 possible scenarios when replaying the oplog

* Replaying an entire oplog file or files
* Partially replaying an oplog file up until a specific point in time or operation

The oplog must be replayed in order with no gaps from the time that the dump was taken. The oplog entries are idempotent, meaning the oplog entries can be replayed multiple times up to a specific point.

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

## Replaying oplog file(s) to a point in time or operation

In order to replay the oplog up to a specific operation, we may need to first identify a specific operation in the oplog that will be the endpoint or last transaction that should be replayed. Assuming that a MongoDB instance is online and available and the corresponding oplog entries are still present, the `oplog.rs` collection in the `local` database can be queried via the mongo shell to identify the desired endpoint. Alternatively, the raw oplog dump files can be converted from binary form to JSON using the `bsondump` utility or loaded into a temporary collection where the entries can be queried.

If only a specific time is required, we can specify a Timestamp to be used as the endpoint.

Every entry in the oplog has a [Timestamp](https://docs.mongodb.org/manual/reference/bson-types/#document-bson-type-timestamp) corresponding to the operation time for each operation. The first field of the Timestamp is a 32-bit integer representing the number of seconds since Unix epoch.

### Example 1 - Recover to a specific time
Assume that we want to restore a database up until 9:30AM on February 8, 2016.

1. Restore the nightly backup prior to the desired point in time
1. Restore eash of the full oplog dumps, following the steps from the previous section. Assuming we are taking hourly oplog backups, and assuming the backups are taken at midnight we would restore the oplog dumps for 1AM through 6AM.
1. Prepare for a partial replay of the oplog file containing the desired restore point. Convert the datetime of the desired restore point to an epoch time using the mongo shell:

    ```javascript
    var date = ISODate("2016-02-08T09:30:00.000-0800")
    date.getTime()/1000
    1454952600
    ```
1. Extract the bson files using the same steps as before
1. Run the `mongorestore` command with the `oplogReplay` and `oplogLimit` options. Note the the ``oplogLimit`` option specifies an exclusive endpoint for the replay, only transactions **newer** than the specified timestamp will be replayed.

    ```
    mongorestore -u admin -p admin --authenticationDatabase admin --oplogReplay --oplogLimit 1454952600:1 .
    ```
    
### Example 2 - Recover to a specific operation
Assume that we are able to identify a specific operation that is the last known good point at which we want to restore a database. For example, if a database were accidently dropped we may want to recover all transactions that occurred up until the point that the database was dropped.

1. Restore the nightly backup prior to the desired operation
1. Identify the timestamp of recovery endpoint, the first operation that we wish to exclude from oplog replay. For example, this could be the timestamp of the drop database command. A drop database command would look like this in the oplog:

	```javascript	
	{
	    "ts" : Timestamp(1454968730, 1),
	    "t" : NumberLong(3),
	    "h" : NumberLong("1729104610031904583"),
	    "v" : 2,
	    "op" : "c",
	    "ns" : "test.$cmd",
	    "o" : { "dropDatabase" : 1 }
	}
	```

    Given that, we should be able to query any such entries in the oplog to identify the timestamp of the offending operation which would be used as the recovery endpoint. For example:

	```
	use local
	db.oplog.rs.find({op:"c", o:{dropDatabase:1}})
	```
    
Record the timestamp of the offending operation which will be used in the following steps.
    
1. Extract the bson files using the same steps as before
1. Run the `mongorestore` command with the `oplogReplay` and `oplogLimit` options. Note the the ``oplogLimit`` option specifies an exclusive endpoint for the replay, only transactions **newer** than the specified timestamp will be replayed.

    ```
    mongorestore -u admin -p admin --authenticationDatabase admin --oplogReplay --oplogLimit 1454968730:1 .
    ```




