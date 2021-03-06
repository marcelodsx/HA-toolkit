#!/bin/bash
#
# $Id: lib/ha.sh 3.26 2017-10-21 00:47:23 rob.navarro $
#
# ha.sh
# contains common code used by the HA toolkit
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

if ! declare -f abend &> /dev/null ; then
	echo "ERROR: ${BASH_SOURCE[0]}: lib/log.sh not included. This is a coding error! " >&2
	exit 1
fi

# with help from:
# http://stackoverflow.com/questions/1923435/how-do-i-echo-stars-when-reading-password-with-read
function getpw { 
        (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <variable name>"
        local pwch inpw1 inpw2=' ' prompt; 
        
        ref=$1 
	while [[ "$inpw1" != "$inpw2" ]] ; do
		prompt="Enter MySQL root password: "
		inpw1=''
		while read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				echo > /dev/tty
				break 
			else 
				prompt='*'
				inpw1+=$pwch 
			fi 
		done 

		prompt="re-enter same password: "
		inpw2=''
		while read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				echo > /dev/tty
				break 
			else 
				prompt='*'
				inpw2+=$pwch 
			fi 
		done 
	
		[[ "$inpw1" == "$inpw2" ]] || echo "passwords unequal. Retry..." 1>&2
	done

	# indirect assignment (without local -n) needs eval. 
	# This only works with global variables :-( Please use weird variable names to
	# avoid namespace conflicts...
        eval "${ref}=\$inpw1"            # assign passwd to parameter variable
}

# helper function to allow separate setting of passwd from command line.
# Use this to persist an obfuscated version of the MySQL passwd to disk.
# Call as:
#  . hafunctions.sh
#  save_mysql_passwd $APPD_ROOT
function save_mysql_passwd {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 
	[[ -d $1 ]] || fatal "$thisfn: \"$1\" is not APPD_ROOT"
	local rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	getpw __inpw1 || exit 1		# updates __inpw1 *ONLY* if global variable
	obf=$(obfuscate $__inpw1) || exit 1
	echo $obf > $rootpw_obf || fatal "$thisfn: failed to save obfuscated passwd to $rootpw_obf"
	chmod 600 $rootpw_obf || warn "$thisfn: failed to make $rootpw_obf readonly"
}

#
# find out which escalation method we are using
#
if [ -f /sbin/service ] ; then
    service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
    service_bin=/usr/sbin/service
else
    fatal 1 "service not found in /sbin or /usr/sbin"
fi

#
# abstract out the privilege escalation at run time
#
# remservice <flags> <machine> <service> <verb>
# service <service> <verb>
#
if [[ `id -u` == 0 ]] ; then
	function service {
		$service_bin $1 $2
	}   
        
	function remservice {
		ssh $1 $2 $service_bin $3 $4
	}
else
	if [ -f $APPD_ROOT/HA/NOROOT ] ; then
		function service {
			$APPD_ROOT/HA/appdservice-noroot.sh $1 $2
		}
		function remservice {
			ssh $1 $2 $APPD_ROOT/HA/appdservice-noroot.sh $3 $4
		}
	elif [ -x /sbin/appdservice ] ; then
		function service {
			/sbin/appdservice $1 $2
		}
		function remservice {
			ssh $1 $2 /sbin/appdservice $3 $4
		}
	else
		function service {
			sudo $service_bin $1 $2
		}
		function remservice {
			ssh $1 $2 sudo -n $service_bin $3 $4
		}
    fi
fi

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
function check_sanity {
	if [ ! -d "$APPD_ROOT" ] ; then
		fatal 1 "controller root $APPD_ROOT is not a directory"
	fi
	if [ ! -w "$DB_CONF" ] ; then
		fatal 2 "db configuration $DB_CONF is not writable"
	fi
	if [ ! -x "$MYSQL" ] ; then
		fatal 3 "controller root $MYSQL is not executable"
	fi
	if [ `id -un` != $RUNUSER ] ; then
		fatal 4 "$0 must run as $RUNUSER"
	fi
}

#
# locate a machine agent install directory and print out it's path
#
function find_machine_agent {
	for ma_path in $(find ../.. .. -maxdepth 2 -type f -name machineagent.jar -print 2>/dev/null | sed "s,/[^/]*$,," | sort -u) ; do
		readlink -e $ma_path
	done
}

# output all the names and aliases on the input /etc/hosts file for the current
# hostname
function get_names {
   (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <hostname>"
   local host=$1

   awk '
   BEGIN	{ IGNORECASE = 1 }
   $1 ~ /^[[:space:]]*#/ {next} 
   $1 ~ /^127.0./ {next} 
   $1 ~ /[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$/ && $0 ~ /'$host'/ {for (i=2; i <= NF; ++i) print $i}'
}
export -f get_names

#
# Check for various problems that prevent passwordless ssh working from each
# node to the other.
# Checks all /etc/hosts names for $(hostname) calling ssh to all secondary's 
# /etc/hosts entries and vice versa.
# Return non-zero for caller to exit if required.
# Requires:
#  . lib/log.sh
# Call as:
#  check_ssh_setup $otherhostname || fatal "2-way passwordless ssh not setup"
# 
# e.g. if function running on primary then:
#  check_ssh_setup $secondary
#
function check_ssh_setup {
   (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <otherhostname>"
   local myhost=$(hostname) otherhost=$1 i j OUT=/tmp/.out.$$ ERR=/tmp/.errs.$$

   touch $OUT && [[ -w $OUT ]] || abend "${FUNCNAME[0]}: unable to write to $OUT"
   touch $ERR && [[ -w $ERR ]] || abend "${FUNCNAME[0]}: unable to write to $ERR"

   # suffers a slight chicken and egg problem as we need /etc/hosts of $otherhost
   # but have not established that ssh to secondary works yet... hence initial
   # test
   timeout 2s bash -c 'ssh -o StrictHostKeyChecking=no '$otherhost' pwd' >$OUT 2>$ERR
   retc=$?
   if (( $retc != 0 )) ; then
      message "ssh Test-0: $myhost unable to reach $otherhost: $(<$ERR)"
      return 2
   fi
   local pattern='^/.*'
   if [[ ! "$(<$OUT)" =~ $pattern ]] ; then
       message "ssh Test-0: $myhost unable to run 'pwd' on $otherhost: $(<$ERR). Please fix and re-try"
       return 3
   fi
   rm -f $OUT $ERR

   local mynames=$(cat /etc/hosts | get_names $myhost)
   local othernames=$(ssh -o StrictHostKeyChecking=no $otherhost cat /etc/hosts | get_names $otherhost)
   if [[ -z "$othernames" ]] ; then
      message "ssh Test-0: $myhost unable to cat /etc/hosts on $otherhost. Please fix and re-try"
      return 4
   fi
   # now check that all names for current hostname can make passwordless ssh call to all names
   # for $otherhost and vice-versa
   for i in $mynames ; do
      for j in $othernames ; do
         do_check_ssh_setup $i $j || return $?
      done
   done
}

# Helper function for check_ssh_setup() that tests ssh between two named hosts.
# Note that these tests will also add entries into the ~/.ssh/known_hosts
# files of both hosts.
function do_check_ssh_setup {
   (( $# == 2 )) || abend "Usage: ${FUNCNAME[0]} <myhostname> <otherhostname>"
   local myhost=$1 otherhost=$2 retc OUT=/tmp/.out.$$ ERR=/tmp/.errs.$$

   touch $OUT && [[ -w $OUT ]] || abend "${FUNCNAME[0]}: unable to write to $OUT"
   touch $ERR && [[ -w $ERR ]] || abend "${FUNCNAME[0]}: unable to write to $ERR"

   # Test-1: check whether possible to reach $otherhost with ssh - fingerprint known or not
   timeout 2s bash -c 'ssh -o StrictHostKeyChecking=no '$otherhost' echo $(id -un):$(id -gn)' >$OUT 2>$ERR
   retc=$?
   if (( $retc != 0 )) ; then
      message "ssh Test-1: $myhost unable to reach $otherhost: $(<$ERR)"
      return 5
   fi
   if [[ "$(<$OUT)" != "$(id -un):$(id -gn)" ]] ; then
       message "ssh Test-1: $myhost unable to determine username:groupname on $otherhost: $(<$ERR). Please ensure same username and groupname on both HA servers and re-try"
       return 6
   fi

   # Test-3: check whether otherhost can reach me with ssh - fingerprint known or not
   timeout 2s bash -c 'ssh '$otherhost' ssh -o StrictHostKeyChecking=no '$myhost' id -un' &> $ERR
   retc=$?
   if (( $retc != 0 )) ; then
      message "ssh Test-3: $otherhost unable to reach $myhost: $(<$ERR)"
      return 8
   fi

   rm -f $OUT $ERR		# files are not deleted after unsuccessful earlier return
   return 0
}

