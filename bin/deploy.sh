#!/bin/bash

source /usr/local/sbin/HIDSoft/bin/settings.sh

if [ -n "$1" ]; then
READER_ID=$1
else
echo "ERROR: Please provide reader MAC."
exit
fi

READER_PREFIX="/mnt/data/config"
BIN_PREFIX="/usr/local/sbin/HIDSoft/bin"
CONF_PREFIX="/tmp"
BACKUP_PREFIX="/usr/local/sbin/HIDSoft/bin/archive"

while IFS=$'\t' read mac ip pass; do
  RDRIP=$ip
  RDRPW=$pass 	
  READERMAC=$mac

RDRUSER=root

rm -f /tmp/archive_*-${READERMAC}


pushd ${CONF_PREFIX}

ftp -inv $RDRIP <<EOF
user $RDRUSER $RDRPW
cd ${READER_PREFIX}
binary
get Schedules archive_Schedules-${READERMAC}
get IOLinkerRules archive_IOLinkerRules-${READERMAC}
get Holidays archive_Holidays-${READERMAC}
put Schedules-${READERMAC} Schedules
put Holidays-${READERMAC} Holidays
put IOLinkerRules-${READERMAC} IOLinkerRules
bye
EOF

tar -zcf ${BACKUP_PREFIX}/${READERMAC}-`date +%Y%m%d%H%M%S`.tgz ${CONF_PREFIX}/archive_Schedules-${READERMAC} ${CONF_PREFIX}/archive_Holidays-${READERMAC} ${CONF_PREFIX}/archive_IOLinkerRules-${READERMAC}
popd
done < <(mysql -u $user -p"$pw" $database -h $host -e "SELECT mac,ip,pass FROM HIDReaders WHERE mac='${READER_ID}'" | sed 1d)
mysql -u root -p'password' readers -e "UPDATE HIDReaders SET manual_open='999' WHERE mac='${READER_ID}'"


