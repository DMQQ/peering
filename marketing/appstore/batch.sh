#!/bin/bash
cd "$(dirname "$0")"
for l in en de es fr it pt-BR ru ja ko zh-Hans; do python3 capture.py $l; done
echo BATCH_DONE
