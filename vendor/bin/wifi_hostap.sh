#!/vendor/bin/sh
#
# Copyright (c) 2019 - 2021 Amazon.com, Inc. or its affiliates.  All rights reserved.
# PROPRIETARY/CONFIDENTIAL.  USE IS SUBJECT TO LICENSE TERMS.
#
# Controls host AP.  By default, start / stop controls allow this to be
# handled on command from AmazonWifiService.  For debug purposes, other controls are
# provided. These configurable settings can be found through the 'dump_cfg' output.
#
# host AP controls
#
#  * start       - starts host AP and initializes as needed
#  * stop        - stops host AP
#  * update_pswd - updates password for host AP; can optionally provide pswd
#  * update_ssid - updates SSID for host AP; can optionally provide SSID
#  * dump_cfg    - DEBUG option to dump host AP configuration
#  * clear_cfg   - DEBUG option to clear host AP configuration
#

# Common functionality for wifi
source /vendor/bin/wifi_common.sh

# Commands from /vendor/bin/
IFCONFIG=/vendor/bin/ifconfig
GETPROP=/vendor/bin/getprop
SETPROP=/vendor/bin/setprop
ECHO=/vendor/bin/echo
HOSTAPD_CLI=/vendor/bin/hostapd_cli
GREP=/vendor/bin/grep
CHMOD=/vendor/bin/chmod
LS=/vendor/bin/ls
KILL=/vendor/bin/kill
TEE=/vendor/bin/tee
SED=/vendor/bin/sed
TR=/vendor/bin/tr
IW=/vendor/bin/iw
IWPRIV=/vendor/bin/iwpriv
DATE=/vendor/bin/date

# Log TAG - defined per script to override default common file definition
CMN_LOG_TAG="${0##*/}: $1"

# Log entry to note start of script
dlog "handling '$@' request for host AP"

# Log file
LOG_FILE="/data/vendor/wifi/wifi_hostap_log.txt"

# Determine if this is a nested call to avoid duplicate output.
# Nested calls will have a second param after the command
# - excludes ssid / pswd commands which will not ever be nested and do have a second param.
PIPE=0
if [[ -z "$2" || "$1" == "update_pswd" || "$1" == "update_ssid" ]]; then
    limit_log_buffer $LOG_FILE

    PIPE=1
fi

