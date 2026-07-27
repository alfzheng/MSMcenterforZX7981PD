#!/bin/sh
set -eu

archive='/root/codex-openclash-core/mihomo-linux-arm64-v1.19.29.gz'
runtime_dir='/tmp/codex-mihomo-runtime'
runtime="$runtime_dir/clash"
archive_sha256='9a868b5e4e0ad91d9d71e1b41b0cfce78aaba44360c30df74a723f8e3926a86c'
runtime_sha256='8e02308f672e89c076bfc2fa1b03379bd54e58b0bafa81ffb01113fcf6da348d'

if [ ! -x "$runtime" ]; then
	mkdir -p "$runtime_dir"
	chmod 0700 "$runtime_dir"

	sha256sum "$archive" | grep -q "^$archive_sha256 "
	gzip -dc "$archive" >"$runtime.new"
	sha256sum "$runtime.new" | grep -q "^$runtime_sha256 "
	chmod 0700 "$runtime.new"
	mv -f "$runtime.new" "$runtime"
fi

exec "$runtime" "$@"
