#!/bin/bash

source /usr/local/sbin/HIDSoft/bin/settings.sh

if [ -n "$1" ]; then
READER_ID=$1
else
echo "ERROR: Please provide reader ID."
exit
fi

BIN_PREFIX="/usr/local/sbin/HIDSoft/bin"

ALWD_GROUPS=`mysql -u $user -p"$pw" $database -h $host -e "SELECT groups FROM HIDReaders WHERE mac='${READER_ID}'" | sed 1d`

rm /tmp/cards_raw

i=0
THE_GROUP="100"

while [ -n "$THE_GROUP" ]; do
	i=$(($i+1))
	THE_GROUP_2=`echo $THE_GROUP`
	THE_GROUP=`echo $ALWD_GROUPS | cut -d',' -f $i`
	[ -n "$THE_GROUP" ] && mysql -u $user -p"$pw" $database -h $host -e "SELECT id, cardnum, DATE(expires) AS expires, TIME(expires) AS timeexpires FROM HIDCards WHERE groupid='`echo -n "$THE_GROUP"`' AND deleted is NULL OR deleted > NOW()" | sed 1d >>/tmp/cards_raw
	[ "$THE_GROUP" = "$THE_GROUP_2" ] && break
done

sort -nu /tmp/cards_raw > /tmp/cards

echo "#n c cn p  u a0 a1 a2 a3 a4 a5 a6 a7 x e m s sD sT eD eT iE oE pE" >/tmp/InputCards

while read line; do
  TIMEEXPIRES=`echo $line | cut -d' ' -f 4`
  EXPIRES=`echo $line | cut -d' ' -f 3`
	if [ ${EXPIRES} != 'NULL' ]; then
	  EXPIRES=`echo ${EXPIRES} | tr '-' '/'`
	else
	  EXPIRES='0'
	  TIMEEXPIRES='0'
	fi
  NUM=`echo $line | cut -d' ' -f 2`
  UNIQID=`echo $line | cut -d' ' -f 1`
	if [ ${NUM} == 'd' ]; then
	  continue
	fi
  #     n c cn     p u          a0 a1a2a3a4a5a6a7x e m  s sD         sT       eD         eT             iEoEpE
  echo "n 0 ${NUM} 0 ${UNIQID}  1  2 0 0 0 0 0 0 0 0 0  0 2013/01/01 00:00:00 ${EXPIRES} ${TIMEEXPIRES} 0 0 1" >>/tmp/InputCards

done </tmp/cards

#set 1 to 100 at the end of the command to get good logs for debugging.
EXITCODE=`cd ${BIN_PREFIX} && ./buildcards /tmp/InputCards ${BIN_PREFIX}/NewIdentDB ${BIN_PREFIX}/NewAccessDB ${BIN_PREFIX}/FormatsDefault ${BIN_PREFIX}/out-Sets ${BIN_PREFIX}/out-Log 100`

echo ${EXITCODE} | grep "= 0"
if [ $? -eq 0 ]; then
  echo "All good."
else
  echo "Problem with permissions DB for reader ${READER_ID}. Error Code: $? Exit code: ${EXITCODE} Please check last card added/modified for errors, or remove and try again." | mail -s "HID DB Build Failure" nsayers@opticfusion.net
  cp /tmp/InputCards /tmp/InputCards-BAD
fi

RDR_MAC=`mysql -u $user -p"$pw" $database -h $host -e "SELECT mac FROM HIDReaders WHERE id='${READER_ID}'" | sed 1d`
cp ${BIN_PREFIX}/NewIdentDB  /tmp/NewIdentDB-${READER_ID}
cp ${BIN_PREFIX}/NewAccessDB  /tmp/NewAccessDB-${READER_ID}

mysql -u $user -p"$pw" $database -h $host -e "UPDATE HIDReaders SET manual_open='200' WHERE id='${READER_ID}'"
