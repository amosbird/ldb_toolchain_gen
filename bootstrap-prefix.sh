#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2015,SC2016,SC2030,SC2031,SC2038,SC2185,SC2120
# Copyright 2006-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

trap 'exit 1' TERM INT QUIT ABRT

# RAP (libc) mode is triggered on Linux kernel and glibc.
is-rap() { [[ ${PREFIX_DISABLE_RAP} != "yes" && ${CHOST} = *linux-gnu* ]]; }
rapx() { is-rap && echo "$1" || echo "$2"; }

## Functions Start Here

estatus() {
	# this can give some garbage in the logs, but it shouldn't be too
	# disturbing -- if it works, it makes it easy to see where we are in
	# the bootstrap from the terminal status line (usually the window
	# name)
	printf '\033]2;%s\007' "$*"
}

eerror() { estatus "$*"; echo "!!! $*" 1>&2; }
einfo() { echo "* $*"; }
v() { echo "$@"; "$@"; }

econf() {
	estatus "stage1: configuring ${PWD##*/}"
	v ${CONFIG_SHELL:+"${CONFIG_SHELL}"} ./configure \
		--host="${CHOST}" \
		--prefix="${ROOT}"/tmp/usr \
		--mandir="${ROOT}"/tmp/usr/share/man \
		--infodir="${ROOT}"/tmp/usr/share/info \
		--datadir="${ROOT}"/tmp/usr/share \
		--sysconfdir="${ROOT}"/tmp/etc \
		--localstatedir="${ROOT}"/tmp/var/lib \
		--build="${CHOST}" \
		"$@" || return 1
}

emake() {
	if [[ $* == *install* ]] ; then
		estatus "stage1: installing ${PWD##*/}"
	else
		estatus "stage1: building ${PWD##*/}"
	fi
	read -r -a makeopts <<< "${MAKEOPTS}"
	if ! v "${MAKE}" "${makeopts[@]}" "$@" ; then
		estatus "stage1: retry with -j1 for clearer error message in ${PWD##*/}"
		v "${MAKE}" "${makeopts[@]}" "$@" -j1 || return 1
	fi
}

efetch() {
	if [[ ! -e ${DISTDIR}/${1##*/} ]] ; then
		mkdir -p "${DISTDIR}" >& /dev/null

		# Try fetching from local mirrors first, as this requires no connection
		for loc in ${GENTOO_MIRRORS} ; do
			if [[ ${loc} = /* && -e "${loc}/${1##*/}" ]]; then
				cp "${loc}/${1##*/}" "${DISTDIR}/${1##*/}" && return 0
			fi
		done

		if [[ ${OFFLINE_MODE} ]] ; then
			echo "I need ${1##*/} from $1 in $DISTDIR, can you give it to me?"
			read -r
			[[ -e ${DISTDIR}/${1##*/} ]] && return 0
			# Give fetch a try
		fi

		if [[ -z ${FETCH_COMMAND} ]] ; then
			# Try to find a download manager, we only deal with wget,
			# curl, FreeBSD's fetch and ftp.
			if [[ $(type -t wget) == "file" ]] ; then
				FETCH_COMMAND="wget -t 3 -T 3"  # 3x3s wait
				[[ $(wget -h) == *"--no-check-certificate"* ]] \
					&& FETCH_COMMAND+=" --no-check-certificate"
			elif [[ $(type -t curl) == "file" ]] ; then
				FETCH_COMMAND="curl -f -L -O"
			elif [[ $(type -t fetch) == "file" ]] ; then
				FETCH_COMMAND="fetch"
			elif [[ $(type -t ftp) == "file" ]] ; then
				FETCH_COMMAND="ftp"
			else
				eerror "no suitable download manager found!"
				eerror "tried: wget, curl, fetch and ftp"
				eerror "could not download ${1##*/}"
				exit 1
			fi
		fi

		einfo "Fetching ${1##*/}"
		estatus "stage1: fetching ${1##*/}"
		pushd "${DISTDIR}" > /dev/null || exit 1

		# Try for mirrors first, fall back to distfiles, then try given location
		local locs=( )
		local loc
		for loc in ${GENTOO_MIRRORS} ${DISTFILES_G_O} ${DISTFILES_PFX}; do
			locs=(
				"${locs[@]}"
				"${loc}/distfiles/${1##*/}"
			)
		done
		locs=( "${locs[@]}" "$1" )

		read -r -a fetchcmd <<< "${FETCH_COMMAND}"
		for loc in "${locs[@]}" ; do
			v "${fetchcmd[@]}" "${loc}" < /dev/null
			[[ -f ${1##*/} ]] && break
		done
		if [[ ! -f ${1##*/} ]] ; then
			eerror "downloading ${1} failed!"
			return 1
		fi
		popd > /dev/null || exit 1
	fi
	return 0
}

configure_cflags() {
	export CPPFLAGS="-I${ROOT}/tmp/usr/include"
	# keep it fairly reasonable (no -march or whatever)
	export OVERRIDE_CFLAGS="-O2 -pipe"
	export OVERRIDE_CXXFLAGS="-O2 -pipe"

	case ${CHOST} in
		*-darwin*)
			export LDFLAGS="-Wl,-search_paths_first -L${ROOT}/tmp/usr/lib"
			;;
		*-solaris*)
			export LDFLAGS="-L${ROOT}/tmp/usr/lib -R${ROOT}/tmp/usr/lib"
			;;
		*)
			export LDFLAGS="-L${ROOT}/tmp/usr/lib -Wl,-rpath=${ROOT}/tmp/usr/lib"
			;;
	esac

	case ${CHOST} in
		# note: we need CXX for binutils-apple which' ld is c++
		*64-apple* | sparcv9-*-solaris* | x86_64-*-solaris*)
			export CC="${CC-gcc} -m64"
			export CXX="${CXX-g++} -m64"
			export HOSTCC="${CC}"
			;;
		i*86-apple-darwin1*)
			export CC="${CC-gcc} -m32"
			export CXX="${CXX-g++} -m32"
			export HOSTCC="${CC}"
			;;
		i*86-pc-linux-gnu)
			if [[ $(${CC} -dumpspecs | grep -A1 multilib_default) != *m32 ]]; then
				export CC="${CC-gcc} -m32"
				export CXX="${CXX-g++} -m32"
			fi
			;;
	esac

	# point possible host pkg-config to stage2 files
	export PKG_CONFIG_PATH=${ROOT}/tmp/usr/lib/pkgconfig
}

configure_toolchain() {
	linker="sys-devel/binutils"
	local gcc_deps="dev-libs/gmp dev-libs/mpfr dev-libs/mpc dev-libs/libffi"
	compiler="${gcc_deps} sys-devel/gcc-config sys-devel/gcc"
	compiler_stage1="${gcc_deps} sys-devel/gcc-config"
	compiler_type="gcc"

	# The host may not have a functioning C++ toolchain, but all
	# compilers available to us require C++ to build.  The last known
	# version not to require C++ is gcc-4.7.
	# We can bootstrap 4.7 in stage1 perhaps if we find envs that do
	# not have a functioning C++ toolchain, but for now we assume this
	# is not a problem.
	# On top of this since gcc-11, C++11 is necessary.  This was
	# introduced in gcc-4.8, but apparently gcc-5 is still buildable
	# with Apple's gcc-apple-4.0.1, so that's a good candidate
	# The Prefix tree only contains gcc-12 as of this writing.
	# The bootstrap Python 3.7 we have in use requires C11, so Apple's
	# 4.x line is no longer enough for that.

	CC=gcc
	CXX=g++

	case ${CHOST}:${DARWIN_USE_GCC} in
		*darwin*:1)
			einfo "Triggering Darwin with GCC toolchain"
			compiler_stage1+=" sys-apps/darwin-miscutils"
			compiler_stage1+=" sys-devel/gcc"

			# binutils-apple/xtools doesn't work (yet) on arm64.  The
			# profiles will mask and keep using native-cctools for that,
			# otherwise stage3 and @system will take care of switching
			# to binutils-apple.
			# one problem: when we have a really old linker, we need
			# to use it sooner or else packages like libffi won't
			# compile.
			case ${CHOST} in
				*-darwin[89])
					linker="=sys-devel/binutils-apple-3.2.6*"
					;;
				*)
					linker="sys-devel/native-cctools"
					;;
			esac
			;;
		*-darwin*)
			local ccvers
			local llvm_deps
			einfo "Triggering Darwin with LLVM/Clang toolchain"
			# for compilers choice, see bug:
			# https://bugs.gentoo.org/show_bug.cgi?id=538366
			compiler_stage1="sys-apps/darwin-miscutils"
			compiler_type="clang"
			ccvers="$(unset CHOST; ${CC} --version 2>/dev/null)"
			llvm_deps="dev-build/ninja"
			case "${ccvers}" in
				*"Apple clang version "*|*"Apple LLVM version "*)
					# this is Clang, recent enough to compile recent clang
					compiler_stage1+="
						${llvm_deps}
						sys-libs/compiler-rt
						sys-devel/llvm
						sys-devel/lld
						sys-devel/clang-common
						sys-devel/clang
					"
					CC=clang
					CXX=clang++
					linker=
					[[ "${BOOTSTRAP_STAGE}" == stage2 ]] && \
						linker=sys-devel/lld
					;;
				*)
					eerror "unknown/unsupported compiler"
					return 1
					;;
			esac

			compiler="
				${llvm_deps}
				sys-libs/compiler-rt
				sys-libs/libcxxabi
				sys-libs/libcxx
				sys-devel/llvm
				sys-devel/lld
				sys-libs/llvm-libunwind
				sys-devel/clang-common
				sys-devel/clang
			"
			;;
		*-linux*)
			is-rap && einfo "Triggering Linux RAP bootstrap"
			compiler_stage1+=" sys-devel/gcc"
			;;
		*)
			compiler_stage1+=" sys-devel/gcc"
			;;
	esac

	return 0
}

bootstrap_setup() {
	einfo "Setting up some guessed defaults"

	local FS_INSENSITIVE=0
	touch "${ROOT}"/FOO.$$
	[[ -e ${ROOT}/foo.$$ ]] && FS_INSENSITIVE=1
	rm "${ROOT}"/FOO.$$

	[[ ! -e "${MAKE_CONF_DIR}" ]] && mkdir -p -- "${MAKE_CONF_DIR}"
	if [[ ! -f ${MAKE_CONF_DIR}/0100_bootstrap_prefix_make.conf ]] ; then
		{
			echo "# Added by bootstrap-prefix.sh for ${CHOST}"
			echo 'USE="unicode nls"'
			echo 'CFLAGS="${CFLAGS} -O2 -pipe"'
			echo 'CXXFLAGS="${CFLAGS}"'
			echo "MAKEOPTS=\"${MAKEOPTS}\""
			echo "CONFIG_SHELL=\"${ROOT}/bin/bash\""
			echo "DISTDIR=\"${DISTDIR:-${ROOT}/var/cache/distfiles}\""
			if is-rap ; then
				echo "# sandbox does not work well on Prefix, bug #490246"
				echo 'FEATURES="${FEATURES} -usersandbox -sandbox"'
				# bug #759424
				[[ -n ${STABLE_PREFIX} ]] && \
					echo 'ACCEPT_KEYWORDS="${ARCH} -~${ARCH}"'
			else
				echo "# last mirror is for Prefix specific distfiles, you"
				echo "# might experience fetch failures if you remove it"
				echo "GENTOO_MIRRORS=\"${GENTOO_MIRRORS} ${DISTFILES_PFX}\""
			fi
			if [[ ${FS_INSENSITIVE} == 1 ]] ; then
				echo
				echo "# Avoid problems due to case-insensitivity, bug #524236"
				echo 'FEATURES="${FEATURES} case-insensitive-fs"'
			fi
			[[ -n ${PORTDIR_OVERLAY} ]] && \
				echo "PORTDIR_OVERLAY=\"\${PORTDIR_OVERLAY} ${PORTDIR_OVERLAY}\""
			[[ -n ${MAKE_CONF_ADDITIONAL_USE} ]] &&
				echo "USE=\"\${USE} ${MAKE_CONF_ADDITIONAL_USE}\""
			[[ ${OFFLINE_MODE} ]] && \
				echo 'FETCHCOMMAND="bash -c \"echo I need \${FILE} from \${URI} in \${DISTDIR}; read\""'

			if [[ ${CHOST} == i*86-apple-darwin9 ]] ; then
				# There's no legitimate reason to use 10.5 with x86 (10.6 and
				# 10.7 run on every device that ever ran 10.5 x86) but it's
				# vastly easier to access and faster than ppc.  Don't want to
				# burden the tree with this aid-arch, so just use the ppc
				# keyword.
				echo
				echo 'ACCEPT_KEYWORDS="~ppc-macos"'
			fi

			if is-rap ; then
				# https://bugs.gentoo.org/933100
				# mainline Portage doesn't set these like Prefix branch
				# does, so hardwire the IDs here
				echo
				echo "PORTAGE_INST_UID=$(id --user)"
				echo "PORTAGE_INST_GID=$(id --group)"
			fi
		} > "${MAKE_CONF_DIR}/0100_bootstrap_prefix_make.conf"
	fi

	if is-rap ; then
		if [[ ! -f ${ROOT}/etc/passwd ]]; then
			if grep -q "^$(id -un):" /etc/passwd; then
				ln -sf {,"${ROOT}"}/etc/passwd
			else
				getent passwd > "${ROOT}"/etc/passwd
				# add user if it's not in /etc/passwd, bug #766417
				getent passwd "$(id -un)" >> "${ROOT}"/etc/passwd
			fi
		fi
		if [[ ! -f ${ROOT}/etc/group ]]; then
			if grep -q "^$(id -gn):" /etc/group; then
				ln -sf {,"${ROOT}"}/etc/group
			else
				getent group > "${ROOT}"/etc/group
				# add group if it's not in /etc/group, bug #766417
				getent group "$(id -gn)" >> "${ROOT}"/etc/group
			fi
		fi
		[[ -f ${ROOT}/etc/resolv.conf ]] || ln -s {,"${ROOT}"}/etc/resolv.conf
		[[ -f ${ROOT}/etc/hosts ]] || cp {,"${ROOT}"}/etc/hosts
	fi

	bootstrap_profile
}

bootstrap_profile() {
	local profile
	local profile_linux

	# 2.6.32.1 -> 2*256^3 + 6*256^2 + 32 * 256 + 1 = 33955841
	kver() { uname -r|cut -d- -f1|awk -F. '{for (i=1; i<=NF; i++){s+=lshift($i,(4-i)*8)};print s}'; }
	# >=glibc-2.20 requires >=linux-2.6.32.
	profile-kernel() {
		if [[ $(kver) -ge 50462720 ]] ; then # 3.2
			echo kernel-3.2+
		elif [[ $(kver) -ge 33955840 ]] ; then # 2.6.32
			echo kernel-2.6.32+
		elif [[ $(kver) -ge 33951744 ]] ; then # 2.6.16
			echo kernel-2.6.16+
		elif [[ $(kver) -ge 33947648 ]] ; then # 2.6
			echo kernel-2.6+
		fi
	}

	if is-rap ; then
		profile_linux="default/linux/ARCH/17.0/prefix/$(profile-kernel)"
	else
		profile_linux="prefix/linux/ARCH"
	fi

	case ${CHOST} in
		powerpc-apple-darwin9)
			rev=${CHOST##*darwin}
			profile="prefix/darwin/macos/10.$((rev - 4))/ppc"
			;;
		i*86-apple-darwin9)
			rev=${CHOST##*darwin}
			profile="prefix/darwin/macos/10.$((rev - 4))/x86"
			;;
		i*86-apple-darwin1[578])
			eerror "REMOVED ARCH: this 32-bit MacOS architecture was removed,"
			eerror "bootstrapping is impossible"
			exit 1
			;;
		x86_64-apple-darwin1[5789])
			rev=${CHOST##*darwin}
			profile="prefix/darwin/macos/10.$((rev - 4))/x64"
			;;
		*64-apple-darwin2[0123456789])
			# Big Sur is  11.0  darwin20
			# Monterey is 12.0  darwin21
			# Ventura is  13.0  darwin22
			# Sanoma is   14.0  darwin23
			rev=${CHOST##*darwin}
			case ${CHOST%%-*} in
				x86_64)  arch=x64    ;;
				arm64)   arch=arm64  ;;
				*)       arch=error  ;;
			esac
			profile="prefix/darwin/macos/$((rev - 9)).0/${arch}"
			;;
		i*86-pc-linux-gnu)
			profile=${profile_linux/ARCH/x86}
			;;
		riscv64-*-linux-gnu)
			profile=${profile_linux/ARCH/riscv}
			profile=${profile/17.0/20.0/rv64gc/lp64d}
			;;
		x86_64-pc-linux-gnu)
			profile=${profile_linux/ARCH/amd64}
			profile=${profile/17.0/17.1/no-multilib}
			;;
		powerpc-unknown-linux-gnu)
			profile=${profile_linux/ARCH/ppc}
			;;
		powerpc64-unknown-linux-gnu)
			profile=${profile_linux/ARCH/ppc64}
			;;
		powerpc64le-unknown-linux-gnu)
			profile=${profile_linux/ARCH/ppc64le}
			;;
		riscv-pc-unknown-linux-gnu)
			profile=${profile_linux/ARCH/riscv}
			profile=${profile/17.0/20.0/rv64gc/lp64d}
			;;
		aarch64-unknown-linux-gnu)
			profile=${profile_linux/ARCH/arm64}
			;;
		armv7*-unknown-linux-gnueabi*)
			profile=${profile_linux/ARCH/arm}
			profile=${profile/17.0/17.0/armv7a}
			;;
		x86_64-pc-solaris2.11)
			profile="prefix/sunos/solaris/5.11/x64"
			;;
		i386-pc-solaris2*|sparc-sun-solaris2*|sparcv9-sun-solaris2*)
			eerror "REMOVED ARCH: this Solaris architecture was removed,"
			eerror "bootstrapping is impossible"
			exit 1
			;;
		i586-pc-winnt*|x86_64-pc-cygwin*)
			eerror "REMOVED ARCH: this Windows architecture was removed,"
			eerror "bootstrapping is impossible"
			exit 1
			;;
		*)
			eerror "UNKNOWN ARCH: You need to set up a make.profile symlink to a"
			eerror "profile in ${PORTDIR} for your CHOST ${CHOST}"
			exit 1
			;;
	esac

	if [[ ${DARWIN_USE_GCC} == 1 ]] ; then
		# amend profile, to use gcc one
		profile="${profile}/gcc"
	elif [[ ${CHOST} == *-darwin* ]] ; then
		[[ "${BOOTSTRAP_STAGE}" != stage2 ]] && profile+="/clang"
	fi

	[[ -n ${PROFILE_BASE}${PROFILE_VARIANT} ]] &&
	profile=${PROFILE_BASE:-prefix}/${profile#prefix/}${PROFILE_VARIANT:+/${PROFILE_VARIANT}}
	if [[ -n ${profile} && ! -e ${ROOT}/etc/portage/make.profile ]] ; then
		local fullprofile="${PORTDIR}/profiles/${profile}"

		ln -s "${fullprofile}" "${ROOT}"/etc/portage/make.profile
		einfo "Your profile is set to ${fullprofile}."
	fi

	# Use package.use to disable in the portage tree to be shared between
	# stage2 and stage3. The hack will be undone during tree sync in stage3.
	cat >> "${ROOT}"/etc/portage/make.profile/package.use <<-EOF
	# Disable bootstrapping libcxx* with libunwind
	sys-libs/libcxxabi -libunwind
	sys-libs/libcxx -libunwind
	EOF

	# On Darwin we might need this to bootstrap the compiler, since
	# bootstrapping the linker (binutils-apple) requires a c++11
	# compiler amongst other things
	cat >> "${ROOT}"/etc/portage/make.profile/package.unmask <<-EOF
	# For Darwin bootstraps
	sys-devel/native-cctools
	EOF
}

