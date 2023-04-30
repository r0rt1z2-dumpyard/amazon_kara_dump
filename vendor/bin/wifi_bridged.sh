#!/vendor/bin/sh
#
# Copyright (c) 2017 - 2021 Amazon.com, Inc. or its affiliates.  All rights reserved.
# PROPRIETARY/CONFIDENTIAL.  USE IS SUBJECT TO LICENSE TERMS.
#
# Controls bridged.  By default, start / stop controls allow this to be handled automatically on
# network connect / disconnect.  For debug purposes, other controls are provided.  For debug purposes
# and only on userdebug builds, some values can be provided using system properties setprop.
# These configurable settings can be found through the 'dump_cfg' output.
#
# bridged controls
#
#  * start       - starts bridged
#  * stop        - stops bridged
#  * restart     - restarts (stop / start) bridged
#
#  * force_start - DEBUG option to start bridged (when auto control disabled)
#  * force_stop  - DEBUG option to stop bridged (when auto control disabled)
#  * dump_cfg    - DEBUG option to dump bridged configuration
#  * clear_cfg   - DEBUG option to clear bridged configuration
#

# Common functionality for wifi
source /vendor/bin/wifi_common.sh

# Commands from /vendor/bin/
ECHO=/vendor/bin/echo
SETPROP=/vendor/bin/setprop
IPTABLES=/system/bin/iptables
IP6TABLES=/system/bin/ip6tables
IP=/system/bin/ip

# Log TAG - defined per script to override default common file definition
CMN_LOG_TAG="${0##*/}: $1"

# Log entry to note start of script
dlog "handling '$@' request"

# Log file
LOG_FILE="/data/vendor/wifi/wifi_bridged_log.txt"

# Determine if this is a nested call to avoid duplicate output
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

# Status
STATUS=""
RESULT=0

# Log event
now=`date`
$ECHO "--- $now ($1) ---"

# System properties
DISABLE_PROP='persist.wifi.auto_bridged_off'        # controls auto bridged start / stop
LOGLEVEL_PROP='persist.wifi.bridged.log_level'      # set / get bridged log level (debug)
PID_PROP='wifi.ro.bridged.pid'                      # set / get pid for bridged
PRODUCT_PROP='ro.build.product'                     # get product build
HOSTAP_SUPPORT_PROP='vendor.sys.hostap.support'     # set / get hostap support property

# Default values
BRIDGED_EXE='system/bin/bridged'
LOGLEVEL=1
HOSTAP_SUPPORT=0

# Get property values
#  usage: get_prop_values
get_prop_values()
{
    # Allow for override of default values under debug mode
    get_prop $DISABLE_PROP DISABLE                  # configurable
    get_prop $PID_PROP PID                          # read only / set to actual
    get_prop $PRODUCT_PROP PRODUCT                  # get product build
    get_prop $HOSTAP_SUPPORT_PROP HOSTAP_SUPPORT    # get hostap support property

    if is_debuggable; then
        get_prop $LOGLEVEL_PROP LOGLEVEL            # configurable (debug)
    fi
}

