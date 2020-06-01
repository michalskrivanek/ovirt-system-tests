#
# Copyright 2020 Red Hat, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
#
# Refer to the README and COPYING files for full details of the license
#

import os
import platform
import re

from ost_utils.memoized import memoized


@memoized
def on_centos(ver=''):
    with open('/etc/redhat-release') as f:
        contents = f.readline()
        return re.match('(Red Hat|CentOS).*release {}'.format(ver), contents)


@memoized
def kernel_version():
    version = platform.uname()[2]
    return [int(v) for v in version.replace('-', '.').split('.')[:4]]


@memoized
def inside_mock():
    return "MOCK_EXTERNAL_USER" in os.environ