# Name: mk/lib.mk - Makefile library
# Usage: include mk/lib.mk
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2026.03.30

#-----
# time
#-----

#
# t()      - return current epoch (sec.ms)
# t_now()  - return current timestamp (yyyy.mm.dd-hh:mm:ss)
# t_znow() - return current compressed timestamp (yyyymmdd.hhmmss)
# usage: $(t)
# usage: $(t_now)
# usage: $(t_znow)
#

t      = $$(date +%s.%3N)
t_now  = $$(date +%Y.%m.%d-%H:%M:%S)
t_znow = $$(date +%Y%m%d.%H%M%S)

#
# at() - format epoch (sec.ms -> yyyy.mm.dd-hh:mm:ss)
# usage: $(call at,epoch)
#

at = $$(date -d @$$(printf "%.0f" $(1)) +%Y.%m.%d-%H:%M:%S)

#
# t_hms_ms()    - format duration as hms.ms
# t_hms()       - format duration as hms
# t_hms_colon() - format duration as h:m:s
# usage: $(call t_hms_ms,t_delta)
# usage: $(call t_hms,t_delta)
# usage: $(call t_hms_colon,t_delta)
#

define t_hms_ms
$$(
    awk -v t=$(1) '
        BEGIN {
            s = int(t);
            ms = 1000 * (t - s);
            h = int(s / 3600); s %= 3600;
            m = int(s / 60); s %= 60;
            if (h > 0) printf("%dh%02dm%02d.%03ds", h, m, s, ms);
            else if (m > 0) printf("%dm%02d.%03ds", m, s, ms);
            else printf("%d.%03ds", s, ms)
        }'
)
endef

define t_hms
$$(
    awk -v t=$(1) '
        BEGIN {
            s = int(t + .5);
            h = int(s / 3600); s %= 3600;
            m = int(s / 60); s %= 60;
            if (h > 0) printf("%dh%02dm%02ds", h, m, s);
            else if (m > 0) printf("%dm%02ds", m, s);
            else printf("%ds", s)
        }'
)
endef

define t_hms_colon
$$(
    awk -v t=$(1) '
        BEGIN {
            s = int(t + .5);
            h = int(s / 3600); s %= 3600;
            m = int(s / 60); s %= 60;
            printf("%02d:%02d:%02d", h, m, s);
        }'
)
endef

#
# t_delta()        - compute time difference (sec.ms)
# t_delta_hms_ms() - compute time difference (hms.ms)
# t_delta_hms()    - compute time difference (hms)
# usage: $(call t_delta,t1,t2)
# usage: $(call t_delta_hms_ms,t1,t2)
# usage: $(call t_delta_hms,t1,t2)
#

t_delta = $$(awk -v t1=$(1) -v t2=$(2) 'BEGIN { printf("%.3f", t2 - t1) }')
t_delta_hms_ms = $(call t_hms_ms,$(call t_delta,$(1),$(2)))
t_delta_hms = $(call t_hms,$(call t_delta,$(1),$(2)))

#------
# runid
#------

#
# get_runid() - get and validate runid
# usage: $(get_runid)
#

define get_runid
$$(
    case "$${runid-}" in
        "")   runid=$$(kv_get $(statusf) runid) ;;
        prev) [ -L "$(prev)" ] && runid=$$(readlink "$(prev)") ;;
        last) [ -L "$(last)" ] && runid=$$(readlink "$(last)") ;;
    esac

    if [ -d "$(stats)/$$runid" ]; then
        printf "%s" $$runid
    else
        if [ -t 2 ]; then
            printf "[%s] $${_RED_}invalid runid '%s'$$RST\n" \
                $(project) $$runid >&2
        fi
        $(call log,[$$runid] invalid runid)
        exit 1
    fi
)
endef

#---------
# kv store
#---------

#
# define_kv() - define kv_get() and kv_set() shell functions
# kv_set()    - replace key/value (append if missing)
# kv_get()    - get key/value (empty if missing)
# usage: $(define_kv)
#        kv_get file key
#        kv_set file key value
#

define define_kv
kv_set() {
    local f=$$1 k=$$2 v=$$3
    printf -v v "%s" "$$v"
    if grep -q "^$$k:" "$$f"; then
        sed -Ei "s|^$$k:.*|$$k: $$v|" "$$f"
    else
        printf "%s: %s\n" $$k "$$v" >> "$$f"
    fi
}