do_tree() {
	local x
	for x in etc{,/portage} usr/{{,s}bin,$(rapx "" lib)} var/tmp var/lib/portage var/log/portage var/db;
	do
		[[ -d ${ROOT}/${x} ]] || mkdir -p "${ROOT}/${x}"
	done
	# Make symlinks as USE=split-usr is masked in prefix/rpath. This is
	# necessary for Cygwin, as there is no such thing like an
	# embedded runpath. Instead we put all the dlls next to the
	# exes, to get them working even without the PATH environment
	# variable being set up.
	#
	# In prefix/standalone, however, no symlink is desired.
	# Because we keep USE=split-usr enabled to align with the
	# default of Gentoo vanilla.
	if ! is-rap; then
		for x in lib sbin bin; do
			[[ -e ${ROOT}/${x} ]] || ( cd "${ROOT}" && ln -s usr/${x} )
		done
	fi

	mkdir -p "${PORTDIR}"
	if [[ ! -e ${PORTDIR}/.unpacked ]]; then
		# latest tree cannot be fetched from mirrors, always have to
		# respect the source to get the latest
		if [[ -n ${LATEST_TREE_YES} ]] ; then
			( export GENTOO_MIRRORS='' DISTFILES_G_O='' DISTFILES_PFX='' ;
			  efetch "$1/$2" ) || return 1
		else
			# use only Prefix mirror
			( export GENTOO_MIRRORS='' DISTFILES_G_O='' ;
			  efetch "$1/$2" ) || return 1
		fi
		einfo "Unpacking, this may take a while"
		estatus "stage1: unpacking Portage tree"
		bzip2 -dc "${DISTDIR}/$2" \
			| tar -xf - -C "${PORTDIR}" --strip-components=1
		[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
		touch "${PORTDIR}"/.unpacked
	fi
}

bootstrap_tree() {
	#                      retain this comment and the line below to
	#                      keep this snapshot around in the snapshots
	# MKSNAPSHOT-ANCHOR -- directory of rsync slaves
	local PV="20240930"

	# RAP uses the latest gentoo main repo snapshot to bootstrap.
	is-rap && LATEST_TREE_YES=1

	[[ -n ${LATEST_TREE_YES} ]] && PV=latest

	do_tree "${SNAPSHOT_URL}" portage-${PV}.tar.bz2

	local ret=$?
	if [[ -n ${TREE_FROM_SRC} ]]; then
		estatus "stage1: rsyncing Portage tree"
		rsync -av --delete \
			--exclude=.unpacked \
			--exclude=distfiles \
			--exclude=snapshots \
			"${TREE_FROM_SRC}"/ "${PORTDIR}"/
	fi
	return $ret
}

bootstrap_startscript() {
	local theshell=${SHELL##*/}
	if [[ ${theshell} == "sh" ]] ; then
		einfo "sh is a generic shell, using bash instead"
		theshell="bash"
	fi
	if [[ ${theshell} == "csh" ]] ; then
		einfo "csh is a prehistoric shell not available in Gentoo, switching to tcsh instead"
		theshell="tcsh"
	fi
	einfo "Trying to emerge the shell you use, if necessary by running:"
	einfo "emerge -u ${theshell}"
	if ! emerge -u "${theshell}" ; then
		eerror "Your shell is not available in portage, hence we cannot" > /dev/stderr
		eerror "automate starting your prefix, set SHELL and rerun this script" > /dev/stderr
		return 1
	fi
	einfo "Finally, emerging prefix-toolkit for your convenience"
	emerge -u app-portage/prefix-toolkit || return 1
	einfo "To start Gentoo Prefix, run the script ${ROOT}/startprefix"

	# see if PATH is kept/respected
	local minPATH
	local theirPATH
	minPATH="preamble:${BASH%/*}:postlude"
	theirPATH="$(echo 'echo "${PATH}"' | env LS_COLORS= PATH="${minPATH}" "${SHELL}" -l 2>/dev/null | grep "preamble:.*:postlude")"
	if [[ ${theirPATH} != *"preamble:"*":postlude"* ]] ; then
		einfo "WARNING: your shell initialisation (.cshrc, .bashrc, .profile)"
		einfo "         seems to overwrite your PATH, this effectively kills"
		einfo "         your Prefix.  Change this to only append to your PATH"
	elif [[ ${theirPATH} != "preamble:"* ]] ; then
		einfo "WARNING: your shell initialisation (.cshrc, .bashrc, .profile)"
		einfo "         seems to prepend to your PATH, this might kill your"
		einfo "         Prefix:"
		einfo "         ${theirPATH%%preamble:*}"
		einfo "         You better fix this, YOU HAVE BEEN WARNED!"
	fi
}

prepare_portage() {
	# see bootstrap_portage for explanations.
	mkdir -p "${ROOT}"/bin/. "${ROOT}"/var/log
	[[ -x ${ROOT}/bin/bash ]] || ln -s "${ROOT}"{/tmp,}/bin/bash || return 1
	[[ -x ${ROOT}/bin/sh ]] || ln -s bash "${ROOT}"/bin/sh || return 1
}

bootstrap_portage() {
	# Set TESTING_PV in env if you want to test a new portage before bumping the
	# STABLE_PV that is known to work. Intended for power users only.
	## It is critical that STABLE_PV is the lastest (non-masked) version that is
	## included in the snapshot for bootstrap_tree.
	STABLE_PV="3.0.56.1"
	[[ ${TESTING_PV} == latest ]] && TESTING_PV="3.0.56.1"
	PV="${TESTING_PV:-${STABLE_PV}}"
	A=prefix-portage-${PV}.tar.bz2
	einfo "Bootstrapping ${A%.tar.*}"

	efetch "${DISTFILES_URL}/${A}" || return 1

	einfo "Unpacking ${A%.tar.*}"
	export S="${PORTAGE_TMPDIR}"/portage-${PV}
	ptmp=${S}
	rm -rf "${S}" >& /dev/null
	mkdir -p "${S}" >& /dev/null
	cd "${S}" || return 1
	bzip2 -dc "${DISTDIR}/${A}" | tar -xf -
	[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
	S="${S}/prefix-portage-${PV}"
	cd "${S}" || return 1

	fix_config_sub

	# disable ipc
	sed -e "s:_enable_ipc_daemon = True:_enable_ipc_daemon = False:" \
		-i lib/_emerge/AbstractEbuildProcess.py || \
		return 1

	# host-provided wget may lack certificates, stage1 wget is without ssl
	[[ $(wget -h) == *"--no-check-certificate"* ]] &&
	sed -e '/wget/s/ --passive-ftp /&--no-check-certificate /' -i cnf/make.globals

	# Portage checks for valid shebangs. These may (xz-utils) originate
	# in CONFIG_SHELL (AIX), which originates in PORTAGE_BASH then.
	# So we need to ensure portage's bash is valid as shebang too.
	# Solaris mkdir chokes on existing symlink-to-dir, trailing /. helps.
	mkdir -p "${ROOT}"/tmp/bin/. || return 1
	[[ -x ${ROOT}/tmp/bin/bash ]] || [[ ! -x ${ROOT}/tmp/usr/bin/bash ]] || ln -s ../usr/bin/bash "${ROOT}"/tmp/bin/bash || return 1
	[[ -x ${ROOT}/tmp/bin/bash ]] || ln -s "${BASH}" "${ROOT}"/tmp/bin/bash || return 1
	[[ -x ${ROOT}/tmp/bin/sh ]] || ln -s bash "${ROOT}"/tmp/bin/sh || return 1
	export PORTAGE_BASH="${ROOT}"/tmp/bin/bash

	einfo "Compiling ${A%.tar.*}"
	econf \
		--with-offset-prefix="${ROOT}"/tmp \
		--with-portage-user="$(id -un)" \
		--with-portage-group="$(id -gn)" \
		--with-extra-path="${PATH}" \
		|| return 1
	emake || return 1

	einfo "Installing ${A%.tar.*}"
	emake install || return 1

	cd "${ROOT}" || return 1
	rm -Rf "${ptmp}" >& /dev/null

	# Some people will skip the tree() step and hence var/log is not created
	# As such, portage complains..
	mkdir -p "${ROOT}"/tmp/var/log

	# in Prefix the sed wrapper is deadly, so kill it
	rm -f "${ROOT}"/tmp/usr/lib/portage/bin/ebuild-helpers/sed

	local tmpportdir=${ROOT}/tmp/${PORTDIR#"${ROOT}"}
	[[ -e "${tmpportdir}" ]] || ln -s "${PORTDIR}" "${tmpportdir}"
	for d in "${ROOT}"/tmp/usr/lib/python$(python_ver); do
		[[ -e ${d}/portage ]] || ln -s "${ROOT}"/tmp/usr/lib/portage/lib/portage "${d}"/portage
		[[ -e ${d}/_emerge ]] || ln -s "${ROOT}"/tmp/usr/lib/portage/lib/_emerge "${d}"/_emerge
	done

	if [[ -s ${PORTDIR}/profiles/repo_name ]]; then
		# sync portage's repos.conf with the tree being used
		sed -i -e "s,gentoo_prefix,$(<"${PORTDIR}"/profiles/repo_name)," "${ROOT}"/tmp/usr/share/portage/config/repos.conf || return 1
	fi

	einfo "${A%.tar.*} successfully bootstrapped"
}

fix_config_sub() {
	# macOS Big Sur (11.x, darwin20) supports Apple Silicon (arm64),
	# which config.sub doesn't understand about.  It is, however, Apple
	# who seem to use arm64-apple-darwin20 CHOST triplets, so patch that
	# for various versions of autoconf
	if [[ ${CHOST} == arm64-apple-darwin* ]] ; then
		# Apple Silicon doesn't use aarch64, but arm64
		# note: macOS /usr/bin/find knows no -print0 or -exec
		find . -name "config.sub" | \
			xargs sed -i -e 's/ arm\(-\*\)* / arm\1 | arm64\1 /'
		find . -name "config.sub" | \
			xargs sed -i -e 's/ aarch64 / aarch64 | arm64 /'
	fi
}

bootstrap_simple() {
	local PN PV A S myconf
	PN=$1
	PV=$2
	A=${PN}-${PV}.tar.${3:-gz}
	einfo "Bootstrapping ${A%.tar.*}"

	efetch "${4:-${DISTFILES_G_O}/distfiles}/${A}" || return 1

	einfo "Unpacking ${A%.tar.*}"
	S="${PORTAGE_TMPDIR}/${PN}-${PV}"
	rm -rf "${S}"
	mkdir -p "${S}" || return 1
	cd "${S}" || return 1
	case $3 in
		zstd)  decomp=zstd  ;;
		xz)    decomp=xz    ;;
		bz2)   decomp=bzip2 ;;
		gz|"") decomp=gzip  ;;
	esac
	${decomp} -dc "${DISTDIR}/${A}" | tar -xf -
	[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
	S="${S}"/${PN}-${PV}
	cd "${S}" || return 1

	fix_config_sub

	# for libressl, only provide static lib, such that wget (above)
	# links it in and we don't have to bother about RPATH or something
	if [[ ${PN} == "libressl" ]] ; then
		myconf=(
			"${myconf[@]}"
			--enable-static
			--disable-shared
		)
	fi

	einfo "Compiling ${A%.tar.*}"
	if [[ -x configure ]] ; then
		econf "${myconf[@]}" || return 1
	fi
	emake || return 1

	einfo "Installing ${A%.tar.*}"
	emake PREFIX="${ROOT}"/tmp/usr install || return 1

	cd "${ROOT}" || return 1
	rm -Rf "${S}"
	einfo "${A%.tar.*} successfully bootstrapped"
}

bootstrap_gnu() {
	local PN PV A S
	PN=$1
	PV=$2

	einfo "Bootstrapping ${A%.tar.*}"

	# GNU does not use zstd (yet?)
	for t in tar.xz tar.bz2 tar.gz tar ; do
		A=${PN}-${PV}.${t}

		# save the user some useless downloading
		if [[ ${t} == tar.gz ]] ; then
			type -P gzip > /dev/null || continue
		fi
		if [[ ${t} == tar.xz ]] ; then
			type -P xz > /dev/null || continue
		fi
		if [[ ${t} == tar.bz2 ]] ; then
			type -P bzip2 > /dev/null || continue
		fi

		URL=${GNU_URL}/${PN}/${A}
		efetch "${URL}" || continue

		einfo "Unpacking ${A%.tar.*}"
		S="${PORTAGE_TMPDIR}/${PN}-${PV}"
		rm -rf "${S}"
		mkdir -p "${S}" || return 1
		cd "${S}" || return 1
		case ${t} in
			tar.xz)  decomp=xz    ;;
			tar.bz2) decomp=bzip2 ;;
			tar.gz)  decomp=gzip  ;;
			tar)
				tar -xf "${DISTDIR}/${A}" || continue
				break
				;;
			*)
				einfo "unhandled extension: $t"
				return 1
				;;
		esac
		${decomp} -dc "${DISTDIR}/${URL##*/}" | tar -xf -
		[[ ${PIPESTATUS[*]} == '0 0' ]] || continue
		break
	done
	S="${S}"/${PN}-${PV}
	[[ -d ${S} ]] || return 1
	cd "${S}" || return 1

	# Tar upstream bug #59755 for broken build on macOS:
	# https://savannah.gnu.org/bugs/index.php?59755
	if [[ ${PN}-${PV} == "tar-1.32" ]] ; then
		local tar_patch_file="tar-1.32-check-sys-ioctl-header-configure.patch"
		local tar_patch_id="file_id=50554"
		local tar_patch_url="https://file.savannah.gnu.org/file/${tar_patch_file}?${tar_patch_id}"
		efetch "${tar_patch_url}" || return 1
		# If fetched from upstream url instead of mirror, filename will
		# have a suffix. Remove suffix by copy, not move, to not
		# trigger refetch on repeated invocations of this script.
		if [[ -f "${DISTDIR}/${tar_patch_file}?${tar_patch_id}" ]]; then
			cp "${DISTDIR}/${tar_patch_file}"{"?${tar_patch_id}",} || return 1
		fi
		patch -p1 < "${DISTDIR}/${tar_patch_file}" || return 1
	fi

	# gcc14 fails to build bash if host lacks /usr/include/termcap.h
	# fixed upstream in devel branch
	if [[ ${PN}-${PV} == "bash-5.2" ]] ; then
		local bash_patch_file="tparam.c"
		local bash_patch_id="id=5b239ebbd2b1251c03b8e5591fe797a791266799"
		local bash_patch_url="https://git.savannah.gnu.org/cgit/bash.git/patch/lib/termcap/${bash_patch_file}?${bash_patch_id}"
		efetch "${bash_patch_url}" || return 1
		# If fetched from upstream url instead of mirror, filename will
		# have a suffix. Remove suffix by copy, not move, to not
		# trigger refetch on repeated invocations of this script.
		if [[ -f "${DISTDIR}/${bash_patch_file}?${bash_patch_id}" ]]; then
			cp "${DISTDIR}/${bash_patch_file}"{"?${bash_patch_id}",} || return 1
		fi
		patch -p1 < "${DISTDIR}/${bash_patch_file}" || return 1
	fi

	local -a myconf
	if [[ ${PN}-${PV} == "make-4.2.1" ]] ; then
		if [[ ${CHOST} == *-linux-gnu* ]] ; then
			# force this, macros aren't set correctly with newer glibc
			export CPPFLAGS="${CPPFLAGS} -D__alloca=alloca -D__stat=stat"
		fi
	fi

	if [[ ${PN} == "m4" ]] ; then
		# drop _GL_WARN_ON_USE which gets turned into an error with
		# recent GCC 1.4.17 and below only, on 1.4.18 this expression
		# doesn't match
		sed -i -e '/_GL_WARN_ON_USE (gets/d' lib/stdio.in.h lib/stdio.h

		if [[ ${PV} == "1.4.18" ]] ; then
			# macOS 10.13 have an issue with %n, which crashes m4
			efetch "http://rsync.prefix.bitzolder.nl/sys-devel/m4/files/m4-1.4.18-darwin17-printf-n.patch" || return 1
			patch -p1 < "${DISTDIR}"/m4-1.4.18-darwin17-printf-n.patch || return 1

			# Bug 715880
			efetch http://dev.gentoo.org/~heroxbd/m4-1.4.18-glibc228.patch || return 1
			patch -p1 < "${DISTDIR}"/m4-1.4.18-glibc228.patch || return 1
		fi
	fi

	fix_config_sub

	if [[ ${PN} == "grep" ]] ; then
		# Solaris and OSX don't like it when --disable-nls is set,
		# so just don't set it at all.
		# Solaris 11 has a messed up prce installation.  We don't need
		# it anyway, so just disable it
		myconf+=( "--disable-perl-regexp" )
	fi

	if [[ ${PN} == "mpfr" || ${PN} == "mpc" || ${PN} == "gcc" ]] ; then
		[[ -e "${ROOT}"/tmp/usr/include/gmp.h ]] \
			&& myconf+=( "--with-gmp=${ROOT}/tmp/usr" )
	fi
	if [[ ${PN} == "mpc" || ${PN} == "gcc" ]] ; then
		[[ -e "${ROOT}"/tmp/usr/include/mpfr.h ]] \
			&& myconf+=( "--with-mpfr=${ROOT}/tmp/usr" )
	fi
	if [[ ${PN} == "gcc" ]] ; then
		[[ -e "${ROOT}"/tmp/usr/include/mpc.h ]] \
			&& myconf+=( "--with-mpc=${ROOT}/tmp/usr" )

		myconf+=(
			"--enable-languages=c,c++"
			"--disable-bootstrap"
			"--disable-multilib"
			"--disable-nls"
			"--disable-libsanitizer"
		)

		if [[ ${CHOST} == *-darwin* ]] ; then
			myconf+=(
				"--with-native-system-header-dir=${ROOT}/MacOSX.sdk/usr/include"
				"--with-ld=${ROOT}/tmp/usr/bin/ldwrapper"
			)
		fi

		export CFLAGS="-O1 -pipe"
		export CXXFLAGS="-O1 -pipe"
	fi

	# pod2man may be too old (not understanding --utf8) but we don't
	# care about manpages at this stage
	export ac_cv_path_POD2MAN=no

	# On e.g. musl systems bash will crash with a malloc error if we use
	# bash' internal malloc, so disable it during it this stage
	[[ ${PN} == "bash" ]] && myconf+=( "--without-bash-malloc" )

	# Ensure we don't read system-wide shell initialisation, it may
	# contain cruft, bug #650284
	[[ ${PN} == "bash" ]] && \
		export CPPFLAGS="${CPPFLAGS} \
			-DSYS_BASHRC=\\\"${ROOT}/etc/bash/bashrc\\\" \
			-DSYS_BASH_LOGOUT=\\\"${ROOT}/etc/bash/bash_logout\\\" \
		"

	# Don't do ACL stuff on Darwin, especially Darwin9 will make
	# coreutils completely useless (install failing on everything)
	# Don't try using gmp either, it may be that just the library is
	# there, and if so, the buildsystem assumes the header exists too
	# stdbuf is giving many problems, and we don't really care about it
	# at this level, so disable it too
	if [[ ${PN} == "coreutils" ]] ; then
		myconf+=(
			"--disable-acl"
			"--without-gmp"
			"--enable-no-install-program=stdbuf"
		)
	fi

	# Gentoo Bug 400831, fails on Ubuntu with libssl-dev installed
	if [[ ${PN} == "wget" ]] ; then
		if [[ -x ${ROOT}/tmp/usr/bin/openssl ]] ; then
			myconf+=(
				"-with-ssl=openssl"
				"--with-libssl-prefix=${ROOT}/tmp/usr"
			)
			export CPPFLAGS="${CPPFLAGS} -I${ROOT}/tmp/usr/include"
			export LDFLAGS="${LDFLAGS} -L${ROOT}/tmp/usr/lib"
		else
			myconf+=( "--without-ssl" )
		fi
	fi

	# SuSE 11.1 has GNU binutils-2.20, choking on crc32_x86
	[[ ${PN} == "xz" ]] && myconf+=( "--disable-assembler" )

	if [[ ${PN} == "libffi" ]] ; then
		# we do not have pkg-config to find lib/libffi-*/include/ffi.h
		sed -i -e '/includesdir =/s/=.*/= $(includedir)/' include/Makefile.in
		# force install into libdir
		myconf+=( "--libdir=${ROOT}/tmp/usr/lib" )
		sed -i -e '/toolexeclibdir =/s/=.*/= $(libdir)/' Makefile.in
		# we have to build the libraries for correct bitwidth
		case $CHOST in
		(x86_64-*-*|sparcv9-*-*)
			export CFLAGS="-m64"
			;;
		(i?86-*-*)
			export CFLAGS="-m32"
			;;
		(arm64-*-darwin*)
			sed -i -e 's/aarch64\*-\*-\*/arm64*-*-*|&/' \
				configure configure.host
			;;
		esac
	fi

	einfo "Compiling ${A%.tar.*}"
	econf "${myconf[@]}" || return 1
	if [[ ${PN} == "make" && $(type -t $MAKE) != "file" ]]; then
		estatus "stage1: building ${A%.tar.*}"
		v ./build.sh || return 1
	else
		emake || return 1
	fi

	einfo "Installing ${A%.tar.*}"
	if [[ ${PN} == "make" && $(type -t $MAKE) != "file" ]]; then
		estatus "stage1: installing ${A%.tar.*}"
		v ./make install MAKE="${S}/make" || return 1
	else
		emake install || return 1
	fi

	cd "${ROOT}" || return 1
	rm -Rf "${S}"
	einfo "${A%.tar.*} successfully bootstrapped"
}

