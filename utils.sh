#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="revanced-extended-magisk"
MODULE_SCRIPTS_DIR="scripts"
TEMP_DIR="temp"
BUILD_DIR="build"
PKGS_LIST="${TEMP_DIR}/module-pkgs"

if [ "${GITHUB_TOKEN+x}" ]; then
	GH_AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
else
	GH_AUTH_HEADER=""
fi

GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-"MatadorProBr/revanced-extended-magisk-module"}
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
DRYRUN=false

SERVICE_SH=$(cat $MODULE_SCRIPTS_DIR/service.sh)
CUSTOMIZE_SH=$(cat $MODULE_SCRIPTS_DIR/customize.sh)
UNINSTALL_SH=$(cat $MODULE_SCRIPTS_DIR/uninstall.sh)

# -------------------- json/toml --------------------
json_get() { grep -o "\"${1}\":[^\"]*\"[^\"]*\"" | sed -E 's/".*".*"(.*)"/\1/'; }
toml_prep() { __TOML__=$(echo "$1" | tr -d '\t\r' | tr "'" '"' | grep -o '^[^#]*' | grep -v '^$' | sed -r 's/(\".*\")|\s*/\1/g; 1i []'); }
toml_get_table_names() {
	local tn
	tn=$(echo "$__TOML__" | grep -x '\[.*\]' | tr -d '[]') || return 1
	if [ "$(echo "$tn" | sort | uniq -u | wc -l)" != "$(echo "$tn" | wc -l)" ]; then
		echo >&2 "ERROR: Duplicate tables in TOML"
		return 1
	fi
	echo "$tn"
}
toml_get_table() { sed -n "/\[${1}]/,/^\[.*]$/p" <<<"$__TOML__"; }
toml_get() {
	local table=$1 key=$2 val
	val=$(grep -m 1 "^${key}=" <<<"$table") && echo "${val#*=}" | sed -e "s/^\"//; s/\"$//"
}
# ---------------------------------------------------