kv_get() {
    local f=$$1 k=$$2
    sed -En 's/^'$$k':[[:space:]]*//p' "$$f"
}
endef

#--------
# process
#--------

#
# watch_child() - return pid of a child process
# usage: $(call watch_child,ppid,procname,tries,delay)
#

define watch_child
$$(
    ppid=$(1) procname=$(2) tries=$(3) delay=$(4)
    for _ in {1..$$tries}; do
        child=$$(pgrep -n -P $$ppid -x $$procname || true)
      $(call log,[watch_child] try=$$_/$$tries ppid=$$ppid proc=$$procname child=$${child:--})
        [ -n "$$child" ] && break
        sleep $$delay
    done
    printf "%s" "$$child"
)
endef

#
# get_command_by_pid() - return command line by pid
# usage: $(call get_command_by_pid,pid)
#

define get_command_by_pid
$$(
	pid=$(1)
    mapfile -d '' -t argv < /proc/$$pid/cmdline
    printf -v cmd "%s " "$${argv[@]}"
    printf "%s" "$${cmd% }"
)
endef

#
# watch_rclone() - discover rclone_pid and rclone_cmd
# usage: $(call watch_rclone,rulef,program_pid)
#

define watch_rclone
(
    rulef=$(1) program_pid=$(2) tries=$(watch_tries) delay=$(watch_delay)
  $(call log,[watch_rclone] start rulef=$$rulef program_pid=$$program_pid tries=$$tries delay=$$delay)
    rclone_pid=$(call watch_child,$$program_pid,rclone,$$tries,$$delay)
  $(call log,[watch_rclone] result program_pid=$$program_pid rclone_pid=$${rclone_pid:--})
    if [ -n "$$rclone_pid" ]; then
        kv_set "$(statusf)" rclone_pid $$rclone_pid
        rclone_cmd=$(call get_command_by_pid,$$rclone_pid)
        if [ -n "$$rclone_cmd" ]; then
            kv_set "$$rulef" rclone_cmd "$$rclone_cmd"
        fi
    else
        kv_set "$(statusf)" rclone_pid unknown
    fi
) & watcher_pid=$$!
endef

#
# stop_guard() - exit current rule if a stop flag exists
# usage: $(call stop_guard,runid,ruleid)
#

define stop_guard
{
    if [ -f "$(stop_flag)" ]; then
        printf "[%s] stop flag found: exit after current rule \
            (runid=%s, ruleid=%s)\n" $(project) $(1) $(2) >&2
        rm -f "$(stop_flag)"
        $(call log,[$(1):$(2)] stop flag found: exit after current rule)
        kv_set "$(statusf)" gstate idle
        kv_set "$(statusf)" result stopped
        kv_set "$(statusf)" rc 200
        exit 0
    fi
}
endef

#
# define_trap_on_signal() - define trap_on_signal() shell function
# trap_on_signal()        - handle signals
# usage: $(define_trap_on_signal)
#        trap_on_signal signal rc
#

define define_trap_on_signal
trap_on_signal() {
    local sig=$$1 sigcode=$$2
    local rc=$$((128 + sigcode))
    local t0 t2 t3 rule_ended_at rule_elapsed rule_elapsed_hms_ms k
    local result=killed

    $(call log,[$$runid:$$ruleid] (WARN) caught $$sig signal)

    t2=$(t)
    rule_ended_at=$(call at,$$t2)
    if [ -n "$${t1-}" ]; then
        rule_elapsed=$(call t_delta,$$t1,$$t2)
        rule_elapsed_hms_ms=$(call t_hms_ms,$$rule_elapsed)
    else
        rule_elapsed=
        rule_elapsed_hms_ms=unknown
    fi

    $(call append_rule_log,$$runid,$$ruleid,$$rule_log)
    kv_set "$$rulef" rule_ended_at $$rule_ended_at
    if [ -n "$$rule_elapsed" ]; then
        kv_set "$$rulef" rule_elapsed $$rule_elapsed
    fi
    kv_set "$$rulef" rc $$rc

    kv_set "$(statusf)" program_pid -
    kv_set "$(statusf)" rclone_pid -
    $(call log,[$$runid:$$ruleid] (WARN) end '$(program_name)': rc=$$rc \
        (elapsed: $$rule_elapsed_hms_ms))

    t0=$$(kv_get "$(statusf)" started_at_epoch)
    t3=$(t)
    kv_set "$(statusf)" ended_at_epoch $$t3
    kv_set "$(statusf)" ended_at $(call at,$$t3)
    kv_set "$(statusf)" total_elapsed $(call t_delta,$$t0,$$t3)
    kv_set "$(statusf)" gstate idle
    kv_set "$(statusf)" result $$result
    kv_set "$(statusf)" rc $$rc

    k=$$(kv_get "$(statusf)" rules_done)
    n=$$(kv_get "$(statusf)" rules_total)
    $(call log,[$$runid] end '$(project)' \
	    (rules=$$k/$$n$(,) result=$$result$(,) rc=$$rc) \
        (total elapsed: $(call t_delta_hms_ms,$$t0,$$t3)))
    exit $$rc
}
endef

