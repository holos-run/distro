#!/bin/sh
# preflight.sh sets up the Proxmox API access talosvm uses and checks the
# host prerequisites it depends on. Run it as root on any one node of the
# garage cluster; access control and SDN are cluster-wide, and the nested
# virtualization check reaches the other nodes over the cluster's own root
# ssh.
#
#   preflight.sh [--check] [privileges.txt]
#
# privileges.txt, next to this script by default, is the authoritative list
# of privileges. The script converges on it:
#
#   - user holos@pve exists;
#   - role HolosProvisioner holds exactly the listed privileges, no more;
#   - holos@pve has that role on / with propagation, and no other ACL entry;
#     a group the user is in that holds ACLs is reported, not changed, since
#     that grant belongs to whoever made the group;
#   - token holos@pve!distro exists with privilege separation off, so it has
#     the user's privileges. Its secret is printed once, when it is created,
#     and an existing token is never rotated or shown.
#
# It changes nothing on the host prerequisites, only reports them: nested
# virtualization on every node, the k8s vnet, the local-zfs storage and the
# garage storage with ISO and snippets content, and the datacenter tag policy
# talosvm's tags rely on.
#
# --check changes nothing, reports what differs, and exits 1 when anything
# differs or a prerequisite is missing. Without it, the script prints each
# change as it makes it and exits 1 only for a missing prerequisite.
set -eu

LC_ALL=C
export LC_ALL

USERID=holos@pve
ROLE=HolosProvisioner
TOKEN=distro
ZONE=cloud
VNET=k8s
MTU=8950
DISK_STORAGE=local-zfs
ISO_STORAGE=garage
export USERID ROLE

usage() {
	sed -n '2,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//'
}

check=0
privfile=
while [ $# -gt 0 ]; do
	case $1 in
	--check | -n) check=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		echo "preflight.sh: unknown flag $1" >&2
		exit 2
		;;
	*) privfile=$1 ;;
	esac
	shift
done
[ -n "$privfile" ] || privfile=$(dirname "$0")/privileges.txt

die() {
	echo "preflight.sh: $*" >&2
	exit 2
}

[ "$(id -u)" = 0 ] || die "run as root on a Proxmox node"
command -v pveum >/dev/null 2>&1 || die "pveum not found: run on a Proxmox node"
[ -r "$privfile" ] || die "cannot read $privfile; copy privileges.txt next to this script or name it"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The same parse as the Go side: drop comments, keep the first word.
sed 's/#.*//' "$privfile" | awk 'NF { print $1 }' | sort -u >"$tmp/want"
[ -s "$tmp/want" ] || die "$privfile lists no privileges"
privs=$(paste -sd, "$tmp/want")

drifts=0
problems=0
changes=0

say() { printf '%s\n' "$*"; }
problem() {
	say "PROBLEM: $*"
	problems=$((problems + 1))
}
ok() { say "ok:      $*"; }

# drift_only DESCRIPTION reports something the script will not change itself:
# a difference in --check mode, a warning otherwise.
drift_only() {
	if [ "$check" = 1 ]; then
		say "DRIFT:   $*"
		drifts=$((drifts + 1))
	else
		say "WARNING: $*"
	fi
}

# change DESCRIPTION COMMAND... makes a change, or in --check mode only
# reports that it would.
change() {
	desc=$1
	shift
	if [ "$check" = 1 ]; then
		say "DRIFT:   $desc"
		drifts=$((drifts + 1))
	else
		say "CHANGE:  $desc"
		# No command may read the script's stdin: the ACL loop reads its
		# entries from there.
		"$@" </dev/null
		changes=$((changes + 1))
	fi
}

get() { pvesh get "$1" --output-format json 2>/dev/null; }

# json PERL-EXPR reads JSON on stdin into $d and evaluates the expression.
# Perl and its core JSON::PP are on every Proxmox host; jq is not.
json() {
	perl -MJSON::PP -0777 -e 'my $d = decode_json(join("", <STDIN>)); '"$1"
}

# --- user -------------------------------------------------------------------

