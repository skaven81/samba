#!/usr/bin/env bash
#===============================================================================
#          FILE: samba.sh
#
#         USAGE: ./samba.sh
#
#   DESCRIPTION: Entrypoint for samba docker container
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: David Personette (dperson@gmail.com),
#  ORGANIZATION:
#       CREATED: 09/28/2014 12:11
#      REVISION: 1.0
#===============================================================================

set -o nounset                              # Treat unset variables as an error

### import: import a smbpasswd file
# Arguments:
#   file) file to import
# Return: user(s) added to container
import() { local name id file="${1}"
    while read name id; do
        useradd "$name" -M -u "$id"
    done < <(cut -d: -f1,2 --output-delimiter=' ' $file)
    pdbedit -i smbpasswd:$file
}

### follow_symlinks: Enable insecure symlink following
# Arguments:
#   none)
# Return: smb.conf updated accordingly
follow_symlinks() { local file=/etc/samba/smb.conf
    sed -i -e 's/^\(\s*\)\(workgroup\)/\1allow insecure wide links = yes\n\1\2/' $file
}


### perms: fix ownership and permissions of share paths
# Arguments:
#   none)
# Return: result
perms() { local i file=/etc/samba/smb.conf
    for i in $(awk -F ' = ' '/   path = / {print $2}' $file); do
        chown -Rh smbuser. $i
        find $i -type d -exec chmod 775 {} \;
        find $i -type f -exec chmod 664 {} \;
    done
}

### share: Add share
# Arguments:
#   share) share name
#   path) path to share
#   browsable) 'yes' or 'no'
#   readonly) 'yes' or 'no'
#   guest) 'yes' or 'no'
#   users) list of allowed users
#   admins) list of admin users
# Return: result
share() { local share="$1" path="$2" browsable=${3:-yes} ro=${4:-yes} \
                guest=${5:-yes} users=${6:-""} admins=${7:-""} \
                file=/etc/samba/smb.conf
    share=$(echo $share)
    sed -i "/\\[$share\\]/,/^\$/d" $file
    echo "[$share]" >>$file
    echo "   path = $path" >>$file
    echo "   browsable = $browsable" >>$file
    echo "   read only = $ro" >>$file
    echo "   guest ok = $guest" >>$file
    [[ ${users:-""} && ! ${users:-""} =~ all ]] &&
        echo "   valid users = $(tr ',' ' ' <<< $users)" >>$file
    [[ ${admins:-""} && ! ${admins:-""} =~ none ]] &&
        echo "   admin users = $(tr ',' ' ' <<< $admins)" >>$file
    if [ "${FOLLOW_LINKS:-""}" = "true" ]; then
        echo "   follow symlinks = yes" >>$file
        echo "   wide links = yes" >>$file
    fi
    echo -e "" >>$file
}

### homes: Add special [homes] share
# Arguments: none
homes() { local file=/etc/samba/smb.conf
    sed -i "/\\[homes\\]/,/^\$/d" $file
    echo "[homes]" >>$file
    echo "    comment = Home Directories" >>$file
    echo "    browseable = no" >>$file
    echo "    writable = yes" >>$file
    if [ "${FOLLOW_LINKS:-""}" = "true" ]; then
        echo "    follow symlinks = yes" >>$file
        echo "    wide links = yes" >> $file
    fi
    echo -e "" >>$file

    # We also have to disable the 'force user' and
    # 'force group' options if we want homedirs
    # to work properly with their owners
    sed -i -e '/force \(user\|group\)/d' $file
}

### timezone: Set the timezone for the container
# Arguments:
#   timezone) for example EST5EDT
# Return: the correct zoneinfo file will be symlinked into place
timezone() { local timezone="${1:-EST5EDT}"
    [[ -e /usr/share/zoneinfo/$timezone ]] || {
        echo "ERROR: invalid timezone specified: $timezone" >&2
        return
    }

    if [[ -w /etc/timezone && $(cat /etc/timezone) != $timezone ]]; then
        echo "$timezone" >/etc/timezone
        ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1
    fi
}

### group: add a group
# Arguments:
#   name) for group
#   gid) for group
# Return: group added to container
group() { local name="${1}" id="${2:-""}"
    groupadd ${id:+-g $id} "$name"
}