#------
# rules
#------

#
# define_parse_rule() - define parse_rule() shell function
# parse_rule()        - parse a rule and set key=value
# usage: $(define_parse_rule)
#        parse_rule rule
#

define define_parse_rule
parse_rule() {
    local rule=$$1
    case "$$rule" in
        *" -- "*) path=$${rule%% -- *} opts=$${rule#* -- } ;;
        *)        path=$$rule opts= ;;
    esac
    [ "$$path" = . ] && path=
    ruleid=$$(printf "%s" "$$path" | sed 's|/|_|g' | tr '[:space:]' '_')
    set -f; eval "$$opts"; set +f
}
endef

#
# count_rules() - count rules in list
# usage: $(count_rules,rules_list)
#

count_rules = $$(grep -Ev '^[[:space:]]*(\#|$$)' "$(1)" | wc -l)

#------
# stats
#------

#
# get_rclone_stats() - parse rclone log and print key/value metrics
# usage: $(call get_rclone_stats,rule_log)
#

define get_rclone_stats
awk '
    function xc(s) { sub(/,$$/, "", s); return s }

    BEGIN {
        checks = 0;
        xfer = 0; xfer_new = 0; xfer_replaced = 0;
        deleted = 0;
    }

    /^Checks:/                       { checks = $$2 "/" xc($$4) }
    /^Transferred:/ && !/ETA/        { xfer = $$2 "/" xc($$4) }
    /^Transferred:/ && /ETA/         { xfer_size = $$2 $$3 "/" $$5 xc($$6) }
    /Copied \(new\)$$/               { xfer_new++ }
    /Copied \(replaced existing\)$$/ { xfer_replaced++ }
    /^Deleted:/                      { deleted = $$2 }
    /^Elapsed time:/                 { elapsed = $$3 }

    END {
        printf "rclone_checks %s\n",           checks
        printf "rclone_transferred %s\n",      xfer
        printf "rclone_transferred_size %s\n", xfer_size
        printf "rclone_copied_new %d\n",       xfer_new
        printf "rclone_copied_replaced %d\n",  xfer_replaced
        printf "rclone_deleted %d\n",          deleted
        printf "rclone_elapsed %s\n",          elapsed
    }
' "$(1)"
endef

#
# save_rclone_stats() - write rclone metrics to the rule stats file
# usage: $(call save_rclone_stats,runid,ruleid,rulef,rule_log)
#

define save_rclone_stats
(
    runid=$(1) ruleid=$(2) rulef=$(3) rule_log=$(4)
    declare -A S
    while read k v; do
        S[$$k]=$$v
        kv_set "$$rulef" $$k $$v
    done < <($(call get_rclone_stats,$$rule_log))
    printf -v stats_log "checks=%s, transferred=%s (%s) \
        (new=%d, replaced=%d), deleted=%d, elapsed=%s" \
        "$${S[rclone_checks]}" \
        "$${S[rclone_transferred]}" "$${S[rclone_transferred_size]}" \
        "$${S[rclone_copied_new]}" "$${S[rclone_copied_replaced]}" \
        "$${S[rclone_deleted]}" "$${S[rclone_elapsed]}"
    $(call log,[$$runid:$ruleid] rclone stats: $$stats_log)
)
endef

#-------
# status
#-------

#
# get_rstate() - compute rule state (done|fail|run|queue)
# usage: $(call get_rstate,rulef,gstate)
#

define get_rstate
$$(
    rulef=$(1) gstate=$(2)
    if [ ! -f "$$rulef" ]; then
        printf queue
    elif rc=$$(kv_get "$$rulef" rc); [ -n "$$rc" ]; then
        printf done
    elif [ $$gstate = running ]; then
        printf run
    else
        printf fail
    fi
)
endef