get_prebuilts() {
	echo "Getting prebuilts"
	RVX_CLI_URL=$(gh_req https://api.github.com/repos/inotia00/revanced-cli/releases/latest - | json_get 'browser_download_url')
	RVX_CLI_JAR="${TEMP_DIR}/${RVX_CLI_URL##*/}"
	log "CLI: ${RVX_CLI_URL##*/}"

	RVX_INTEGRATIONS_URL=$(gh_req https://api.github.com/repos/inotia00/revanced-integrations/releases/latest - | json_get 'browser_download_url')
	RVX_INTEGRATIONS_APK=${RVX_INTEGRATIONS_URL##*/}
	log "Integrations: $RVX_INTEGRATIONS_APK"
	RVX_INTEGRATIONS_APK="${TEMP_DIR}/${RVX_INTEGRATIONS_APK}"

	RVX_PATCHES=$(gh_req https://api.github.com/repos/inotia00/revanced-patches/releases/latest -)
	RVX_PATCHES_CHANGELOG=$(echo "$RVX_PATCHES" | json_get 'body' | sed 's/\(\\n\)\+/\\n/g')
	RVX_PATCHES_URL=$(echo "$RVX_PATCHES" | json_get 'browser_download_url' | grep 'jar')
	RVX_PATCHES_JAR="${TEMP_DIR}/${RVX_PATCHES_URL##*/}"
	log "Patches: ${RVX_PATCHES_URL##*/}"
	log "\n${RVX_PATCHES_CHANGELOG//# [/### [}\n"

	dl_if_dne "$RVX_CLI_JAR" "$RVX_CLI_URL"
	dl_if_dne "$RVX_INTEGRATIONS_APK" "$RVX_INTEGRATIONS_URL"
	dl_if_dne "$RVX_PATCHES_JAR" "$RVX_PATCHES_URL"
}

get_cmpr() {
	mkdir -p revanced-extended-magisk/bin/arm64 revanced-extended-magisk/bin/arm
	dl_if_dne "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
	dl_if_dne "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
}

abort() { echo "abort: $1" && exit 1; }

set_prebuilts() {
	[ -d "$TEMP_DIR" ] || abort "${TEMP_DIR} directory could not be found"
	RVX_CLI_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-cli-*.jar" | tail -n1)
	[ "$RVX_CLI_JAR" ] || abort "ReVanced CLI not found"
	log "CLI: ${RVX_CLI_JAR#"$TEMP_DIR/"}"
	RVX_INTEGRATIONS_APK=$(find "$TEMP_DIR" -maxdepth 1 -name "app-release-unsigned-*.apk" | tail -n1)
	[ "$RVX_INTEGRATIONS_APK" ] || abort "ReVanced Integrations not found"
	log "Integrations: ${RVX_INTEGRATIONS_APK#"$TEMP_DIR/"}"
	RVX_PATCHES_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-patches-*.jar" | tail -n1)
	[ "$RVX_PATCHES_JAR" ] || abort "ReVanced Patches not found"
	log "Patches: ${RVX_PATCHES_JAR#"$TEMP_DIR/"}"
}

req() { wget -nv -O "$2" --header="$WGET_HEADER" "$1"; }
gh_req() { wget -nv -O "$2" --header="$GH_AUTH_HEADER" "$1"; }
log() { echo -e "$1  " >>build.md; }
get_largest_ver() {
	read -r max
	while read -r v; do
		if ! semver_validate "$max" "$v"; then continue; fi
		if [ "$(semver_cmp "$max" "$v")" = 1 ]; then max=$v; fi
	done
	echo "$max"
}
get_patch_last_supported_ver() {
	local vs
	vs=$(unzip -p "$RVX_PATCHES_JAR" | strings -s , | sed -rn "s/.*${1},versions,(([0-9.]*,*)*),Lk.*/\1/p" | tr ',' '\n')
	printf "%s\n" "$vs" | get_largest_ver
}
semver_cmp() {
	IFS=. read -r -a v1 <<<"${1//[^.0-9]/}"
	IFS=. read -r -a v2 <<<"${2//[^.0-9]/}"
	local c1="${1//[^.]/}"
	local c2="${2//[^.]/}"
	local mi=$((${#c1} < ${#c2} ? ${#c1} : ${#c2}))
	for ((i = 0; i <= mi; i++)); do
		if ((v1[i] > v2[i])); then
			echo -1
			return 0
		elif ((v2[i] > v1[i])); then
			echo 1
			return 0
		fi
	done
	echo 0
}
semver_validate() {
	local a1="${1%-*}" a2="${2%-*}"
	local a1c="${a1//[.0-9]/}" a2c="${a2//[.0-9]/}"
	[ ${#a1c} = 0 ] && [ ${#a2c} = 0 ]
}

dl_if_dne() {
	if [ ! -f "$1" ]; then
		echo -e "\nGetting '$1' from '$2'"
		req "$2" "$1"
	fi
}

# -------------------- APKMirror --------------------
dl_apkmirror() {
	local url=$1 version=$2 regexp=$3 output=$4
	if [ $DRYRUN = true ]; then
		echo "#" >"$output"
		return
	fi
	local resp
	url="${url}/${url##*/}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	url="https://www.apkmirror.com$(echo "$resp" | tr '\n' ' ' | sed -n "s/href=\"/@/g; s;.*${regexp}.*;\1;p")"
	[ "$url" != https://www.apkmirror.com ] || return 1
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	req "$url" "$output"
}
get_apkmirror_vers() {
	local apkmirror_category=$1 allow_alpha_version=$2
	local vers
	# apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${apkmirror_category}" -)
	# apkm_name=$(echo "$apkm_resp" | sed -n 's;.*Latest \(.*\) Uploads.*;\1;p')
	vers=$(req "https://www.apkmirror.com/uploads/?appcategory=${apkmirror_category}" - | sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p')
	if [ "$allow_alpha_version" = false ]; then grep -i -v -e "beta" -e "alpha" <<<"$vers"; else echo "$vers"; fi
}
get_apkmirror_pkg_name() { req "$1" - | sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p'; }
# --------------------------------------------------

# -------------------- Uptodown --------------------
get_uptodown_resp() { req "${1}/versions" -; }
get_uptodown_vers() { echo "$1" | grep -x '^[0-9.]* <span>.*</span>' | sed 's/ <s.*//'; }
dl_uptodown() {
	local uptwod_resp=$1 version=$2 output=$3
	url=$(echo "$uptwod_resp" | grep "${version} <span>" -B 1 | head -1 | sed -n 's;.*data-url="\(.*\)".*;\1;p')
	url=$(req "$url" - | sed -n 's;.*data-url="\(.*\)".*;\1;p')
	req "$url" "$output"
}
get_uptodown_pkg_name() {
	local p
	p=$(req "${1}/download" - | grep -A 1 "Package Name" | tail -1)
	echo "${p:4:-5}"
}
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3
	declare -r tdir=$(mktemp -d -p $TEMP_DIR)
	local cmd="java -jar $RVX_CLI_JAR --rip-lib x86_64 --rip-lib x86 --temp-dir=$tdir -c -a $stock_input -o $patched_apk -b $RVX_PATCHES_JAR --keystore=ks.keystore $patcher_args"
	echo "$cmd"
	if [ $DRYRUN = true ]; then
		cp -f "$stock_input" "$patched_apk"
	else
		eval "$cmd"
	fi
}

zip_module() {
	local patched_apk=$1 module_name=$2 stock_apk=$3 pkg_name=$4 template_dir=$5
	cp -f "$patched_apk" "${template_dir}/base.apk"
	cp -f "$stock_apk" "${template_dir}/${pkg_name}.apk"
	pushd "$template_dir" || abort "Module template dir not found"
	zip -"$COMPRESSION_LEVEL" -FSr "../../${BUILD_DIR}/${module_name}" .
	popd || :
}

build_rvx() {
	local -n args=$1
	local version patcher_args build_mode_arr pkg_name uptwod_resp
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name_l=${args[app_name],,}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	else
		echo "ERROR: undefined build mode for '${args[app_name]}': '${mode_arg}'"
		echo "    only 'both', 'apk' or 'module' are allowed"
		return 1
	fi

	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args="${args[patcher_args]}"
		echo -n "Building '${args[app_name]}' (${arch}) in "
		if [ "$build_mode" = module ]; then echo "'module' mode"; else echo "'APK' mode"; fi
		if [ "${args[microg_patch]}" ]; then
			if [ "$build_mode" = module ]; then
				patcher_args="$patcher_args -e ${args[microg_patch]}"
			elif [[ "${args[patcher_args]}" = *"${args[microg_patch]}"* ]]; then
				abort "UNREACHABLE $LINENO"
			fi
		fi
		if [ "$dl_from" = apkmirror ]; then
			pkg_name=$(get_apkmirror_pkg_name "${args[apkmirror_dlurl]}")
		elif [ "$dl_from" = uptodown ]; then
			uptwod_resp=$(get_uptodown_resp "${args[uptodown_dlurl]}")
			pkg_name=$(get_uptodown_pkg_name "${args[uptodown_dlurl]}")
		fi

		local get_latest_ver=false
		if [ "$version_mode" = auto ]; then
			version=$(get_patch_last_supported_ver "$pkg_name")
			if [ -z "$version" ]; then get_latest_ver=true; fi
		elif [ "$version_mode" = latest ]; then
			get_latest_ver=true
		else
			version=$version_mode
			patcher_args="$patcher_args --experimental"
		fi
		if [ "$build_mode" = module ]; then
			# --unsigned and --rip-lib is only available in my revanced-cli builds
			patcher_args="$patcher_args --unsigned --rip-lib arm64-v8a --rip-lib armeabi-v7a"
		fi
		if [ $get_latest_ver = true ]; then
			local apkmvers uptwodvers
			if [ "$dl_from" = apkmirror ]; then
				apkmvers=$(get_apkmirror_vers "${args[apkmirror_dlurl]##*/}" "${args[allow_alpha_version]}")
				version=$(echo "$apkmvers" | get_largest_ver)
				[ "$version" ] || version=$(echo "$apkmvers" | head -1)
			elif [ "$dl_from" = uptodown ]; then
				uptwodvers=$(get_uptodown_vers "$uptwod_resp")
				version=$(echo "$uptwodvers" | get_largest_ver)
				[ "$version" ] || version=$(echo "$uptwodvers" | head -1)
			fi
		fi
		if [ -z "$version" ]; then
			echo "ERROR: empty version"
			return 1
		fi
		echo "Choosing version '${version}' (${args[app_name]})"

		local stock_apk="${TEMP_DIR}/${pkg_name}-stock-${version}-${arch}.apk"
		local apk_output="${BUILD_DIR}/${app_name_l}-revanced-extended-v${version}-${arch}.apk"
		if [ "${args[microg_patch]}" ]; then
			local patched_apk="${TEMP_DIR}/${app_name_l}-revanced-extended-${version}-${arch}-${build_mode}.apk"
		else
			local patched_apk="${TEMP_DIR}/${app_name_l}-revanced-extended-${version}-${arch}.apk"
		fi
		if [ ! -f "$stock_apk" ]; then
			if [ "$dl_from" = apkmirror ]; then
				echo "Downloading '${args[app_name]}' from APKMirror"
				if ! dl_apkmirror "${args[apkmirror_dlurl]}" "$version" "${args[apkmirror_regex]}" "$stock_apk"; then
					echo "ERROR: Could not find any release of '${args[app_name]}' with the given version ('${version}') and regex"
					return 1
				fi
			elif [ "$dl_from" = uptodown ]; then
				echo "Downloading '${args[app_name]}' from Uptodown"
				if ! dl_uptodown "$uptwod_resp" "$version" "$stock_apk"; then
					echo "ERROR: Could not download ${args[app_name]}"
					return 1
				fi
			else
				abort "UNREACHABLE $LINENO"
			fi
		fi

		if [ "${arch}" = "all" ]; then
			! grep -q "${args[app_name]}:" build.md && log "${args[app_name]}: ${version}"
		else
			! grep -q "${args[app_name]} (${arch}):" build.md && log "${args[app_name]} (${arch}): ${version}"
		fi

		if [ ! -f "$patched_apk" ]; then patch_apk "$stock_apk" "$patched_apk" "$patcher_args"; fi
		if [ ! -f "$patched_apk" ]; then
			echo "BUILDING '${args[app_name]}' FAILED"
			return
		fi
		if [ "$build_mode" = apk ]; then
			cp -f "$patched_apk" "$apk_output"
			echo "Built ${args[app_name]} (${arch}) (non-root): '${apk_output}'"
			continue
		fi
		if [ "$BUILD_MINDETACH_MODULE" = true ] && ! grep -q "$pkg_name" $PKGS_LIST; then echo "$pkg_name" >>$PKGS_LIST; fi

		declare -r base_template=$(mktemp -d -p $TEMP_DIR)
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"

		uninstall_sh "$pkg_name" "$base_template"
		service_sh "$pkg_name" "$version" "$base_template"
		customize_sh "$pkg_name" "$version" "$base_template"

		local upj
		upj=$([ "${arch}" = "all" ] && echo "${app_name_l}-update.json" || echo "${app_name_l}-${arch}-update.json")
		module_prop "${args[module_prop_name]}" \
			"${args[app_name]} ReVanced Extended" \
			"$version" \
			"${args[app_name]} ReVanced Extended Magisk module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-revanced-extended-magisk-v${version}-${arch}.zip"
		zip_module "$patched_apk" "$module_output" "$stock_apk" "$pkg_name" "$base_template"

		echo "Built ${args[app_name]} (${arch}) (root): '${BUILD_DIR}/${module_output}'"
	done
}

join_args() {
	echo "$1" | tr -d '\t\r' | tr ' ' '\n' | grep -v '^$' | sed "s/^/${2} /" | paste -sd " " - || :
}

uninstall_sh() { echo "${UNINSTALL_SH//__PKGNAME/$1}" >"${2}/uninstall.sh"; }
customize_sh() {
	local s="${CUSTOMIZE_SH//__PKGNAME/$1}"
	echo "${s//__PKGVER/$2}" >"${3}/customize.sh"
}
service_sh() {
	local s="${SERVICE_SH//__PKGNAME/$1}"
	echo "${s//__PKGVER/$2}" >"${3}/service.sh"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc & MatadorProBr
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MAGISK_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
