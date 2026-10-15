#!/bin/bash
seg=0
nevents=-1
first_event=0
# Check number of arguments
if [[ $# -eq 1 ]]; then
    run=$1
    analyzer "replay.C(${run},${seg},${nevents},${first_event})"
elif [[ $# -eq 2 ]]; then
    run=$1
    seg=$2
    analyzer "replay.C(${run},${seg},${nevents},${first_event})"
elif [[ $# -eq 3 ]]; then
    run=$1
    seg=$2
    nevents=$3
    analyzer "replay.C(${run},${seg},${nevents},${first_event})"
elif [[ $# -eq 4 ]]; then
    run=$1
    seg=$2
    nevents=$3
    first_event=$4
    analyzer "replay.C(${run},${seg},${nevents},${first_event})"
else
    echo "Usage: $0 RUN"
    echo "   or: $0 RUN $1 SEGMENT"
    echo "   or: $0 Run $1 SEGMENT $2 NEVENTS"
    echo "   or: $0 Run $1 SEGMENT $2 NEVENTS $3 FIRSTEVENT"
    exit 1
fi

