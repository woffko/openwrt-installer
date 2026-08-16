#!/bin/sh

# Shared, fixed release inputs. Generated payload files are ignored explicitly
# below; every other tracked, staged, untracked, or ignored file here matters.
CANDIDATE_RUNTIME_PATHS='Makefile files-installer files-target iso packages profiles scripts'

candidate_die() {
	printf '[owrt-installer] ERROR: %s\n' "$*" >&2
	exit 1
}

candidate_validate_release_version() {
	version="$1"
	case "$version" in
		''|*[!A-Za-z0-9._-]*) candidate_die "Invalid candidate version: ${version:-empty}" ;;
		v[0-9]*) ;;
		*) candidate_die "Candidate version must start with v and a digit: $version" ;;
	esac
	case "$version" in
		*-dev*) candidate_die "Development versions cannot be frozen: $version" ;;
	esac
}

candidate_require_hex() {
	name="$1"
	value="$2"
	length="$3"
	case "$value" in
		''|*[!0-9a-f]*) candidate_die "$name must contain exactly $length lowercase hexadecimal characters" ;;
	esac
	[ "${#value}" -eq "$length" ] ||
		candidate_die "$name must contain exactly $length lowercase hexadecimal characters"
}

candidate_metadata_validate() {
	metadata_file="$1"
	LC_ALL=C awk '
		BEGIN {
			required["CANDIDATE_VERSION"] = 1
			required["CANDIDATE_RUNTIME_COMMIT"] = 1
			required["CANDIDATE_ISO_FILE"] = 1
			required["CANDIDATE_ISO_SHA256"] = 1
			required["CANDIDATE_MANIFEST_SHA256"] = 1
			sq = sprintf("%c", 39)
		}
		{
			eq = index($0, "=")
			if (eq < 2) {
				bad = 1
				next
			}
			key = substr($0, 1, eq - 1)
			raw = substr($0, eq + 1)
			if (!(key in required) || seen[key]++) {
				bad = 1
				next
			}
			if (length(raw) < 2 || substr(raw, 1, 1) != sq ||
			    substr(raw, length(raw), 1) != sq) {
				bad = 1
				next
			}
			value = substr(raw, 2, length(raw) - 2)
			if (index(value, sq) != 0) {
				bad = 1
			}
		}
		END {
			if (bad || NR != 5) exit 1
			for (key in required) {
				if (seen[key] != 1) exit 1
			}
		}
	' "$metadata_file"
}

candidate_metadata_value() {
	metadata_file="$1"
	metadata_key="$2"
	LC_ALL=C awk -v wanted="$metadata_key" '
		{
			eq = index($0, "=")
			if (substr($0, 1, eq - 1) == wanted) {
				raw = substr($0, eq + 1)
				print substr(raw, 2, length(raw) - 2)
				exit
			}
		}
	' "$metadata_file"
}

candidate_manifest_string() {
	manifest_file="$1"
	manifest_key="$2"
	LC_ALL=C awk -v wanted="$manifest_key" '
		{
			line = $0
			trimmed = line
			sub(/^[[:space:]]*/, "", trimmed)
			prefix = "\"" wanted "\""
			if (index(trimmed, prefix) == 1 &&
			    substr(trimmed, length(prefix) + 1) ~ /^[[:space:]]*:/) {
				sub(/^[^:]*:[[:space:]]*"/, "", line)
				sub(/"[[:space:]]*,?[[:space:]]*$/, "", line)
				print line
				count++
			}
		}
		END { if (count != 1) exit 1 }
	' "$manifest_file"
}

candidate_manifest_boolean() {
	manifest_file="$1"
	manifest_key="$2"
	LC_ALL=C awk -v wanted="$manifest_key" '
		{
			line = $0
			trimmed = line
			sub(/^[[:space:]]*/, "", trimmed)
			prefix = "\"" wanted "\""
			if (index(trimmed, prefix) == 1 &&
			    substr(trimmed, length(prefix) + 1) ~ /^[[:space:]]*:/) {
				sub(/^[^:]*:[[:space:]]*/, "", line)
				sub(/,[[:space:]]*$/, "", line)
				gsub(/[[:space:]]/, "", line)
				if (line != "true" && line != "false") exit 1
				print line
				count++
			}
		}
		END { if (count != 1) exit 1 }
	' "$manifest_file"
}

candidate_assert_repository_clean() {
	repository_state="$(git status --porcelain=v1 --untracked-files=all)"
	[ -z "$repository_state" ] ||
		candidate_die "Repository must be clean before freezing candidate metadata"
}

candidate_unexpected_ignored_runtime() {
	# Keep this allowlist limited to files produced by build-installer.sh. New
	# ignored inputs must be reviewed here or candidate verification rejects them.
	# shellcheck disable=SC2086 # Fixed repository-owned path list.
	git -c core.quotePath=true ls-files --others --ignored --exclude-standard -- \
		$CANDIDATE_RUNTIME_PATHS |
	while IFS= read -r ignored_path; do
		case "$ignored_path" in
			files-installer/usr/share/owrt-installer/manifest.json|\
			files-installer/usr/share/owrt-installer/target.img.gz|\
			files-installer/usr/share/owrt-installer/98-installer-network|\
			files-installer/usr/share/owrt-installer/storage-guard/install-upgrade-guard|\
			files-installer/usr/share/owrt-installer/storage-guard/owrt-installer-guard.init|\
			files-installer/usr/share/owrt-installer/storage-guard/sysupgrade-wrapper|\
			files-installer/usr/share/owrt-installer/storage-guard/upgrade-guard)
				;;
			*) printf '%s\n' "$ignored_path" ;;
		esac
	done
}