python_ver() {
	# keep this number in line with PV below for stage1,2
	# also, note that this version must match the Python version in the
	# snapshot for stage3, else packages will break with some python
	# mismatch error due to Portage using a different version after it
	# upgraded itself with a newer Python
	echo 3.11
	export PYTHON_FULL_VERSION="3.11.7-gentoo-prefix-patched"
	# keep this number in line with PV below for stage1,2
}

bootstrap_python() {
	python_ver  # to get full version
	PV=${PYTHON_FULL_VERSION}
	A=Python-${PV}.tar.xz
	einfo "Bootstrapping ${A%.tar.*}"

	if [[ ${PV} == *-gentoo-prefix-patched ]] ; then
		efetch https://dev.gentoo.org/~grobian/distfiles/${A}
	else
		efetch https://www.python.org/ftp/python/${PV}/${A}
	fi

	einfo "Unpacking ${A%.tar.*}"
	export S="${PORTAGE_TMPDIR}/python-${PV}"
	rm -rf "${S}"
	mkdir -p "${S}" || return 1
	cd "${S}" || return 1
	case ${A} in
		*bz2) bzip2 -dc "${DISTDIR}"/${A} | tar -xf - ;;
		*xz)  xz -dc "${DISTDIR}"/${A} | tar -xf -    ;;
		*)    einfo "Don't know to unpack ${A}"       ;;
	esac
	[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
	S="${S}"/Python-${PV%%-*}
	cd "${S}" || return 1
	rm -rf Modules/_ctypes/libffi* || return 1
	rm -rf Modules/zlib || return 1

	case ${CHOST} in
	(*-solaris*)
		# Solaris' host compiler (if old -- 3.4.3) doesn't grok HUGE_VAL,
		# and barfs on isnan() so patch it out
		sed -i \
			-e '/^#define Py_HUGE_VAL/s/HUGE_VAL$/(__builtin_huge_val())/' \
			-e '/defined HAVE_DECL_ISNAN/s/ISNAN/USE_FALLBACK/' \
			Include/pymath.h
		# OpenIndiana/Solaris 11 defines inet_aton no longer in
		# libresolv, so use hstrerror to check if we need -lresolv
		sed -i -e '/AC_CHECK_LIB/s/inet_aton/hstrerror/' \
			configure.ac || die
		# we don't regenerate configure at this point, so just force the
		# fix result
		export LIBS="${LIBS} -lresolv"
		;;
	(*-darwin9)
		# Darwin 9's kqueue seems to act up (at least at this stage), so
		# make Python's selectors resort to poll() or select() for the
		# time being
		sed -i \
			-e 's/kqueue/kqueue_DISABLED/' \
			configure
		# fixup thread id detection (only needed on vanilla Python tar)
		efetch "https://dev.gentoo.org/~sam/distfiles/dev-lang/python/python-3.9.6-darwin9_pthreadid.patch"
		patch -p1 < "${DISTDIR}"/python-3.9.6-darwin9_pthreadid.patch
		;;
	(*-openbsd*)
		# OpenBSD is not a multilib system
		sed -i \
			-e '0,/#if defined(__ANDROID__)/{s/ANDROID/OpenBSD/}' \
			-e '0,/MULTIARCH=/{s/\(MULTIARCH\)=.*/\1=""/}' \
			configure
		;;
	esac

	case ${CHOST} in
	(*-darwin*)
		# avoid triggering compiled out system proxy retrieval code (_scproxy)
		sed -i -e '/sys.platform/s/darwin/disabled-darwin/' \
			Lib/urllib/request.py
		;;
	esac

	fix_config_sub

	case ${CHOST} in
	(x86_64-*-*|sparcv9-*-*)
		export CFLAGS="-m64"
		;;
	(i?86-*-*)
		export CFLAGS="-m32"
		;;
	esac

	case ${CHOST} in
		*-linux*)
			# Bug 382263: make sure Python will know about the libdir in use for
			# the current arch
			local -a flgarg
			read -r -a flgarg <<< "${CFLAGS}"
			libdir="-L/usr/lib/$(gcc "${flgarg[@]}" -print-multi-os-directory)"
		;;
		x86_64-*-solaris*|sparcv9-*-solaris*)
			# Like above, make Python know where GCC's 64-bits
			# libgcc_s.so is on Solaris
			libdir="-L/usr/sfw/lib/64"
		;;
		*-solaris*) # 32bit
			libdir="-L/usr/sfw/lib"
		;;
	esac

	# python refuses to find the zlib headers that are built in the offset,
	# same for libffi, which installs into compiler's multilib-osdir
	export CPPFLAGS="-I${ROOT}/tmp/usr/include"
	export LDFLAGS="${CFLAGS} -L${ROOT}/tmp/usr/lib"
	# set correct flags for runtime for ELF platforms
	case ${CHOST} in
		*-linux*)
			# GNU ld
			LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOT}/tmp/usr/lib ${libdir}"
			LDFLAGS="${LDFLAGS} -Wl,-rpath,${libdir#-L}"
		;;
		*-openbsd*)
			# LLD
			LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOT}/tmp/usr/lib"
		;;
		*-solaris*)
			# Sun ld
			LDFLAGS="${LDFLAGS} -R${ROOT}/tmp/usr/lib ${libdir}"
			LDFLAGS="${LDFLAGS} -R${libdir#-L}"
		;;
	esac

	# if the user has a $HOME/.pydistutils.cfg file, the python
	# installation is going to be screwed up, as reported by users, so
	# just make sure Python won't find it
	export HOME="${S}"

	export OPT="${CFLAGS}"

	einfo "Compiling ${A%.tar.*}"

	# - Some ancient versions of hg fail with "hg id -i", so help
	#   configure to not find them using HAS_HG (TODO: obsolete?)
	# - Do not find libffi via pkg-config using PKG_CONFIG
	HAS_HG=no \
	PKG_CONFIG='' \
	econf \
		--with-system-ffi \
		--without-ensurepip \
		--disable-ipv6 \
		--disable-shared \
		--libdir="${ROOT}"/tmp/usr/lib \
		|| return 1
	emake || return 1

	einfo "Installing ${A%.tar.*}"
	emake -k install || echo "??? Python failed to install *sigh* continuing anyway"
	cd "${ROOT}"/tmp/usr/bin || return 1
	ln -sf python${PV%.*} python
	cd "${ROOT}"/tmp/usr/lib || return 1
	# messes up python emerges, and shouldn't be necessary for anything
	# http://forums.gentoo.org/viewtopic-p-6890526.html
	rm -f libpython${PV%.*}.a

	einfo "${A%.tar.*} bootstrapped"
}

bootstrap_cmake_core() {
	PV=${1:-3.16.5}
	A=cmake-${PV}.tar.gz

	einfo "Bootstrapping ${A%.tar.*}"

	efetch "https://github.com/Kitware/CMake/releases/download/v${PV}/${A}" \
		|| return 1

	einfo "Unpacking ${A%.tar.*}"
	export S="${PORTAGE_TMPDIR}/cmake-${PV}"
	rm -rf "${S}"
	mkdir -p "${S}" || return 1
	cd "${S}" || return 1
	gzip -dc "${DISTDIR}/${A}" | tar -xf -
	[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
	S="${S}"/cmake-${PV}
	cd "${S}" || return 1

	# don't set a POSIX standard, system headers don't like that, #757426
	sed -i -e 's/^#if !defined(_WIN32) && !defined(__sun)/& \&\& !defined(__APPLE__)/' \
		Source/cmLoadCommandCommand.cxx \
		Source/cmStandardLexer.h \
		Source/cmSystemTools.cxx \
		Source/cmTimestamp.cxx

	einfo "Bootstrapping ${A%.tar.*}"
	estatus "stage1: configuring ${A%.tar.*}"
	./bootstrap --prefix="${ROOT}"/tmp/usr || return 1

	einfo "Compiling ${A%.tar.*}"
	emake || return 1

	einfo "Installing ${A%.tar.*}"
	emake install || return 1

	# we need sysroot crap to build cmake itself, but it makes trouble
	# later on, so kill it in the installed version
	sed -i -e '/cmake_gnu_set_sysroot_flag/d' \
		"${ROOT}"/tmp/usr/share/cmake*/Modules/Platform/Apple-GNU-*.cmake || die
	# disable isysroot usage with clang as well
	sed -i -e '/_SYSROOT_FLAG/d' \
		"${ROOT}"/tmp/usr/share/cmake*/Modules/Platform/Apple-Clang.cmake || die

	einfo "${A%.tar.*} bootstrapped"
}

bootstrap_cmake() {
	bootstrap_cmake_core 3.20.6 || \
	bootstrap_cmake_core 3.16.5 || \
	bootstrap_cmake_core 3.0.2
}

bootstrap_zlib_core() {
	# Use 1.2.8 by default, current bootstrap guides
	PV="${1:-1.2.8}"
	A=zlib-${PV}.tar.gz

	einfo "Bootstrapping ${A%.tar.*}"

	efetch "${DISTFILES_G_O}/distfiles/${A}" || return 1

	einfo "Unpacking ${A%.tar.*}"
	export S="${PORTAGE_TMPDIR}/zlib-${PV}"
	rm -rf "${S}"
	mkdir -p "${S}" || return 1
	cd "${S}" || return 1
	case ${A} in
		*.tar.gz) decomp=gzip  ;;
		*)        decomp=bzip2 ;;
	esac
	${decomp} -dc "${DISTDIR}/${A}" | tar -xf -
	[[ ${PIPESTATUS[*]} == '0 0' ]] || return 1
	S="${S}"/zlib-${PV}
	cd "${S}" || return 1

	if [[ ${CHOST} == x86_64-*-* || ${CHOST} == sparcv9-*-* ]] ; then
		# 64-bits targets need zlib as library (not just to unpack),
		# hence we need to make sure that we really bootstrap this
		# 64-bits (in contrast to the tools which we don't care if they
		# are 32-bits)
		export CC="${CC} -m64"
	elif [[ ${CHOST} == i?86-*-* ]] ; then
		# This is important for bootstraps which are 64-native, but we
		# want 32-bits, such as most Linuxes, and more recent OSX.
		# OS X Lion and up default to a 64-bits userland, so force the
		# compiler to 32-bits code generation if requested here
		export CC="${CC} -m32"
	fi
	local makeopts=()
	# 1.2.5 suffers from a concurrency problem
	[[ ${PV} == 1.2.5 ]] || read -r -a makeopts <<< "${MAKEOPTS}"

	einfo "Compiling ${A%.tar.*}"
	CHOST='' ${CONFIG_SHELL} ./configure --prefix="${ROOT}"/tmp/usr || return 1
	MAKEOPTS=''
	emake "${makeopts[@]}" || return 1

	einfo "Installing ${A%.tar.*}"
	emake "${makeopts[@]}" -j1 install || return 1

	# this lib causes issues when emerging python again on Solaris
	# because the tmp lib path is in the library search path there
	local x
	for x in "${ROOT}"/tmp/usr/lib/libz*.a ; do
		[[ ${x} == *.dll.a ]] && continue # keep Cygwin import lib
		rm -Rf "${x}"
	done

	einfo "${A%.tar.*} bootstrapped"
}

bootstrap_zlib() {
	bootstrap_zlib_core 1.2.11 || \
	bootstrap_zlib_core 1.2.8 || bootstrap_zlib_core 1.2.7 || \
	bootstrap_zlib_core 1.2.6 || bootstrap_zlib_core 1.2.5
}

bootstrap_libffi() {
	# 3.0.8: last version to bootstrap on Darwin 9 x86
	bootstrap_gnu libffi 3.4.5 || \
	bootstrap_gnu libffi 3.3 || \
	bootstrap_gnu libffi 3.2.1 || \
	bootstrap_gnu libffi 3.0.8
}

bootstrap_gmp() {
	bootstrap_gnu gmp 6.2.1
}

bootstrap_mpfr() {
	bootstrap_gnu mpfr 4.1.0
}

bootstrap_mpc() {
	bootstrap_gnu mpc 1.2.1
}

bootstrap_ldwrapper() {
	A=ldwrapper.c

	einfo "Bootstrapping ${A%.c}"

	efetch "https://rsync.prefix.bitzolder.nl/sys-devel/binutils-config/files/${A}" || return 1

	export S="${PORTAGE_TMPDIR}/ldwrapper"
	rm -rf "${S}"
	mkdir -p "${S}" || return 1
	cd "${S}" || return 1
	cp "${DISTDIR}/${A}" . || return 1

	einfo "Compiling ${A%.c}"
	${CC:-gcc} \
		-o ldwrapper \
		-DCHOST="\"${CHOST}\"" \
		-DEPREFIX="\"${ROOT}\"" \
		ldwrapper.c || return 1

	einfo "Installing ${A%.c}"
	mkdir -p "${ROOT}"/tmp/usr/bin
	cp -a ldwrapper "${ROOT}"/tmp/usr/bin/ || return 1

	einfo "${A%.c} bootstrapped"
}

bootstrap_gcc5() {
	# bootstraps with gcc-4.0.1 (Darwin 8), provides C11
	bootstrap_gnu gcc 5.5.0
}

bootstrap_sed() {
	bootstrap_gnu sed 4.9 || bootstrap_gnu sed 4.5 || \
	bootstrap_gnu sed 4.2.2 || bootstrap_gnu sed 4.2.1
}

bootstrap_findutils() {
	bootstrap_gnu findutils 4.9.0 ||
	bootstrap_gnu findutils 4.7.0 ||
	bootstrap_gnu findutils 4.5.10 ||
	bootstrap_gnu findutils 4.2.33
}

bootstrap_wget() {
	bootstrap_gnu wget 1.20.1 || \
	bootstrap_gnu wget 1.17.1 || bootstrap_gnu wget 1.13.4
}

bootstrap_grep() {
	# don't use 2.13, it contains a bug that bites, bug #425668
	# 2.9 is the last version provided as tar.gz (platforms without xz)
	# 2.7 is necessary for Solaris/OpenIndiana (2.8, 2.9 fail to configure)
	bootstrap_gnu grep 3.3 || \
	bootstrap_gnu grep 2.9 || bootstrap_gnu grep 2.7 || \
	bootstrap_gnu grep 2.14 || bootstrap_gnu grep 2.12
}

bootstrap_coreutils() {
	# 8.16 is the last version released as tar.gz
	# 8.18 is necessary for macOS High Sierra (darwin17) and converted
	#      to tar.gz for this case
	bootstrap_gnu coreutils 9.5 || \
	bootstrap_gnu coreutils 8.32 || bootstrap_gnu coreutils 8.30 || \
	bootstrap_gnu coreutils 8.16 || bootstrap_gnu coreutils 8.17
}

bootstrap_tar() {
	bootstrap_gnu tar 1.32 || bootstrap_gnu tar 1.26
}

bootstrap_make() {
	MAKEOPTS= # no GNU make yet
	bootstrap_gnu make 4.2.1 || return 1
	if [[ ${MAKE} == gmake ]] ; then
		# make make available as gmake
		( cd "${ROOT}"/tmp/usr/bin && ln -s make gmake )
	fi
}

bootstrap_patch() {
	# 2.5.9 needed for OSX 10.6.x still?
	bootstrap_gnu patch 2.7.5 ||
	bootstrap_gnu patch 2.7.4 ||
	bootstrap_gnu patch 2.7.3 ||
	bootstrap_gnu patch 2.6.1
}

bootstrap_gawk() {
	bootstrap_gnu gawk 5.0.1 || bootstrap_gnu gawk 4.0.1 || \
		bootstrap_gnu gawk 3.1.8
}

bootstrap_binutils() {
	bootstrap_gnu binutils 2.17
}

bootstrap_texinfo() {
	bootstrap_gnu texinfo 4.8
}

bootstrap_bash() {
	bootstrap_gnu bash 5.2 ||
	bootstrap_gnu bash 5.1 ||
	bootstrap_gnu bash 5.0
}

bootstrap_bison() {
	bootstrap_gnu bison 3.8.2 || \
	bootstrap_gnu bison 2.6.2 || \
	bootstrap_gnu bison 2.5.1 || \
	bootstrap_gnu bison 2.4
}

