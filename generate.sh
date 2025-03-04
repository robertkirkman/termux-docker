#!/usr/bin/env bash

set -e

cd "$(dirname "$(realpath "$0")")"

OCI="docker"
OCI_ARG="build"
case $1 in
	-p|--podman) OCI="podman" ; OCI_ARG+=" --format docker" ;;
esac

if [ -n "${TERMUX_DOCKER_USE_SUDO-}" ]; then
	SUDO="sudo"
else
	SUDO=""
fi

if [ -z "${ARCHITECTURE}" ]; then
	ARCHITECTURE="$(uname -m)"
fi

case $ARCHITECTURE in
	aarch64)           ARCHITECTURE="aarch64" PLATFORM_TAG="linux/arm64" ;;
	armv7l|armv8l|arm) ARCHITECTURE="arm"     PLATFORM_TAG="linux/arm/v7" ;;
	x86_64)            ARCHITECTURE="x86_64"  PLATFORM_TAG="linux/amd64" ;;
	i686)              ARCHITECTURE="i686"    PLATFORM_TAG="linux/386" ;;
	*)
		echo "error: ${ARCHITECTURE} is not a valid architecture!"
		exit 1
		;;
esac

PLATFORM_ARG=""
if [ "${OCI}" = "docker" ] && $OCI --help 2>&1 | grep -q buildx; then
	OCI_ARG="buildx ${OCI_ARG}"
	PLATFORM_ARG="--load --platform ${PLATFORM_TAG}"
fi

# packages that are extracted, along with their dependencies,
# on top of the bootstrap to form the termux-docker rootfs.
# libandroid-stub is described in multiple places as existing explicitly
# for use with termux-docker, so pulling it in here.
# dnsmasq will not get automatically updated during 'pkg upgrade' by the user
# after termux-docker has been installed, since root-repo is not installed for now
# to imply that other root-packages are not directly supported,
# but aosp-utils, aosp-libs and libandroid-stub will get automatically updated
# by user-invoked instances of 'pkg upgrade' since they are in the main repository.
TERMUX_DOCKER_DEPENDS="aosp-utils, libandroid-stub, dnsmasq"
BOOTSTRAP_VERSION=2023.02.19-r1%2Bapt-android-7
BOOTSTRAP_SRCURL=https://github.com/termux/termux-packages/releases/download/bootstrap-${BOOTSTRAP_VERSION}/bootstrap-${ARCHITECTURE}.zip
declare -A REPO_BASE_URLS=(
	["main"]="https://packages-cf.termux.dev/apt/termux-main/dists/stable/main"
	["root"]="https://packages-cf.termux.dev/apt/termux-root/dists/root/stable"
)
TERMUX_APP_PACKAGE="com.termux"
TERMUX_BASE_DIR="/data/data/${TERMUX_APP_PACKAGE}/files"
TERMUX_PREFIX="${TERMUX_BASE_DIR}/usr"
ROOTFS="$(pwd)/termux-docker-rootfs"
TMPDIR="$(mktemp -d "/tmp/termux-docker-tmp.XXXXXXXX")"
PKGDIR="${TMPDIR}/packages-${ARCHITECTURE}"
unset TERMUX_DOCKER_DEPENDS_ARRAY
IFS=, read -a TERMUX_DOCKER_DEPENDS_ARRAY <<< "${TERMUX_DOCKER_DEPENDS// /}"
unset PACKAGE_METADATA
unset PACKAGE_URLS
declare -A PACKAGE_METADATA
declare -A PACKAGE_URLS

# Check for some important utilities that may not be available for
# some reason.
for cmd in ar awk curl grep gzip find sed tar xargs xz zip; do
	if [ -z "$(command -v $cmd)" ]; then
		echo "[!] Utility '$cmd' is not available in PATH."
		exit 1
	fi
done

# read_package_lists and pull_package are based on their implementations
# in https://github.com/termux/termux-packages/blob/7a95ee9c2d0ee05e370d1cf951d9f75b4aef8677/scripts/generate-bootstraps.sh

