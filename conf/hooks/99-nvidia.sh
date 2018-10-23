#! /bin/bash

# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

# Uncomment the following line to gather logs from libnvidia-container.
#exec "$(dirname $0)/nvidia" --debug=/tmp/enroot-hook-nvidia.log

exec "$(dirname $0)/nvidia"