candidate_assert_runtime_clean() {
	# shellcheck disable=SC2086 # Fixed repository-owned path list.
	git diff --quiet -- $CANDIDATE_RUNTIME_PATHS ||
		candidate_die "Uncommitted tracked runtime changes invalidate the candidate"
	# shellcheck disable=SC2086 # Fixed repository-owned path list.
	git diff --cached --quiet -- $CANDIDATE_RUNTIME_PATHS ||
		candidate_die "Staged runtime changes invalidate the candidate"
	# shellcheck disable=SC2086 # Fixed repository-owned path list.
	untracked_runtime="$(git -c core.quotePath=true ls-files --others --exclude-standard -- \
		$CANDIDATE_RUNTIME_PATHS)"
	[ -z "$untracked_runtime" ] ||
		candidate_die "Untracked runtime files invalidate the candidate: $untracked_runtime"
	ignored_runtime="$(candidate_unexpected_ignored_runtime)"
	[ -z "$ignored_runtime" ] ||
		candidate_die "Unexpected ignored runtime files invalidate the candidate: $ignored_runtime"
}

candidate_assert_runtime_unchanged_since() {
	runtime_commit="$1"
	# shellcheck disable=SC2086 # Fixed repository-owned path list.
	git diff --quiet "$runtime_commit"..HEAD -- $CANDIDATE_RUNTIME_PATHS ||
		candidate_die "Tracked runtime files changed after the frozen candidate commit"
	candidate_assert_runtime_clean
}

candidate_assert_metadata_committed() {
	metadata_path="$1"
	git ls-files --error-unmatch "$metadata_path" >/dev/null 2>&1 ||
		candidate_die "Candidate metadata must be committed: $metadata_path"
	git diff --quiet -- "$metadata_path" ||
		candidate_die "Candidate metadata has uncommitted changes: $metadata_path"
	git diff --cached --quiet -- "$metadata_path" ||
		candidate_die "Candidate metadata has staged changes: $metadata_path"
}

candidate_extract_iso_manifest() {
	project_dir="$1"
	iso_file="$2"
	destination="$3"
	local_xorriso="$project_dir/build/host-tools/usr/bin/xorriso"
	local_lib="$project_dir/build/host-tools/usr/lib/x86_64-linux-gnu"

	if command -v xorriso >/dev/null 2>&1; then
		xorriso_bin="$(command -v xorriso)"
		xorriso_lib=""
	elif [ -x "$local_xorriso" ]; then
		xorriso_bin="$local_xorriso"
		xorriso_lib="$local_lib"
	else
		candidate_die "xorriso is required to verify the manifest embedded in the ISO"
	fi

	if [ -n "$xorriso_lib" ]; then
		LD_LIBRARY_PATH="$xorriso_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$xorriso_bin" -osirrox on -indev "$iso_file" \
			-extract /manifest.json "$destination" >/dev/null 2>&1 ||
			candidate_die "Could not extract /manifest.json from candidate ISO"
	else
		"$xorriso_bin" -osirrox on -indev "$iso_file" \
			-extract /manifest.json "$destination" >/dev/null 2>&1 ||
			candidate_die "Could not extract /manifest.json from candidate ISO"
	fi
}
