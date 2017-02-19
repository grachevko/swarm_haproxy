#!/bin/bash

ACL_HOST="	acl %id% hdr(host) -i %host%"
ACL_PATH="	acl %id% path_beg -i %host%"
USE_BACKEND="	use_backend %id%_backend if %condition%"

REDIRECT="	http-request redirect code %code% scheme %scheme% location %location% if %id%"

BACKEND_START="backend %id%_backend
	mode http
	server %id%_server %service%"
BACKEND_RESOLVER=" resolvers dns check inter 1000"
BACKEND_HEADER_FORWARDED="	http-request add-header X-Forwarded-Proto https if { ssl_fc }
	http-request set-header X-Forwarded-Port %[dst_port] if { ssl_fc }"

handle_http () {
	ENV_PREFIX=$1
	FILE_PREFIX=$2
	REDIRECT_PREFIX=$3

	index=0
	for i in `env | fgrep "$ENV_PREFIX"`; do
		((index++))

		IFS='=' read id options <<< "$i"
		id=${id:${#ENV_PREFIX}}

		if [[ ${id:0:8} == "$REDIRECT_PREFIX" ]] ; then
			IFS=';' read hosts location code scheme <<< "$options"
		else
			IFS=';' read hosts service <<< "$options"

			if ! ping -c 1 "$service" &> /dev/null
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
            ((host_index++))

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

			sed -i "s~%id%~"$id"_"$host_index"~g" "$FRONT_FILE"
			sed -i "s~%host%~$host~g" "$FRONT_FILE"
		done
		echo -e "" >> "$FRONT_FILE"

		if [[ ${id:0:8} == "$REDIRECT_PREFIX" ]] ; then
			echo "$REDIRECT" >> "$FRONT_FILE"

			sed -i "s~%id%~"$id"_1~g" "$FRONT_FILE" // _1 костыль
			sed -i "s~%location%~$location~g" "$FRONT_FILE"
			sed -i "s~%code%~$code~g" "$FRONT_FILE"
			sed -i "s~%scheme%~$scheme~g" "$FRONT_FILE"

			continue
		else
			echo "$USE_BACKEND" >> "$FRONT_FILE"
			sed -i "s~%id%~$id~g" "$FRONT_FILE"
			sed -i "s~%condition%~$condition~g" "$FRONT_FILE"
		fi

	### Backend
		BACK_FILE="$HAPROXY_CFG_DIR"/conf.d/$((index + 500))-"$id"

		echo -n "$BACKEND_START" > "$BACK_FILE"
		if [[ "$service" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
			echo "" >> "$BACK_FILE"
		else
			echo "$BACKEND_RESOLVER" >> "$BACK_FILE"
		fi
		echo "$BACKEND_HEADER_FORWARDED" >> "$BACK_FILE"

		sed -i "s~%id%~$id~g" "$BACK_FILE"
		sed -i "s~%service%~$service~g" "$BACK_FILE"
	done
}

handle_http HTTP_ 300 REDIRECT
handle_http HTTPS_ 400 REDIRECT

cat "$HAPROXY_CFG_DIR"/conf.d/* > "$HAPROXY_CFG_DIR"/haproxy.cfg

cat "$HAPROXY_CFG_DIR"/haproxy.cfg
exec /docker-entrypoint.sh "$@"