bootstrap_m4() {
	bootstrap_gnu m4 1.4.19 || \
	bootstrap_gnu m4 1.4.18 # version is patched, so beware
}

bootstrap_gzip() {
	bootstrap_gnu gzip 1.4
}

bootstrap_xz() {
	GNU_URL=http://tukaani.org/xz bootstrap_gnu xz 5.4.5 || \
	GNU_URL=http://tukaani.org/xz bootstrap_gnu xz 5.2.4 || \
	GNU_URL=http://tukaani.org/xz bootstrap_gnu xz 5.2.3
}

bootstrap_bzip2() {
	bootstrap_simple bzip2 1.0.6 gz \
		https://sourceware.org/pub/bzip2
}

bootstrap_libressl() {
	bootstrap_simple libressl 3.4.3 gz \
		https://ftp.openbsd.org/pub/OpenBSD/LibreSSL || \
	bootstrap_simple libressl 3.2.4 gz \
		https://ftp.openbsd.org/pub/OpenBSD/LibreSSL || \
	bootstrap_simple libressl 2.8.3 gz \
		https://ftp.openbsd.org/pub/OpenBSD/LibreSSL
}

bootstrap_stage_host_gentoo() {
	if ! is-rap ; then
		einfo "Shortcut only supports prefix-standalone, but we "
		einfo "are bootstrapping prefix-rpath.  Do nothing."
		return 0
	fi

	if [[ ! -L ${ROOT}/tmp ]] ; then
		if [[ -e ${ROOT}/tmp ]] ; then
			einfo "${ROOT}/tmp exists and is not a symlink to ${HOST_GENTOO_EROOT}"
			einfo "Let's ignore the shortcut and continue."
		else
			ln -s "${HOST_GENTOO_EROOT}" "${ROOT}"/tmp
		fi
	fi

	# checks itself if things need to be done still
	(bootstrap_tree) || return 1

	# setup a profile
	[[ -e ${ROOT}/etc/portage/make.profile && \
		-e ${MAKE_CONF_DIR}/0100_bootstrap_prefix_make.conf ]] \
		|| (bootstrap_setup) || return 1

	prepare_portage
}