user_exists=0
if get "/access/users/$USERID" >"$tmp/user.json"; then
	user_exists=1
	ok "user $USERID exists"
	# enable defaults to on; expire is epoch seconds, 0 for never. groups
	# may come back as a list or as comma-separated text.
	json '
		my $g = $d->{groups} // [];
		my @g = ref $g eq "ARRAY" ? @$g : split /[,;\s]+/, $g;
		print join(" ", (defined $d->{enable} && !$d->{enable}) ? 1 : 0,
			$d->{expire} // 0, time), "\n";
		print "$_\n" for grep { length } @g;' <"$tmp/user.json" >"$tmp/user"
	read -r disabled expire now <"$tmp/user"
	sed 1d "$tmp/user" >"$tmp/groups"
	if [ "$disabled" = 1 ]; then
		problem "user $USERID is disabled; enable it with pveum user modify $USERID --enable 1"
	fi
	if [ "$expire" != 0 ] && [ "$expire" -le "$now" ]; then
		problem "user $USERID expired; clear it with pveum user modify $USERID --expire 0"
	fi
else
	: >"$tmp/groups"
	change "create user $USERID" \
		pveum user add "$USERID" --comment "Holos distro provider"
fi

get /access/acl >"$tmp/acl.json"

# Anyone else holding the role is affected when the role is set to the list.
json '
	for my $e (@$d) {
		my $u = $e->{ugid};
		next if $e->{roleid} ne $ENV{ROLE};
		next if $u eq $ENV{USERID} || index($u, "$ENV{USERID}!") == 0;
		print "$e->{path} $e->{type} $u\n";
	}' <"$tmp/acl.json" >"$tmp/others"
while read -r path type ugid; do
	drift_only "$ROLE is also granted on $path to $type $ugid; setting the role to the list narrows it for them too"
done <"$tmp/others"

# --- role -------------------------------------------------------------------

if get "/access/roles/$ROLE" >"$tmp/role.json"; then
	json 'print "$_\n" for sort grep { $d->{$_} } keys %$d' <"$tmp/role.json" >"$tmp/have"
	if cmp -s "$tmp/want" "$tmp/have"; then
		ok "role $ROLE holds exactly the $(wc -l <"$tmp/want" | tr -d ' ') listed privileges"
	else
		add=$(comm -23 "$tmp/want" "$tmp/have" | paste -sd' ' -)
		del=$(comm -13 "$tmp/want" "$tmp/have" | paste -sd' ' -)
		# No -append: the role is set to exactly the list, which is what
		# removes privileges the list no longer has.
		change "set role $ROLE to the list (add: ${add:-none}; remove: ${del:-none})" \
			pveum role modify "$ROLE" -privs "$privs"
	fi
else
	change "create role $ROLE with $privs" \
		pveum role add "$ROLE" -privs "$privs"
fi

# --- ACL --------------------------------------------------------------------

# Every ACL entry naming the user or one of its tokens, as
# path<TAB>roleid<TAB>type<TAB>ugid<TAB>propagate.
json '
	for my $e (@$d) {
		my $u = $e->{ugid};
		next unless $u eq $ENV{USERID} || index($u, "$ENV{USERID}!") == 0;
		print join("\t", $e->{path}, $e->{roleid}, $e->{type}, $u, $e->{propagate} ? 1 : 0), "\n";
	}' <"$tmp/acl.json" >"$tmp/acl"

found=0
tab=$(printf '\t')
while IFS=$tab read -r path roleid type ugid propagate; do
	if [ "$path" = / ] && [ "$roleid" = "$ROLE" ] && [ "$type" = user ] && [ "$ugid" = "$USERID" ]; then
		found=1
		if [ "$propagate" = 1 ]; then
			ok "$USERID has $ROLE on / with propagation"
		else
			change "turn on propagation of $ROLE on / for $USERID" \
				pveum acl modify / --users "$USERID" --roles "$ROLE" --propagate 1
		fi
		continue
	fi
	# Anything else grants privileges outside the list.
	if [ "$type" = token ]; then
		change "remove ACL $path $roleid for token $ugid" \
			pveum acl delete "$path" --tokens "$ugid" --roles "$roleid"
	else
		change "remove ACL $path $roleid for $type $ugid" \
			pveum acl delete "$path" --users "$ugid" --roles "$roleid"
	fi
done <"$tmp/acl"
if [ "$found" = 0 ]; then
	change "grant $ROLE on / to $USERID" \
		pveum acl modify / --users "$USERID" --roles "$ROLE" --propagate 1
fi

# A group's ACLs reach the user too, and so its token, outside the list. The
# script does not take the user out of a group someone else made for their
# own grant; it reports it, and --check fails on it.
while read -r group; do
	n=$(GROUP=$group json 'print scalar grep { $_->{type} eq "group" && $_->{ugid} eq $ENV{GROUP} } @$d' <"$tmp/acl.json")
	if [ "$n" != 0 ]; then
		drift_only "$USERID is in group $group, which holds $n ACL entries outside the list; not changed here, since the group is someone else's grant: take the user out of it with pveum user modify $USERID --groups <the others>"
	fi
done <"$tmp/groups"

# --- token ------------------------------------------------------------------

if [ "$user_exists" = 1 ] && get "/access/users/$USERID/token/$TOKEN" >"$tmp/token.json"; then
	privsep=$(json 'print $d->{privsep} ? 1 : 0' <"$tmp/token.json")
	if [ "$privsep" = 0 ]; then
		ok "token $USERID!$TOKEN exists with privilege separation off (secret not shown)"
	else
		change "turn off privilege separation on token $USERID!$TOKEN (the secret is unchanged)" \
			pveum user token modify "$USERID" "$TOKEN" --privsep 0
	fi
elif [ "$check" = 1 ]; then
	change "create token $USERID!$TOKEN" true
else
	say "CHANGE:  create token $USERID!$TOKEN"
	# The secret exists only in this output, so it is printed raw before
	# anything else can fail and lose it. Parsing it for the env-file lines
	# comes after and is allowed to fail.
	created=$(pveum user token add "$USERID" "$TOKEN" --privsep 0 \
		--comment "talosvm, go.holos.run/distro" --output-format json </dev/null) || {
		printf '%s\n' "$created"
		die "pveum user token add failed; if it printed a secret above, keep it"
	}
	printf '\nThe new token, with its secret, shown this once:\n%s\n' "$created"
	changes=$((changes + 1))
	secret=$(printf '%s' "$created" | json 'print $d->{value} // ""' 2>/dev/null) || secret=
	if [ -n "$secret" ]; then
		cat <<EOF

Put it in ~/.config/holos/proxmox.env on the machine that runs talosvm,
never in git:

  PROXMOX_URL=https://$(hostname -f 2>/dev/null || hostname):8006
  PROXMOX_TOKEN_ID=$USERID!$TOKEN
  PROXMOX_TOKEN_SECRET=$secret

EOF
	else
		say "Could not parse that output; the secret is its \"value\". Put it in ~/.config/holos/proxmox.env as PROXMOX_TOKEN_SECRET."
	fi
fi

# --- host prerequisites -----------------------------------------------------

get /nodes | json 'print "$_->{node}\n" for sort { $a->{node} cmp $b->{node} } @$d' >"$tmp/nodes"
self=$(hostname)

nested_cmd='for m in kvm_intel kvm_amd; do f=/sys/module/$m/parameters/nested; if [ -r $f ]; then echo "$m $(cat $f)"; fi; done'
while read -r node; do
	if [ "$node" = "$self" ]; then
		out=$(sh -c "$nested_cmd")
	elif ! out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$node" "$nested_cmd" 2>/dev/null); then
		problem "cannot reach $node over ssh to check nested virtualization; check it there by hand"
		continue
	fi
	case $out in
	*" Y"* | *" 1"*) ok "$node: nested virtualization on ($out)" ;;
	"") problem "$node: neither kvm_intel nor kvm_amd is loaded" ;;
	*) problem "$node: nested virtualization off ($out); see providers/proxmox/README.md" ;;
	esac

	for s in "$DISK_STORAGE" "$ISO_STORAGE"; do
		if get "/nodes/$node/storage/$s/status" >"$tmp/st.json" &&
			[ "$(json 'print $d->{active} ? 1 : 0' <"$tmp/st.json")" = 1 ]; then
			ok "$node: storage $s active"
		else
			problem "$node: storage $s is missing or not active"
		fi
	done