# Download package lists from remote repository.
# Actually, there 2 lists can be downloaded: one architecture-independent and
# one for architecture specified as '$1' argument. That depends on repository.
# If repository has been created using "aptly", then architecture-independent
# list is not available.
read_package_lists() {
	local architecture
	for architecture in all "$1"; do
		for repository in "${!REPO_BASE_URLS[@]}"; do
			REPO_BASE_URL="${REPO_BASE_URLS[${repository}]}"
			if [ ! -e "${TMPDIR}/${repository}-packages.${architecture}" ]; then
				echo "[*] Downloading ${repository} package list for architecture '${architecture}'..."
				if ! curl --fail --location \
					--output "${TMPDIR}/${repository}-packages.${architecture}" \
					"${REPO_BASE_URL}/binary-${architecture}/Packages"; then
					if [ "$architecture" = "all" ]; then
						echo "[!] Skipping architecture-independent package list as not available..."
						continue
					fi
				fi
				echo >> "${TMPDIR}/${repository}-packages.${architecture}"
			fi

			echo "[*] Reading ${repository} package list for '${architecture}'..."
			while read -r -d $'\xFF' package; do
				if [ -n "$package" ]; then
					local package_name
					package_name=$(echo "$package" | grep -i "^Package:" | awk '{ print $2 }')
					package_url="$(dirname "$(dirname "$(dirname "${REPO_BASE_URL}")")")"/"$(echo "${package}" | \
						grep -i "^Filename:" | awk '{ print $2 }')"

					if [ -z "${PACKAGE_METADATA["$package_name"]}" ]; then
						PACKAGE_METADATA["$package_name"]="$package"
						PACKAGE_URLS["$package_name"]="$package_url"
					else
						local prev_package_ver cur_package_ver
						cur_package_ver=$(echo "$package" | grep -i "^Version:" | awk '{ print $2 }')
						prev_package_ver=$(echo "${PACKAGE_METADATA["$package_name"]}" | grep -i "^Version:" | awk '{ print $2 }')

						# If package has multiple versions, make sure that our metadata
						# contains the latest one.
						if [ "$(echo -e "${prev_package_ver}\n${cur_package_ver}" | sort -rV | head -n1)" = "${cur_package_ver}" ]; then
							PACKAGE_METADATA["$package_name"]="$package"
							PACKAGE_URLS["$package_name"]="$package_url"
						fi
					fi
				fi
			done < <(sed -e "s/^$/\xFF/g" "${TMPDIR}/${repository}-packages.${architecture}")
		done
	done
}

