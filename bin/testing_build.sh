#!/bin/bash
BIN_PREFIX=/home/intranet/bin/HID/
EXITCODE=`${BIN_PREFIX}/buildcards /tmp/InputCards ${BIN_PREFIX}/NewIdentDB ${BIN_PREFIX}/NewAccessDB ${BIN_PREFIX}/FormatsDefault ${BIN_PREFIX}/out-Sets ${BIN_PREFIX}/out-Log 100`
echo ${EXITCODE}