done <"$tmp/nodes"

if get "/storage/$DISK_STORAGE" >"$tmp/s.json" &&
	json 'exit(($d->{content} // "") =~ /(^|,)images(,|$)/ ? 0 : 1)' <"$tmp/s.json"; then
	ok "storage $DISK_STORAGE allows VM images"
else
	problem "storage $DISK_STORAGE is missing or does not allow images"
fi
if get "/storage/$ISO_STORAGE" >"$tmp/s.json" &&
	json 'my $c = $d->{content} // ""; exit($c =~ /(^|,)iso(,|$)/ && $c =~ /(^|,)snippets(,|$)/ && ($d->{shared} || $d->{type} eq "nfs") ? 0 : 1)' <"$tmp/s.json"; then
	ok "storage $ISO_STORAGE is shared and allows ISO images and snippets"
else
	problem "storage $ISO_STORAGE is missing, not shared, or does not allow both ISO images and snippets (talosvm puts each node's network snippet there)"
fi

if get "/cluster/sdn/vnets/$VNET" >"$tmp/vnet.json"; then
	zone=$(json 'print $d->{zone} // ""' <"$tmp/vnet.json")
	if [ "$zone" = "$ZONE" ]; then
		ok "SDN vnet $VNET is in zone $ZONE"
	else
		problem "SDN vnet $VNET is in zone '$zone', want $ZONE"
	fi
