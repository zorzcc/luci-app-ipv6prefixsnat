#!/bin/sh

. /usr/share/libubox/jshn.sh

RULE_DIR="/usr/share/nftables.d/ruleset-post"
RULE_FILE="${RULE_DIR}/90-ipv6prefixsnat.nft"
TABLE_NAME="ipv6prefixsnat_nat"

STATE_DIR="/var/run/ipv6prefixsnat"
CORE_LOCK_DIR="${STATE_DIR}/core.lock"
CORE_LOCK_PID_FILE="${CORE_LOCK_DIR}/pid"
APPLIED_META_FILE="${STATE_DIR}/applied_ifaces"

log() {
	logger -t ipv6prefixsnat "$*"
}

normalize_bool() {
	case "$1" in
		1|true|TRUE|yes|on|enabled) echo 1 ;;
		*) echo 0 ;;
	esac
}

ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null
}

acquire_core_lock() {
	local i=0 pid

	ensure_state_dir || return 1

	while :; do
		if mkdir "$CORE_LOCK_DIR" 2>/dev/null; then
			printf '%s\n' "$$" > "$CORE_LOCK_PID_FILE"
			return 0
		fi

		pid=""
		[ -f "$CORE_LOCK_PID_FILE" ] && pid="$(cat "$CORE_LOCK_PID_FILE" 2>/dev/null)"

		if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$CORE_LOCK_PID_FILE" 2>/dev/null
			rmdir "$CORE_LOCK_DIR" 2>/dev/null && continue
		fi

		i=$((i + 1))
		[ "$i" -ge 20 ] && return 1
		sleep 1
	done
}

release_core_lock() {
	rm -f "$CORE_LOCK_PID_FILE" 2>/dev/null
	rmdir "$CORE_LOCK_DIR" 2>/dev/null
}

run_with_lock() {
	local rc

	acquire_core_lock || {
		log "failed to acquire core lock"
		return 22
	}

	trap 'release_core_lock' EXIT INT TERM

	"$@"
	rc=$?

	trap - EXIT INT TERM
	release_core_lock

	return "$rc"
}

ensure_config() {
	uci -q show ipv6prefixsnat.config >/dev/null 2>&1 || {
		uci -q set ipv6prefixsnat.config=ipv6prefixsnat
		uci -q set ipv6prefixsnat.config.enabled='0'
		uci commit ipv6prefixsnat
	}
}

load_state() {
	local raw_enabled

	ensure_config

	raw_enabled="$(uci -q get ipv6prefixsnat.config.enabled)"

	if [ "${OVERRIDE_ENABLED_PRESENT:-0}" = "1" ]; then
		enabled="$OVERRIDE_ENABLED"
	else
		enabled="$raw_enabled"
	fi

	auto_includes="$(uci -q get firewall.@defaults[0].auto_includes)"

	[ -n "$enabled" ] || enabled="0"
	[ -n "$auto_includes" ] || auto_includes="1"

	rule_file_exists=0
	[ -f "$RULE_FILE" ] && rule_file_exists=1

	nft_table_present=0
	nft list table ip6 "$TABLE_NAME" >/dev/null 2>&1 && nft_table_present=1
}

prefix_is_eligible() {
	local addr lc

	addr="${1%%/*}"
	lc="$(printf '%s' "$addr" | tr 'A-F' 'a-f')"

	case "$lc" in
		""|::|::1|0:0:0:0:0:0:0:0|0:0:0:0:0:0:0:1|::ffff:*)
			return 1
			;;
		fe8*|fe9*|fea*|feb*)   # link-local fe80::/10
			return 1
			;;
		fec*|fed*|fee*|fef*)   # deprecated site-local fec0::/10
			return 1
			;;
		fc*|fd*)               # ULA fc00::/7
			return 1
			;;
		ff*)                   # multicast ff00::/8
			return 1
			;;
		*)
			return 0
			;;
	esac
}