# Process command
#  usage: process_cmd $@
process_cmd()
{
    case "$1" in
        start)
            if [[ "$DISABLE" == '1' ]]; then
                STATUS="$BRIDGED_EXE auto setup disabled"
                RESULT=1
                return
            fi
            if [[ "$CMN_DISABLE24" == '1' && "$CMN_DISABLE50" == '1' ]]; then
                STATUS="soft APs auto setup completely disabled"
                return
            fi
            ;&

        force_start)
            if [[ -n "$PID" ]] && ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                STATUS="$BRIDGED_EXE already running (or disabled) - can't start $BRIDGED_EXE"
                RESULT=1
                return
            fi

            # Check for valid upstream interface
            # - wait up to 5 seconds for the interface which can be delayed due to DHCP confirmation
            update_upstream_iface 5
            if [[ -z "$CMN_UIF" ]]; then
                STATUS="no upstream interface found - can't start bridged"
                RESULT=1
                return
            fi

            if [[ "$HOSTAP_SUPPORT" == '1' ]]; then
                # Check if host AP is up before enabling bridge
                # - allow up to 5 secs for them to come up
                local c=1
                while (( $c <= 20 ))
                do
                    if ( is_hostAP_interface_up $CMN_HIF ) ; then
                        break
                    fi
                    sleep 0.25
                    (( c++ ))
                done
                if ! ( is_hostAP_interface_up $CMN_HIF ) ; then
                    STATUS="downstream interface(s) not available - can't start $BRIDGED_EXE"
                    RESULT=1
                    return
                fi

                # Enable bridging
                BRIDGED_PARAMS=("-U $CMN_UIF")
                BRIDGED_PARAMS+=("-I $CMN_HIF")
            else
                # Check if soft APs are up before enabling bridge
                # - allow up to 5 secs for them to come up
                local c=1
                while (( $c <= 20 ))
                do
                    if are_softAPs_up; then
                        break
                    fi
                    sleep 0.25
                    (( c++ ))
                done
                if ! ( are_softAPs_up 1 ) ; then
                    STATUS="downstream interface(s) not available - can't start $BRIDGED_EXE"
                    RESULT=1
                    return
                fi

                # Enable bridging
                BRIDGED_PARAMS=("-U $CMN_UIF")
                if [[ "$CMN_DISABLE24" != '1' ]]; then
                    BRIDGED_PARAMS+=("-I $CMN_DIF24")
                fi
                if [[ "$CMN_DISABLE50" != '1' ]]; then
                    BRIDGED_PARAMS+=("-I $CMN_DIF50")
                fi

            fi

            BRIDGED_PARAMS+=("-m" "-l")
            if [[ -n "$LOGLEVEL" ]]; then
                BRIDGED_PARAMS+=("-d $LOGLEVEL")
            fi
            dlog "$(echo $BRIDGED_EXE ${BRIDGED_PARAMS[@]})"
            $BRIDGED_EXE ${BRIDGED_PARAMS[@]} > /dev/null 2>&1 & # Unquoted so array is expanded

            # Capture and store pid
            PID="$(echo $!)"
            $SETPROP "$PID_PROP" "$PID"

            # Check if bridged started
            # - allow up to 5 secs for it to come up
            local c=1
            while (( $c <= 20 ))
            do
                if ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                    break
                fi
                sleep 0.25
                (( c++ ))
            done
            if ! ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                STATUS="failed to start $BRIDGED_EXE"
                RESULT=1
                return
            fi

            # Enable forwarding
            $ECHO '1' > /proc/sys/net/ipv4/conf/all/forwarding
            $IPTABLES -I FORWARD -j ACCEPT
            $ECHO '1' > /proc/sys/net/ipv6/conf/all/forwarding
            $IP6TABLES -I FORWARD -j ACCEPT
            # disable unicast DHCP forwarding
            $IPTABLES -I FORWARD -p udp --sport 67 -j DROP
            $IPTABLES -I FORWARD -p udp --sport 68 -j DROP
            # add ip rule
            $IP rule add from all fwmark 0x0/0xffff lookup $CMN_UIF prio 20000

            STATUS="$BRIDGED_EXE started"
            ;;

        stop)
            if [[ "$DISABLE" == '1' ]]; then
                STATUS="bridged auto setup disabled"
                RESULT=1
                return
            fi
            ;&

        force_stop)
            if [[ -z "$PID" ]] || ! ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                STATUS="bridged not running - can't stop bridged"
                RESULT=1
                return
            fi

            # Disable forwarding
            $IP6TABLES -D FORWARD -j ACCEPT
            $ECHO '0' > /proc/sys/net/ipv6/conf/all/forwarding
            $IPTABLES -D FORWARD -j ACCEPT
            $ECHO '0' > /proc/sys/net/ipv4/conf/all/forwarding
            # remove disabling unicast DHCP forwarding
            $IPTABLES -D FORWARD -p udp --sport 67 -j DROP
            $IPTABLES -D FORWARD -p udp --sport 68 -j DROP

            # Disable bridging
            kill -SIGTERM $PID

            # Check if bridged stopped
            # - allow up to 5 seconds for termination
            local c=1
            while (( $c <= 20 ))
            do
                if ! ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                    break
                fi
                sleep 0.25
                (( c++ ))
            done
            if ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                # Force kill bridging if needed
                kill -SIGKILL "$PID"
            fi
            if ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                STATUS="failed to stop $BRIDGED_EXE"
                RESULT=1
                return
            fi

            STATUS="$BRIDGED_EXE stopped"
            ;;

        restart)
            dlog "$BRIDGED_EXE restarting..."
            "$0" stop NO_PIPE
            sleep 5
            "$0" start NO_PIPE
            STATUS="$BRIDGED_EXE restarted"
            ;;

        dump_cfg)
            if is_debuggable; then
                $ECHO "$DISABLE_PROP = $DISABLE"
                $ECHO "$LOGLEVEL_PROP = $LOGLEVEL"
                $ECHO "$PID_PROP = $PID"
                dump_cmn_cfg
            fi
            ;;

        clear_cfg)
            if is_debuggable; then
                if ( is_pid_active "$PID" "$BRIDGED_EXE" ); then
                    STATUS="$BRIDGED_EXE running - stop before clearing config"
                    RESULT=1
                    return
                fi

                clear_prop $LOGLEVEL_PROP

                STATUS="configuration cleared"
            fi
            ;;

        *)
            STATUS="Unknown request ($1) for $BRIDGED_EXE state!!"
            RESULT=1
            ;;
    esac
} # process_cmd

get_prop_values

if ! ( is_wifi_enabled 0 1 ) ; then
    ilog "NOTE: wifi is not fully enabled"
fi

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
    ( main "$@" ) 2>&1 | tee -ia "$LOG_FILE"
else
    main "$@"
fi