# Main functionality needing timing and log capture
#  usage: main $@
main()
{

# Capture timing of this script
time {

# Log time
now=`$DATE`
$ECHO "--- $now ($1) ---"

# Status
STATUS=""
RESULT=0

# System properties
# NOTE: AmazonWifiService needs to be update if these properties change
SSID_PROP='persist.service.hostap.ssid'             # set / get SSID for host AP
PSWD_PROP='persist.service.hostap.pswd'             # set / get password for host AP (or null)
CHNL_PROP='persist.service.hostap.chan'             # set / get channel number for host AP (or null)
REGN_PROP='persist.service.hostap.regn'             # set / get country code for host AP (or null)
PID_PROP='wifi.ro.hostapd.pid'                      # set / get pid for hostapd
TRGT_FREQ_PROP='persist.service.hostap.tgfr'        # set / get newly targeted freq for host AP
TRGT_CHNL_PROP='persist.service.hostap.tgch'        # set / get newly targeted channel for host AP
BRAND_PROP='ro.product.brand'                       # get product brand
SERIAL_PROP='ro.serialno'                           # get product serial number
PRODUCT_PROP='ro.build.product'                     # get product build

MODULE="wlan_mt76x8_sdio"               # driver module name
#MODULE_FILE="wlan_mt76x8_sdio.ko"      # driver module file name

# Default values
WLAN_INTERFACE='wlan0'
AP_CHANNEL_DEFAULT='36'
WLAN_FREQ_DEFAULT='5180'
DFS_START_FREQ='5250'
DFS_END_FREQ='5720'
FREQ_BASE5=5000
FREQ_BASE24=2407
BR='Amazon'
SN='000'
PSWD=''
CHNL='36'
PRV_CHNL=$AP_CHANNEL_DEFAULT
PRV_FREQ=$WLAN_FREQ_DEFAULT
HOSTAPD_EXE='/vendor/bin/hw/hostapd'    # FOS7
HOSTAPD_CONF='/data/vendor/wifi/hostapd.conf'
HOSTAPD_CTRL_IF='/data/vendor/wifi/hostapd'

# Character set for SSID and password
POSSIBLE_CHARS='a-zA-Z0-9~!@#$%^&*()-_=+[{]}\|:,<.>/?'

# Check password
#  usage: check_pswd password
check_pswd()
{
    # Check for valid password (for user defined passwords)
    local pswd=$1
    local pswd_len=${#pswd}
    if (( $pswd_len < 8 || $pswd_len > 64 )); then
        elog "host AP password $pswd must be between 8 and 64 characters long - can't continue"
        return 1
    fi
    if [[ -n `echo -E "$pswd" | tr -d "$POSSIBLE_CHARS"` ]]; then
        elog "host AP password $pswd must only contain $POSSIBLE_CHARS characters - can't continue"
        return 1
    fi
}

# Set password
#  usage: set_pswd [password]
set_pswd()
{
    # Update password as needed
    if [[ "$1" != "$PSWD" ]]; then
        PSWD=$1
    fi

    # Generate password as needed
    if [[ -z "$PSWD" ]]; then
        # Generated secret share / password - random 63 alphanumeric
        ilog "generating password for host AP"
        PSWD=`od -vAn -N128 -t a < /dev/urandom | tr -dc "$POSSIBLE_CHARS" | sed 's/.*\(.\{63\}\)/\1/'`
    fi

    # Check for valid password
    if ! check_pswd "$PSWD"; then
        return 1
    fi

    # Update / store password
    $SETPROP $PSWD_PROP "$PSWD"
}

# Check SSID
#  usage: check_ssid ssid name
check_ssid()
{
    # Check for valid SSID (for user defined SSID)
    local ssid=$1
    local ssid_len=${#ssid}
    if (( $ssid_len > 32 )); then
        elog "host AP SSID must be 32 characters or less - can't continue"
        return 1
    fi
    if [[ -n `echo -E "$ssid" | tr -d "$POSSIBLE_CHARS"` ]]; then
        elog "host AP SSID must only contain $POSSIBLE_CHARS characters - can't continue"
        return 1
    fi
}

# Set SSID
#  usage: set_ssid [ssid name]
set_ssid()
{
    # Update SSID as needed
    if [[ "$1" != "$SSID" ]]; then
        SSID=$1
    fi

    # Generate SSID as needed
    if [[ -z "$SSID" ]]; then
        # Generated SSID as 'Amazon-{Last 3 SN}{random 8 chars}-FTVSAP'
        # -  FTVSAP for FireTV host AP to make this more unique for debug purposessoft
        ilog "generating SSID for host AP"
        SN3=${SN: -3}
        RAND=`od -vAn -N16 -t a < /dev/urandom | tr -dc "$POSSIBLE_CHARS" | sed 's/.*\(.\{8\}\)/\1/'`
        SSID="$BR-$SN3$RAND-FTVSAP"
    fi

    # Check for valid SSID
    if ! check_ssid "$SSID"; then
        elog "host AP SSID is invalid"
        return 1
    fi

    # Update / store SSID
    $SETPROP $SSID_PROP "$SSID"
}

set_regn()
{
    WLAN_REGN=`$IW reg get |grep country |cut -d " " -f2 |cut -c 1-2`
    AP_REGN=$WLAN_REGN
    $SETPROP $REGN_PROP "$AP_REGN"
}

set_chan()
{
    get_prop $TRGT_FREQ_PROP PRV_FREQ
    get_prop $TRGT_CHNL_PROP PRV_CHNL

    ilog "PRV_FREQ is $PRV_FREQ"

    WLAN_FREQ=`$IW $WLAN_INTERFACE link |grep freq |cut -d " " -f2`
    if [[ ( "$WLAN_FREQ" > "5000" ) ]]; then
        WLAN_CHANNEL=$(($((WLAN_FREQ-FREQ_BASE5))/5))
        AP_CHANNEL=$WLAN_CHANNEL
        TRGT_FREQ=$WLAN_FREQ
    elif [[ ( "$WLAN_FREQ" < "3000" ) ]]; then
        WLAN_CHANNEL=$(($((WLAN_FREQ-FREQ_BASE24))/5))
        if [ "$PRV_FREQ" -ge "$DFS_START_FREQ" ] && [ "$PRV_FREQ" -le "$DFS_END_FREQ" ]; then
            AP_CHANNEL=$AP_CHANNEL_DEFAULT
            TRGT_FREQ=$WLAN_FREQ_DEFAULT
        else
            AP_CHANNEL=$PRV_CHNL
            TRGT_FREQ=$PRV_FREQ
        fi
    fi
    $SETPROP $CHNL_PROP "$AP_CHANNEL"
    $SETPROP $TRGT_CHNL_PROP "$AP_CHANNEL"
    $SETPROP $TRGT_FREQ_PROP "$TRGT_FREQ"
}

# Execute channel switch
#  usage: hostapd_switch_chan
hostapd_switch_chan()
{
    # Switch channel to the target freq (TRGT_FREQ) through hostapd_cli.
    # The count of beacon with CSA is set to be 10 by default.
    $HOSTAPD_CLI -i $CMN_HIF -p $HOSTAPD_CTRL_IF chan_switch 10 $TRGT_FREQ
}

# Execute channel update evaluation
#  usage: hostapd_update_chan
update_chan()
{
    # Evaluate if switch channel is needed by compare previous freq to the target freq (TRGT_FREQ)
    # call hostapd_switch_chan() if decide switch channel is needed
    ilog "update_chan - PRV_FREQ: $PRV_FREQ TRGT_FREQ: $TRGT_FREQ"
    if [ "$PRV_FREQ" -ne "$TRGT_FREQ" ]
    then
        if [ "$TRGT_FREQ" -ge "$DFS_START_FREQ" ] && [ "$TRGT_FREQ" -le "$DFS_END_FREQ" ]; then
            ilog "SoftAP is in DFS channel, disable/enable SoftAP ..."
            stop_hostAP "skip_clear"
            get_prop_values
            start_hostAP
        else
            hostapd_switch_chan
            ilog "Switching SoftAP channel using hostapd_switch_chan ..."
        fi
    fi
}

# Get property values
#  usage: get_prop_values
get_prop_values()
{
    # Get existing property values
    get_prop $SSID_PROP SSID                        # configurable
    get_prop $PSWD_PROP PSWD                        # configurable
    get_prop $CHNL_PROP CHNL                        # configurable
    get_prop $REGN_PROP REGN                        # configurable
    get_prop $BRAND_PROP BR                         # read only / set to actual
    get_prop $PID_PROP PID                          # set / get pid for hostapd
    get_prop $TRGT_FREQ_PROP TRGT_FREQ              # get target freq
    get_prop $TRGT_CHNL_PROP TRGT_CHNL              # get target channel
    get_prop $SERIAL_PROP SN                        # read only
    get_prop $PRODUCT_PROP PRODUCT                  # get product build
}

# Clear property values
#  usage: clear_prop_values
clear_prop_values()
{
    clear_prop $SSID_PROP                           # configurable
    clear_prop $PSWD_PROP                           # configurable
    clear_prop $CHNL_PROP                           # configurable
    clear_prop $REGN_PROP                           # configurable
    clear_prop $TRGT_CHNL_PROP                      # configurable
    clear_prop $TRGT_FREQ_PROP                      # configurable
    clear_prop $PID_PROP                            # configurable
}

wifi_multicast_start_stop()
{
    if [[ "$PRODUCT" == "raven" || "$PRODUCT" == "brandenburg" || "$PRODUCT" == "kara" ]]; then
        if [[ "$1" == "start" ]]; then
            # Enable Multicast in Wifi firmware
            $IWPRIV $WLAN_INTERFACE driver "set_mcastburst 1" > /dev/null
            # Set Multicast rate to MCS2
            $IWPRIV $WLAN_INTERFACE driver "fixedmrate=0-2-0-2-0-0-0-0-0-0" > /dev/null
        else #stop
            # Disable Multicast in Wifi firmware
            $IWPRIV $WLAN_INTERFACE driver "set_mcastburst 0" > /dev/null
            # Set Multicast rate to Auto
            $IWPRIV $WLAN_INTERFACE driver "fixedmrate=auto" > /dev/null
        fi
    fi
}

# Start host AP
#  usage: start_hostAP
start_hostAP()
{
    dlog "creating host AP"

    # check whether hostapd has been started already
    if [[ -n "$PID" ]] && ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
        STATUS="$HOSTAPD_EXE already running (or disabled) - can't start $HOSTAPD_EXE"
        RESULT=1
        return
    fi

    # create hostapd.conf file
    dlog "creating hostapd.conf"
    $ECHO 'interface=ap0' > $HOSTAPD_CONF
    $ECHO 'driver=nl80211' >> $HOSTAPD_CONF
    $ECHO 'ctrl_interface='$HOSTAPD_CTRL_IF >> $HOSTAPD_CONF
    $ECHO 'beacon_int=100' >> $HOSTAPD_CONF
    # dtim might be needed pending confirmation on power save.
#    $ECHO 'dtim_period=2' >> $HOSTAPD_CONF
    $ECHO 'ieee80211n=1' >> $HOSTAPD_CONF
    $ECHO 'ieee80211h=1' >> $HOSTAPD_CONF
    $ECHO 'ieee80211d=1' >> $HOSTAPD_CONF
    $ECHO 'ieee80211ac=1' >> $HOSTAPD_CONF
    $ECHO 'hw_mode=a' >> $HOSTAPD_CONF
    $ECHO 'max_num_sta=8' >> $HOSTAPD_CONF
    $ECHO 'device_name=Wireless Host AP' >> $HOSTAPD_CONF
    $ECHO 'serial_number=1.0' >> $HOSTAPD_CONF
    $ECHO 'device_type=6-0050F204-1' >> $HOSTAPD_CONF
    $ECHO 'device_type=10-0050F204-1' >> $HOSTAPD_CONF
    $ECHO 'wpa=2' >> $HOSTAPD_CONF
    $ECHO 'rsn_pairwise=CCMP' >> $HOSTAPD_CONF
    $ECHO 'ignore_broadcast_ssid=1' >> $HOSTAPD_CONF
    ilog "hostapd hidden ssid in use"
    $ECHO 'ssid='$SSID >> $HOSTAPD_CONF
    $ECHO 'wpa_passphrase='$PSWD >> $HOSTAPD_CONF
    $ECHO 'country_code='$REGN >> $HOSTAPD_CONF
    $ECHO 'channel='$CHNL >> $HOSTAPD_CONF
    $CHMOD g=rw $HOSTAPD_CONF

    # check whether hostapd.conf has been created
    local cmd=`$LS $HOSTAPD_CONF 2>/dev/null`
    if [[ -z "$cmd" ]]; then
        elog "failed to create hostapd.conf"
        STATUS="failed to create hostapd.conf"
        RESULT=1
        return
    else
        dlog "hostapd.conf created"
    fi

    # start hostapd service
    $HOSTAPD_EXE -e /data/vendor/wifi/entropy.bin -dddddddd $HOSTAPD_CONF > /dev/null 2>&1 &

    # Capture and store pid
    PID="$($ECHO $!)"
    $SETPROP "$PID_PROP" "$PID"

    # Check if hostapd started
    # - allow up to 10 seconds for it to come up
    local c=1
    while (( $c <= 40 ))
    do
        if ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
            break
        fi
        sleep 0.25
        (( c++ ))
    done
    if ! ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
        STATUS="failed to start $HOSTAPD_EXE"
        RESULT=1
        return
    fi

    wifi_multicast_start_stop "start"
    dlog "host AP created"

} # start_hostAP

stop_hostAP()
{
    dlog "removing host AP"

    # stop hostapd service
    rm $HOSTAPD_CONF

    # stop hostapd
    if [[ -z "$PID" ]] || ! ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
        ilog "hostapd not running - can't stop hostapd"
    fi

    ilog "$KILL -SIGTERM $PID"
    $KILL -SIGTERM $PID

    # Check if hostapd stopped
    # - allow up to 10 seconds for termination
    local c=1
    while (( $c <= 40 ))
    do
        if ! ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
            break
        fi
        sleep 0.25
        (( c++ ))
    done

    if ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
        # Force kill hostapd if needed
        $KILL -SIGKILL "$PID"
    fi

    if ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
        STATUS="failed to stop $HOSTAPD_EXE"
        RESULT=1
        return
    fi

    wifi_multicast_start_stop "stop"

    # turn down the interface
#    $IFCONFIG "$CMN_HIF" down

    if [[ "$1" != "skip_clear" ]]; then
        ilog "clear prop values"
        clear_prop_values
    fi
    dlog "host AP removed"

} # stop_hostAP

switch_chan()
{
    dlog "switching channel for host AP"

    # check whether the values are Null
    if [[ -z "$TRGT_FREQ" ]] || [[ -z "$TRGT_CHNL" ]]; then
        ilog "$TRGT_CHNL_PROP or $TRGT_FREQ_PROP value is null; cannot update channel"
        STATUS="failed to get value of $TRGT_CHNL_PROP or $TRGT_FREQ_PROP"
        RESULT=1
        return
    fi

    # execute channel switch
    hostapd_switch_chan

    # check whether channel switch is successful
    local c=1
    while (( $c <= 40 ))
    do
        if $HOSTAPD_CLI -i $CMN_HIF -p $HOSTAPD_CTRL_IF status | $GREP channel=$TRGT_CHNL; then
            $ECHO "Channel is updated to $TRGT_CHNL"
            break
        fi
        hostapd_switch_chan
        sleep 0.25
        (( c++ ))
    done
    if ! $HOSTAPD_CLI -i $CMN_HIF -p $HOSTAPD_CTRL_IF status | $GREP channel=$TRGT_CHNL; then
        ilog "Channel is not updated to $TRGT_CHNL"
        STATUS="failed to update channel to $TRGT_CHNL"
        RESULT=1
        return
    fi

    dlog "host AP channel switched"

} # switch_chan

# Process command
#  usage: process_cmd $@
process_cmd()
{
    case "$1" in
        start)
            # Update SSID and passwords for host AP
            if ! set_ssid "$SSID"; then
                STATUS="failure setting SSID for host AP interfaces"
                RESULT=1
                return
            fi
            if ! set_pswd "$PSWD"; then
                STATUS="failure setting password for host AP interfaces"
                RESULT=1
                return
            fi
            start_hostAP
            ;;

        stop)
            stop_hostAP
            ;;

        switch)
            switch_chan
            ;;

        update)
            update_chan
            ;;

        update_ssid)
            # Update SSID either using
            # what's passed in or generating a new one
            if ! set_ssid "$2"; then
                STATUS="failure setting SSID for host AP interface"
                RESULT=1
                return
            fi
            STATUS="SSID stored - applied on next start"
            ;;

        update_pswd)
            # Update password either using
            # what's passed in or generating a new one
            if ! set_pswd "$2"; then
                STATUS="failure setting password for host AP interface"
                RESULT=1
                return
            fi
            STATUS="password stored - applied on next start"
            ;;

        dump_cfg)
            if is_debuggable; then
                $ECHO "$SSID_PROP = $SSID"
                $ECHO "$PSWD_PROP = $PSWD"
                $ECHO "$CHNL_PROP = $CHNL"
                $ECHO "$REGN_PROP = $REGN"
                $ECHO "$PID_PROP = $PID"
            fi
            ;;

        clear_cfg)
            if is_debuggable; then

                if ( is_pid_active "$PID" "$HOSTAPD_EXE" ); then
                    STATUS="$HOSTAPD_EXE running - stop before clearing config"
                    RESULT=1
                    return
                fi

                clear_prop $SSID_PROP
                clear_prop $PSWD_PROP
                clear_prop $CHNL_PROP
                clear_prop $REGN_PROP

                STATUS="configuration cleared"
            fi
            ;;

        *)
            STATUS="unknown request ($1) for host APs state"
            RESULT=1
            ;;
    esac
} # process_cmd

set_regn

set_chan

get_prop_values

process_cmd "$@"

if [[ -n "$STATUS" ]]; then
    if ! (( $RESULT )); then
        elog "$STATUS"
    else
        ilog "$STATUS"
    fi
fi

} # time

exit $RESULT

} # main

# Conditionally capture output
if [[ "$PIPE" == '1' ]]; then
    ( main "$@" ) 2>&1 | $TEE -ia "$LOG_FILE"
else
    main "$@"
fi

