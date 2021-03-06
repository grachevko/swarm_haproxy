#!/bin/bash

set -e

ACL_HOST="	acl %id% hdr(host) -i %host%"
ACL_PATH="	acl %id% path_beg -i %host%"
USE_BACKEND="	use_backend %id%_backend if %condition%"

REDIRECT="	http-request redirect code %code% scheme %scheme% location %location% if %id%"

FRONTEND_HTTPS="frontend https_frontend
	bind *:443  ssl crt /usr/local/etc/haproxy/certs
	mode http
	monitor-uri /healthcheck
	reqadd X-Forwarded-Proto:\ https"

BACKEND_START="backend %id%_backend
	mode http
	server %id%_server %service%"
BACKEND_RESOLVER=" resolvers dns check inter 1000"
BACKEND_HEADER_FORWARDED="	http-request add-header X-Forwarded-Proto https if { ssl_fc }
	http-request set-header X-Forwarded-Port %[dst_port] if { ssl_fc }"

REDIRECT_ALL_TO_HTTPS_FRONTEND="
	acl http	  ssl_fc,not
	use_backend redirect_to_https_backend if http"

REDIRECT_ALL_TO_HTTPS_BACKEND="
	backend redirect_to_https_backend
	mode http
	http-request redirect code 301 scheme https"

handle_host () {
	ENV_PREFIX=$1
	FILE_PREFIX=$2
	REDIRECT_PREFIX=$3
	index=$4

    IFS='=' read id options <<< "$i"
    id=${id:${#ENV_PREFIX}}

    if [[ ${id:0:8} == "$REDIRECT_PREFIX" ]] ; then
        IFS=';' read hosts location code scheme <<< "$options"
    else
        IFS=';' read hosts service <<< "$options"
        IFS=':' read host port <<< "$service"

        if ! nslookup "$host" 127.0.0.11 &> /dev/null
        then
            >&2 echo service host \""$service"\" is unreachable and will be skipped

            continue
        fi
    fi

	### Frontend
    FRONT_FILE="$HAPROXY_CFG_DIR"/conf.d/$((index + FILE_PREFIX))-"$id"

    IFS=',' read -ra HOSTS <<< "$hosts"
    host_index=0
    condition=""
    for host in "${HOSTS[@]}"; do
        host_index=$((host_index + 1))

        negate=""
        if [[ ${host:0:1} == "!" ]] ; then
            host=${host:1}
            negate="!"
        fi
        condition="${condition} ${negate}${id}_${host_index}"

        echo "" >> "$FRONT_FILE"
        if [[ ${host:0:1} == "/" ]] ; then
            echo -n "$ACL_PATH" >> "$FRONT_FILE"
        else
            echo -n "$ACL_HOST" >> "$FRONT_FILE"
        fi

        sed -i "s~%id%~"$id"_"$host_index"~g;s~%host%~$host~g" "$FRONT_FILE"
    done
    echo -e "" >> "$FRONT_FILE"

    if [[ ${id:0:8} == "$REDIRECT_PREFIX" ]] ; then
        echo "$REDIRECT" >> "$FRONT_FILE"

        sed -i "s~%id%~"$id"_1~g;s~%location%~$location~g;s~%code%~$code~g;s~%scheme%~$scheme~g" "$FRONT_FILE" // _1 костыль

        continue
    else
        echo "$USE_BACKEND" >> "$FRONT_FILE"
        sed -i "s~%id%~$ENV_PREFIX$id~g;s~%condition%~$condition~g" "$FRONT_FILE"
    fi

	### Backend
    BACK_FILE="$HAPROXY_CFG_DIR"/conf.d/$((index + 5000))-"$id"

    echo -n "$BACKEND_START" > "$BACK_FILE"
    if [[ "$service" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "" >> "$BACK_FILE"
    else
        echo "$BACKEND_RESOLVER" >> "$BACK_FILE"
    fi
    echo "$BACKEND_HEADER_FORWARDED" >> "$BACK_FILE"

    sed -i "s~%id%~$ENV_PREFIX$id~g;s~%service%~$service~g" "$BACK_FILE"
}

index=0
handle_http () {
	ENV_PREFIX=$1
	FILE_PREFIX=$2
	REDIRECT_PREFIX=$3

	for i in `env | sort | grep "^$ENV_PREFIX"`; do
		index=$((index + 1))

        handle_host ${ENV_PREFIX} ${FILE_PREFIX} ${REDIRECT_PREFIX} ${index} &
	done

	wait
}

if env | fgrep HTTP_ > /dev/null; then
    handle_http HTTP_ 3000 REDIRECT
fi

if env | fgrep HTTPS_ > /dev/null; then
    echo "${FRONTEND_HTTPS}" > ${HAPROXY_CFG_DIR}/conf.d/400-frontend_https
    handle_http HTTPS_ 4000 REDIRECT
fi

if [ "$REDIRECT_ALL_TO_HTTPS" == "true" ]; then
    echo "${REDIRECT_ALL_TO_HTTPS_FRONTEND}" > "${HAPROXY_CFG_DIR}"/conf.d/3999-https_redirect
    echo "${REDIRECT_ALL_TO_HTTPS_BACKEND}" > "${HAPROXY_CFG_DIR}"/conf.d/5999-https_redirect
fi

cat "$HAPROXY_CFG_DIR"/conf.d/* > "$HAPROXY_CFG_DIR"/haproxy.cfg

cat "$HAPROXY_CFG_DIR"/haproxy.cfg
exec /docker-entrypoint.sh "$@"
