#!/bin/bash -e

# Copyright (c) 2022 BigBlueButton Inc.
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.

# BigBlueButton is an open source conferencing system. For more information see
#    https://www.bigbluebutton.org/.
#
# This gl-install.sh script automates many of the installation and configuration
# steps at https://docs.bigbluebutton.org/greenlight_v3/gl3-install.html
#
#
#  Examples
#
#  Install a standaolne Greenlight 3.x.x with a publicly trusted SSL certificate issued by Let's Encrypt using a FQDN of www.example.com
#  and an email address of info@example.com.
#
#    wget -qO- https://raw.githubusercontent.com/bigbluebutton/greenlight-run/master/gl-install.sh | bash -s -- -s www.example.com -e info@example.com 
#


usage() {
    set +x
    cat 1>&2 <<HERE

Script for installing a Greenlight 3.x standalone server in under 15 minutes. It also supports upgrading an existing installation of Greenlight 3.x on replay.

USAGE:
    wget -qO- https://raw.githubusercontent.com/bigbluebutton/greenlight-run/master/gl-install.sh | bash -s -- [OPTIONS]

OPTIONS (install Greenlight):

  -s <hostname>          Configure server with <hostname> (required)
  -e <email>             Email for Let's Encrypt certbot (required)
  -b <hostname>:<secret> The BigBlueButton server accessible on <hostname> with secret <secret> (Defaults to our demo server, do not use for production).

  -h                     Print help

EXAMPLES:

Sample options for setup a Greenlight 3.x server with a publicly signed (by Let's encrypt) SSL certificate for a FQDN of www.example.com and an email
of info@example.com that uses a BigBlueButton server at bbb.example.com with secret SECRET: 

    -s www.example.com -e info@example.com -b bbb.example.com:SECRET

SUPPORT:
         Community: https://groups.google.com/g/bigbluebutton-greenlight
         Source: https://github.com/bigbluebutton/greenlight-run
         Docs: https://docs.bigbluebutton.org/greenlight_v3/gl3-install.html

HERE
}

main() {
  export DEBIAN_FRONTEND=noninteractive
  LETS_ENCRYPT_OPTIONS="--webroot --non-interactive"
  SOURCES_FETCHED=false
  GL3_DIR=~/greenlight-v3
  ACCESS_LOG_DEST=/var/log/nginx
  NGINX_FILES_DEST=/etc/greenlight/nginx
  ASSETS_DEST=/var/www/greenlight-default/assets
  CR_TMPFILE=$(mktemp /tmp/carriage-return.XXXXXX)
  echo "\n" > $CR_TMPFILE

  # Eager checks and assertions.
  check_root
  check_ubuntu 20.04
  need_x64

  while builtin getopts "s:e:b:h" opt "${@}"; do

    case $opt in
      h)
        usage
        exit 0
        ;;

      s)
        HOST=$OPTARG
        if [ "$HOST" == "bbb.example.com" ]; then 
          err "You must specify a valid FQDN (not the FQDN given in the docs)."
        fi
        ;;
      e)
        EMAIL=$OPTARG
        if [ "$EMAIL" == "info@example.com" ]; then 
          err "You must specify a valid email address (not the email in the docs)."
        fi
        ;;
      b)
        BIGBLUEBUTTON=$OPTARG
        if [ "$BIGBLUEBUTTON" == "bbb.example.com:SECRET" ]; then 
          err "You must use a valid BigBlueButton server (not the one in the example)."
        fi

        if [[ ! $BIGBLUEBUTTON =~ .+:.+ ]]; then
          err "You must respect the format <hostname>:<secret> when specifying your BigBlueButton server."
        fi

        IFS=: BIGBLUEBUTTON=($BIGBLUEBUTTON) IFS=' ' # Making BIGBLUEBUTTON an array, first element is the BBB hostname and the second is the BBB secret.
        ;;  
      :)
        err "Missing option argument for -$OPTARG"
        ;;

      \?)
        err "Invalid option: -$OPTARG"
        ;;
    esac
  done

  check_env # Meeting requirements.

  say "Checks passed, installing/upgrading Greenlight!"

  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade
  
  install_ssl
  install_greenlight_v3

  apt-get auto-remove -y
  say "DONE ^^"
}

