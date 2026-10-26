set -u
T=$(mktemp -d)
BK="$T/igpu-backup-20261020-120000"; mkdir -p "$BK"
printf 'STATE=partial\n' > "$BK/STATE"
printf 'EXISTED_KEXT=yes\n' > "$BK/META"
printf 'old_binary=aaaa\nold_plist=bbbb\n' > "$BK/SHA256.old"
printf 'STATE=complete\n' > "$BK/STATE"
state_of() { sed -n 's/^STATE=//p' "$1/STATE" 2>/dev/null | head -1; }
echo "state_of = [$(state_of "$BK")]"
[ "$(state_of "$BK")" = "complete" ] && echo "STATE 判定: MATCH ✓" || echo "STATE 判定: NOMATCH ✗"
echo "EXISTED  = [$(sed -n 's/^EXISTED_KEXT=//p' "$BK/META" | head -1)]"
echo "old_bin  = [$(sed -n 's/^old_binary=//p' "$BK/SHA256.old" | head -1)]"
echo "old_plist= [$(sed -n 's/^old_plist=//p' "$BK/SHA256.old" | head -1)]"
rm -rf "$T"