bootstrap_stage1() {
	# NOTE: stage1 compiles all tools (no libraries) in the native
	# bits-size of the compiler, which needs not to match what we're
	# bootstrapping for.  This is no problem since they're just tools,
	# for which it really doesn't matter how they run, as long AS they
	# run.  For libraries, this is different, since they are relied upon
	# by packages we emerge later on.
	# Changing this to compile the tools for the bits the bootstrap is
	# for, is a BAD idea, since we're extremely fragile here, so
	# whatever the native toolchain is here, is what in general works
	# best.

	# See comments in do_tree().
	local portroot=${PORTDIR%/*}
	mkdir -p "${ROOT}/tmp/${portroot#"${ROOT}"/}"
	for x in lib sbin bin; do
		mkdir -p "${ROOT}"/tmp/usr/${x}
		[[ -e ${ROOT}/tmp/${x} ]] || ( cd "${ROOT}"/tmp && ln -s usr/${x} )
	done

	BOOTSTRAP_STAGE="stage1" configure_toolchain || return 1
	export CC CXX

	# default: empty = NO
	local USEGCC5=

	if [[ ${CHOST} == *-darwin* ]] ; then
		# setup MacOSX.sdk symlink for GCC, this should probably be
		# managed using an eselect module in the future
		# FWIW, just use system (/) if it seems OK, for some reason
		# early versions of TAPI-based SDKs did not include some symbols
		# like fclose, which ld64 is able to resolve from the dylibs
		# although they are unvisible using e.g. nm.
		rm -f "${ROOT}"/MacOSX.sdk
		local SDKPATH
		if [[ -e /usr/lib/libSystem.B.dylib && -d /usr/include ]] ; then
			SDKPATH=/
		else
			SDKPATH=$(xcrun --show-sdk-path --sdk macosx)
			if [[ -e ${SDKPATH} ]] ; then
				local fsdk
				local osvers
				# try and find a matching OS SDK, xcrun seems to return
				# the latest installed, so not necessarily the one
				# matching the macOS version
				[[ -L ${SDKPATH} ]] && fsdk="$(readlink "${SDKPATH}")"
				# note readlink -f is not supported on older versions of
				# macOS so need to emulate it
				if [[ ${fsdk} != /* ]] ; then
					# this is not proper, but Apple does not use ../
					# constructs here, as far as we know
					fsdk="${SDKPATH%/*}/${fsdk}"
				fi
				osvers="$(sw_vers -productVersion)"
				if [[ ${osvers%%.*} -le 10 ]] ; then
					osvers=$(echo "${osvers}" | cut -d'.' -f1-2)
				else
					osvers=${osvers%%.*}
				fi
				fsdk=${fsdk%/MacOSX*.sdk}
				fsdk=${fsdk}/MacOSX${osvers}.sdk
				[[ -e ${fsdk} ]] && SDKPATH=${fsdk}
			fi
			if [[ ! -e ${SDKPATH} ]] ; then
				SDKPATH=$(xcodebuild -showsdks | sort -nr \
					| grep -o "macosx.*" | head -n1)
				SDKPATH=$(xcode-select -print-path)/SDKs/MacOSX${SDKPATH#macosx}.sdk
			fi
		fi
		( cd "${ROOT}" && ln -s "${SDKPATH}" MacOSX.sdk )
		einfo "using system sources from ${SDKPATH}"

		# GCC 14 cannot be compiled by versions of Clang at least on
		# Darwin17, so go the safe route and get GCC-5 which is sufficient
		# and the last one we can compile without C11.  This also compiles
		# on Darwin 8 and 9.
		# see also configure_toolchain
		case ${CHOST} in
			*-darwin2[23456789]) :      ;;  # host toolchain can compile gcc-14
			*-darwin[89])  USEGCC5=yes  ;;
			*86*-darwin*)  USEGCC5=yes  ;;
			# arm64/M1 isn't supported by old GCC-5!
		esac
	fi

	if [[ -n ${USEGCC5} ]] ; then
		# benefit from 4.2 if it's present
		if [[ -e /usr/bin/gcc-4.2 ]] ; then
			export CC=gcc-4.2
			export CXX=g++-4.2
		fi

		[[ -e ${ROOT}/tmp/usr/include/gmp.h ]] \
			|| (bootstrap_gmp) || return 1
		[[ -e ${ROOT}/tmp/usr/include/mpfr.h ]] \
			|| (bootstrap_mpfr) || return 1
		[[ -e ${ROOT}/tmp/usr/include/mpc.h ]] \
			|| (bootstrap_mpc) || return 1
		[[ -x ${ROOT}/tmp/usr/bin/ldwrapper ]] \
			|| (bootstrap_ldwrapper) || return 1
		# get ldwrapper target in PATH
		export BINUTILS_CONFIG_LD="$(type -P ld)"
		# force deployment target in GCCs build, GCC-5 doesn't quite get
		# the newer macOS versions (20+) and thus confuses ld when it
		# passes on the deployment version.  Use High Sierra as it has
		# everything we need
		[[ ${CHOST##*darwin} -gt 10 ]] && export MACOSX_DEPLOYMENT_TARGET=10.13
		[[ -x ${ROOT}/tmp/usr/bin/gcc ]] \
			|| (bootstrap_gcc5) || return 1

		if [[ ${CHOST##*darwin} -gt 10 ]] ; then
			# install wrappers in tmp/usr/local/bin which comes before
			# /tmp/usr/bin in PATH
			mkdir -p "${ROOT}"/tmp/usr/local/bin
			rm -f "${ROOT}"/tmp/usr/local/bin/{gcc,${CHOST}-gcc}
			cat > "${ROOT}/tmp/usr/local/bin/${CHOST}-gcc" <<-EOS
				#!/usr/bin/env sh
				export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}
				export BINUTILS_CONFIG_LD="$(type -P ld)"
				exec "${ROOT}"/tmp/usr/bin/${CHOST}-gcc "\$@"
			EOS
			chmod 755 "${ROOT}/tmp/usr/local/bin/${CHOST}-gcc"
			ln -s ${CHOST}-gcc "${ROOT}"/tmp/usr/local/bin/gcc

			rm -f "${ROOT}"/tmp/usr/local/bin/{g++,${CHOST}-g++}
			cat > "${ROOT}"/tmp/usr/local/bin/${CHOST}-g++ <<-EOS
				#!/usr/bin/env sh
				export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}
				export BINUTILS_CONFIG_LD="$(type -P ld)"
				exec "${ROOT}"/tmp/usr/bin/${CHOST}-g++ "\$@"
			EOS
			chmod 755 "${ROOT}"/tmp/usr/local/bin/${CHOST}-g++
			ln -s ${CHOST}-g++ "${ROOT}"/tmp/usr/local/bin/g++
		fi

		# reset after gcc-4.2 usage
		export CC=gcc
		export CXX=g++
	fi

	# Run all bootstrap_* commands in a subshell since the targets
	# frequently pollute the environment using exports which affect
	# packages following (e.g. zlib builds 64-bits)

	local CP

	# don't rely on $MAKE, if make == gmake packages that call 'make' fail
	[[ -x ${ROOT}/tmp/usr/bin/make ]] \
		|| [[ $(make --version 2>&1) == *GNU" Make "4* ]] \
		|| (bootstrap_make) || return 1
	[[ ${OFFLINE_MODE} ]] || [[ -x ${ROOT}/tmp/usr/bin/openssl ]] \
		|| (bootstrap_libressl) # do not fail if this fails, we'll try without
	[[ ${OFFLINE_MODE} ]] || type -P wget > /dev/null \
		|| (bootstrap_wget) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/sed ]] \
		|| [[ $(sed --version 2>&1) == *GNU* ]] \
		|| (bootstrap_sed) || return 1
	type -P xz > /dev/null || (bootstrap_xz) || return 1
	type -P bzip2 > /dev/null || (bootstrap_bzip2) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/patch ]] \
		|| [[ $(patch --version 2>&1) == *"patch 2."[6-9]*GNU* ]] \
		|| (bootstrap_patch) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/m4 ]] \
		|| [[ $(m4 --version 2>&1) == *GNU*1.4.1?* ]] \
		|| (bootstrap_m4) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/bison ]] \
		|| [[ $(bison --version 2>&1) == *"GNU Bison) "2.[3-7]* ]] \
		|| [[ $(bison --version 2>&1) == *"GNU Bison) "[3-9]* ]] \
		|| (bootstrap_bison) || return 1
	if [[ ! -x ${ROOT}/tmp/usr/bin/uniq ]]; then
		# If the system has a uniq, let's use it to test whether
		# coreutils is new enough (and GNU).
		if [[ $(uniq --version 2>&1) == *"(GNU coreutils) "[6789]* ]]; then
			CP="cp"
		else
			(bootstrap_coreutils) || return 1
		fi
	fi

	# But for e.g. BSD, it isn't going to be, so if our test failed,
	# use bootstrapped coreutils.
	[[ -z ${CP} ]] && CP="${ROOT}/tmp/bin/cp"

	[[ -x ${ROOT}/tmp/usr/bin/find ]] \
		|| [[ $(find --version 2>&1) == *GNU* ]] \
		|| (bootstrap_findutils) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/tar ]] \
		|| [[ $(tar --version 2>&1) == *GNU* ]] \
		|| (bootstrap_tar) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/grep ]] \
		|| [[ $(grep --version 2>&1) == *GNU* ]] \
		|| (bootstrap_grep) || return 1
	[[ -x ${ROOT}/tmp/usr/bin/gawk ]] \
		|| [[ $(awk --version < /dev/null 2>&1) == *GNU" Awk "[456789]* ]] \
		|| (bootstrap_gawk) || return 1
	# always build our own bash, for we don't know what devilish thing
	# we're working with now, bug #650284
	[[ -x ${ROOT}/tmp/usr/bin/bash ]] \
		|| (bootstrap_bash) || return 1

	# Some host tools need to be wrapped to be useful for us.
	# We put them in tmp/usr/local/bin, to not accidentally
	# be identified as stage1-installed like in bug #615410.
	mkdir -p "${ROOT}"/tmp/usr/local/bin
	case ${CHOST} in
		*-darwin*)
			# Recent Mac OS X have a nice popup to install java when
			# it's called without being installed, this doesn't stop the
			# process from going, but keeps popping up a dialog during
			# the bootstrap process, which is slightly anoying.
			# Nevertheless, we don't want Java when it's installed to be
			# detected, so hide during the stage builds
			{
				echo "#!$(type -P false)"
			} > "${ROOT}"/tmp/usr/local/bin/java
			cp "${ROOT}"/tmp/usr/local/bin/java{,c}
			chmod 755 "${ROOT}"/tmp/usr/local/bin/java{,c}
			;;
		*-linux*)
			if [[ ! -x "${ROOT}"/tmp/usr/bin/gcc ]] \
			&& [[ $(gcc -print-prog-name=as),$(gcc -print-prog-name=ld) != /*,/* ]]
			then
				# RHEL's system gcc is set up to use binutils via PATH search.
				# If the version of our binutils an older one, they may not
				# provide what the system gcc is configured to use.
				# We need to direct the system gcc to find the system binutils.
				EXEC="$(PATH="${ORIGINAL_PATH}" type -P gcc)"
				if [[ -z ${EXEC} ]] ; then
					eerror "could not find 'gcc' in your PATH!"
					eerror "please install gcc or provide access via PATH or symlink"
					return 1
				fi
				cat >> "${ROOT}"/tmp/usr/local/bin/gcc <<-EOF
					#! /bin/sh
					PATH="${ORIGINAL_PATH}" export PATH
					exec "${EXEC}" "\$@"
				EOF
				EXEC="$(PATH="${ORIGINAL_PATH}" type -P g++)"
				if [[ -z ${EXEC} ]] ; then
					eerror "could not find 'g++' in your PATH!"
					eerror "please install g++ or provide access via PATH or symlink"
					return 1
				fi
				cat >> "${ROOT}"/tmp/usr/local/bin/g++ <<-EOF
					#! /bin/sh
					PATH="${ORIGINAL_PATH}" export PATH
					exec "${EXEC}" "\$@"
				EOF
				chmod 755 "${ROOT}"/tmp/usr/local/bin/g{cc,++}
			fi
			;;
	esac

	# Host compiler can output a variety of libdirs.  At stage1,
	# they should be the same as lib.  Otherwise libffi may not be
	# found by python.  Don't do this when we're using a Gentoo host to
	# speed up bootstrapping, it should be good, and we shouldn't be
	# touching the host either.  Bug #927957
	if is-rap && [[ ! -L "${ROOT}"/tmp ]] ; then
		[[ -d ${ROOT}/tmp/usr/lib ]] || mkdir -p "${ROOT}"/tmp/usr/lib
		local libdir
		for libdir in lib64 lib32 libx32; do
			if [[ ! -L ${ROOT}/tmp/usr/${libdir} ]] ; then
				if [[ -e "${ROOT}"/tmp/usr/${libdir} ]] ; then
					echo "${ROOT}"/tmp/usr/${libdir} should be a symlink to lib
					return 1
				fi
				ln -s lib "${ROOT}"/tmp/usr/${libdir}
			fi
		done
	fi

	# important to have our own (non-flawed one) since Python (from
	# Portage) and binutils use it
	# note that this actually breaks the concept of stage1, this will be
	# compiled for the target prefix
	for zlib in "${ROOT}"/tmp/usr/lib*/libz.* ; do
		[[ -e ${zlib} ]] && break
		zlib=
	done
	[[ -n ${zlib} ]] || (bootstrap_zlib) || return 1
	for libffi in "${ROOT}"/tmp/usr/lib*/libffi.* ; do
		[[ -e ${libffi} ]] && break
		libffi=
	done
	[[ -n ${libffi} ]] || (bootstrap_libffi) || return 1
	# too vital to rely on a host-provided one
	[[ -x ${ROOT}/tmp/usr/bin/python ]] || (bootstrap_python) || return 1

	# cmake for llvm/clang toolchain on macOS
	[[ -e ${ROOT}/tmp/usr/bin/cmake ]] \
		|| [[ ${CHOST} != *-darwin* ]] \
		|| [[ ${DARWIN_USE_GCC} == 1 ]] \
		|| (bootstrap_cmake) || return 1

	# checks itself if things need to be done still
	(bootstrap_tree) || return 1

	# setup a profile
	[[ -e ${ROOT}/etc/portage/make.profile && \
		-e ${MAKE_CONF_DIR}/0100_bootstrap_prefix_make.conf ]] \
		|| (bootstrap_setup) || return 1

	# setup a profile for stage2
	mkdir -p "${ROOT}"/tmp/etc/. || return 1
	[[ -e ${ROOT}/tmp/etc/portage/make.profile ]] || \
		(
			"${CP}" -dpR "${ROOT}"/etc/portage "${ROOT}"/tmp/etc && \
			rm -f "${ROOT}"/tmp/etc/portage/make.profile && \
			(
				ROOT="${ROOT}"/tmp \
				PREFIX_DISABLE_RAP="yes" \
				BOOTSTRAP_STAGE="stage2" \
				bootstrap_profile
			)
		) || return 1

	# setup portage
	[[ -e ${ROOT}/tmp/usr/bin/emerge ]] || (bootstrap_portage) || return 1
	prepare_portage

	estatus "stage1 finished"
	einfo "stage1 successfully finished"
}

bootstrap_stage1_log() {
	{
		echo "===== stage 1 -- $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
		echo "CHOST:     ${CHOST}"
		echo "IDENT:     ${CHOST_IDENTIFY}"
		echo "==========================================="
	} >> "${ROOT}"/stage1.log
	bootstrap_stage1 "${@}" 2>&1 | tee -a "${ROOT}"/stage1.log
	local ret=${PIPESTATUS[0]}
	[[ ${ret} == 0 ]] && touch "${ROOT}"/.stage1-finished
	return "${ret}"
}

do_emerge_pkgs() {
	local opts=$1 ; shift
	local pkg vdb pvdb evdb
	for pkg in "$@"; do
		vdb=${pkg}
		if [[ ${vdb} == "="* ]] ; then
			vdb=${vdb#=}
		elif [[ ${vdb} == "<"* ]] ; then
			vdb=${vdb#<}
			vdb=${vdb%-r*}
			vdb=${vdb%-*}
			vdb=${vdb}-\*
		else
			vdb=${vdb}-\*
		fi
		for pvdb in "${EPREFIX}/var/db/pkg/${vdb%-*}"-* ; do
			if [[ -d ${pvdb} ]] ; then
				evdb=${pvdb##*/}
				if [[ ${pkg} == "="* ]] ; then
					# exact match required (* should work here)
					[[ ${evdb} == "${vdb##*/}" ]] && break
				else
					vdb=${vdb%-*}
					evdb=${evdb%-r*}
					evdb=${evdb%_p*}
					evdb=${evdb%-*}
					[[ ${evdb} == "${vdb#*/}" ]] && break
				fi
			fi
			pvdb=
		done
		[[ -n ${pvdb} ]] && continue

		# avoid many deps at this stage which aren't necessary, e.g.
		# having a bash without readline is OK, we're not using the
		# shell interactive
		local myuse=(
			"${DISABLE_USE[@]}"
			"-acl"
			"-berkdb"
			"-fortran"            # gcc
			"-gdbm"
			"-nls"
			"-pcre"
			"-python"
			"-qmanifest"          # portage-utils
			"-qtegrity"           # portage-utils
			"-readline"           # bash
			"-sanitize"
			"system-bootstrap"
			"clang"
			"internal-glib"
		)

		local skip_llvm_pkg_setup=
		if [[ ${CHOST}:${DARWIN_USE_GCC} == *-darwin*:0 ]] ; then
			# Clang-based Darwin
			myuse+=(
				"-binutils-plugin"
				"default-compiler-rt"
				"default-libcxx"
				"default-lld"
			)
			if [[ "${BOOTSTRAP_STAGE}" == stage2 ]] ; then
				myuse+=( "bootstrap-prefix" )
				skip_llvm_pkg_setup="yes"
			fi
		fi

		local override_make_conf_dir="${PORTAGE_OVERRIDE_EPREFIX}"
		override_make_conf_dir+="${MAKE_CONF_DIR#"${ROOT}"}"

		if [[ " ${USE} " == *" prefix-stack "* ]] &&
		   [[ ${PORTAGE_OVERRIDE_EPREFIX} == */tmp ]] &&
		   ! grep -Rq '^USE=".*" # by bootstrap-prefix.sh$' \
		   "${override_make_conf_dir}"
		then
			# With prefix-stack, the USE env var does apply to the stacked
			# prefix only, not the base prefix (any more? since some portage
			# version?), so we have to persist the base USE flags into the
			# base prefix - without the additional incoming USE flags.
			mkdir -p -- "${override_make_conf_dir}"
			echo "USE=\"\${USE} ${myuse[*]}\" # by bootstrap-prefix.sh" \
				>> "${override_make_conf_dir}/0101_bootstrap_prefix_stack.conf"
		fi
		local smyuse=" ${myuse[*]} "
		local use
		for use in ${USE} ; do
			smyuse=" ${smyuse/ ${use} /} "
			smyuse=" ${smyuse/ -${use} /} "
			smyuse=" ${smyuse/ ${use#-} /} "
			smyuse=" ${smyuse} ${use} "
		done
		read -r -a myuse <<< "${smyuse}"

		# Disable the STALE warning because the snapshot frequently gets stale.
		#
		# No need to spam the user about news until the final emerge @world
		# because the tools aren't available to read the news items yet anyway.
		#
		# Avoid circular deps caused by the default profiles (and IUSE
		# defaults).
		echo "USE=${myuse[*]} PKG=${pkg}"
		(
			local -a eopts
			read -r -a eopts <<< "${opts}"
			eopts=(
				"--color" "n"
				"-v"
				"--oneshot"
				"--root-deps"
				"${eopts[@]}"
			)
			estatus "${STAGE}: emerge ${pkg}"
			unset CFLAGS CXXFLAGS
			[[ -n ${OVERRIDE_CFLAGS} ]] \
				&& export CFLAGS="${OVERRIDE_CFLAGS}"
			[[ -n ${OVERRIDE_CXXFLAGS} ]] \
				&& export CXXFLAGS="${OVERRIDE_CXXFLAGS}"
			# In the stage3 bootstrap we always prefer to use tools that
			# have been built for stage3; to accomplish this we ensure
			# that it is the first thing evaluated in PATH.
			# Unfortunately, Portage, Python, and Python-exec are often
			# pulled into the depgraph at some point before we're fully
			# boostrapped. To ensure that we don't try and execute
			# ${EPREFIX}/usr/bin/emerge before we're ready, always
			# provide the full path to the bootstrap Python interpreter
			# and emerge script.
			PORTAGE_SYNC_STALE=0 \
			FEATURES="-news ${FEATURES}" \
			USE="${myuse[*]}" \
			LLVM_ECLASS_SKIP_PKG_SETUP="${skip_llvm_pkg_setup}" \
			"${ROOT}"/tmp/bin/python \
			"${ROOT}"/tmp/usr/bin/emerge "${eopts[@]}" "${pkg}"
		) || return 1
	done
}

bootstrap_stage2() {
	export PORTAGE_CONFIGROOT="${ROOT}"/tmp

	if ! type -P emerge > /dev/null ; then
		eerror "emerge not found, did you bootstrap stage1?"
		return 1
	fi

	# Find out what toolchain packages we need, and configure LDFLAGS
	# and friends.
	BOOTSTRAP_STAGE="stage2" configure_toolchain || return 1
	configure_cflags || return 1
	export CONFIG_SHELL="${ROOT}"/tmp/bin/bash
	export CC CXX

	emerge_pkgs() {
		EPREFIX="${ROOT}"/tmp \
		STAGE=stage2 \
		do_emerge_pkgs "$@"
	}

	# bison's configure checks for perl, but doesn't use it,
	# except for tests.  Since we don't want to pull in perl at this
	# stage, fake it
	PERL="$(which touch)" ; export PERL
	# GCC sometimes decides that it needs to run makeinfo to update some
	# info pages from .texi files.  Obviously we don't care at this
	# stage and rather have it continue instead of abort the build
	if [[ ! -x "${ROOT}"/tmp/usr/bin/makeinfo ]]
	then
		cat > "${ROOT}"/tmp/usr/bin/makeinfo <<-EOF
		#!${ROOT}/bin/bash
		### bootstrap-prefix.sh will act on this line ###
		echo "makeinfo GNU texinfo 4.13"
		f=
		while (( \$# > 0 )); do
		a=\$1
		shift
		case \$a in
		--output=) continue ;;
		--output=*) f=\${a#--output=} ;;
		-o) f=\$1; shift;;
		esac
		done
		[[ -z \$f ]] || [[ -e \$f ]] || touch "\$f"
		EOF
		cat > "${ROOT}"/tmp/usr/bin/install-info <<-EOF
		#!${ROOT}/bin/bash
		:
		EOF
		chmod +x "${ROOT}"/tmp/usr/bin/{makeinfo,install-info}
	fi

	# on Solaris 64-bits, (at least up to 10) libgcc_s resides in a
	# non-standard location, and the compiler doesn't seem to record
	# this in rpath while it does find it, resulting in a runtime trap
	if [[ ${CHOST} == x86_64-*-solaris* || ${CHOST} == sparcv9-*-solaris* ]] ;
	then
		local libgccs64=/usr/sfw/lib/64/libgcc_s.so.1
		[[ -e ${ROOT}/tmp/usr/bin/gcc ]] || \
			cp "${libgccs64}" "${ROOT}"/tmp/usr/lib/
		# save another copy for after gcc-config gets run and removes
		# usr/lib/libgcc_s.* because new links should use the compiler
		# specific libgcc_s, but existing objs need to find this
		# libgcc_s for as long as they are around (bash->libreadline)
		LDFLAGS="${LDFLAGS} -R${ROOT}/tmp/tmp"
		mkdir -p "${ROOT}"/tmp/tmp/
		cp "${libgccs64}" "${ROOT}"/tmp/tmp/
	fi

	# Disable RAP directory hacks of binutils and gcc.  If libc.so
	# linker script provides no hint of ld-linux*.so*, ld should
	# look into its default library path.  Prefix library paths
	# are taken care of by LDFLAGS in configure_cflags().
	# see profiles/features/prefix/standalone/profile.bashrc
	export BOOTSTRAP_RAP_STAGE2=yes

	# elt-patches needs gentoo-functions, but gentoo-functions these
	# days needs meson to install, which requires a properly installed
	# Python -- at this stage we don't have that
	# so fake gentoo-functions with some dummies to make elt-patches
	# and others install
	if [[ ! -e "${ROOT}"/tmp/lib/gentoo/functions.sh ]] ; then
		mkdir -p "${ROOT}"/tmp/lib/gentoo
		cat > "${ROOT}"/tmp/lib/gentoo/functions.sh <<-EOF
			#!${BASH}

			ewarn() {
			  echo $*
			}

			eerror() {
			  echo "!!! $*"
			}
		EOF
	fi

	# provide active SDK link on Darwin
	if [[ ${CHOST} == *-darwin* ]] ; then
		rm -f "${ROOT}"/tmp/MacOSX.sdk
		( cd "${ROOT}"/tmp && ln -s ../MacOSX.sdk MacOSX.sdk )
		if [[ ${DARWIN_USE_GCC} == 0 ]] ; then
			# Until proper clang is installed, just redirect calls to it
			# to the system's one. Libtool is here because its path is
			# passed to the compiler-rt and llvm's ebuilds.
			for bin in libtool clang clang++ ; do
				{
					echo "#!${ROOT}/tmp/bin/sh"
					echo "exec ${bin}"' "$@"'
				} > "${ROOT}/tmp/usr/bin/${CHOST}-${bin}"
				chmod +x "${ROOT}/tmp/usr/bin/${CHOST}-${bin}"
			done
		fi
	fi

	# Build a basic compiler and portage dependencies in $ROOT/tmp.
	pkgs=(
		sys-devel/gnuconfig
		app-portage/elt-patches
		sys-libs/ncurses
		sys-libs/readline
		app-shells/bash
		app-arch/xz-utils
		sys-apps/sed
		sys-apps/baselayout
		sys-devel/m4
		sys-devel/flex
		sys-apps/diffutils # needed by bison-3 build system
		sys-devel/bison
		sys-devel/patch
		sys-devel/binutils-config
	)

	# cmake has some external dependencies which require autoconf, etc.
	# unless we only build the buildtool, bug #603012
	echo "dev-build/cmake -server" >> "${ROOT}"/tmp/etc/portage/package.use

	mkdir -p "${ROOT}"/tmp/etc/portage/profile  # site-specific overrides
	if [[ ${CHOST} == *-solaris* ]] ; then
		# avoid complexities with the host toolchain
		echo "sys-devel/gcc -pie" >> \
			"${ROOT}"/tmp/etc/portage/profile/package.use.force
		echo "sys-devel/gcc -pie" >> "${ROOT}"/tmp/etc/portage/package.use
	fi

	# don't use CET, we don't know if the host compiler supports it
	echo "sys-devel/binutils -cet" >> \
		"${ROOT}"/tmp/etc/portage/profile/package.use.force

	emerge_pkgs --nodeps "${pkgs[@]}" || return 1

	for pkg in ${linker} ; do
		# Debian multiarch supported by RAP needs ld to support sysroot.
		EXTRA_ECONF=$(rapx --with-sysroot=/) \
		emerge_pkgs --nodeps "${pkg}" || return 1
	done

	# GCC doesn't respect CPPFLAGS because of its own meddling as well
	# as toolchain.eclass, so provide a wrapper here to force just
	# installed packages to be found
	mkdir -p "${ROOT}"/tmp/usr/local/bin
	rm -f "${ROOT}"/tmp/usr/local/bin/my{gcc,g++}
	cat > "${ROOT}/tmp/usr/local/bin/mygcc" <<-EOS
		#!/usr/bin/env sh
		exec ${CC} "\$@" ${CPPFLAGS}
	EOS
	cat > "${ROOT}/tmp/usr/local/bin/myg++" <<-EOS
		#!/usr/bin/env sh
		exec ${CXX} "\$@" ${CPPFLAGS}
	EOS
	chmod 755 "${ROOT}/tmp/usr/local/bin/my"{gcc,g++}

	for pkg in ${compiler_stage1} ; do
		# <glibc-2.5 does not understand .gnu.hash, use
		# --hash-style=both to produce also sysv hash.
		# GCC apparently drops CPPFLAGS at some point, which makes it
		# not find things like gmp which we just installed, so force it
		# to find our prefix
		EXTRA_ECONF="$(rapx --with-linker-hash-style=both) --with-local-prefix=${ROOT}" \
		MYCMAKEARGS="-DCMAKE_USE_SYSTEM_LIBRARY_LIBUV=OFF" \
		GCC_MAKE_TARGET=all \
		OVERRIDE_CFLAGS="${CPPFLAGS} ${OVERRIDE_CFLAGS}" \
		OVERRIDE_CXXFLAGS="${CPPFLAGS} ${OVERRIDE_CXXFLAGS}" \
		CC=mygcc CXX=myg++ \
		PYTHON_COMPAT_OVERRIDE=python$(python_ver) \
		emerge_pkgs --nodeps "${pkg}" || return 1

		if [[ "${pkg}" == *sys-devel/llvm* || ${pkg} == *sys-devel/clang* ]] ;
		then
			# we need llvm/clang ASAP for libcxx* doesn't build
			# without C++11
			[[ -x ${ROOT}/tmp/usr/bin/clang   ]] && CC=clang
			[[ -x ${ROOT}/tmp/usr/bin/clang++ ]] && CXX=clang++
		fi
	done

	if [[ ${compiler_type} == clang ]] ; then
		if [[ ${CHOST} == *-darwin* ]] ; then
			# Stop using host's compilers, but still need 'libtool' in PATH.
			rm "${ROOT}/tmp/usr/bin/${CHOST}"-{libtool,clang,clang++}
			mkdir -p "${ROOT}"/usr/bin
			ln -s "${ROOT}"/tmp/usr/lib/llvm/*/bin/llvm-libtool-darwin \
				"${ROOT}"/usr/bin/libtool
		fi

		# We use Clang as our toolchain compiler, so we need to make
		# sure we actually use it
		mkdir -p -- "${MAKE_CONF_DIR}"
		{
			echo
			echo "# System compiler on $(uname) Prefix is Clang, do not remove this"
			echo "AS=\"${CHOST}-clang -c\""
			echo "CPP=${CHOST}-clang-cpp"
			echo "CC=${CHOST}-clang"
			echo "CXX=${CHOST}-clang++"
			echo "OBJC=${CHOST}-clang"
			echo "OBJCXX=${CHOST}-clang++"
			echo "BUILD_CC=${CHOST}-clang"
			echo "BUILD_CXX=${CHOST}-clang++"
		} >> "${MAKE_CONF_DIR}/0100_bootstrap_prefix_clang.conf"

		# llvm won't setup symlinks to CHOST-clang here because
		# we're in a cross-ish situation (at least according to
		# multilib.eclass -- can't blame it at this point really)
		# do it ourselves here to make the bootstrap continue
		if [[ -x "${ROOT}"/tmp/usr/bin/${CHOST}-clang ]] ; then
			( cd "${ROOT}"/tmp/usr/bin && \
				ln -s clang "${CHOST}-clang" && \
				ln -s clang++ "${CHOST}-clang++" )
		fi
	elif ! is-rap ; then
		# make sure the EPREFIX gcc shared libraries are there
		mkdir -p "${ROOT}/usr/${CHOST}/lib/gcc"
		cp "${ROOT}/tmp/usr/${CHOST}/lib/gcc"/* "${ROOT}/usr/${CHOST}/lib/gcc"
	fi

	estatus "stage2 finished"
	einfo "stage2 successfully finished"
}

bootstrap_stage2_log() {
	{
		echo "===== stage 2 -- $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
		echo "CHOST:     ${CHOST}"
		echo "IDENT:     ${CHOST_IDENTIFY}"
		echo "==========================================="
	} >> "${ROOT}"/stage2.log
	bootstrap_stage2 "${@}" 2>&1 | tee -a "${ROOT}"/stage2.log
	local ret=${PIPESTATUS[0]}
	[[ ${ret} == 0 ]] && touch "${ROOT}/.stage2-finished"
	return "${ret}"
}

bootstrap_stage3() {
	export PORTAGE_CONFIGROOT="${ROOT}"

	# We need the stage2 in PATH for bootstrapping.  We rely on
	# emerge running on some benign package before running anything
	# that would rely on 98stage2 coming before 99host
	mkdir -p "${ROOT}"/etc/env.d/
	cat > "${ROOT}"/etc/env.d/98stage2 <<-EOF
		PATH="$(unset PATH;
			source "${ROOT}"/tmp/etc/profile.env;
			echo "$PATH")"
	EOF

	if ! type -P emerge > /dev/null ; then
		eerror "emerge not found, did you bootstrap stage1?"
		return 1
	fi

	# At this point, we should have a proper GCC, and don't need to
	# rely on the system wrappers.  Let's get rid of them, so that
	# they stop mucking up builds.
	rm -f "${ROOT}"/tmp/usr/local/bin/{,my,${CHOST}-}{gcc,g++}

	BOOTSTRAP_STAGE=stage3 configure_toolchain || return 1

	if [[ ${compiler_type} == clang ]] ; then
		if ! type -P clang > /dev/null ; then
			eerror "clang not found, did you bootstrap stage2?"
			return 1
		fi
	else
		if ! type -P gcc > /dev/null ; then
			eerror "gcc not found, did you bootstrap stage2?"
			return 1
		fi
	fi

	# If we resume this stage and python-exec was installed already in
	# tmp, we basically made the system unusable, so remove python-exec
	# here so we can use the python in tmp
	for pef in python{,3} python{,3}-config ; do
		rm -f "${ROOT}/tmp/usr/bin/${pef}"
		[[ ${pef} == *-config ]] && ppf=-config || ppf=
		( cd "${ROOT}"/tmp/usr/bin && \
			ln -s "python$(python_ver)${ppf}" "${pef}" )
	done

	get_libdir() {
		local l
		l="$(portageq envvar "LIBDIR_$(portageq envvar ABI)" 2>/dev/null)"
		[[ -z ${l} ]] && l=lib
		echo "${l}"
	}

	# Remember: binutils-config and gcc were built in ROOT/tmp, so they
	# are looking for includes and libraries under ROOT/tmp, *NOT* ROOT,
	# therefore we need to export search paths for ROOT (the final
	# destination Prefix) here until we've installed the toolchain
	export CONFIG_SHELL="${ROOT}"/tmp/bin/bash
	[[ ${compiler_type} == gcc ]] && \
		export CPPFLAGS="-isystem ${ROOT}/usr/include"
	LDFLAGS="-L${ROOT}/usr/$(get_libdir)" ; export LDFLAGS
	[[ ${CHOST} == *-darwin* ]] || \
		LDFLAGS+=" -Wl,-rpath=${ROOT}/usr/$(get_libdir)"
	unset CC CXX

	emerge_pkgs() {
		# stage3 tools should be used first.
		# PORTAGE_TMPDIR, EMERGE_LOG_DIR are needed with host portage.
		#
		# After the introduction of EAPI-7, eclasses now
		# strictly distinguish between build dependencies that
		# are binary compatible with the native build system
		# (CBUILD, BDEPEND) and with the system being built
		# (CHOST, RDEPEND).  To correctly bootstrap stage3,
		# PORTAGE_OVERRIDE_EPREFIX as BROOT is needed.
		EPREFIX="${ROOT}" PORTAGE_TMPDIR="${PORTAGE_TMPDIR}" \
		EMERGE_LOG_DIR="${ROOT}"/var/log \
		STAGE=stage3 \
		do_emerge_pkgs "$@"
	}

	# retained in case we *do* need this, but using this will cause
	# packages installed end up in ROOT/tmp, which means we keep using
	# stage2 area and config which breaks things like binutils-config'
	# path search, so don't use this
	#with_stack_emerge_pkgs() {
	#	# keep FEATURES=stacked-prefix until we bump portage in stage1
	#	FEATURES="${FEATURES} stacked-prefix" \
	#	USE="${USE} prefix-stack" \
	#	PORTAGE_OVERRIDE_EPREFIX="${ROOT}/tmp" \
	#	emerge_pkgs "$@"
	#}

	# pre_emerge_pkgs relies on stage 2 portage, but installs into the
	# final destination Prefix
	pre_emerge_pkgs() {
		PORTAGE_OVERRIDE_EPREFIX="${ROOT}" \
		emerge_pkgs "$@"
	}

	# Some packages fail to properly depend on sys-apps/texinfo.
	# We don't really need that package, so we fake it instead,
	# explicitly emerging it later on will overwrite the fakes.
	if [[ ! -x "${ROOT}"/usr/bin/makeinfo ]]
	then
		cp -p "${ROOT}"/tmp/usr/bin/{makeinfo,install-info} "${ROOT}"/usr/bin
	fi

	# Bug 655414, 676096.
	# Portage does search it's global config using PORTAGE_OVERRIDE_EPREFIX,
	# so we need to provide it there - emerging portage itself is expected
	# to finally overwrite it.
	if [[ ! -d "${ROOT}"/usr/share/portage ]]; then
		mkdir -p "${ROOT}"/usr/share
		cp -a "${ROOT}"{/tmp,}/usr/share/portage
	fi

	local -a linker_pkgs compiler_pkgs
	read -r -a linker_pkgs <<< "${linker}"
	read -r -a compiler_pkgs <<< "${compiler}"

	# We need gentoo-functions but it meson is still a no-go, because we
	# don't have a Python.  Why would such simple package with a silly
	# script file need meson is beyond me.  So, we have no other way
	# than to fake it here for the time being like in stage2.
	if [[ ! -e "${ROOT}"/lib/gentoo/functions.sh ]] ; then
		mkdir -p "${ROOT}"/lib/gentoo
		cp "${ROOT}"/tmp/lib/gentoo/functions.sh \
			"${ROOT}"/lib/gentoo/functions.sh
	fi

	if is-rap ; then
		# We need ${ROOT}/usr/bin/perl to merge glibc.
		if [[ ! -x "${ROOT}"/usr/bin/perl ]]; then
			# trick "perl -V:apiversion" check of glibc-2.19.
			echo -e "#!${ROOT}/bin/sh\necho 'apiversion=9999'" \
				> "${ROOT}"/usr/bin/perl
			chmod +x "${ROOT}"/usr/bin/perl
		fi

		# Need rsync to for linux-headers installation
		if [[ ! -x "${ROOT}"/usr/bin/rsync ]]; then
			cat > "${ROOT}"/usr/bin/rsync <<-EOF
		#!${ROOT}/bin/bash
		while (( \$# > 0 )); do
		case \$1 in
		-*) shift; continue ;;
		*) break ;;
		esac
		done
		dst="\$2"/\$(basename \$1)
		mkdir -p "\${dst}"
		cp -rv \$1/* "\${dst}"/
		EOF
			chmod +x "${ROOT}"/usr/bin/rsync
		fi

		# Tell dynamic loader the path of libgcc_s.so of stage2
		if [[ ! -f "${ROOT}"/etc/ld.so.conf.d/stage2.conf ]]; then
			mkdir -p "${ROOT}"/etc/ld.so.conf.d
			dirname "$(gcc -print-libgcc-file-name)" \
				> "${ROOT}"/etc/ld.so.conf.d/stage2.conf
		fi

		pkgs=(
			sys-devel/gnuconfig
			sys-apps/baselayout
			app-portage/elt-patches
			sys-kernel/linux-headers
			sys-libs/glibc
		)

		BOOTSTRAP_RAP=yes \
		pre_emerge_pkgs --nodeps "${pkgs[@]}" || return 1
		grep -q 'apiversion=9999' "${ROOT}"/usr/bin/perl && \
			rm "${ROOT}"/usr/bin/perl
		grep -q 'esac' "${ROOT}"/usr/bin/rsync && \
			rm "${ROOT}"/usr/bin/rsync

		# sys-apps/baselayout will install a dummy openrc-run wrapper
		# for any package that installs an init.d script, like rsync and
		# python will need openrc-run to exist, else we'll die with a QA
		# error, bug #858596.  However it only does this for
		# prefix-guest, so NOT For RAP, which results in bug #913856.
		if [[ ! -x "${ROOT}"/sbin/openrc-run ]]; then
			[[ -e "${ROOT}"/sbin ]] || mkdir -p "${ROOT}"/sbin
			echo "We need openrc-run at ${ROOT}/sbin to merge some packages." \
				> "${ROOT}"/sbin/openrc-run
			chmod +x "${ROOT}"/sbin/openrc-run
		fi

		pkgs=(
			sys-devel/binutils-config
			sys-libs/zlib
			"${linker_pkgs[@]}"
		)
		# use the new dynamic linker in place of rpath from now on.
		RAP_DLINKER=$(echo "${ROOT}/$(get_libdir)"/ld*.so.[0-9] | sed s"!${ROOT}/$(get_libdir)/ld-lsb.*!!")
		export CPPFLAGS="--sysroot=${ROOT}"
		export LDFLAGS="-Wl,--dynamic-linker=${RAP_DLINKER}"
		# make sure these flags are used even in places that ignore/strip CPPFLAGS/LDFLAGS
		export CC="gcc ${CPPFLAGS} ${LDFLAGS}"
		export CXX="g++ ${CPPFLAGS} ${LDFLAGS}"
		BOOTSTRAP_RAP=yes \
		pre_emerge_pkgs --nodeps "${pkgs[@]}" || return 1

		# avoid circular deps with sys-libs/pam, bug#712020
		pkgs=(
			sys-apps/attr
			sys-libs/libcap
			sys-libs/libxcrypt
		)
		BOOTSTRAP_RAP=yes \
		USE="${USE} -pam" \
		pre_emerge_pkgs --nodeps "${pkgs[@]}" || return 1
	else
		pkgs=(
			sys-devel/gnuconfig
			app-portage/elt-patches
			app-arch/xz-utils
			sys-apps/sed
			sys-apps/baselayout
			sys-devel/m4
			sys-devel/flex
			sys-devel/binutils-config
			sys-libs/zlib
			"${linker_pkgs[@]}"
		)

		pre_emerge_pkgs --nodeps "${pkgs[@]}" || return 1
	fi
	# remove stage2 ld so that stage3 ld is used by stage2 gcc.
	is-rap && [[ -f ${ROOT}/tmp/usr/${CHOST}/bin/ld ]] && \
		mv "${ROOT}/tmp/usr/${CHOST}/bin"/ld{,.stage2}

	# On some hosts, gcc gets confused now when it uses the new linker,
	# see for instance bug #575480.  While we would like to hide that
	# linker, we can't since we want the compiler to pick it up.
	# Therefore, inject some kludgy workaround, for deps like gmp that
	# use c++
	[[ ${CHOST} != *-darwin* ]] && ! is-rap && export CXX="${CHOST}-g++ -lgcc_s"

	# Clang unconditionally requires python, the eclasses are really not
	# setup for a scenario where python doesn't live in the target
	# prefix and no helpers are available
	( cd "${ROOT}"/usr/bin && test ! -e python && \
		ln -s "${ROOT}/tmp/usr/bin/python$(python_ver)" "python$(python_ver)" )
	# in addition, avoid collisions
	rm -Rf "${ROOT}/tmp/usr/lib/python$(python_ver)/site-packages/clang"

	# Try to get ourself out of the mud, bug #575324
	EXTRA_ECONF="--disable-compiler-version-checks $(rapx '--disable-lto --disable-bootstrap')" \
	GCC_MAKE_TARGET="$(rapx all)" \
	MYCMAKEARGS="-DCMAKE_USE_SYSTEM_LIBRARY_LIBUV=OFF" \
	PYTHON_COMPAT_OVERRIDE="python$(python_ver)" \
	pre_emerge_pkgs --nodeps "${compiler_pkgs[@]}" || return 1

	if [[ ${CHOST}:${DARWIN_USE_GCC} == *-darwin*:0 ]] ; then
		# At this point our libc++abi.dylib is dynamically linked to
		# /usr/lib/libc++abi.dylib. That causes issues with perl later. Force
		# rebuild of sys-libs/libcxxabi to break this link.
		rm -Rf "${ROOT}/var/db/pkg/sys-libs/libcxxabi"*
		PYTHON_COMPAT_OVERRIDE=python$(python_ver) \
			pre_emerge_pkgs --nodeps "sys-libs/libcxxabi" || return 1

		# Make ${CHOST}-libtool (used by compiler-rt's and llvm's ebuild) to
		# point at the correct libtool in stage3. Resolve it in runtime, to
		# support llvm version upgrades.
		rm -f ${ROOT}/usr/bin/${CHOST}-libtool
		{
			echo "#!${ROOT}/bin/sh"
			echo 'exec llvm-libtool-darwin "$@"'
		} > "${ROOT}"/usr/bin/${CHOST}-${bin}

		# Now clang is ready, can use it instead of /usr/bin/gcc
		# TODO: perhaps symlink the whole etc/portage instead?
		ln -s -f "${ROOT}/etc/portage/make.profile" \
			"${ROOT}/tmp/etc/portage/make.profile"
		cp "${ROOT}/etc/portage/make.conf/0100_bootstrap_prefix_clang.conf" \
			"${ROOT}/tmp/etc/portage/make.conf/"
	fi

	# Undo libgcc_s.so path of stage2
	# Now we have the compiler right there
	unset CC CXX CPPFLAGS LDFLAGS

	rm -f "${ROOT}"/etc/ld.so.conf.d/stage2.conf

	# need special care, it depends on texinfo, #717786
	pre_emerge_pkgs --nodeps sys-apps/gawk || return 1

	( cd "${ROOT}"/usr/bin && test ! -e python && rm -f "python$(python_ver)" )
	# Use $ROOT tools where possible from now on.
	if [[ $(readlink "${ROOT}"/bin/sh) == "${ROOT}/tmp/"* ]] ; then
		rm -f "${ROOT}"/bin/sh
		ln -s bash "${ROOT}"/bin/sh
	fi

	if [[ "${compiler_type}" == clang ]] ; then
		if [[ ! -e "${ROOT}"/tmp/etc/env.d/11stage3-llvm ]]; then
			ln -s "${ROOT}"/etc/env.d/60llvm-* \
				"${ROOT}"/tmp/etc/env.d/11stage3-llvm
		fi
		# Prevent usage of AppleClang aka gcc for bad packages which ignore $CC
		if [[ ! -e "${ROOT}"/usr/bin/gcc ]]; then
			echo "#!${ROOT}/bin/bash" > "${ROOT}"/usr/bin/gcc
			echo "false ${CHOST}-clang \"\$@\"" >> "${ROOT}"/usr/bin/gcc
		fi
		if [[ ! -e "${ROOT}"/usr/bin/g++ ]]; then
			echo "#!${ROOT}/bin/bash" > "${ROOT}"/usr/bin/g++
			echo "false ${CHOST}-clang++ \"\$@\"" >> "${ROOT}"/usr/bin/g++
		fi
		chmod +x "${ROOT}"/usr/bin/{gcc,g++}
		if [[ ${CHOST} == *-darwin* ]]; then
			if [[ ! -e "${ROOT}"/usr/bin/ld ]]; then
				echo "#!${ROOT}/bin/bash" > "${ROOT}"/usr/bin/ld
				echo "false ld64.lld \"\$@\"" >> "${ROOT}"/usr/bin/ld
			fi
			chmod +x "${ROOT}"/usr/bin/ld
		fi
	fi
	
	# Start using apps from the final destination Prefix
	cat > "${ROOT}"/tmp/etc/env.d/10stage3 <<-EOF
		PATH="${ROOT}/usr/bin:${ROOT}/bin"
	EOF
	"${ROOT}"/tmp/usr/sbin/env-update

	# Get a sane bash, overwriting tmp symlinks
	pre_emerge_pkgs "" "app-shells/bash" || return 1

	# now we have a shell right there
	unset CONFIG_SHELL

	# Build portage dependencies.
	pkgs=(
		sys-apps/coreutils
		sys-apps/findutils
		app-arch/gzip
		app-arch/tar
		sys-apps/grep
		dev-build/make
		sys-apps/file
		app-admin/eselect
	)

	# For grep we need to do a little workaround as we might use llvm-3.4
	# here, which doesn't necessarily grok the system headers on newer
	# OSX, confusing the buildsystem
	ac_cv_c_decl_report=warning \
	TIME_T_32_BIT_OK=yes \
	pre_emerge_pkgs "" "${pkgs[@]}" || return 1

	pkgs=(
		virtual/os-headers
		sys-devel/gettext
		sys-apps/portage
		sys-apps/gentoo-functions
	)

	pre_emerge_pkgs "" "${pkgs[@]}" || return 1

	# Switch to the proper portage.
	hash -r

	# Update the portage tree.
	estatus "stage3: updating Portage tree"
	treedate=$(date -f "${PORTDIR}"/metadata/timestamp +%s)
	nowdate=$(date +%s)
	[[ ( ! -e ${PORTDIR}/.unpacked ) && \
		$((nowdate - (60 * 60 * 24))) -lt ${treedate} ]] || \
	if [[ ${OFFLINE_MODE} ]]; then
		# --keep used ${DISTDIR}, which make it easier to download a
		# snapshot beforehand
		emerge-webrsync --keep || return 1
	else
		emerge --color n --sync || emerge-webrsync || return 1
	fi

	# Avoid installing git or encryption just for fun while completing @system
	# e.g. bug #901101, this is a reduced (e.g. as minimal as possible)
	# set of DISABLE_USE, to set the stage for solving circular
	# dependencies, such as:
	export USE="${DISABLE_USE[*]}"

	# Portage should figure out itself what it needs to do, if anything.
	local eflags=( "--deep" "--update" "--changed-use" "@system" )
	einfo "running emerge ${eflags[*]}"
	estatus "stage3: emerge ${eflags[*]}"
	emerge --color n -v "${eflags[@]}" || return 1

	# gcc no longer depends on sys-devel/binutils which means it is to
	# be depcleaned at this point, quite strange, but to prevent this
	# from happening, add to the worldfile #936629#c5
	emerge --color n --noreplace sys-devel/binutils

	# Remove the stage2 hack from above.  A future emerge run will
	# get env-update to happen.
	rm "${ROOT}"/etc/env.d/98stage2

	# now try and get things in the way they should be according to the
	# default USE-flags
	unset USE

	# re-emerge anything hopefully not running into circular deps
	eflags=( "--deep" "--changed-use" "@world" )
	einfo "running emerge ${eflags[*]}"
	estatus "stage3: emerge ${eflags[*]}"
	emerge --color n -v "${eflags[@]}" || return 1

	# Remove anything that we don't need (compilers most likely)
	einfo "running emerge --depclean"
	estatus "stage3: emerge --depclean"
	emerge --color n --depclean

	# "wipe" mtimedb such that the resume list is proper after this stage
	# (--depclean may fail, which is ok)
	sed -i -e 's/resume/cleared/' "${ROOT}"/var/cache/edb/mtimedb

	estatus "stage3 finished"
	einfo "stage3 successfully finished"
}

bootstrap_stage3_log() {
	{
		echo "===== stage 3 -- $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
		echo "CHOST:     ${CHOST}"
		echo "IDENT:     ${CHOST_IDENTIFY}"
		echo "==========================================="
	} >> "${ROOT}"/stage3.log
	bootstrap_stage3 "${@}" 2>&1 | tee -a "${ROOT}"/stage3.log
	local ret=${PIPESTATUS[0]}
	[[ ${ret} == 0 ]] && touch "${ROOT}/.stage3-finished"
	return "${ret}"
}

set_helper_vars() {
	CXXFLAGS="${CXXFLAGS:-${CFLAGS}}"
	export PORTDIR=${PORTDIR:-"${ROOT}/var/db/repos/gentoo"}
	export DISTDIR=${DISTDIR:-"${ROOT}/var/cache/distfiles"}
	PORTAGE_TMPDIR=${PORTAGE_TMPDIR:-${ROOT}/var/tmp}
	MAKE_CONF_DIR="${ROOT}/etc/portage/make.conf/"
	DISTFILES_URL=${DISTFILES_URL:-"http://dev.gentoo.org/~grobian/distfiles"}
	GNU_URL=${GNU_URL:="http://ftp.gnu.org/gnu"}
	DISTFILES_G_O="http://distfiles.prefix.bitzolder.nl"
	DISTFILES_PFX="http://distfiles.prefix.bitzolder.nl/prefix"
	GENTOO_MIRRORS=${GENTOO_MIRRORS:="http://distfiles.gentoo.org"}
	SNAPSHOT_HOST=$(rapx http://distfiles.gentoo.org http://rsync.prefix.bitzolder.nl)
	SNAPSHOT_URL=${SNAPSHOT_URL:-"${SNAPSHOT_HOST}/snapshots"}

	# USE-flags to disable during bootstrap for they produce
	# unnecessary, or worse: circular deps #901101, #936629
	# - nghttp2 -> cmake -> curl -> nghttp2  (http2)
	DISABLE_USE=(
		"-crypt"
		"-curl_quic_openssl"  # curl
		"-git"
		"-http2"              # curl
		"-http3"              # curl
		"-quic"               # curl
	)

	export MAKE CONFIG_SHELL
}

bootstrap_interactive() {
	# TODO should immediately die on platforms that we know are
	# impossible due to extremely hard dependency chains
	# (NetBSD/OpenBSD)

	cat <<"EOF"


                                             .
       .vir.                                d$b
    .d$$$$$$b.    .cd$$b.     .d$$b.   d$$$$$$$$$$$b  .d$$b.      .d$$b.
    $$$$( )$$$b d$$$()$$$.   d$$$$$$$b Q$$$$$$$P$$$P.$$$$$$$b.  .$$$$$$$b.
    Q$$$$$$$$$$B$$$$$$$$P"  d$$$PQ$$$$b.   $$$$.   .$$$P' `$$$ .$$$P' `$$$
      "$$$$$$$P Q$$$$$$$b  d$$$P   Q$$$$b  $$$$b   $$$$b..d$$$ $$$$b..d$$$
     d$$$$$$P"   "$$$$$$$$ Q$$$     Q$$$$  $$$$$   `Q$$$$$$$P  `Q$$$$$$$P
    $$$$$$$P       `"""""   ""        ""   Q$$$P     "Q$$$P"     "Q$$$P"
    `Q$$P"                                  """

             Welcome to the Gentoo Prefix interactive installer!


    I will attempt to install Gentoo Prefix on your system.  To do so, I'll
    ask  you some questions first.    After that,  you'll have to  practise
    patience as your computer and I try to figure out a way to get a lot of
    software  packages  compiled.    If everything  goes according to plan,
    you'll end up with what we call  "a Prefix install",  but by that time,
    I'll tell you more.


EOF
	[[ ${TODO} == 'noninteractive' ]] && ans=yes ||
	read -r -p "Do you want me to start off now? [Yn] " ans
	case "${ans}" in
		[Yy][Ee][Ss]|[Yy]|"")
			: ;;
		*)
			echo "Right.  Aborting..."
			exit 1
			;;
	esac

	if [[ ${UID} == 0 ]] ; then
		cat << EOF

Hmmm, you appear to be root, or at least someone with UID 0.  I really
don't like that.  The Gentoo Prefix people really discourage anyone
running Gentoo Prefix as root.  As a matter of fact, I'm just refusing
to help you any further here.
If you insist, you'll have go without my help, or bribe me.
EOF
		exit 1
	fi
	echo
	echo "It seems to me you are '${USER:-$(whoami 2> /dev/null)}' (${UID}), that looks cool to me."

	# In case $ROOT were specified as $1, use it
	[[ -z "${EPREFIX}" ]] && EPREFIX="${ROOT}"

	echo
	echo "I'm going to check for some variables in your environment now:"
	local flag dvar badflags=
	for flag in \
		ASFLAGS \
		CFLAGS \
		CPPFLAGS \
		CXXFLAGS \
		DYLD_LIBRARY_PATH \
		GREP_OPTIONS \
		LDFLAGS \
		LD_LIBRARY_PATH \
		LIBPATH \
		PERL_MM_OPT \
		PERL5LIB \
		PKG_CONFIG_PATH \
		PYTHONPATH \
		ROOT \
		CPATH \
		LIBRARY_PATH \
	; do
		# starting on purpose a shell here iso ${!flag} because I want
		# to know if the shell initialisation files trigger this
		# note that this code is so complex because it handles both
		# C-shell as well as *sh
		dvar="echo \"((${flag}=\${${flag}}))\""
		dvar="$(echo "${dvar}" | env -i HOME="${HOME}" "$SHELL" -l 2>/dev/null)"
		if [[ ${dvar} == *"((${flag}="?*"))" ]] ; then
			badflags="${badflags} ${flag}"
			dvar=${dvar#*"((${flag}="}
			dvar=${dvar%%))*}
			echo "  uh oh, ${flag}=${dvar} :("
		else
			echo "  it appears ${flag} is not set :)"
		fi
		# unset for the current environment
		unset ${flag}
	done
	if [[ -n ${badflags} ]] ; then
		cat << EOF

Ahem, your shell environment contains some variables I'm allergic to:
 ${badflags}
These flags can and will influence the way in which packages compile.
In fact, they have a long standing tradition to break things.  I really
prefer to be on my own here.  So please make sure you disable these
environment variables in your shell initialisation files.  After you've
done that, you can run me again.
EOF
		exit 1
	fi
	echo
	echo "I'm excited!  Seems we can finally do something productive now."

	cat << EOF

Ok, I'm going to do a little bit of guesswork here.  Thing is, your
machine appears to be identified by CHOST=${CHOST}.
EOF
	case "${CHOST}" in
		powerpc*|ppc*|sparc*)
			cat << EOF

To me, it seems to be a big-endian machine.  I told you before you need
patience, but with your machine, regardless how many CPUs you have, you
need some more.  Context switches are just expensive, and guess what
fork/execs result in all the time.  I'm going to make it even worse for
you, configure and make typically are fork/exec bombs.
I'm going to assume you're actually used to having patience with this
machine, which is good, because I really love a box like yours!
EOF
			;;
	esac

	# eventually the user does know where to find a compiler
	[[ ${TODO} == 'noninteractive' ]] &&
	usergcc=$(type -P gcc 2>/dev/null)

	# the standard path we want to start with, override anything from
	# the user on purpose
	PATH="/usr/bin:/bin"
	# don't exclude the path to bash if it isn't in a standard location
	type -P bash > /dev/null || PATH="${BASH%/bash}:${PATH}"
	case "${CHOST}" in
		*-solaris*)
			cat << EOF

Ok, this is Solaris, or a derivative like OpenSolaris or OpenIndiana.
Sometimes, useful tools necessary at this stage are hidden.  I'm going
to check if that's the case for your system too, and if so, add those
locations to your PATH.
EOF
			# could do more "smart" CHOST deductions here, but brute
			# force is most likely as quick, but simpler
			[[ -d /usr/sfw/bin ]] \
				&& PATH="${PATH}:/usr/sfw/bin"
			[[ -d /usr/sfw/i386-sun-solaris${CHOST##*-solaris}/bin ]] \
				&& PATH="${PATH}:/usr/sfw/i386-sun-solaris${CHOST##*-solaris}/bin"
			[[ -d /usr/sfw/sparc-sun-solaris${CHOST##*-solaris}/bin ]] \
				&& PATH="${PATH}:/usr/sfw/sparc-sun-solaris${CHOST##*-solaris}/bin"
			# OpenIndiana 151a5
			[[ -d /usr/gnu/bin ]] && PATH="${PATH}:/usr/gnu/bin"
			# SmartOS
			[[ -d /opt/local/gcc7/bin ]] && PATH="${PATH}:/opt/local/gcc7/bin"
			[[ -d /opt/local/gcc47/bin ]] && PATH="${PATH}:/opt/local/gcc47/bin"
			;;
		*-darwin1*)
			# Apple ships a broken clang by default, fun!
			[[ -e /Library/Developer/CommandLineTools/usr/bin/clang ]] \
				&& PATH="/Library/Developer/CommandLineTools/usr/bin:${PATH}"
			;;
	esac

	# TODO: should we better use cc here? or check both?
	if ! type -P gcc > /dev/null && ! type -P clang > /dev/null ; then
		case "${CHOST}" in
			*-darwin*)
				cat << EOF

Uh oh... a Mac OS X system, but without compiler.  You must have
forgotten to install Xcode tools.  If your Mac didn't come with an
install DVD (pre Lion) you can find it in the Mac App Store, or download
the Xcode command line tools from Apple Developer Connection.  If you
did get a CD/DVD with your Mac, there is a big chance you can find Xcode
on it, and install it right away.
Please do so, and try me again!
EOF
				exit 1
				;;
			*-solaris2.[789]|*-solaris2.10)
				cat << EOF

Yikes!  Your Solaris box doesn't come with gcc in /usr/sfw/blabla/bin?
What good is it to me then?  I can't find a compiler!  I'm afraid
you'll have to find a way to install the Sun FreeWare tools somehow, is
it on the Companion disc perhaps?
See me again when you figured it out.
EOF
				exit 1
				;;
			*-solaris*)
				SOLARIS_RELEASE=$(head -n1 /etc/release)
				if [[ ${SOLARIS_RELEASE} == *"Oracle Solaris"* ]] ; then
					cat << EOF
Seems like you have installed Oracle Solaris ${SOLARIS_RELEASE}.
I suppose you have solaris publisher set.  If not, use:
  pkg set-publisher -p http://pkg.oracle.com/solaris/release
You need to install some necessary packages:
  pkg install developer/gcc-45 system/header
In the meanwhile, I'll wait here until you run me again, with a compiler.
EOF
				else
					cat << EOF

Sigh.  This is OpenSolaris or OpenIndiana?  I can't tell the difference
without looking more closely.  What I DO know, is that there is no
compiler, at least not where I was just looking, so how do we continue
from here, eh?  I just think you didn't install one.  I know it can be
tricky on OpenIndiana, for instance, so won't blame you.  In case you're
on OpenIndiana, I'll help you a bit.  Perform the following as
super-user:
  pkg install developer/gnu system/header
In the meanwhile, I'll wait here until you run me again, with a compiler.
EOF
				fi
				exit 1
				;;
			*)
				cat << EOF

Well, well... let's make this painful situation as short as it can be:
you don't appear to have a compiler around for me to play with.
Since I like your PATH to be as minimal as possible, I threw away
everything you put in it, and started from scratch.  Perhaps, the almost
impossible happened that I was wrong in doing so.
Ok, I'll give you a chance.  You can now enter what you think is
necessary to add to PATH for me to find a compiler.  I start off with
PATH=${PATH} and will add anything you give me here.
EOF
				[[ ${TODO} == 'noninteractive' ]] && ans="${usergcc%/gcc}" ||
				read -r -p "Where can I find your compiler? [] " ans
				case "${ans}" in
					"")
						: ;;
					*)
						PATH="${PATH}:${ans}"
						;;
				esac
				if ! type -P gcc > /dev/null ; then
					cat << EOF

Are you sure you have a compiler?  I didn't find one.  I think you
better first go get one, then run me again.
EOF
					exit 1
				else
					echo
					echo "Pfff, ok, it seems you were right.  Can we move on now?"
				fi
			;;
		esac
	else
		echo
		echo "Great!  You appear to have a compiler in your PATH"
	fi

	if type -P xcode-select > /dev/null ; then
		if [[ -d /usr/include ]] ; then
			# if we have /usr/include we're on an older system
			if [[ ${CHOST} == *-darwin[89] ]]; then
				# ancient Xcode (3.0/3.1)
				cat << EOF

Ok, this is an old system, let's just try and see what happens.
EOF
			elif [[ $(xcode-select -p) != */CommandLineTools ]] ; then
				# to an extent, bug #564814 and bug #562800
				cat << EOF

Your xcode-select is not set to CommandLineTools.  This prevents builds
from succeeding.  Switch to command line tools for the bootstrap to
continue.  Please execute:
  xcode-select -s /Library/Developer/CommandLineTools
and try running me again.
EOF
				exit 1
			fi
		else
			# let's see if we have an xcode install
			if [[ ! -e $(xcrun -f gcc 2>/dev/null) ]] ; then
				cat << EOF

You don't have Xcode installed, or xcode-select isn't pointing to a
valid install.  Try resetting it using:
  sudo xcode-select -r
and try running me again.
EOF
				exit 1
			fi
		fi
	fi
	echo
	local ncpu=
	case "${CHOST}" in
		*-darwin*)
			ncpu=$(/usr/sbin/sysctl -n hw.ncpu) ;;
		*-freebsd* | *-openbsd*)
			ncpu=$(/sbin/sysctl -n hw.ncpu) ;;
		*-solaris*)
			ncpu=$(/usr/sbin/psrinfo | wc -l) ;;
		*-linux-gnu*)
			ncpu=$(grep -c processor /proc/cpuinfo) ;;
		*)
			ncpu=1 ;;
	esac
	# get rid of excess spaces (at least Solaris wc does)
	ncpu=$((ncpu + 0))
	# Suggest usage of 50% to 75% of the available CPUs
	[[ ${tcpu} -eq 0 ]] && tcpu=1
	local tcpu=$((((ncpu * 3) + 1) / 4))
	[[ -n ${USE_CPU_CORES} ]] && tcpu=${USE_CPU_CORES}
	cat << EOF