#-------
# config
#-------

#
# get_config() - extract config params
# usage: $(get_config)
#

define get_config
{
    type= provider= region= endpoint=
	while read -r k _ v; do
        case "$$k" in
            type)     type=$$v     ;;
            provider) provider=$$v ;;
            region)   region=$$v   ;;
            endpoint) endpoint=$$v ;;
        esac
    done < <($(rclone) --config $(rclone_conf) config show $(remote));
}
endef

#--------
# logging
#--------

#
# log() - write timestamped log
# usage: $(call log,message)
#

make := $(shell basename "$(MAKE)")
log = printf "%s [%s(%s):%d] %s\n" $(t_now) $(make) $@ $$$$ "$(1)" >> "$(logf)"

#
# append_rule_log() - append rclone log to the main log
# usage: $(call append_rule_log,runid,ruleid,rule_log)
#

define append_rule_log
{
    printf -- "-- begin rclone log (runid=%s, ruleid=%s) --\n" $(1) $(2)
    sed '$${/^$$/d}' "$(3)"
    printf -- "-- end rclone log (runid=%s, ruleid=%s) --\n" $(1) $(2)
} >> "$(logf)"
endef

#-----------
# formatting
#-----------

#
# truncate() - truncate string to a max length (chars), append '+' if longer
# usage: $(call truncate,string,width)
#

