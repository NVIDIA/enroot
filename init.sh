# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

set -eu

if [ -s /etc/rc.local ]; then
    . /etc/rc.local
elif [ -x /bin/sh ]; then
    exec /bin/sh
fi

exit 127
