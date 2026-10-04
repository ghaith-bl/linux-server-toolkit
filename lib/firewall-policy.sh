#!/usr/bin/env bash
# shellcheck disable=SC2034
# (SC2034: the POLICY_* variables are read by the scripts that source this file.)
#
# lib/firewall-policy.sh — reads the firewall policy (firewall/policy.conf)
#
# This file is SOURCED, not executed, and after lib/common.sh (it uses die).
# firewall-apply.sh and firewall-check.sh both read the policy through it, so
# the two can never understand the policy in different ways.

# ---- re-source guard -------------------------------------------------------
[[ -n "${FIREWALL_POLICY_SH_LOADED:-}" ]] && return 0
FIREWALL_POLICY_SH_LOADED=1

# ---- what policy_load fills ------------------------------------------------

POLICY_DEFAULT_INCOMING=""   # deny | allow | reject
POLICY_DEFAULT_OUTGOING=""
POLICY_DEFAULT_ROUTED=""
POLICY_LOGGING=""            # off | low | medium | high | full
POLICY_RULES=()              # this machine's rules, one ufw command per entry
POLICY_RULES_IN=0            # how many of them let a connection in
POLICY_RULES_OUT=0           # how many let a connection out

# ---- one rule as a ufw command ---------------------------------------------

# policy_rule_command DIR PROTO PORT PEER COMMENT
# Prints the rule as the words that follow "ufw" on a command line, spelled
# exactly the way `ufw show added` prints a rule back (ufw 0.36.2, get_command
# in src/parser.py). firewall-apply.sh runs these words; firewall-check.sh
# compares them with what ufw prints. The four shapes:
#
#   out, to anywhere      allow out 67/udp comment '...'
#   out, to an address    allow out to 192.168.122.1 port 53 proto udp comment '...'
#   in, from anywhere     allow 22/tcp comment '...'
#   in, from an address   allow from 192.168.122.1 to any port 22 proto tcp comment '...'
policy_rule_command() {
    local dir="$1"
    local proto="$2"
    local port="$3"
    local peer="$4"
    local comment="$5"

    if [ "$dir" = "out" ] && [ "$peer" = "any" ]; then
        echo "allow out $port/$proto comment '$comment'"
    elif [ "$dir" = "out" ]; then
        echo "allow out to $peer port $port proto $proto comment '$comment'"
    elif [ "$peer" = "any" ]; then
        echo "allow $port/$proto comment '$comment'"
    else
        echo "allow from $peer to any port $port proto $proto comment '$comment'"
    fi
}

# ---- the whole policy ------------------------------------------------------