I did my utmost best, and found that you have ${ncpu} cpu cores.  If
this looks wrong to you, you can happily ignore me.  Based on the number
of cores you have, I came up with the idea of parallelising compilation
work where possible with ${tcpu} parallel make threads.  If you have no
clue what this means, you should go with my excellent default I've
chosen below, really!
EOF
	[[ ${TODO} == 'noninteractive' ]] && ans="" ||
	read -r -p "How many parallel make jobs do you want? [${tcpu}] " ans
	case "${ans}" in
		"")
			MAKEOPTS="-j${tcpu}"
			;;
		*)
			if [[ ${ans} -le 0 ]] ; then
				echo
				echo "You should have entered a non-zero integer number, obviously..."
				exit 1
			elif [[ ${ans} -gt ${tcpu} && ${tcpu} -ne 1 ]] ; then
				if [[ ${ans} -gt ${ncpu} ]] ; then
					cat << EOF

Want to push it very hard?  I already feel sorry for your poor box with
its mere ${ncpu} cpu cores.
EOF
				elif [[ $((ans - tcpu)) -gt 1 ]] ; then
					cat << EOF

So you think you can stress your system a bit more than my extremely
well thought out formula suggested you?  Hmmpf, I'll take it you know
what you're doing then.
EOF
					sleep 1
					echo "(are you?)"
				fi
			fi
			MAKEOPTS="-j${ans}"
			;;
	esac
	export MAKEOPTS

	#32/64 bits, multilib
	local candomultilib=no
	local t64 t32
	case "${CHOST}" in
		*86*-darwin1[012345])
			# PPC/Darwin only works in 32-bits mode, so this is Intel
			# only, and officially starting from Leopard (10.5, darwin9)
			# but this is broken, so stick to 32-bits there, and use it
			# from Snow Lepard (10.6).
			# with Big Sur (11.0, darwin20) we have x64 or arm64 only
			candomultilib=yes
			t64=x86_64-${CHOST#*-}
			t32=i686-${CHOST#*-}
			;;
		*-solaris*)
			# Solaris is a true multilib system from as long as it does
			# 64-bits, we only need to know if the CPU we use is capable
			# of doing 64-bits mode
			[[ $(/usr/bin/isainfo | tr ' ' '\n' | wc -l) -ge 2 ]] \
				&& candomultilib=yes
			if [[ ${CHOST} == sparc* ]] ; then
				t64=sparcv9-${CHOST#*-}
				t32=sparc-${CHOST#*-}
			else
				t64=x86_64-${CHOST#*-}
				t32=i386-${CHOST#*-}
			fi
			;;
		# Even though multilib on Linux is often supported in some way,
		# it's hardly ever installed by default (it seems)
		# Since it's non-trivial to figure out if such system (binary
		# packages can report to be multilib, but lack all necessary
		# libs) is truely multilib capable, we don't bother here.  The
		# user can override if he/she is really convinced the system can
		# do it.
	esac
	if [[ ${candomultilib} == yes ]] ; then
		cat << EOF

Your system appears to be a multilib system, that is in fact also
capable of doing multilib right here, right now.  Multilib means
something like "being able to run multiple kinds of binaries".  The most
interesting kind for you now is 32-bits versus 64-bits binaries.  I can
create both a 32-bits as well as a 64-bits Prefix for you, but do you
actually know what I'm talking about here?  If not, just accept the
default here.  Honestly, you don't want to change it if you can't name
one advantage of 64-bits over 32-bits other than that 64 is a higher
number and when you buy a car or washing machine, you also always choose
the one with the highest number.
EOF
		[[ ${TODO} == 'noninteractive' ]] && ans="" ||
		case "${CHOST}" in
			x86_64-*|sparcv9-*)  # others can't do multilib, so don't bother
				# 64-bits native
				read -r -p "How many bits do you want your Prefix to target? [64] " ans
				;;
			*)
				# 32-bits native
				read -r -p "How many bits do you want your Prefix to target? [32] " ans
				;;
		esac
		case "${ans}" in
			"")
				: ;;
			32)
				CHOST=${t32}
				;;
			64)
				CHOST=${t64}
				;;
			*)
				cat << EOF