get_first_assigned_prefix_from_selected_iface() {
	local pfx_keys pfx_idx assigned_keys assigned_key addr mask pfx selected

	selected=""

	json_select "ipv6-prefix" 2>/dev/null || return 1
	json_get_keys pfx_keys

	for pfx_idx in $pfx_keys; do
		json_select "$pfx_idx" 2>/dev/null || continue

		if json_select "assigned" 2>/dev/null; then
			json_get_keys assigned_keys
			for assigned_key in $assigned_keys; do
				addr=""
				mask=""

				json_select "$assigned_key" 2>/dev/null || continue

				json_get_var addr address
				json_get_var mask mask
				json_select ".."

				[ -n "$addr" ] || continue
				[ -n "$mask" ] || mask="64"

				pfx="${addr}/${mask}"
				prefix_is_eligible "$pfx" || continue

				selected="$pfx"
				break
			done

			json_select ".."
		fi

		json_select ".."

		[ -n "$selected" ] && break
	done

	json_select ".."

	[ -n "$selected" ] || return 1
	printf '%s\n' "$selected"
	return 0
}

collect_runtime_rows() {
	local dump ifaces idx iface up dev pfx key

	runtime_rows=""
	runtime_count=0
	runtime_seen=""

	dump="$(ubus call network.interface dump 2>/dev/null)"
	[ -n "$dump" ] || return 0

	json_cleanup >/dev/null 2>&1 || true
	json_load "$dump" 2>/dev/null || return 1

	json_select "interface" 2>/dev/null || {
		json_cleanup >/dev/null 2>&1 || true
		return 0
	}

	json_get_keys ifaces
	for idx in $ifaces; do
		iface=""
		up=""
		dev=""
		pfx=""

		json_select "$idx" 2>/dev/null || continue

		json_get_var iface interface
		if [ "$iface" = "loopback" ]; then
			json_select ".."
			continue
		fi

		json_get_var up up
		if [ "$(normalize_bool "$up")" != "1" ]; then
			json_select ".."
			continue
		fi

		json_get_var dev l3_device
		[ -n "$dev" ] || json_get_var dev device
		if [ -z "$dev" ]; then
			json_select ".."
			continue
		fi

		pfx="$(get_first_assigned_prefix_from_selected_iface)"
		if [ -z "$pfx" ]; then
			json_select ".."
			continue
		fi

		key="$dev"
		case "
$runtime_seen
" in
			*"
$key
"*)
				json_select ".."
				continue
				;;
		esac

		runtime_seen="${runtime_seen}${runtime_seen:+
}${key}"

		runtime_rows="${runtime_rows}${runtime_rows:+
}${iface}|${dev}|${pfx}"
		runtime_count=$((runtime_count + 1))

		json_select ".."
	done

	json_cleanup >/dev/null 2>&1 || true
}

json_add_ifaces_from_rows() {
	local rows="$1"
	local row old_ifs iface dev pfx

	json_add_array interfaces

	[ -n "$rows" ] || {
		json_close_array
		return 0
	}

	old_ifs="$IFS"
	IFS='
'

	for row in $rows; do
		[ -n "$row" ] || continue

		IFS='|'
		set -- $row
		iface="$1"
		dev="$2"
		pfx="$3"
		IFS='
'

		json_add_object ""
		json_add_string interface "$iface"
		json_add_string device "$dev"
		json_add_string prefix "$pfx"
		json_close_object
	done

	IFS="$old_ifs"
	json_close_array
}

build_preview() {
	local row row2 old_ifs
	local cur_iface cur_dev cur_pfx
	local other_iface other_pfx
	local map_entries rule valid_rules seen_other_pfx

	preview_ready=0
	preview_reason_code=""
	combined_rule_preview=""

	collect_runtime_rows

	if [ "$(normalize_bool "$auto_includes")" != "1" ]; then
		preview_reason_code="FW4_AUTO_INCLUDES_DISABLED"
		return 0
	fi

	if [ "$runtime_count" -lt 2 ]; then
		preview_reason_code="NEED_AT_LEAST_2_ACTIVE_IPV6_INTERFACES"
		return 0
	fi

	valid_rules=0
	old_ifs="$IFS"
	IFS='
'

	for row in $runtime_rows; do
		IFS='|'
		set -- $row
		cur_iface="$1"
		cur_dev="$2"
		cur_pfx="$3"
		IFS='
'

		map_entries=""
		seen_other_pfx=""

		for row2 in $runtime_rows; do
			IFS='|'
			set -- $row2
			other_iface="$1"
			other_pfx="$3"
			IFS='
'

			[ "$other_iface" = "$cur_iface" ] && continue
			[ -n "$other_pfx" ] || continue
			[ "$other_pfx" = "$cur_pfx" ] && continue

			case "
$seen_other_pfx
" in
				*"
$other_pfx
"*)
					continue
					;;
			esac

			seen_other_pfx="${seen_other_pfx}${seen_other_pfx:+
}${other_pfx}"
			map_entries="${map_entries}${map_entries:+, }${other_pfx} : ${cur_pfx}"
		done

		[ -n "$map_entries" ] || continue

		rule="oifname \"${cur_dev}\" ip6 saddr != ${cur_pfx} snat ip6 prefix to ip6 saddr map { ${map_entries} }"

		combined_rule_preview="${combined_rule_preview}${combined_rule_preview:+
}${rule}"

		valid_rules=$((valid_rules + 1))
	done

	IFS="$old_ifs"

	if [ "$valid_rules" -eq 0 ]; then
		preview_reason_code="NO_VALID_RULES_GENERATED"
		return 0
	fi

	preview_ready=1
	return 0
}

