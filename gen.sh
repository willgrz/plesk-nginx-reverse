#!/bin/bash
#https://github.com/willgrz/plesk-nginx-reverse
sver="0.9b2/initial"


#conf dir to read, below is the default Plesk nginx config dir
#NO SUPPORT FOR APACHE ONLY VHOSTS - you need to have at least nginx as cache (with SSL, if on domain) enabled in your Plesk.
confdir="/etc/nginx/plesk.conf.d/vhosts"
#local tmp dir, below makes sense to keep nginx stuff central
tmpdir="/etc/nginx/reverse-sync/"
#target servers separated by space
targetservers="10.250.1.1 10.250.2.1"
#target directory on servers, this is the directory also set in the configs for SSL, you need to edit templates.conf* if you change it
targetdir="/etc/nginx/conf.d/plesk-reverse/"
#log file on this system, the log style follows syslog with INFO/ERROR/UNKNOWN tags
logfile="/var/log/plesk-nginx-reverse.log"
#override backend to always use SSL - this forces HTTPS to backend also in HTTP vhosts/port 80. Breaks some CMS, use on own risk. Does *NOT* verify backend has any SSL.
forcessl="0"

#My default log function
function log {
  sexit=$1
  slog=$2
  if [ "$sexit" == "0" ]; then
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: INFO")
	if [ "$eonly" != "1" ]; then
		  echo "${slog}"
        fi
  elif [ "$sexit" == "1" ]; then
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: ERROR")
	echo "${slog}"
  else
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: UNKNOWN")
	echo "${slog}"
  fi
  echo "${base}" "${slog}" >>${logfile}
}

argg=$1
if [ "x${argg}" != "x" ]; then
	if [ "$argg" == "init" ]; then
		sip=$2
		if [ "x${sip}" == "x" ]; then
			log 1 "Server init failed: no IP/hostname supplied"
			exit 1
		fi
		log 0 "Starting setup of server $sip"
		scheck=$(ssh $sip echo 1)
		if [ "$scheck" != "1" ]; then
			log 1 "Server init failed: Test SSH connection to $sip failed"
			exit 1
		fi
                ssys=$(ssh $sip cat /etc/debian_version; echo $?)
                if [ "$ssys" == "1" ]; then
                        log 1 "Server init failed: Not a Debian/apt based system"
                        exit 1
                fi
		snginx=$(ssh $sip 'if [ -f "/etc/nginx/nginx.conf" ] && [ ! -f "/etc/nginx/.pleskproxy" ]; then echo 1; fi')
                if [ "$snginx" == "1" ]; then
                        log 1 "Server init failed: Nginx already installed and NOT ours"
                        exit 1
                fi
		log 0 "Checks ok - starting install via apt"
		ssh $sip "apt-get update >>/dev/null; apt-get install nginx -y; mkdir -p ${targetdir}"
		log 0 "Syncing Nginx config"
		scp nginx.conf root@${sip}:/etc/nginx/nginx.conf
		log 0 "Syncing existing configs and certificates"
	        rsync --size-only -r ${tmpdir}/conf root@${sip}:/${targetdir}/
	        rsync --size-only -r ${tmpdir}/ssl root@${sip}:/${targetdir}/
		log 0 "Restarting nginx"
		ssh $sip service nginx restart
		log 0 "Server init on $sip finished - please add to config as target"
	fi
	exit 0
fi


cd ${tmpdir}
for conf in $(ls ${confdir}/*.conf); do
	domain=$(echo "${conf}" | sed -e 's/.conf$//g' | sed -e "s+${confdir}++g" | sed -e 's+/++g')
	backendssl="https://$(cat ${confdir}/${domain}.conf |grep 'listen' |grep 'ssl' | awk '{print $2}' | sed -e 's/;//g' | head -1 | xargs)"
	backendplain="http://$(cat ${confdir}/${domain}.conf |grep 'listen' |grep -v 'ssl' | awk '{print $2}' | sed -e 's/;//g' | head -1 | xargs)"
	if [ "x${backendplain}" == "xhttp://" ] || [ "$forcessl" == "1" ]; then
		backendplain=${backendssl}
	fi
	if [ "$(cat ${confdir}/${domain}.conf |grep 'server_name www.' >>/dev/null; echo $?)" == "0" ]; then
		srvname="${domain} www.${domain}"
	else
		srvname="${domain}"
	fi
	log 0 "$domain starting update"
	if [ "x${backendssl}" != "x" ]; then
		log 0 "$domain has SSL certificate - copying"
		mkdir -p ssl
		ssl="1"
		sslcert=$(cat ${confdir}/${domain}.conf |grep 'ssl_certificate' |grep -v 'ssl_certificate_key' | awk '{print $2}' | sed -e 's/;//')
		sslkey=$(cat ${confdir}/${domain}.conf |grep 'ssl_certificate_key' | awk '{print $2}' | sed -e 's/;//')
		sslclient=$(cat ${confdir}/${domain}.conf |grep 'ssl_client_certificate' | awk '{print $2}' | sed -e 's/;//')
		if [ ! -f "ssl/${domain}.crt" ] || [ "$(md5sum ${sslcert} | awk '{print $1}')" != "$(md5sum ssl/${domain}.crt | awk '{print $1}')" ]; then
			cat ${sslcert} >ssl/${domain}.crt
			cat ${sslkey} >ssl/${domain}.key
			if [ "x${sslclient}" != "x" ];then
				sslc="1"
				cat ${sslclient} >ssl/${domain}.client
			fi
		fi
	fi
	cat template.conf >conf/${domain}.conf.tmp
	if [ "$ssl" == "1" ]; then
		cat template.conf.ssl >>conf/${domain}.conf.tmp
		sed -i "s+SSLCERT+${targetdir}/ssl/${domain}.crt+g" conf/${domain}.conf.tmp
		sed -i "s+SSLKEY+${targetdir}/ssl/${domain}.key+g" conf/${domain}.conf.tmp
		if [ "$sslc" == "1" ]; then
			sed -i "s+SSLCLIENT+${targetdir}/ssl/${domain}.client+g" conf/${domain}.conf.tmp
			sed -i "s/#ssl_client_certificate/ssl_client_certificate/" conf/${domain}.conf.tmp
			sed -i "s+SSLBACKEND+${backendssl}+g" conf/${domain}.conf.tmp
		fi
	fi
	sed -i "s/SRVNAME/${srvname}/g" conf/${domain}.conf.tmp
	sed -i "s+BACKEND+${backendplain}+g" conf/${domain}.conf.tmp
	if [ ! -f "conf/${domain}.conf" ] || [ "$(md5sum conf/${domain}.conf | awk '{print $1}')" != "$(md5sum conf/${domain}.conf.tmp | awk '{print $1}')" ]; then
		mv conf/${domain}.conf.tmp conf/${domain}.conf
		log 0 "$domain updated"
	else
		log 0 "$domain not updated - deleting tmp file"
		rm -f conf/${domain}.conf.tmp
	fi
done

for server in $(echo ${targetservers}); do
	log 0 "Syncing server $server"
	rsync --size-only -r ${tmpdir}/conf root@${server}:/${targetdir}/
	rsync --size-only -r ${tmpdir}/ssl root@${server}:/${targetdir}/
	cnginx=$(ssh $server "nginx -t >>/dev/null 2>/dev/null; echo $?")
	if [ "$cnginx" == "0" ]; then
		log 0 "Reloading nginx on $server"
		ssh $server service nginx reload
	fi
done