# policy_load FILE HOST
# Checks every line of FILE, then fills the POLICY_* variables above with the
# defaults, the logging level and the rules of the machine HOST. One wrong
# line anywhere ends the script (die): a policy is used whole, or not at all.
policy_load() {
    local file="$1"
    local host="$2"
    local keyword f1 f2 f3 f4 f5 f6 extra
    local field
    local comment
    local rule_cmd
    local seen=""       # the comments already used, to catch a tag used twice
    local line_no=0

    # -s: the file exists and is not empty.
    if [ ! -s "$file" ]; then
        die "policy file not found, or empty: $file"
    fi

    POLICY_RULES=()
    POLICY_RULES_IN=0
    POLICY_RULES_OUT=0

    # sed cuts each comment off (from the # to the end of the line), so a
    # comment line arrives empty. "|| [ -n ... ]" keeps a last line that has
    # no newline after it.
    while read -r keyword f1 f2 f3 f4 f5 f6 extra || [ -n "$keyword" ]; do
        line_no=$(( line_no + 1 ))

        if [ -z "$keyword" ]; then
            continue
        fi

        case "$keyword" in
            default)
                # default <direction> <policy>
                if [ -n "$f3" ]; then
                    die "$file line $line_no: too many fields"
                fi
                case "$f2" in
                    deny | allow | reject) ;;
                    *) die "$file line $line_no: unknown policy '$f2'" ;;
                esac
                case "$f1" in
                    incoming) POLICY_DEFAULT_INCOMING="$f2" ;;
                    outgoing) POLICY_DEFAULT_OUTGOING="$f2" ;;
                    routed)   POLICY_DEFAULT_ROUTED="$f2" ;;
                    *) die "$file line $line_no: unknown direction '$f1'" ;;
                esac
                ;;

            logging)
                # logging <level>
                if [ -n "$f2" ]; then
                    die "$file line $line_no: too many fields"
                fi
                case "$f1" in
                    off | low | medium | high | full) POLICY_LOGGING="$f1" ;;
                    *) die "$file line $line_no: unknown logging level '$f1'" ;;
                esac
                ;;

            rule)
                # rule <host> <dir> <proto> <port> <peer> <tag>
                if [ -n "$extra" ]; then
                    die "$file line $line_no: too many fields"
                fi
                for field in "$f1" "$f2" "$f3" "$f4" "$f5" "$f6"; do
                    if [ -z "$field" ]; then
                        die "$file line $line_no: a rule needs 6 fields"
                    fi
                done
                # A hostname: lowercase letters, digits and -.
                if ! [[ "$f1" =~ ^[a-z][a-z0-9-]*$ ]]; then
                    die "$file line $line_no: not a host name: '$f1'"
                fi
                case "$f2" in
                    in | out) ;;
                    *) die "$file line $line_no: dir must be in or out, not '$f2'" ;;
                esac
                case "$f3" in
                    tcp | udp) ;;
                    *) die "$file line $line_no: proto must be tcp or udp, not '$f3'" ;;
                esac
                # A port: 1 to 5 digits with no leading 0, and at most 65535.
                if ! [[ "$f4" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$f4" -gt 65535 ]; then
                    die "$file line $line_no: not a port number: '$f4'"
                fi
                # A peer: any, one IPv4 address, or a range (address/bits).
                # Only the shape is checked here; ufw itself checks the value
                # before firewall-apply.sh changes anything.
                if ! [[ "$f5" =~ ^(any|([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?)$ ]]; then
                    die "$file line $line_no: peer is not any, an address or a range: '$f5'"
                fi
                # ufw stores a single address without /32, and firewall-check.sh
                # compares the text: write it the way ufw does.
                if [[ "$f5" == */32 ]]; then
                    die "$file line $line_no: write one address without /32: '$f5'"
                fi
                if ! [[ "$f6" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
                    die "$file line $line_no: tag may hold a-z, 0-9 and - only: '$f6'"
                fi

                # The comment names the rule: once per machine and direction.
                comment="pol:$f1:$f2:$f6"
                case " $seen " in
                    *" $comment "*) die "$file line $line_no: tag used twice: $comment" ;;
                esac
                seen="$seen $comment"

                # Every machine's lines are checked; only HOST's are kept.
                if [ "$f1" != "$host" ]; then
                    continue
                fi
                rule_cmd=$(policy_rule_command "$f2" "$f3" "$f4" "$f5" "$comment")
                POLICY_RULES+=("$rule_cmd")
                if [ "$f2" = "in" ]; then
                    POLICY_RULES_IN=$(( POLICY_RULES_IN + 1 ))
                else
                    POLICY_RULES_OUT=$(( POLICY_RULES_OUT + 1 ))
                fi
                ;;

            *)
                die "$file line $line_no: unknown record '$keyword'"
                ;;
        esac
    done < <(sed 's/#.*//' "$file")

    # The policy must say all of it: nothing is left to ufw's own defaults.
    if [ -z "$POLICY_DEFAULT_INCOMING" ] || [ -z "$POLICY_DEFAULT_OUTGOING" ] ||
       [ -z "$POLICY_DEFAULT_ROUTED" ]; then
        die "$file: the three defaults (incoming, outgoing, routed) must all be set"
    fi
    if [ -z "$POLICY_LOGGING" ]; then
        die "$file: the logging level must be set"
    fi

    # A machine with no rules is a machine missing from the policy.
    if [ "${#POLICY_RULES[@]}" -eq 0 ]; then
        die "$file: no rules for the machine '$host'"
    fi
}