check_env() {
  # Required ARGS
  if [ -z "$HOST" ] || [ -z "$EMAIL" ] ; then
    err "You must provide a FQDN and an email address to generate a certificate."
  fi

  local bbb_detected_err="This deployment installs Greenlight without BigBlueButton if planning to install both on the same system then please use https://github.com/bigbluebutton/bbb-install to instead"

  # Detecting BBB on the system
  if [ "${BIGBLUEBUTTON[0]}" == "$HOST" ]; then
    say "Your FQDN match that of the BigBlueButton server, are you willing to install Greenlight with BigBlueButton on this system?"
    err "$bbb_detected_err."
  fi

  if dpkg -l | grep -q bbb; then
    say "BigBlueButton modules has been detected on this system!" 
    err "$bbb_detected_err."
  fi

  # Possible conflicts on setup.
  if [ ! -d "$GL3_DIR" ]; then
    # Conflict detection of existent nginx on the system not installed by this script (possible collision with other applications).
    if dpkg -s nginx 1> /dev/null 2>&1; then
      say "Nginx is already installed on this system by another mean, this deployment may impact your workload!"
      err "Remove and cleanup nginx configurations on this system or kindly consider using a clean enviroment before proceeding."
    fi

    # Conflict detection of required ports being already in use.
    if check_ports_listen "80|443|5050"; then
      say "Some required ports are already in use by another application!"
      err "Make sure to clear out the required ports (TCP 80, 443, 5050) if possible or kindly consider using a clean enviroment before proceeding."
    fi
  fi

  check_host "$HOST"
}

say() {
  echo "gl-install: $1"
}

err() {
  say "$1" >&2
  exit 1
}

check_root() {
  if [ $EUID != 0 ]; then err "You must run this command as root."; fi
}

check_ubuntu() {
  RELEASE=$(lsb_release -r | sed 's/^[^0-9]*//g')
  if [ "$RELEASE" != "$1" ]; then err "You must run this command on Ubuntu $1 server."; fi
}

need_x64() {
  UNAME=`uname -m`
  if [ "$UNAME" != "x86_64" ]; then err "You must run this command on a 64-bit server."; fi
}

wait_443() {
  check_ports_clearing 443 && say "Waiting for port 443 to clear "

  while check_ports_clearing 443; do sleep 1; echo -n '.'; done
  echo
}

check_ports_listen() {
  local pattern=${1:-80|443}

  ss -lnt | awk '{print $4}' | egrep -q "$pattern"
}

check_ports_clearing() {
  local pattern=${1:-80|443}

  ss -ant | grep TIME-WAIT | awk '{print $4}' | egrep -q "$pattern"
}

