# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.

if [ -s /etc/rc ]; then
    . /etc/rc
elif [ -x /bin/sh ]; then
    exec /bin/sh
fi

exit 127