define truncate
$$(
    s=$(1) w=$(2)
    [ $${#s} -le $$w ] && printf "%s" "$$s" || printf "%s+" "$${s:0:$$((w-1))}"
)
endef

#
# iec2mib() - convert IEC size (B, KiB, MiB, GiB, TiB) to MiB (1 decimal)
# usage: $(call iec2mib,size)
#

define iec2mib
$$(
    awk -v s=$(1) '
        function n(x) { sub(/(B|[KMGT]iB)$$/, "", x); return x }
        BEGIN {
            if      (s ~ /^[0-9]+B$$/)   print sprintf("%.1f", n(s) / 1048576)
            else if (s ~ /^[0-9]+KiB$$/) print sprintf("%.1f", n(s) / 1024)
            else if (s ~ /^[0-9]+MiB$$/) print sprintf("%.1f", n(s))
            else if (s ~ /^[0-9]+GiB$$/) print sprintf("%.1f", n(s) * 1024)
            else if (s ~ /^[0-9]+TiB$$/) print sprintf("%.1f", n(s) * 1048576)
        }'
)
endef

#
# mib2iec() - convert MiB to best IEC unit (B, KiB, MiB, GiB, TiB) (1 decimal)
# usage: $(call mib2iec,mib)
#

define mib2iec
$$(
    awk -v mib=$(1) '
        BEGIN {
            u = split("B KiB MiB GiB TiB", U)
            n = 1048576 * mib
            for (i = 1; n >= 1024 && i < u; i++) n /= 1024
            printf("%.1f %s", n, U[i])
        }'
)
endef

#
# iec2bytes() - convert IEC size (K[iB], M[iB], G[iB]) to bytes
# usage: $(call iec2bytes,size)
#

define iec2bytes
$$(
    awk -v s=$(1) '
        function n(x) { sub(/(B|[KMG](iB)?)$$/, "", x); return x }
        BEGIN {
            if      (s ~ /^[0-9]+B?$$/)     print n(s)
            else if (s ~ /^[0-9]+K(iB)?$$/) print n(s) * 1024
            else if (s ~ /^[0-9]+M(iB)?$$/) print n(s) * 1048576
            else if (s ~ /^[0-9]+G(iB)?$$/) print n(s) * 1073741824
        }'
)
endef

#
# bytes2iec() - convert bytes to best IEC unit (KiB, MiB, GiB) (1 decimal)
# usage: $(call bytes2iec,bytes)
#

define bytes2iec
$$(
    awk -v n=$(1) '
        BEGIN {
            u = split("B KiB MiB GiB", U)
            for (i = 1; n >= 1024 && i < u; i++) n /= 1024
            printf("%.1f %s", n, U[i])
        }'
)
endef

#
# num3() - format integer with 3-digit grouping
# usage: $(call num3,num)
#

num3 = $$(printf "%s" $(1) | sed -E ':a;s/^(-?[0-9]+)([0-9]{3})/\1'\''\2/;ta')

#------
# email
#------

#
# send_report() - send multipart email with report and optional log attachment
# usage: $(call send_report,runid,reportf,reportlog,subject)
#

define send_report
(
    boundary="==$(call random,4)$(fortytwo)==$(call random,4)"
    runid=$(1) reportf=$(2) reportlog=$(3) subject=$(4)

    printf "From: %s\n" "$(mail_From)"
    printf "To: %s\n" "$(mail_To)"
    printf "Date: %s\n" "$$(date -R)"
    printf "Subject: %s\n" "$$subject"
    printf "MIME-Version: 1.0\n"
    printf "Content-Type: multipart/mixed; boundary=\"%s\"\n" "$$boundary"
    printf "Rclone-Sync-Project: %s (v%s)\n" $(project) $(version)
    printf "Rclone-Version: %s\n" $(rclone_ver)
    printf "\n"

    printf -- "--%s\n" "$$boundary"
    printf "Content-Type: text/html; charset=UTF-8\n"
    printf "Content-Transfer-Encoding: 8bit\n"
    printf "\n"

    printf "<html><body><pre>\n"
    cat "$$reportf"

    if [ $(mail_log) = yes ]; then
        log_size=$$(stat -c%s "$$reportlog")
        log_max=$(call iec2bytes,$(mail_log_max))
        log_gz_max=$(call iec2bytes,$(mail_log_gz_max))
        if [ $$log_size -le $$log_max ]; then
            attach_mode=raw
            attach_file="$$reportlog"
            $(call log,[$$runid] log attachment: raw file '$$reportlog' \
                (size=$$log_size))
        elif [ $$log_size -le $$log_gz_max ]; then
            attach_mode=gz
            attach_file="$(tmp)/$${reportlog##*/}.gz"
            gzip -c "$$reportlog" > "$$attach_file"
            $(call log,[$$runid] log attachment: gzip file '$$reportlog' \
                (size=$$log_size > limit=$(mail_log_max)))
        else
            attach_mode=skip
            printf "\n"
            printf "log attachment skipped: file size %d bytes exceeds %s=%s\n" \
                $$log_size mail_log_gz_max $(mail_log_gz_max)
            $(call log,[$$runid] log attachment: skip file '$$reportlog' \
                (size=$$log_size > limit=$(mail_log_gz_max)))
        fi
    else
        $(call log,[$$runid] log attachment: disabled (mail_log=$(mail_log)))
    fi

    printf "</pre></body></html>\n"

    if [ "$$attach_mode" = raw ]; then
        printf "\n"
        printf -- "--%s\n" "$$boundary"
        printf "Content-Type: text/plain; charset=UTF-8; name=\"%s\"\n" \
            "$${reportlog##*/}"
        printf "Content-Transfer-Encoding: 8bit\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\n" \
            "$${reportlog##*/}"
        printf "\n"
        cat "$$attach_file"
    elif [ "$$attach_mode" = gz ]; then
        printf "\n"
        printf -- "--%s\n" "$$boundary"
        printf "Content-Type: application/gzip; name=\"%s\"\n" \
            "$${reportlog##*/}.gz"
        printf "Content-Transfer-Encoding: base64\n"
        printf "Content-Disposition: attachment; filename=\"%s\"\n" \
            "$${reportlog##*/}.gz"
        printf "\n"
        base64 "$$attach_file"
        printf "\n"
        rm -f "$$attach_file"
    fi

    printf "\n"
    printf -- "--%s--\n" "$$boundary"
) | $(sendmail) -i -f $(mail_from) $(mail_to)
endef

#------
# utils
#------

#
# colors() - initialize ansi colors
# usage: $(colors)
#

define colors
if [ -t 1 ]; then
    BLD=$(bld) RST=$(rst)

    RED=$(red) _RED_=$(_red_)
    GRN=$(grn) _GRN_=$(_grn_)
    YEL=$(yel) _YEL_=$(_yel_)
    BLU=$(blu) _BLU_=$(_blu_)
    MAG=$(mag) _MAG_=$(_mag_)
    CYN=$(cyn) _CYN_=$(_cyn_)
else
    BLD= RST=
     RED=   GRN=   YEL=   BLU=   MAG=   CYN=
    _RED_= _GRN_= _YEL_= _BLU_= _MAG_= _CYN_=
fi
endef

#
# relpath() - return path relative to home
# usage: $(call relpath,path)
#

relpath = $$(printf "%s" "$(1)" | sed 's|$(home)/||')


# vim: ts=4
