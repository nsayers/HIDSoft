#!/bin/bash

source /usr/local/sbin/HIDSoft/bin/settings.sh

function builddatabase() {
        mysql -u $user -p"$pw" $database -h $host -e "SELECT id, cardnum, DATE(expires) AS expires, TIME(expires) AS timeexpires FROM HIDCards WHERE "`for i in $THE_GROUP; do echo groupid = '$i' OR ; done`" groupid = '10' AND deleted is NULL OR deleted > NOW() order by cardnum" | sed 1d >>/tmp/neil_raw-$1
echo "SELECT id, cardnum, DATE(expires) AS expires, TIME(expires) AS timeexpires FROM HIDCards WHERE "`for i in $THE_GROUP; do echo groupid = '$i' OR ; done`" groupid = '10' AND deleted is NULL OR deleted > NOW() order by cardnum"
}

if [ -n "$1" ]; then
builddatabase $1
else
        ALLGROUP=`mysql -u $user -p"$pw" $database -h $host -e "select mac from HIDReaders where Deleted = '0000-00-00 00:00:00' OR Deleted >= NOW()" | sed 1d`
for i in $ALLGROUP; do
	builddatabase $i
	done
fi