${ans}? Yeah Right(tm)!  You obviously don't know what you're talking
about, so I'll take the default instead.
EOF
				;;
		esac
	fi
	export CHOST

	# Figure out if we are bootstrapping from an existing Gentoo
	# It can be forced by setting HOST_GENTOO_EROOT manually
	local t_GENTOO_EROOT
	t_GENTOO_EROOT=$(env -u EPREFIX portageq envvar EROOT 2> /dev/null)
	if [[ ! -d ${HOST_GENTOO_EROOT} && -d ${t_GENTOO_EROOT} ]]; then
		cat <<EOF

Sweet, a Gentoo Penguin is found at ${t_GENTOO_EROOT}.  Hey, you are
really a Gentoo lover, aren't you?  Me too!  By leveraging the existing
portage, we can save a lot of time."
EOF
		[[ ${TODO} == 'noninteractive' ]] && ans=no ||
		read -r -p "  Do you want me to take the shortcut? [yN] " ans
		case "${ans}" in
			[Yy][Ee][Ss]|[Yy])
				echo "Good!"
				export HOST_GENTOO_EROOT="${t_GENTOO_EROOT}"
				: ;;
			*)
				echo "Fine, I will bootstrap from scratch."
				;;
		esac
	fi

	# The experimental support for Stable Prefix.
	# When expanding this to other CHOSTs, don't forget to update
	# make.conf generation in bootstrap_setup().
	# TODO: Consider at some point removing the ~ARCH override from
	# profiles/features/prefix/standalone/make.defaults.
	# https://bugs.gentoo.org/759424
	if is-rap ; then
		if [[ "${CHOST}" == x86_64-pc-linux-gnu ]]; then
			cat <<EOF

Normally I can only give you ~amd64 packages, and you would be exposed
to all the bugs of the newest untested software.  Well, ok, sometimes
it also has new features, but who needs those.  But as you are a VIP
customer who uses Linux on x86_64, I have a one-time offer for you!
I can limit your Prefix to use only packages keyworded for stable amd64
by default.  Of course, you can still enable testing ~amd64 for
the packages you want, when the need arises.
EOF
			[[ ${TODO} == 'noninteractive' ]] && ans=yes ||
			read -r -p "  Do you want to use stable Prefix? [Yn] " ans
			case "${ans}" in
				[Yy][Ee][Ss]|[Yy]|"")
					echo "Okay, I'll disable ~amd64 by default."
					export STABLE_PREFIX="yes"
					;;
				*)
					echo "Fine, I will not disable ~amd64, no problem."
					;;
			esac
		fi
	fi

	# choose EPREFIX, we do this last, since we have to actually write
	# to the filesystem here to check that the EPREFIX is sane
	cat << EOF

