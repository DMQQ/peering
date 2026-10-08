#!/bin/bash
cd "$(dirname "$0")"
for l in "$@"; do
  python3 capture.py $l || python3 capture.py $l
  python3 lock.py $l
  python3 frame.py $l
  echo "LANG_DONE $l"
done
echo ALL_DONE
