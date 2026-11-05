#!/bin/sh
# Persistence helpers for the Horaco ZX-SW82TS-L2P (JFFS2_CFG partition).
#
# Sourced by /etc/init.d/persist. All paths are overridable so the logic can be
# exercised against a tmpfs scratch tree during development (D2a).
#
# Design notes:
#  - The store is a JFFS2 filesystem on the vendor "JFFS2_CFG" partition
#    (mtd3, 1 MiB). Vendor files (inos_ifksdk.ko, myrundir/) are never touched;
#    everything OpenWrt owns lives under <store>/openwrt/.
#  - /etc is overlaid (not bind-mounted file-by-file) because account updates
#    (passwd/opkg) replace files via rename(2); a file bind-mount would silently
#    detach and lose the new inode.
#  - If the store is enabled but unusable, we fail *closed* for remote login and
#    keep the switch booting with RAM defaults (see persist_fallback).

PERSIST_MP=${PERSIST_MP:-/persist}
PERSIST_NS=${PERSIST_NS:-openwrt}
PERSIST_STATE="$PERSIST_MP/$PERSIST_NS"
PERSIST_MIN_KB=${PERSIST_MIN_KB:-64}

persist_log() {
	echo "persist: $*" >&2
	logger -t persist "$*" 2>/dev/null
}

# persist_mtd_dev <label> -> mountable device node for that partition.
# jffs2 must be mounted through the block device (/dev/mtdblockN); the
# character device is only good for raw I/O.
persist_mtd_dev() {
	local idx blk
	idx=$(awk -v lbl="\"$1\"" '$0 ~ lbl { sub(":", "", $1); print $1; exit }' /proc/mtd 2>/dev/null)
	[ -n "$idx" ] || return 1
	blk=$(echo "$idx" | sed 's/^mtd/mtdblock/')
	if [ -e "/dev/$blk" ]; then
		echo "/dev/$blk"
	else
		echo "/dev/$idx"
	fi
}

# persist_probe <dev> -> prints "enabled" or "clean"; read-only, never writes
persist_probe() {
	mkdir -p "$PERSIST_MP" || return 1
	mount -t jffs2 -o ro "$1" "$PERSIST_MP" 2>/dev/null || return 1
	if [ -f "$PERSIST_STATE/enabled" ]; then
		echo enabled
	else
		echo clean
	fi
	umount "$PERSIST_MP" 2>/dev/null
	return 0
}

persist_mount_rw() {
	mkdir -p "$PERSIST_MP" || return 1
	mount -t jffs2 "$1" "$PERSIST_MP"
}

persist_free_kb() {
	df -k "$PERSIST_MP" 2>/dev/null | awk 'NR==2 {print $4}'
}

persist_init_tree() {
	mkdir -p "$PERSIST_STATE/etc/upper" "$PERSIST_STATE/etc/work" \
	         "$PERSIST_STATE/meta" || return 1
	chmod 0700 "$PERSIST_STATE" "$PERSIST_STATE/etc" 2>/dev/null
	return 0
}

# Images change their /etc defaults over time; a stale upper can shadow new
# files. Compare a fingerprint of the base system and quarantine a mismatch.
persist_etc_fingerprint() {
	{
		cat /etc/openwrt_release 2>/dev/null
		uname -r 2>/dev/null
	} | md5sum | cut -d' ' -f1
}

persist_version_gate() {
	local cur stored old
	cur=$(persist_etc_fingerprint)
	stored=$(cat "$PERSIST_STATE/meta/fingerprint" 2>/dev/null)
	if [ -z "$stored" ]; then
		echo "$cur" > "$PERSIST_STATE/meta/fingerprint"
		return 0
	fi
	[ "$stored" = "$cur" ] && return 0
	old="$PERSIST_STATE/etc.upper.$(date +%Y%m%d%H%M%S)"
	persist_log "base system changed ($stored -> $cur): quarantining overlay as $(basename "$old")"
	mv "$PERSIST_STATE/etc" "$old" 2>/dev/null || return 1
	persist_init_tree || return 1
	echo "$cur" > "$PERSIST_STATE/meta/fingerprint"
	return 0
}

persist_etc_overlay() {
	mount -t overlay overlay \
		-o "lowerdir=/etc,upperdir=$PERSIST_STATE/etc/upper,workdir=$PERSIST_STATE/etc/work" /etc
}

persist_safe_mode() {
	[ -e "$PERSIST_STATE/safe_mode" ]
}

# Fail closed: keep switching up, refuse remote password login this boot.
persist_fallback() {
	local rc
	persist_log "FAILED: $* - continuing with RAM defaults"
	touch /tmp/persist-failed 2>/dev/null
	for rc in /etc/rc.d/S??dropbear; do
		[ -e "$rc" ] || continue
		mv "$rc" "$rc.disabled" 2>/dev/null && \
			persist_log "remote login disabled for this boot (use the serial console)"
	done
	return 0
}

persist_mounted() {
	grep -q " $1 " /proc/mounts 2>/dev/null
}

persist_teardown() {
	persist_mounted /etc && umount /etc 2>/dev/null
	persist_mounted "$PERSIST_MP" && umount "$PERSIST_MP" 2>/dev/null
	return 0
}

# The initramfs ships Dropbear host keys that were generated at image build
# time, so every device flashed with the same image would share them (and the
# image file contains the private half). On first activation, generate a unique
# per-device set inside the overlay and record that it was done.
persist_hostkeys_init() {
	local marker="$PERSIST_STATE/meta/hostkeys-done"
	local k

	[ -e "$marker" ] && return 0
	[ -x /usr/bin/dropbearkey ] || return 0

	rm -f /etc/dropbear/dropbear_*_host_key 2>/dev/null
	mkdir -p /etc/dropbear || return 1
	chmod 0700 /etc/dropbear 2>/dev/null

	for k in rsa ecdsa ed25519; do
		dropbearkey -t "$k" -f "/etc/dropbear/dropbear_${k}_host_key" >/dev/null 2>&1 || \
			persist_log "host key generation for $k failed"
	done

	# force the new keys through the overlay into the store
	sync
	if [ -f /etc/dropbear/dropbear_rsa_host_key ] && \
	   [ -f "$PERSIST_STATE/etc/upper/dropbear/dropbear_rsa_host_key" ]; then
		touch "$marker"
		persist_log "generated unique SSH host keys and stored them"
	else
		persist_log "WARNING: host keys not persisted (upper missing them)"
	fi
	return 0
}
