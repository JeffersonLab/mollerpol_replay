#!/usr/bin/env bash

# replay_live.sh
#
# Replay EVIO segments while they are being collected.
#
# Usage:
#   ./replay_live.sh RUN_NUMBER [MAX_PROCESSES] [POLL_SECONDS]
#
# Examples:
#   ./replay_live.sh 570
#   ./replay_live.sh 570 16
#   ./replay_live.sh 570 16 5
#
# Script looks for evio file size changing. When file stops growing and a
# new one is not created, the script will then stop looking for new segments
# and wait for all queued/running replay processes to finish.

set -u
COUNTER=0
# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

if [[ $# -lt 1 || $# -gt 3 ]]
then
    echo "Usage: $0 RUN_NUMBER [MAX_PROCESSES] [POLL_SECONDS]"
    exit 1
fi

RUN_NUMBER="$1"

if [[ $# -ge 2 ]]
then
    MAX_PROCESSES="$2"

    if ! [[ "$MAX_PROCESSES" =~ ^[1-9][0-9]*$ ]]
    then
        echo "Error: MAX_PROCESSES must be a positive integer."
        exit 1
    fi
else
    MAX_PROCESSES=12
fi

if [[ $# -ge 3 ]]
then
    POLL_SECONDS="$3"

    if ! [[ "$POLL_SECONDS" =~ ^[1-9][0-9]*$ ]]
    then
        echo "Error: POLL_SECONDS must be a positive integer."
        exit 1
    fi
else
    POLL_SECONDS=5
fi


# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

if [[ -z "${HAMOLLER_EVIO_DIR:-}" ]]
then
    echo "Error: HAMOLLER_EVIO_DIR is not set."
    exit 1
fi

if [[ ! -d "$HAMOLLER_EVIO_DIR" ]]
then
    echo "Error: directory does not exist:"
    echo "  $HAMOLLER_EVIO_DIR"
    exit 1
fi


# ------------------------------------------------------------
# Temporary directory
# ------------------------------------------------------------

cleanup()
{
    rm -rf "$TMPDIR_REPLAY"
}

trap cleanup EXIT

TMPDIR_REPLAY=$(mktemp -d "/tmp/replay_live_${RUN_NUMBER}.XXXXXX")


# ------------------------------------------------------------
# State
# ------------------------------------------------------------

# Segments that have already been started.
declare -A STARTED

# Segments currently running.
declare -a PIDS=()
declare -a PID_SEGMENTS=()

# Segments that have been discovered but are not yet ready.
declare -A LAST_SIZE
declare -A STABLE_COUNT

RUNNING=0
STARTED_COUNT=0
COMPLETED=0
FAILED=0
DISCOVERED=0

# ------------------------------------------------------------
# Timing
# ------------------------------------------------------------

START_TIME=$(date +%s)


# ------------------------------------------------------------
# End-of-run detection variables
# ------------------------------------------------------------

END_OF_RUN_SECONDS=10
NEWEST_SEGMENT=""
NEWEST_SIZE=""
NEWEST_LAST_CHANGE=0
STOPPING=0
AUTO_STOP=0

# ------------------------------------------------------------
# Ctrl-C handler
# ------------------------------------------------------------

stop_monitoring()
{
    if [[ $STOPPING -eq 0 ]]
    then
        echo
        echo "========================================"
        echo "Stopping segment monitoring."
        echo "No new segments will be started."
        echo "Waiting for existing replay processes..."
        echo "========================================"
        echo

        STOPPING=1
	AUTO_STOP=0
    fi
}

trap stop_monitoring INT TERM


# ------------------------------------------------------------
# Start replay for one segment
# ------------------------------------------------------------

start_segment()
{
    local SEGMENT="$1"
    local LOGFILE="$TMPDIR_REPLAY/segment_${SEGMENT}.log"
    local STATFILE="$TMPDIR_REPLAY/segment_${SEGMENT}.stat"

    echo "Starting segment $SEGMENT"

    (

        /usr/bin/time \
            -f 'ELAPSED=%e\nUSER=%U\nSYSTEM=%S\nMAX_RSS_KB=%M\nEXIT_STATUS=%x' \
            -o "$STATFILE" \
            analyzer -q "replay.C($RUN_NUMBER,$SEGMENT)" \
            >"$LOGFILE" 2>&1
    ) &

    local PID=$!

    PIDS+=("$PID")
    PID_SEGMENTS+=("$SEGMENT")

    STARTED["$SEGMENT"]=1

    RUNNING=$((RUNNING + 1))
    STARTED_COUNT=$((STARTED_COUNT + 1))
}


# ------------------------------------------------------------
# Check for completed replay processes
# ------------------------------------------------------------

check_for_complete_processes()
{
    local i
    local PID
    local SEGMENT

    # Nothing running.
    if (( RUNNING == 0 ))
    then
        return 1
    fi

    for (( i=0; i<${#PIDS[@]}; i++ ))
    do

        PID="${PIDS[$i]}"
        SEGMENT="${PID_SEGMENTS[$i]}"

        if ! kill -0 "$PID" 2>/dev/null
        then

            if wait "$PID"
            then
                echo "Segment $SEGMENT completed successfully."
            else
                echo "Segment $SEGMENT FAILED (PID $PID)."
                FAILED=$((FAILED + 1))
            fi

            COMPLETED=$((COMPLETED + 1))
            RUNNING=$((RUNNING - 1))

            # Remove this PID without creating a sparse array.
            PIDS=("${PIDS[@]:0:i}" "${PIDS[@]:i+1}")
            PID_SEGMENTS=("${PID_SEGMENTS[@]:0:i}" "${PID_SEGMENTS[@]:i+1}")

            return 0
        fi

    done

    return 1
}


# ------------------------------------------------------------
# Scan EVIO directory
#
# A file is considered ready when its size has remained unchanged
# for two consecutive scans.
# ------------------------------------------------------------

scan_for_segments()
{
    local FILE
    local BASENAME
    local SEGMENT
    local SIZE
    local OLD_SIZE

    local NEWEST_SEEN=""
    local NEWEST_SEEN_SIZE=""
    local NEWEST_FILE=""
    COUNTER=$((COUNTER + 1))
    for FILE in "$HAMOLLER_EVIO_DIR"/${HAMOLLER_EVIO_BASENAME}${RUN_NUMBER}.evio.*
    do

        [[ -f "$FILE" ]] || continue

        BASENAME="${FILE##*/}"

        SEGMENT="${BASENAME#mollerpol_test_${RUN_NUMBER}.evio.}"

        # Make sure the suffix is numeric.
        if ! [[ "$SEGMENT" =~ ^[0-9]+$ ]]
        then
            continue
        fi

        DISCOVERED=$((DISCOVERED + 1))

        SIZE=$(stat -c %s "$FILE" 2>/dev/null)

        [[ -n "$SIZE" ]] || continue

        # --------------------------------------------------------
        # Find newest segment numerically.
        # --------------------------------------------------------

        if [[ -z "$NEWEST_SEEN" || "$SEGMENT" -gt "$NEWEST_SEEN" ]]
        then
            NEWEST_SEEN="$SEGMENT"
            NEWEST_SEEN_SIZE="$SIZE"
            NEWEST_FILE="$FILE"
        fi

        # Already started?
        if [[ ${STARTED[$SEGMENT]+_} ]]
        then
            continue
        fi

        # --------------------------------------------------------
        # Determine whether this segment has become stable.
        # --------------------------------------------------------

        OLD_SIZE="${LAST_SIZE[$SEGMENT]:-}"

        if [[ "$OLD_SIZE" == "$SIZE" ]]
        then
            STABLE_COUNT["$SEGMENT"]=$(( ${STABLE_COUNT[$SEGMENT]:-0} + 1 ))
        else
            STABLE_COUNT["$SEGMENT"]=0
        fi

        LAST_SIZE["$SEGMENT"]="$SIZE"

        # Require size to be unchanged for two scans.
        if [[ ${STABLE_COUNT[$SEGMENT]} -ge 1 ]]
        then

	    if [[ ( $STOPPING -eq 0 || $AUTO_STOP -eq 1 ) && $RUNNING -lt $MAX_PROCESSES ]]
	    then
		start_segment "$SEGMENT"

                unset 'LAST_SIZE[$SEGMENT]'
                unset 'STABLE_COUNT[$SEGMENT]'
            fi

        fi

    done

    # ------------------------------------------------------------
    # End-of-run detection.
    # ------------------------------------------------------------


    if [[ $STOPPING -eq 0 && -n "$NEWEST_SEEN" ]]
    then

        local NOW
        NOW=$(date +%s)
	
        # A new highest-numbered segment appeared.
        if [[ "$NEWEST_SEEN" != "$NEWEST_SEGMENT" ]]
        then
	    
            NEWEST_SEGMENT="$NEWEST_SEEN"
            NEWEST_SIZE="$NEWEST_SEEN_SIZE"
            NEWEST_LAST_CHANGE="$NOW"
	    
            echo "New segment started: $NEWEST_SEGMENT (${NEWEST_SIZE} bytes)"
	    
            # The newest segment is still growing.
        elif [[ "$NEWEST_SEEN_SIZE" != "$NEWEST_SIZE" ]]
        then
	    
            NEWEST_SIZE="$NEWEST_SEEN_SIZE"
            NEWEST_LAST_CHANGE="$NOW"
	    if [[ COUNTER -gt 4 ]]
	    then
		echo "Segment $NEWEST_SEGMENT is still growing (${NEWEST_SIZE} bytes)"
		COUNTER=1
	    fi
            # Same segment and same size.
        elif (( NOW - NEWEST_LAST_CHANGE >= END_OF_RUN_SECONDS ))
        then
	    
            # ----------------------------------------------------
            # Size has been unchanged long enough.
            #
            # Now make sure no process still has the file open.
            # ----------------------------------------------------
	    
            if ! lsof -- "$NEWEST_FILE" >/dev/null 2>&1
            then
		
                echo
                echo "========================================"
                echo "End of data collection detected."
                echo "Newest segment:       $NEWEST_SEGMENT"
                echo "Size:                 $NEWEST_SIZE bytes"
                echo "Unchanged for:        $((NOW - NEWEST_LAST_CHANGE)) s"
                echo "No writer has file open."
                echo "Stopping segment monitoring."
                echo "Waiting for replay processes..."
                echo "========================================"
                echo
		
                STOPPING=1
		AUTO_STOP=1
		
            else
		
                # A writer still has the file open. Do not stop.
                :
            fi
	    
        fi
    fi
}


# ------------------------------------------------------------
# Print initial information
# ------------------------------------------------------------

echo
echo "========================================"
echo "Live EVIO replay"
echo "========================================"
echo "Run:                  $RUN_NUMBER"
echo "EVIO directory:       $HAMOLLER_EVIO_DIR"
echo "Maximum processes:    $MAX_PROCESSES"
echo "Poll interval:        ${POLL_SECONDS} s"
echo
echo "Replay will begin as segments appear."
echo "Replay will stop automatically when the newest segment"
echo "has not grown for 10 seconds and no newer segment appears."
echo "Press Ctrl-C to stop monitoring manually."
echo "========================================"
echo


# ------------------------------------------------------------
# Main monitoring loop
# ------------------------------------------------------------

while [[ $STOPPING -eq 0 ]]
do

    # Look for new EVIO segments.
    scan_for_segments

    #Collect any completed replay jobs.
    while check_for_complete_processes
    do
        :
    done


    sleep "$POLL_SECONDS"

done

# ------------------------------------------------------------
# Monitoring has stopped.
#
# If the stop was automatic, continue processing all segments
# that already exist.
#
# If the user pressed Ctrl-C, do NOT start additional segments.
# Just wait for the currently running processes to finish/exit.
# ------------------------------------------------------------

if [[ $AUTO_STOP -eq 1 ]]
then


    echo
    echo "Finalizing remaining segments..."
    echo

    while :
    do
        scan_for_segments

        while check_for_complete_processes
        do
            :
        done

        if [[ $RUNNING -eq 0 ]]
        then
	    break
        fi

        sleep 1
    done

else

    # Manual Ctrl-C:
    # do NOT scan again. Waiting segments must not be started.

    echo
    echo "Waiting for $RUNNING running replay process(es)..."
    echo

    while [[ $RUNNING -gt 0 ]]
    do
        while check_for_complete_processes
        do
            :
        done

        if [[ $RUNNING -gt 0 ]]
        then
            sleep 1
        fi
    done

fi


# ------------------------------------------------------------
# Final timing
# ------------------------------------------------------------

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))


# ------------------------------------------------------------
# Collect resource statistics
# ------------------------------------------------------------

TOTAL_USER=0
TOTAL_SYSTEM=0
MAX_RSS=0

for STATFILE in "$TMPDIR_REPLAY"/segment_*.stat
do

    [[ -f "$STATFILE" ]] || continue

    USER=$(awk -F= '/^USER=/{print $2}' "$STATFILE")
    SYSTEM=$(awk -F= '/^SYSTEM=/{print $2}' "$STATFILE")
    RSS=$(awk -F= '/^MAX_RSS_KB=/{print $2}' "$STATFILE")

    TOTAL_USER=$(awk \
        -v a="$TOTAL_USER" \
        -v b="$USER" \
        'BEGIN { printf "%.2f", a+b }')

    TOTAL_SYSTEM=$(awk \
        -v a="$TOTAL_SYSTEM" \
        -v b="$SYSTEM" \
        'BEGIN { printf "%.2f", a+b }')

    if [[ "$RSS" -gt "$MAX_RSS" ]]
    then
        MAX_RSS="$RSS"
    fi

done


# ------------------------------------------------------------
# Calculate statistics
# ------------------------------------------------------------

TOTAL_CPU=$(awk \
    -v u="$TOTAL_USER" \
    -v s="$TOTAL_SYSTEM" \
    'BEGIN { printf "%.2f", u+s }')

MAX_RSS_GB=$(awk \
    -v kb="$MAX_RSS" \
    'BEGIN { printf "%.2f", kb/1024/1024 }')

CPU_PERCENT=$(awk \
    -v cpu="$TOTAL_CPU" \
    -v wall="$TOTAL_TIME" \
    'BEGIN {
        if (wall > 0)
            printf "%.1f", 100*cpu/wall;
        else
            printf "N/A";
    }')


# ------------------------------------------------------------
# Final report
# ------------------------------------------------------------

echo
echo "========================================"
echo "Replay summary"
echo "========================================"
echo "Run:                  $RUN_NUMBER"
echo "Segments replayed:    $STARTED_COUNT"
echo "Completed:             $COMPLETED"
echo "Failed:                $FAILED"
echo "Maximum concurrent:    $MAX_PROCESSES"
echo "Total wall time:       ${TOTAL_TIME} s"
echo "Total CPU time:        ${TOTAL_CPU} s"
echo "Aggregate CPU usage:   ${CPU_PERCENT}%"
echo "Maximum RAM used:      ${MAX_RSS_GB} GiB"
echo "========================================"

if [[ $FAILED -ne 0 ]]
then
    echo
    echo "WARNING: $FAILED replay process(es) failed."
    exit 1
fi

echo
echo "Replay completed successfully."