# Download specified package, its dependencies and then extract *.deb files to
# the root.
pull_package() {
	local package_name=$1
	local package_url="${PACKAGE_URLS[${package_name}]}"
	local package_tmpdir="${PKGDIR}/${package_name}"
	mkdir -p "$package_tmpdir"

	local package_dependencies
	package_dependencies=$(
		while read -r token; do
			echo "$token" | cut -d'|' -f1 | sed -E 's@\(.*\)@@'
		done < <(echo "${PACKAGE_METADATA[${package_name}]}" | grep -i "^Depends:" | sed -E 's@^[Dd]epends:@@' | tr ',' '\n')
	)

	# Recursively handle dependencies.
	if [ -n "$package_dependencies" ]; then
		local dep
		for dep in $package_dependencies; do
			if [ ! -e "${PKGDIR}/${dep}" ]; then
				pull_package "$dep"
			fi
		done
		unset dep
	fi

	if [ ! -e "$package_tmpdir/package.deb" ]; then
		echo "[*] Downloading '$package_name'..."
		curl --fail --location --output "$package_tmpdir/package.deb" "$package_url"

		echo "[*] Extracting '$package_name'..."
		(cd "$package_tmpdir"
			ar x package.deb

			# data.tar may have extension different from .xz
			if [ -f "./data.tar.xz" ]; then
				data_archive="data.tar.xz"
			elif [ -f "./data.tar.gz" ]; then
				data_archive="data.tar.gz"
			else
				echo "No data.tar.* found in '$package_name'."
				exit 1
			fi

			# Do same for control.tar.
			if [ -f "./control.tar.xz" ]; then
				control_archive="control.tar.xz"
			elif [ -f "./control.tar.gz" ]; then
				control_archive="control.tar.gz"
			else
				echo "No control.tar.* found in '$package_name'."
				exit 1
			fi

			# Extract files.
			tar xf "$data_archive" -C "$ROOTFS"

			# Register extracted files.
			tar tf "$data_archive" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${ROOTFS}${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.list"

			# Generate checksums (md5).
			tar xf "$data_archive"
			find data -type f -print0 | xargs -0 -r md5sum | sed 's@^\.$@@g' > "${ROOTFS}${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.md5sums"

			# Extract metadata.
			tar xf "$control_archive"
			{
				cat control
				echo "Status: install ok installed"
				echo
			} >> "${ROOTFS}${TERMUX_PREFIX}/var/lib/dpkg/status"

			# Additional data: conffiles & scripts
			for file in conffiles postinst postrm preinst prerm; do
				if [ -f "${PWD}/${file}" ]; then
					cp "$file" "${ROOTFS}${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.${file}"
				fi
			done
		)
	fi
}

echo "[*] Regenerating rootfs..."
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

echo "[*] Downloading bootstrap..."
curl --fail --location --output "${TMPDIR}/bootstrap-${ARCHITECTURE}.zip" "${BOOTSTRAP_SRCURL}"
mkdir -p "${ROOTFS}${TERMUX_PREFIX}"
mkdir -p "${ROOTFS}${TERMUX_BASE_DIR}/home"
mkdir -p "${ROOTFS}/data/data/${TERMUX_APP_PACKAGE}/cache"

echo "[*] Extracting bootstrap..."
unzip -q -d "${ROOTFS}${TERMUX_PREFIX}" "${TMPDIR}/bootstrap-${ARCHITECTURE}.zip"
pushd "${ROOTFS}${TERMUX_PREFIX}/"
cat "${ROOTFS}${TERMUX_PREFIX}/SYMLINKS.txt" | while read -r line; do
	dest=$(echo "$line" | awk -F '←' '{ print $1 }');
	link=$(echo "$line" | awk -F '←' '{ print $2 }');
	ln -s "$dest" "$link";
done
popd
rm "${ROOTFS}${TERMUX_PREFIX}/SYMLINKS.txt"

read_package_lists "${ARCHITECTURE}"
for package in "${TERMUX_DOCKER_DEPENDS_ARRAY[@]}"; do
	pull_package "${package}"
done

echo '[*] Linking /system to $PREFIX/opt/aosp...'
ln -s "data/data/${TERMUX_APP_PACKAGE}/files/usr/opt/aosp" "${ROOTFS}/system"

echo "[*] Creating /system/etc/group..."
cat << 'EOF' > "${ROOTFS}/system/etc/group"
root:x:0:
system:!:1000:system
EOF

echo "[*] Creating /system/etc/hosts..."
cat << 'EOF' > "${ROOTFS}/system/etc/hosts"
127.0.0.1 localhost
::1 ip6-localhost
EOF

echo "[*] Creating /system/etc/passwd..."
cat << EOF > "${ROOTFS}/system/etc/passwd"
root:x:0:0:root:/:/system/bin/sh
system:x:1000:1000:system:${TERMUX_BASE_DIR}/home:${TERMUX_PREFIX}/bin/login
EOF

echo "[*] Copying entrypoint.sh to /..."
cp entrypoint.sh "${ROOTFS}/"

echo "[*] Copying entrypoint_root.sh to /..."
cp entrypoint_root.sh "${ROOTFS}/"

echo "[*] Setting permissions..."
find -L "${ROOTFS}/data" \
	-type d -exec \
	chmod 755 "{}" \;
find -L "${ROOTFS}${TERMUX_BASE_DIR}" \
	-type f -o -type d -exec \
	chmod g-rwx,o-rwx "{}" \;
find -L "${ROOTFS}${TERMUX_PREFIX}/bin" \
		"${ROOTFS}${TERMUX_PREFIX}/libexec" \
		"${ROOTFS}${TERMUX_PREFIX}/lib/apt" \
	-type f -exec \
	chmod 700 "{}" \;
find -L "${ROOTFS}/system" \
	-type f -executable -exec \
	chmod 755 "{}" \;
find -L "${ROOTFS}/system" \
	-type f ! -executable -exec \
	chmod 644 "{}" \;

echo "[*] Rootfs generation complete. Building Docker image..."
$SUDO $OCI ${OCI_ARG} \
	--no-cache \
	-t termux/termux-docker:"${ARCHITECTURE}" \
	${PLATFORM_ARG} \
	--build-arg ROOTFS="$(basename ${ROOTFS})" \
	--build-arg TERMUX_APP_PACKAGE="${TERMUX_APP_PACKAGE}" \
	--build-arg TERMUX_BASE_DIR="${TERMUX_BASE_DIR}" \
	--build-arg TERMUX_PREFIX="${TERMUX_PREFIX}" \
	.

if [ "${1-}" = "publish" ]; then
	$SUDO $OCI push termux/termux-docker:"${ARCHITECTURE}"
fi

if [ "${ARCHITECTURE}" = "x86_64" ]; then
	$SUDO $OCI tag termux/termux-docker:"${ARCHITECTURE}" termux/termux-docker:latest
	if [ "${1-}" = "publish" ]; then
		$SUDO $OCI push termux/termux-docker:latest
	fi
fi
