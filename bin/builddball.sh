#!/bin/bash

source /usr/local/sbin/HIDSoft/bin/settings.sh

function builddatabase() {
BIN_PREFIX="/usr/local/sbin/HIDSoft/bin"

ALWD_GROUPS=`mysql -u $user -p"$pw" $database -h $host -e "SELECT groups FROM HIDReaders WHERE mac='$1'" | sed 1d`

rm /tmp/cards_raw-$1
touch /tmp/cards_raw-$1

mysql -u $user -p"$pw" $database -h $host -e "SELECT id, cardnum, access, DATE(expires) AS expires, TIME(expires) AS timeexpires FROM HIDCards WHERE groupid IN ($ALWD_GROUPS) AND (deleted is NULL OR deleted > NOW()) AND (expires > NOW() or expires IS NULL) ORDER BY cardnum" | sed 1d >>/tmp/cards_raw-$1

sort -nu /tmp/cards_raw-$1 > /tmp/cards-$1

echo "#n c cn p  u a0 a1 a2 a3 a4 a5 a6 a7 x e m s sD sT eD eT iE oE pE" >/tmp/InputCards-$1

while read line; do
  TIMEEXPIRES=`echo $line | cut -d' ' -f 5`
  EXPIRES=`echo $line | cut -d' ' -f 4`
        if [ ${EXPIRES} != 'NULL' ]; then
          EXPIRES=`echo ${EXPIRES} | tr '-' '/'`
        else
          EXPIRES='0'
          TIMEEXPIRES='0'
        fi
  ACCESS=`echo $line | cut -d' ' -f 3`
  NUM=`echo $line | cut -d' ' -f 2`
  UNIQID=`echo $line | cut -d' ' -f 1`
        if [ ${NUM} == 'd' ]; then
          continue
        fi
  #     n c    cn  p    u       a0 a1 a2 a3 a4 a5 a6 a7 x e 	    m  s sD sT    eD         eT          iE oE pE
  echo "n 0 ${NUM} 0 ${UNIQID}  1  2  0  0  0  0  0  0  0 ${ACCESS} 0  0 0  0  ${EXPIRES} ${TIMEEXPIRES} 0  0  1" >>/tmp/InputCards-$1

done </tmp/cards-$1

#set 1 to 100 at the end of the command to get good logs for debugging.
EXITCODE=`cd ${BIN_PREFIX} && ./buildcards /tmp/InputCards-$1 ${BIN_PREFIX}/NewIdentDB-$1 ${BIN_PREFIX}/NewAccessDB-$1 ${BIN_PREFIX}/FormatsDefault ${BIN_PREFIX}/out-Sets ${BIN_PREFIX}/out-Log-$1 100`

echo ${EXITCODE} | grep "= 0"
if [ $? -eq 0 ]; then
  echo "All good on $1"
else
  echo "Problem with permissions DB for reader $1. \nError Code: $? Exit code: ${EXITCODE} Please check last card added/modified for errors, or remove and try again." >> /tmp/errorlog
  echo "Cards with duplicates are " >> /tmp/errorlog-$1
  cut -d' ' -f3 /tmp/InputCards-$1 | uniq -c | grep -v '^ *1 ' >> /tmp/errorlog-$1
  echo "The raw output" >> /tmp/errorlog-$1
  cut -d' ' -f3 /tmp/InputCards-$1 | uniq -c >> /tmp/errorlog-$1
  cat /tmp/errorlog-$1 | mail -s "HID DB Build Failure" someuser@somedomain.com
  rm /tmp/errorlog-$1
  cp /tmp/InputCards-$1 /tmp/InputCards-$1-BAD
fi

cp ${BIN_PREFIX}/NewIdentDB-$1  /tmp/NewIdentDB-$1
cp ${BIN_PREFIX}/NewAccessDB-$1  /tmp/NewAccessDB-$1

}

if [ -n "$1" ]; then
builddatabase $1
else
	ALLGROUP=`mysql -u $user -p"$pw" $database -h $host -e "select mac from HIDReaders where Deleted = '0000-00-00 00:00:00' OR Deleted >= NOW() OR Deleted IS NULL" | sed 1d`
	for i in $ALLGROUP; do
        builddatabase $i
        done
fi
