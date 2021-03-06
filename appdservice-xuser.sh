#!/bin/bash
#
# $Id: appdservice-xuser.sh 3.12 2017-03-07 17:04:25 cmayer $
#
# user defined shell wrapper for appdynamics service changes
#
# Copyright 2016 AppDynamics, Inc
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

function usage {
	echo usage: "$0 [appdcontroller appdcontroller-db] [start stop status]"
	exit 1
}

if [ $# -ne 2 ] ; then
	usage
fi

case $1 in
	appdcontroller|appdcontroller-db)
		service=$1
		;;
	*)
		usage
		;;
esac

case $2 in
	start|stop|status)
		action=$2
		;;
	*)
		usage
		;;
esac

#
# insert user state change handler code
# use $service and $action
#
exit 0