save_applied_meta() {
	ensure_state_dir || return 1
	printf '%s\n' "$runtime_rows" > "$APPLIED_META_FILE" || return 1
	chmod 0644 "$APPLIED_META_FILE" >/dev/null 2>&1 || true
	return 0
}

load_applied_meta() {
	applied_rows=""
	[ -f "$APPLIED_META_FILE" ] || return 0
	applied_rows="$(cat "$APPLIED_META_FILE" 2>/dev/null)"
	return 0
}

clear_applied_meta() {
	rm -f "$APPLIED_META_FILE" 2>/dev/null
}

delete_runtime_table() {
	nft delete table ip6 "$TABLE_NAME" >/dev/null 2>&1
}

remove_rule_file() {
	rm -f "$RULE_FILE"
}

backup_rule_file() {
	rule_file_backup=""

	[ -f "$RULE_FILE" ] || return 0

	rule_file_backup="${RULE_FILE}.bak.$$"
	cp -fp "$RULE_FILE" "$rule_file_backup" || {
		rule_file_backup=""
		return 1
	}

	return 0
}

restore_rule_file_backup() {
	if [ -n "$rule_file_backup" ] && [ -f "$rule_file_backup" ]; then
		mv "$rule_file_backup" "$RULE_FILE" || return 1
	else
		rm -f "$RULE_FILE"
	fi
}

discard_rule_file_backup() {
	[ -n "$rule_file_backup" ] && rm -f "$rule_file_backup" 2>/dev/null
	rule_file_backup=""
}

cleanup_rules() {
	remove_rule_file
	delete_runtime_table
	clear_applied_meta
}

write_rule_file() {
	local tmp_file rules_body

	mkdir -p "$RULE_DIR" || return 1
	tmp_file="${RULE_FILE}.tmp.$$"

	rules_body="$(printf '%s\n' "$combined_rule_preview" | sed 's/^/\t\t/')"

	cat > "$tmp_file" <<EOF2
table ip6 ${TABLE_NAME} {
	chain srcnat {
		type nat hook postrouting priority srcnat; policy accept;
${rules_body}
	}
}
EOF2

	if ! nft -c -f "$tmp_file" >/dev/null 2>&1; then
		rm -f "$tmp_file"
		log "rule validation failed: $tmp_file"
		return 1
	fi

	chmod 0644 "$tmp_file" || {
		rm -f "$tmp_file"
		return 1
	}

	mv "$tmp_file" "$RULE_FILE" || {
		rm -f "$tmp_file"
		return 1
	}

	return 0
}

fw_reload() {
	fw4 reload >/dev/null 2>&1
}

has_residual_rules() {
	[ "$rule_file_exists" = "1" ] || [ "$nft_table_present" = "1" ]
}

apply_rules() {
	load_state
	build_preview

	if [ "$(normalize_bool "$enabled")" != "1" ]; then
		if ! has_residual_rules; then
			clear_applied_meta
			log "disabled, no residual rules; skipped fw4 reload"
			return 0
		fi

		cleanup_rules
		fw_reload || return 11
		log "disabled, rules removed"
		return 0
	fi

	if [ "$preview_ready" != "1" ]; then
		if ! has_residual_rules; then
			clear_applied_meta
			log "cannot apply: reason_code=$preview_reason_code; no residual rules, skipped fw4 reload"

			case "$preview_reason_code" in
				"FW4_AUTO_INCLUDES_DISABLED") return 20 ;;
				*) return 13 ;;
			esac
		fi

		cleanup_rules
		fw_reload || return 12
		log "cannot apply: reason_code=$preview_reason_code; old rules removed"

		case "$preview_reason_code" in
			"FW4_AUTO_INCLUDES_DISABLED") return 20 ;;
			*) return 13 ;;
		esac
	fi

	backup_rule_file || return 18

	write_rule_file || {
		discard_rule_file_backup
		return 18
	}

	delete_runtime_table
	if ! fw_reload; then
		restore_rule_file_backup || true
		fw_reload >/dev/null 2>&1 || true
		return 19
	fi

	save_applied_meta || log "failed to save applied interface metadata"
	discard_rule_file_backup

	log "rules rebuilt, iface_count=$runtime_count"
	return 0
}