else
	problem "SDN vnet $VNET does not exist"
fi

# talosvm writes this MTU into every node's network snippet (VnetMTU in
# internal/talosvm/network.go), so the zone must carry it. An EVPN zone's MTU
# is set on the zone; unset, Proxmox derives a smaller one.
if get "/cluster/sdn/zones/$ZONE" >"$tmp/zone.json"; then
	mtu=$(json 'print $d->{mtu} // ""' <"$tmp/zone.json")
	if [ "$mtu" = "$MTU" ]; then
		ok "SDN zone $ZONE has MTU $MTU"
	else
		problem "SDN zone $ZONE has MTU '${mtu:-unset}', want $MTU, which talosvm writes into every node's snippet"
	fi
else
	problem "SDN zone $ZONE does not exist"
fi

# The role has no Sys.Modify, so Proxmox lets the token set tags only while
# the datacenter allows users free-form tags (the default) and none of
# talosvm's tags is registered as privileged.
# Both options may come back parsed or as their property-string text.
get /cluster/options | json '
	my $uta = $d->{"user-tag-access"};
	my $allow = ref $uta eq "HASH" ? $uta->{"user-allow"}
		: (defined $uta && $uta =~ /user-allow=(\w+)/) ? $1 : undef;
	$allow //= "free";
	my $rt = $d->{"registered-tags"} // [];
	my @reg = grep { /^talosvm/ } (ref $rt eq "ARRAY" ? @$rt : split /[;,\s]+/, $rt);
	print "$allow ", scalar(@reg), "\n";' >"$tmp/tags"
read -r allow registered <"$tmp/tags"
if [ "$allow" = free ] && [ "$registered" = 0 ]; then
	ok "datacenter tag policy lets the token set talosvm tags"
else
	problem "datacenter tag policy (user-allow=$allow, $registered registered talosvm tags) would refuse talosvm's tags; set user-tag-access user-allow=free"
fi

# --- summary ----------------------------------------------------------------

say ""
if [ "$check" = 1 ]; then
	say "check: $drifts difference(s) from privileges.txt and the access setup, $problems prerequisite problem(s)"
	[ "$drifts" = 0 ] && [ "$problems" = 0 ]
else
	say "applied $changes change(s); $problems prerequisite problem(s)"
	[ "$problems" = 0 ]
fi
