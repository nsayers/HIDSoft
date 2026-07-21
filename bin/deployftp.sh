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
put NewAccessDB-${READERMAC} NewAccessDB
put NewIdentDB-${READERMAC} NewIdentDB
bye
EOF

done < <(mysql -u $user -p"$pw" $database -h $host -e "SELECT mac,ip,pass FROM HIDReaders WHERE mac='${READER_ID}'" | sed 1d)