### user: add a user
# Arguments:
#   name) for user
#   password) for user
#   id) for user
# Return: user added to container
user() { local name="${1}" passwd="${2}" id="${3:-""}" groups="${4:-""}"
    useradd "$name" -M ${id:+-u $id} ${groups:+-G $groups}
    echo -e "$passwd\n$passwd" | smbpasswd -s -a "$name"
}

### workgroup: set the workgroup
# Arguments:
#   workgroup) the name to set
# Return: configure the correct workgroup
workgroup() { local workgroup="${1}" file=/etc/samba/smb.conf
    sed -i 's|^\( *workgroup = \).*|\1'"$workgroup"'|' $file
}

### usage: Help
# Arguments:
#   none)
# Return: Help text
usage() { local RC=${1:-0}
    echo "Usage: ${0##*/} [-opt] [command]
Options (fields in '[]' are optional, '<>' are required):
    -h          This help
    -i \"<path>\" Import smbpassword
                required arg: \"<path>\" - full file path in container
    -n          Start the 'nmbd' daemon to advertise the shares
    -p          Set ownership and permissions on the shares
    -l          Enable following of symlinks + wide links for any
                shares or homedirs specified after this option (insecure!)
    -s \"<name;/path>[;browsable;readonly;guest;users;admins]\" Configure a share
                required arg: \"<name>;<comment>;</path>\"
                <name> is how it's called for clients
                <path> path to share
                NOTE: for the default value, just leave blank
                [browsable] default:'yes' or 'no'
                [readonly] default:'yes' or 'no'
                [guest] allowed default:'yes' or 'no'
                [users] allowed default:'all' or list of allowed users
                [admins] allowed default:'none' or list of admin users
    -m          Enable homedir sharing for users (defined below).  Mount your
                users' homedirs at /home
    -t \"\"       Configure timezone
                possible arg: \"[timezone]\" - zoneinfo timezone for container
    -g \"<group>[;gid]\"                         Add a group
                required arg: \"<group>\"
                <group> name of group
                [gid] set a specific GID
    -u \"<username;password>[;id;group,group]\"  Add a user
                required arg: \"<username>;<passwd>\"
                <username> for user
                <password> for user
                [id] UID for user
                [group,group] supplementary groups for user
    -w \"<workgroup>\"       Configure the workgroup (domain) samba should use
                required arg: \"<workgroup>\"
                <workgroup> for samba

The 'command' (if provided and valid) will be run instead of samba
" >&2
    exit $RC
}

while getopts ":hi:npls:mt:g:u:w:" opt; do
    case "$opt" in
        h) usage ;;
        i) import "$OPTARG" ;;
        n) NMBD="true" ;;
        p) PERMISSIONS="true" ;;
        l) FOLLOW_LINKS="true" && follow_symlinks ;;
        s) eval share $(sed 's/^\|$/"/g; s/;/" "/g' <<< $OPTARG) ;;
        m) homes ;;
        t) timezone "$OPTARG" ;;
        g) eval group $(sed 's|;| |g' <<< $OPTARG) ;;
        u) eval user $(sed 's|;| |g' <<< $OPTARG) ;;
        w) workgroup "$OPTARG" ;;
        "?") echo "Unknown option: -$OPTARG"; usage 1 ;;
        ":") echo "No argument value for option: -$OPTARG"; usage 2 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ "${TZ:-""}" ]] && timezone "$TZ"
[[ "${WORKGROUP:-""}" ]] && workgroup "$WORKGROUP"
[[ "${PERMISSIONS:-""}" ]] && perms

if [[ $# -ge 1 && -x $(which $1 2>&-) ]]; then
    exec "$@"
elif [[ $# -ge 1 ]]; then
    echo "ERROR: command not found: $1"
    exit 13
elif ps -ef | egrep -v grep | grep -q smbd; then
    echo "Service already running, please restart container to apply changes"
else
    [[ ${NMBD:-""} ]] && ionice -c 3 nmbd -D
    exec ionice -c 3 smbd --interactive --foreground --debuglevel=3 --debug-stdout
fi