disable_rules() {
	load_state

	if ! has_residual_rules; then
		clear_applied_meta
		log "rules already absent; skipped fw4 reload"
		return 0
	fi

	cleanup_rules
	fw_reload || return 21
	log "rules disabled"
	return 0
}

set_config_and_disable_rules() {
	ensure_config

	uci -q set ipv6prefixsnat.config.enabled='0' || return 23
	uci commit ipv6prefixsnat || return 24

	disable_rules
}

status_json() {
	load_state
	build_preview

	json_init
	json_add_boolean ok 1
	json_add_string code "STATUS_READ"
	json_add_string reason_code "$preview_reason_code"
	json_add_boolean enabled "$(normalize_bool "$enabled")"
	json_add_boolean rule_file_exists "$rule_file_exists"
	json_add_boolean nft_table_present "$(normalize_bool "$nft_table_present")"
	json_add_boolean auto_includes "$(normalize_bool "$auto_includes")"
	json_add_boolean ready "$(normalize_bool "$preview_ready")"
	json_add_int iface_count "$runtime_count"
	json_add_string rule_file "$RULE_FILE"
	json_add_ifaces_from_rows "$runtime_rows"
	json_dump
}

test_runtime_json() {
	load_state
	build_preview

	json_init
	json_add_boolean ok 1
	json_add_string code "RUNTIME_TESTED"
	json_add_string reason_code "$preview_reason_code"
	json_add_boolean enabled "$(normalize_bool "$enabled")"
	json_add_boolean auto_includes "$(normalize_bool "$auto_includes")"
	json_add_boolean ready "$(normalize_bool "$preview_ready")"
	json_add_int iface_count "$runtime_count"
	json_add_string rule_preview "$combined_rule_preview"
	json_add_string rule_file "$RULE_FILE"
	json_add_ifaces_from_rows "$runtime_rows"
	json_dump
}

current_rules_json() {
	local rules source

	load_state
	load_applied_meta

	rules=""
	source="none"

	if nft list table ip6 "$TABLE_NAME" >/dev/null 2>&1; then
		rules="$(nft list table ip6 "$TABLE_NAME" 2>/dev/null)"
		source="nft_runtime"
	elif [ -f "$RULE_FILE" ]; then
		rules="$(cat "$RULE_FILE" 2>/dev/null)"
		source="rule_file"
	fi

	json_init
	json_add_boolean ok 1
	json_add_string code "CURRENT_RULES_READ"
	json_add_string reason_code ""
	json_add_boolean nft_table_present "$(normalize_bool "$nft_table_present")"
	json_add_boolean rule_file_exists "$(normalize_bool "$rule_file_exists")"
	json_add_string source "$source"
	json_add_string rules "$rules"
	json_add_string rule_file "$RULE_FILE"
	json_add_ifaces_from_rows "$applied_rows"
	json_dump
}

case "$1" in
	reload|start|restart|"")
		run_with_lock apply_rules
		;;
	disable|stop)
		run_with_lock set_config_and_disable_rules
		;;
	status_json)
		status_json
		;;
	test_runtime_json)
		test_runtime_json
		;;
	current_rules_json)
		current_rules_json
		;;
	status)
		load_state
		build_preview
		echo "enabled=$enabled"
		echo "rule_file_exists=$rule_file_exists"
		echo "nft_table_present=$nft_table_present"
		echo "auto_includes=$auto_includes"
		echo "preview_ready=$preview_ready"
		echo "preview_reason_code=$preview_reason_code"
		echo "iface_count=$runtime_count"
		echo "rule_preview=$combined_rule_preview"
		;;
	*)
		echo "Usage: $0 {reload|disable|status|status_json|test_runtime_json|current_rules_json}"
		exit 1
		;;
esac