get_IP() {
  if [ -n "$IP" ]; then return 0; fi

  # Determine local IP
  if [ -e "/sys/class/net/venet0:0" ]; then
    # IP detection for OpenVZ environment
    _dev="venet0:0"
  else
    _dev=$(awk '$2 == 00000000 { print $1 }' /proc/net/route | head -1)
  fi
  _ips=$(LANG=C ip -4 -br address show dev "$_dev" | awk '{ $1=$2=""; print $0 }')
  _ips=${_ips/127.0.0.1\/8/}
  read -r IP _ <<< "$_ips"
  IP=${IP/\/*} # strip subnet provided by ip address
  if [ -z "$IP" ]; then
    read -r IP _ <<< "$(hostname -I)"
  fi


  # Determine external IP 
  if grep -sqi ^ec2 /sys/devices/virtual/dmi/id/product_uuid; then
    # EC2
    local external_ip=$(wget -qO- http://169.254.169.254/latest/meta-data/public-ipv4)
  elif [ -f /var/lib/dhcp/dhclient.eth0.leases ] && grep -q unknown-245 /var/lib/dhcp/dhclient.eth0.leases; then
    # Azure
    local external_ip=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text")
  elif [ -f /run/scw-metadata.cache ]; then
    # Scaleway
    local external_ip=$(grep "PUBLIC_IP_ADDRESS" /run/scw-metadata.cache | cut -d '=' -f 2)
  elif which dmidecode > /dev/null && dmidecode -s bios-vendor | grep -q Google; then
    # Google Compute Cloud
    local external_ip=$(wget -O - -q "http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" --header 'Metadata-Flavor: Google')
  elif [ -n "$1" ]; then
    # Try and determine the external IP from the given hostname
    need_pkg dnsutils
    local external_ip=$(dig +short "$1" @resolver1.opendns.com | grep '^[.0-9]*$' | tail -n1)
  fi

  # Check if the external IP reaches the internal IP
  if [ -n "$external_ip" ] && [ "$IP" != "$external_ip" ]; then
    if which nginx; then
      systemctl stop nginx
    fi

    need_pkg netcat-openbsd

    wait_443

    nc -l -p 443 > /dev/null 2>&1 &
    nc_PID=$!
    sleep 1
    
     # Check if we can reach the server through it's external IP address
     if nc -zvw3 "$external_ip" 443  > /dev/null 2>&1; then
       INTERNAL_IP=$IP
       IP=$external_ip
       echo 
       echo "  Detected this server has an internal/external IP address."
       echo 
       echo "      INTERNAL_IP: $INTERNAL_IP"
       echo "    (external) IP: $IP"
       echo 
     fi

    kill $nc_PID  > /dev/null 2>&1;

    if which nginx; then
      systemctl start nginx
    fi
  fi

  if [ -z "$IP" ]; then err "Unable to determine local IP address."; fi
}

need_pkg() {
  check_root
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do echo "Sleeping for 1 second because of dpkg lock"; sleep 1; done

  if [ ! "$SOURCES_FETCHED" = true ]; then
    apt-get update
    SOURCES_FETCHED=true
  fi

  if ! dpkg -s ${@:1} >/dev/null 2>&1; then
    LC_CTYPE=C.UTF-8 apt-get install -yq ${@:1}
  fi
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do echo "Sleeping for 1 second because of dpkg lock"; sleep 1; done
}

check_host() {
    need_pkg dnsutils apt-transport-https
    DIG_IP=$(dig +short "$1" | grep '^[.0-9]*$' | tail -n1)
    if [ -z "$DIG_IP" ]; then err "Unable to resolve $1 to an IP address using DNS lookup.";  fi
    get_IP "$1"
    if [ "$DIG_IP" != "$IP" ]; then err "DNS lookup for $1 resolved to $DIG_IP but didn't match this system $IP."; fi
}

# This function will install the latest official version of greenlight-v3 and set it as the hosting Bigbluebutton default frontend or update greenlight-v3 if installed.
# Greenlight is a simple to use Bigbluebutton room manager that offers a set of features useful to online workloads especially virtual schooling.
# https://docs.bigbluebutton.org/greenlight/gl-overview.html
install_greenlight_v3(){
  check_root
  install_docker

  # Preparing and checking the enviroment.
  say "preparing and checking the enviroment to install/update greelight-v3..."

  if [ ! -d $GL3_DIR ]; then
    mkdir -p $GL3_DIR && say "created $GL3_DIR"
  fi

  local GL_IMG_REPO=bigbluebutton/greenlight:v3

  say "pulling latest $GL_IMG_REPO image..."
  docker pull $GL_IMG_REPO

  if [ ! -f $GL3_DIR/.env ]; then
    docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat sample.env' > $GL3_DIR/.env && say ".env file was created"
  fi

  if [ ! -f $GL3_DIR/docker-compose.yml ]; then
    docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat docker-compose.yml' > $GL3_DIR/docker-compose.yml && say "docker compose file was created"
  fi

  # Configuring Greenlight v3.
  say "checking the configuration of greenlight-v3..."

  local SECRET_KEY_BASE=$(docker run --rm --entrypoint bundle $GL_IMG_REPO exec rake secret)
  local PGUSER=postgres # Postgres db user to be used by greenlight-v3.
  local PGTXADDR=postgres:5432 # Postgres DB transport address (pair of (@ip:@port)).
  local PGDBNAME=greenlight-v3-production
  local PGPASSWORD=$(openssl rand -hex 24) # Postgres user password.
  local RSTXADDR=redis:6379

  if [ -n "$BIGBLUEBUTTON" ]; then
    # BigBlueButton server configuration.
    local BIGBLUEBUTTON_ENDPOINT="https://${BIGBLUEBUTTON[0]}/bigbluebutton/api"
    local BIGBLUEBUTTON_SECRET=${BIGBLUEBUTTON[1]}

    # In this case admins can use the script to configure Greenlight to use the BigBlueButton server or update it to use a different one (overwrite). 
    sed -i "s|^[# \t]*BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BIGBLUEBUTTON_ENDPOINT|" $GL3_DIR/.env
    sed -i "s|^[# \t]*BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BIGBLUEBUTTON_SECRET|"  $GL3_DIR/.env
  else
    # Demo BigBlueButton server configuration.
    local BIGBLUEBUTTON_ENDPOINT="https://test-install.blindsidenetworks.com/bigbluebutton/api"
    local BIGBLUEBUTTON_SECRET=8cd8ef52e8e101574e400365b55e11a6

    # In this case admins can use the script to configure Greenlight with the demo server but not update it to use a dedicated server if already configured (no overwrite).
    sed -i "s|^[# \t]*BIGBLUEBUTTON_ENDPOINT=[ \t]*$|BIGBLUEBUTTON_ENDPOINT=$BIGBLUEBUTTON_ENDPOINT|" $GL3_DIR/.env
    sed -i "s|^[# \t]*BIGBLUEBUTTON_SECRET=[ \t]*$|BIGBLUEBUTTON_SECRET=$BIGBLUEBUTTON_SECRET|"  $GL3_DIR/.env
  fi

  # A note for future maintainers:
  #   The following configuration operations were made idempotent, meaning that playing these actions will have an outcome on the system (configure it) only once.
  #   Replaying these steps are a safe and an expected operation, this gurantees the seemless simple installation and upgrade of Greenlight v3.
  #   A simple change can impact that property and therefore render the upgrading functionnality unoperationnal or impact the running system.

  # Configuring Greenlight v3 .env file (if already configured this will only update the BBB endpoint and secret).

  sed -i "s|^[# \t]*SECRET_KEY_BASE=[ \t]*$|SECRET_KEY_BASE=$SECRET_KEY_BASE|" $GL3_DIR/.env
  sed -i "s|^[# \t]*DATABASE_URL=[ \t]*$|DATABASE_URL=postgres://$PGUSER:$PGPASSWORD@$PGTXADDR/$PGDBNAME|" $GL3_DIR/.env
  sed -i "s|^[# \t]*REDIS_URL=[ \t]*$|REDIS_URL=redis://$RSTXADDR/|" $GL3_DIR/.env
  # Configuring Greenlight v3 docker-compose.yml (if configured no side effect will happen).
  sed -i "s|^\([ \t-]*POSTGRES_PASSWORD\)\(=[ \t]*\)$|\1=$PGPASSWORD|g" $GL3_DIR/docker-compose.yml

  # Placing greenlight-v3 nginx file, this will enable greenlight-v3 as your Bigbluebutton frontend (bbb-fe).
  docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat greenlight-v3.nginx' > $NGINX_FILES_DEST/greenlight-v3.nginx && say "added greenlight-v3 nginx file"

  nginx -qt || err 'greenlight-v3 failed to install due to nginx tests failing to pass - if using the official image then please contact the maintainers.'
  nginx -qs reload && say 'greenlight-v3 was successfully configured'

  # Eager pulling images.
  say "pulling latest greenlight-v3 services images..."
  docker-compose -f $GL3_DIR/docker-compose.yml pull

  if check_container_running greenlight-v3; then
    # Restarting Greenlight-v3 services after updates.
    say "greenlight-v3 is updating..."
    say "shutting down greenlight-v3..."
    docker-compose -f $GL3_DIR/docker-compose.yml down
  fi

  say "starting greenlight-v3..."
  docker-compose -f $GL3_DIR/docker-compose.yml up -d
  sleep 5
  say "greenlight-v3 is ready, You can VISIT: http://$HOST/ !"
  return 0;
}

install_ssl() {
  need_pkg nginx

  mkdir -p $ACCESS_LOG_DEST $NGINX_FILES_DEST $ASSETS_DEST

  if [ ! -f /etc/nginx/sites-available/greenlight ]; then
          cat <<HERE > /etc/nginx/sites-available/greenlight
server_tokens off;
server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  access_log  $ACCESS_LOG_DEST/greenlight.access.log;

  # Greenlight landing page.
  location / {
    root   $ASSETS_DEST;
    try_files \$uri @bbb-fe;
  }

  include $NGINX_FILES_DEST/*.nginx;
}

HERE
  fi

  if [ ! -f /etc/nginx/sites-enabled/greenlight ]; then
    ln -s /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
  fi

  if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -v /etc/nginx/sites-enabled/default
  fi

  systemctl reload nginx
}

# Given a container name as $1, this function will check if there's a match for that name in the list of running docker containers on the system.
# The result will be binded to $?.
check_container_running() {
  docker ps | grep -q "$1" || return 1;

  return 0;
}

# Given a filename as $1, if file exists under $sites_dir then the file will be suffixed with '.disabled'.
# sites_dir points to Bigbluebutton nginx sites, when suffixed with '.disabled' nginx will not include the site on reload/restart thus disabling it.
disable_nginx_site() {
  local site_path="$1"
  local sites_dir=/usr/share/bigbluebutton/nginx

  if [ -z $site_path ]; then
    return 1;
  fi

  if [ -f $sites_dir/$site_path ]; then
    mv $sites_dir/$site_path $sites_dir/$site_path.disabled && return 0;
  fi

  return 1;
}

install_docker() {
  need_pkg apt-transport-https ca-certificates curl gnupg-agent software-properties-common openssl

  # Install Docker
  if ! apt-key list | grep -q Docker; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  fi

  if ! dpkg -l | grep -q docker-ce; then
    echo "deb [ arch=amd64 ] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    
    add-apt-repository --remove\
     "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) \
     stable"

    apt-get update
    need_pkg docker-ce docker-ce-cli containerd.io
  fi
  if ! which docker; then err "Docker did not install"; fi

  # Purge older docker compose if exists.
  if dpkg -l | grep -q docker-compose; then
    apt-get purge -y docker-compose
  fi

  if [ ! -x /usr/local/bin/docker-compose ]; then
    curl -L "https://github.com/docker/compose/releases/download/1.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

main "$@" || exit 1