Each and every Prefix has a home.  That is, a place where everything is
supposed to be in.  That place must be fully writable by you (duh), but
should also be able to hold some fair amount of data and preferably be
reasonably fast.  In terms of space, I advise something around 2GiB
(it's less if you're lucky).  I suggest a reasonably fast place because
we're going to compile a lot, and that generates a fair bit of IO.  If
some networked filesystem like NFS is the only option for you, then
you're just going to have to wait a fair bit longer.
This place which is your Prefix' home, is often referred to by a
variable called EPREFIX.
EOF
	while true ; do
		if [[ -z ${EPREFIX} ]] ; then
			# Make the default for Mac users a bit more "native feel"
			[[ ${CHOST} == *-darwin* ]] \
				&& EPREFIX=$HOME/Gentoo \
				|| EPREFIX=$HOME/gentoo
		fi
		echo
		[[ ${TODO} == 'noninteractive' ]] && ans= ||
		read -r -p "What do you want EPREFIX to be? [$EPREFIX] " ans
		case "${ans}" in
			"")
				: ;;
			/*)
				EPREFIX=${ans}
				;;
			*)
				echo
				echo "EPREFIX must be an absolute path!"
				[[ ${TODO} == 'noninteractive' ]] && exit 1
				EPREFIX=
				continue
				;;
		esac
		if [[ ! -d ${EPREFIX} ]] && ! mkdir -p "${EPREFIX}"/. ; then
			echo
			echo "It seems I cannot create ${EPREFIX}."
			[[ ${TODO} == 'noninteractive' ]] && exit 1
			echo "I'll forgive you this time, try again."
			EPREFIX=
			continue
		fi
		#readlink -f would not work on darwin, so use bash builtins
		local realEPREFIX
		realEPREFIX=$(cd "${EPREFIX}" && pwd -P)
		if [[ -z ${I_KNOW_MY_GCC_WORKS_FINE_WITH_SYMLINKS} && \
			${EPREFIX} != "${realEPREFIX}" ]]; then
			echo
			echo "$EPREFIX contains a symlink, which will make the merge of gcc"
			echo "imposible, use '${realEPREFIX}' instead or"
			echo "export I_KNOW_MY_GCC_WORKS_FINE_WITH_SYMLINKS='hell yeah'"
			[[ ${TODO} == 'noninteractive' ]] && exit 1
			echo "Have another try."
			EPREFIX="${realEPREFIX}"
			continue
		fi
		if ! touch "${EPREFIX}"/.canihaswrite >& /dev/null ; then
			echo
			echo "I cannot write to ${EPREFIX}!"
			[[ ${TODO} == 'noninteractive' ]] && exit 1
			echo "You want some fun, but without me?  Try another location."
			EPREFIX=
			continue
		fi
		# GNU and BSD variants of stat take different arguments (and
		# format specifiers are not equivalent)
		case "${CHOST}" in
			*-darwin* | *-freebsd* | *-openbsd*) STAT='stat -f %u/%g' ;;
			*)                                   STAT='stat -c %U/%G' ;;
		esac

		if [[ $(${STAT} "${EPREFIX}"/.canihaswrite) != \
			$(${STAT} "${EPREFIX}") ]] ;
		then
			echo
			echo "The $EPREFIX directory has different ownership than expected."
			echo "Ensure the directory is owned (user and group) by your"
			echo "primary ids"
			EPREFIX=
			continue
		fi
		# don't really expect this one to fail
		rm -f "${EPREFIX}"/.canihaswrite || exit 1
		# location seems ok
		break
	done
	export PATH="$EPREFIX/usr/bin:$EPREFIX/bin:$EPREFIX/tmp/usr/local/bin:$EPREFIX/tmp/usr/bin:$EPREFIX/tmp/bin:${PATH}"

	cat << EOF

OK!  I'm going to give it a try, this is what I have collected sofar:
  EPREFIX=${EPREFIX}
  CHOST=${CHOST}
  PATH=${PATH}
  MAKEOPTS=${MAKEOPTS}

I'm now going to make an awful lot of noise going through a sequence of
stages to make your box as groovy as I am myself, setting up your
Prefix.  In short, I'm going to run stage1, stage2, stage3, followed by
installing a package to enter your Prefix.  If any of these stages
fail, both you and me are in deep trouble.  So let's hope that doesn't
happen.
EOF
	echo
	[[ ${TODO} == 'noninteractive' ]] && ans="" ||
	read -r -p "Type here what you want to wish me [luck] " ans
	if [[ -n ${ans} && ${ans} != "luck" ]] ; then
		echo "Huh?  You're not serious, are you?"
		sleep 3
	fi
	echo

	# because we unset ROOT from environment above, and we didn't set
	# ROOT as argument in the script, we set ROOT here to the EPREFIX we
	# just harvested
	ROOT="${EPREFIX}"
	set_helper_vars

	# stop here if all we wanted was the env to be setup correctly
	[[ -n ${SETUP_ENV_ONLY} ]] && return 0

	if [[ -d ${HOST_GENTOO_EROOT} ]]; then
		if ! [[ -x ${EPREFIX}/tmp/usr/lib/portage/bin/emerge ]] && ! ${BASH} "${BASH_SOURCE[0]}" "${EPREFIX}" stage_host_gentoo ; then
			# stage host gentoo fail
			cat << EOF

I tried running
  ${BASH} ${BASH_SOURCE[0]} "${EPREFIX}" stage_host_gentoo
but that failed :(  I have no clue, really.  Please find friendly folks
in #gentoo-prefix on irc.gentoo.org, gentoo-alt@lists.gentoo.org mailing list,
or file a bug at bugs.gentoo.org under Gentoo/Alt, Prefix Support.
Sorry that I have failed you master.  I shall now return to my humble cave.

  CHOST:     ${CHOST}
  IDENT:     ${CHOST_IDENTIFY}
EOF
			exit 1
		fi
	fi

	if ! [[ -e ${EPREFIX}/.stage1-finished ]] && ! bootstrap_stage1_log ; then
		# stage 1 fail
		cat << EOF

I tried running
  bootstrap_stage1_log
but that failed :(  I have no clue, really.  Please find friendly folks
in #gentoo-prefix on irc.gentoo.org, gentoo-alt@lists.gentoo.org mailing list,
or file a bug at bugs.gentoo.org under Gentoo/Alt, Prefix Support.
Sorry that I have failed you master.  I shall now return to my humble cave.
You can find a log of what happened in ${EPREFIX}/stage1.log

  CHOST:     ${CHOST}
  IDENT:     ${CHOST_IDENTIFY}
EOF
		exit 1
	fi

	[[ ${STOP_BOOTSTRAP_AFTER} == stage1 ]] && exit 0

	unset ROOT

	# stage1 has set a profile, which defines CHOST, so unset any CHOST
	# we've got here to avoid cross-compilation due to slight
	# differences caused by our guessing vs. what the profile sets.
	# This happens at least on 32-bits Darwin, with i386 and i686.
	# https://bugs.gentoo.org/show_bug.cgi?id=433948
	unset CHOST
	CHOST=$(portageq envvar CHOST)
	export CHOST

	# after stage1 and stage2 we should have a bash of our own, which
	# is preferable over the host-provided one, because we know it can
	# deal with the bash-constructs we use in stage3 and onwards
	hash -r

	local https_needed=no
	if ! [[ -e ${EPREFIX}/.stage2-finished ]] \
		&& ! ${BASH} "${BASH_SOURCE[0]}" "${EPREFIX}" stage2_log ; then
		# stage 2 fail
		cat << EOF

Odd!  Running
  ${BASH} ${BASH_SOURCE[0]} "${EPREFIX}" stage2
failed! :(  Details might be found in the build log:
EOF
		for log in "${EPREFIX}"{/tmp,}/var/tmp/portage/*/*/temp/build.log ; do
			[[ -e ${log} ]] || continue
			echo "  ${log}"
			grep -q "HTTPS support not compiled in" "${log}" && https_needed=yes
		done
		[[ -e ${log} ]] || echo "  (no build logs found?!?)"
		if [[ ${https_needed} == "yes" ]] ; then
			cat << EOF
It seems one of your logs indicates a download problem due to missing
HTTPS support.  If this appears to be the problem for real, you can work
around this for now by downloading the file manually and placing it in
  "${DISTDIR}"
I will find it when you run me again.  If this is NOT the problem, then
EOF
		fi
		cat << EOF
I have no clue, really.  Please find friendly folks in #gentoo-prefix on
irc.gentoo.org, gentoo-alt@lists.gentoo.org mailing list, or file a bug
at bugs.gentoo.org under Gentoo/Alt, Prefix Support.
Remember you might find some clues in ${EPREFIX}/stage2.log

  CHOST:     ${CHOST}
  IDENT:     ${CHOST_IDENTIFY}
EOF
		exit 1
	fi

	[[ ${STOP_BOOTSTRAP_AFTER} == stage2 ]] && exit 0

	# new bash
	hash -r

	if ! [[ -e ${EPREFIX}/.stage3-finished ]] \
		&& ! bash "${BASH_SOURCE[0]}" "${EPREFIX}" stage3_log ; then
		# stage 3 fail
		hash -r  # previous cat (tmp/usr/bin/cat) may have been removed
		cat << EOF

Hmmmm, I was already afraid of this to happen.  Running
  $(type -P bash) ${BASH_SOURCE[0]} "${EPREFIX}" stage3
somewhere failed :(  Details might be found in the build log:
EOF
		for log in "${EPREFIX}"{/tmp,}/var/tmp/portage/*/*/temp/build.log ; do
			[[ -e ${log} ]] || continue
			echo "  ${log}"
			grep -q "HTTPS support not compiled in" "${log}" && https_needed=yes
		done
		[[ -e ${log} ]] || echo "  (no build logs found?!?)"
		if [[ ${https_needed} == "yes" ]] ; then
			cat << EOF
It seems one of your logs indicates a download problem due to missing
HTTPS support.  If this appears to be the problem for real, you can work
around this for now by downloading the file manually and placing it in
  "${DISTDIR}"
I will find it when you run me again.  If this is NOT the problem, then
EOF
		fi
		cat << EOF
I have no clue, really.  Please find friendly folks in #gentoo-prefix on
irc.gentoo.org, gentoo-alt@lists.gentoo.org mailing list, or file a bug
at bugs.gentoo.org under Gentoo/Alt, Prefix Support.  This is most
inconvenient, and it crushed my ego.  Sorry, I give up.
Should you want to give it a try, there is ${EPREFIX}/stage3.log

  CHOST:     ${CHOST}
  IDENT:     ${CHOST_IDENTIFY}
EOF
		exit 1
	fi

	[[ ${STOP_BOOTSTRAP_AFTER} == stage3 ]] && exit 0

	# Now, we've got everything in $ROOT, we can get rid of /tmp
	if [[ -d ${EPREFIX}/tmp/var/tmp ]] ; then
		rm -Rf "${EPREFIX}"/tmp || return 1
		mkdir -p "${EPREFIX}"/tmp || return 1
	fi

	hash -r  # tmp/* stuff is removed in stage3

	if ! bash "${BASH_SOURCE[0]}" "${EPREFIX}" startscript ; then
		# startscript fail?
		cat << EOF

Ok, let's be honest towards each other.  If
  $(type -P bash) ${BASH_SOURCE[0]} "${EPREFIX}" startscript
fails, then who cheated on who?  Either you use an obscure shell, or
your PATH isn't really sane afterall.  Despite, I can't really
congratulate you here, but you basically made it to the end.
Please find friendly folks in #gentoo-prefix on irc.gentoo.org,
gentoo-alt@lists.gentoo.org mailing list, or file a bug at
bugs.gentoo.org under Gentoo/Alt, Prefix Support.
It's sad we have to leave each other this way.  Just an inch away...
EOF
		exit 1
	fi

	echo
	cat << EOF

Woah!  Everything just worked!  Now YOU should run
  ${EPREFIX}/startprefix
and enjoy!  Thanks for using me, it was a pleasure to work with you.
EOF
}

## End Functions

## some vars

# We do not want stray $TMP, $TMPDIR or $TEMP settings
unset TMP TMPDIR TEMP

# Try to guess the CHOST if not set.  We currently only support guessing
# on a very sloppy base.
if [[ -z ${CHOST} ]]; then
	if [[ $(type -t uname) == "file" ]]; then
		case $(uname -s) in
			Linux)
				CHOST=$(uname -m)
				CHOST=${CHOST/#ppc/powerpc}
				case "${CHOST}" in
					x86_64|i*86)
						CHOST+=-pc ;;
					*)
						CHOST+=-unknown ;;
				esac
				plt=gnu
				for f in /lib/ld-musl-*.so.1; do
					[[ -e $f ]] && plt=musl
				done
				CHOST+=-linux-${plt}
				case "${CHOST}" in
					arm*)
						CHOST+=eabi
						for f in /lib/ld-*hf.so.*; do
							if [[ -e $f ]]; then
								CHOST+=hf
								break
							fi
						done
						;;
				esac
				;;
			Darwin)
				rev=$(uname -r | cut -d'.' -f 1)
				if [[ ${rev} -ge 11 && ${rev} -le 19 ]] ; then
					# Lion and up are 64-bits default (and 64-bits CPUs)
					CHOST="x86_64-apple-darwin$rev"
				elif [[ ${rev} -ge 20 ]] ; then
					# uname -p returns arm, -m returns arm64 on this
					# release while on Darwin 9 -m returns something
					# like "PowerPC Machine", hence the distinction
					CHOST="$(uname -m)-apple-darwin$rev"
				else
					CHOST="$(uname -p)-apple-darwin$rev"
				fi
				;;
			SunOS)
				case $(isainfo -n) in
					amd64)
						CHOST="x86_64-pc-solaris$(uname -r | sed 's|5|2|')"
					;;
					i386)
						CHOST="i386-pc-solaris$(uname -r | sed 's|5|2|')"
					;;
					sparcv9)
						CHOST="sparcv9-sun-solaris$(uname -r | sed 's|5|2|')"
					;;
					sparc)
						CHOST="sparc-sun-solaris$(uname -r | sed 's|5|2|')"
					;;
				esac
				;;
			CYGWIN*)
				CHOST="$(uname -m)-pc-cygwin"
				;;
			FreeBSD)
				case $(uname -m) in
					amd64)
						CHOST="x86_64-pc-freebsd$(uname -r | sed 's|-.*$||')"
					;;
				esac
				;;
			OpenBSD)
				case $(uname -m) in
					amd64)
						CHOST="x86_64-pc-openbsd$(uname -r | sed 's|-.*$||')"
					;;
				esac
				;;
			*)
				eerror "Nothing known about platform $(uname -s)."
				eerror "Please set CHOST appropriately for your system"
				eerror "and rerun $0"
				exit 1
				;;
		esac
	fi
fi

CHOST_IDENTIFY=${CHOST}
# massage CHOST on Linux systems
if [[ ${CHOST} == *-linux-* ]] ; then
	# two choices here: x86_64_ubuntu16-linux-gnu
	#                   x86_64-pc-linux-ubuntu16
	# I choose the latter because it is compatible with most
	# UNIX vendors and it allows to fit RAP into platform
	dist=$(lsb_release -si)
	rel=$(lsb_release -sr)
	if [[ -z ${dist} ]] || [[ -z ${rel} ]] ; then
		source /etc/os-release  # this may fail if the file isn't there
		[[ -z ${dist} ]] && dist=${ID}
		[[ -z ${dist} ]] && dist=${NAME}
		[[ -z ${rel} ]] && rel=${VERSION_ID}
	fi
	[[ -z ${dist} ]] && dist=linux

	# Gentoo's versioning isn't really relevant, since it is
	# a rolling distro
	if [[ ${dist,,} == "gentoo" ]] ; then
		rel=
		[[ ${CHOST##*-} == "musl" ]] && rel="musl"
	fi

	# leave rel unset/empty if we don't know about it
	while [[ ${rel} == *.*.* ]] ; do
		rel=${rel%.*}
	done

	platform=${CHOST#*-}; platform=${platform%%-*}
	platform=$(rapx rap "${platform}")
	CHOST_IDENTIFY=${CHOST%%-*}-${platform}-linux-${dist,,}${rel}
fi

# Now based on the CHOST set some required variables.  Doing it here
# allows for user set CHOST still to result in the appropriate variables
# being set.
case ${CHOST} in
	*-*-solaris*)
		if type -P gmake > /dev/null ; then
			MAKE="gmake"
		else
			MAKE="make"
		fi
	;;
	*)
		MAKE="make"
	;;
esac

# handle GCC install path on recent Darwin
case ${CHOST} in
	powerpc-*darwin*)
		DARWIN_USE_GCC=1  # must use GCC, Clang is impossible
		;;
	*-darwin*)
		# normalise value of DARWIN_USE_GCC
		case ${DARWIN_USE_GCC} in
			yes|true|1)  DARWIN_USE_GCC=1  ;;
			no|false|0)  DARWIN_USE_GCC=0  ;;
			*)           DARWIN_USE_GCC=1  ;;   # default to GCC build
		esac
		;;
	*)
		unset DARWIN_USE_GCC
		;;
esac

# deal with a problem on OSX with Python's locales
case ${CHOST}:${LC_ALL}:${LANG} in
	*-darwin*:UTF-8:*|*-darwin*:*:UTF-8)
		eerror "Your LC_ALL and/or LANG is set to 'UTF-8'."
		eerror "This setting is known to cause trouble with Python.  Please run"
		case ${SHELL} in
			*/tcsh|*/csh)
				eerror "  setenv LC_ALL en_US.UTF-8"
				eerror "  setenv LANG en_US.UTF-8"
				eerror "and make it permanent by adding it to your ~/.${SHELL##*/}rc"
				exit 1
			;;
			*)
				eerror "  export LC_ALL=en_US.UTF-8"
				eerror "  export LANG=en_US.UTF-8"
				eerror "and make it permanent by adding it to your ~/.profile"
				exit 1
			;;
		esac
	;;
esac

# save original path, need this before interactive, #788334
ORIGINAL_PATH="${PATH}"

# Just guessing a prefix is kind of scary.  Hence, to make it a bit less
# scary, we force the user to give the prefix location here.  This also
# makes the script a bit less dangerous as it will die when just run to
# "see what happens".
if [[ -n $1 && -z $2 ]] ; then
	echo "usage: $0 [<prefix-path> <action>]"
	echo
	echo "Either you give no argument and I'll ask you interactively, or"
	echo "you need to give both the path offset for your Gentoo prefixed"
	echo "portage installation, and the action I should do there, e.g."
	echo "  $0 $HOME/prefix <action>"
	echo
	echo "See the source of this script for which actions exist."
	echo
	echo "$0: insufficient number of arguments" 1>&2
	exit 1
elif [[ -z $1 ]] ; then
	bootstrap_interactive
	exit 0
fi

ROOT="$1"
set_helper_vars

case $ROOT in
	chost.guess)
		# undocumented feature that sort of is our own config.guess, if
		# CHOST was unset, it now contains the guessed CHOST
		echo "${CHOST}"
		exit 0
	;;
	chost.identify)
		# another undocumented feature, produces a pseudo CHOST that
		# identifies the system for bootstraps, currently only Linux is
		# different from CHOST

		echo "${CHOST_IDENTIFY}"
		exit 0
	;;
	/*) ;;
	*)
		echo "Your path offset needs to be absolute!" 1>&2
		exit 1
	;;
esac


einfo "Bootstrapping Gentoo prefixed portage installation using"
einfo "host:   ${CHOST}"
einfo "ident:  ${CHOST_IDENTIFY}"
einfo "prefix: ${ROOT}"

TODO=${2}
if [[ ${TODO} != "noninteractive" && $(type -t "bootstrap_${TODO}") != "function" ]];
then
	eerror "bootstrap target ${TODO} unknown"
	exit 1
fi

if [[ -n ${LD_LIBRARY_PATH} || -n ${DYLD_LIBRARY_PATH} ]] ; then
	eerror "EEEEEK!  You have LD_LIBRARY_PATH or DYLD_LIBRARY_PATH set"
	eerror "in your environment.  This is a guarantee for TROUBLE."
	eerror "Cowardly refusing to operate any further this way!"
	exit 1
fi

if [[ -n ${PKG_CONFIG_PATH} ]] ; then
	eerror "YUK!  You have PKG_CONFIG_PATH set in your environment."
	eerror "This is a guarantee for TROUBLE."
	eerror "Cowardly refusing to operate any further this way!"
	exit 1
fi

einfo "ready to bootstrap ${TODO}"

# When we call individual stages separately (e.g. not from
# bootstrap_interactive) we might need some env to be setup in order to
# function properly.  Basically do a non-interactive call for each stage
# that will only set whatever needs to be set.
if [[ ${TODO} != "interactive" && ${TODO} != "noninteractive" ]] ; then
	# squelch the output, we've seen it already when running from
	# interactive proper
	SETUP_ENV_ONLY=true TODO=noninteractive \
		bootstrap_interactive > /dev/null || exit 1
fi

# call the appropriate function,
# beware noninteractive is just a mode of interactive
bootstrap_"${TODO#non}" || exit 1

# Local Variables:
# sh-indentation: 4
# sh-basic-offset: 4
# indent-tabs-mode: t
# End:
# vim: set ts=4 sw=4 noexpandtab:
