# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.11.04

include .include.mk

#
# targets
#

.PHONY: help dirs \
        list start main end stop kill \
        status status-v report report-mail \
        usage

help:
	@echo Makefile: Please specify a target: list, start, main, end, ...

$(project): start main end

# list

list::
	@{
	    if find "$(src_root)" -mindepth 1 -maxdepth 1 -type f | read -r; then
	        printf ". -- ruleid=root-files opts=\"--max-depth 1\"\n"
	    fi
	    find "$(src_root)" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" |
	        sort
	} > "$(rules_list)"
	n=$$(wc -l < "$(rules_list)")
	$(call log,list $$n rules from '$(src_root)' to '$(rules_list)')

	$(define_parse_rule)
	while IFS= read -r rule; do
	    parse_rule "$$rule"
	    printf "%s\n" $$ruleid
	done < "$(rules_list)" > "$(ruleids_list)"
	n=$$(wc -l < "$(ruleids_list)")
	$(call log,list $$n ruleids from '$(src_root)' to '$(ruleids_list)')

# main

start:
	@t0=$(t)
	$(define_kv)
	runid=$(t_znow)

	mkdir -p "$(stats)" "$(stats)/$$runid"
	[ -L "$(last)" ] && ln -fns $$(readlink "$(last)") "$(prev)"
	ln -fns $$runid "$(last)"
	ln -fns stats/last/.status data/status

	rm -rf "$(logrun)"; mkdir -p "$(logrun)"

	> "$(statusf)"
	kv_set "$(statusf)" state RUNNING
	kv_set "$(statusf)" runid $$runid
	kv_set "$(statusf)" started_at_epoch $$t0
	kv_set "$(statusf)" started_at $(call at,$$t0)
	kv_set "$(statusf)" rules_done 0
	kv_set "$(statusf)" rules_total -
	kv_set "$(statusf)" current_ruleid -
	kv_set "$(statusf)" current_rule_src -
	kv_set "$(statusf)" current_rule_dst -
	kv_set "$(statusf)" make_pid $$PPID
	kv_set "$(statusf)" shell_pid -
	kv_set "$(statusf)" program_pid -
	kv_set "$(statusf)" rclone_pid -
	kv_set "$(statusf)" ended_at_epoch -
	kv_set "$(statusf)" ended_at -
	kv_set "$(statusf)" total_elapsed -
	kv_set "$(statusf)" rc -

	$(call log,[$$runid] start '$(project)' (v$(version)) \
        @ $(hostname) ($(ip)) (runid=$$runid))

main:
	@$(define_kv)
	runid=$$(kv_get $(statusf) runid)
	n=$(call count_rules,$(rules_list))
	kv_set "$(statusf)" rules_total $$n
	$(call log,[$$runid] loop over '$(call relpath,$(rules_list))' ($$n rules))

	$(define_trap_on_signal)
	trap 'trap_on_signal SIGINT 2' INT
	trap 'trap_on_signal SIGTERM 15' TERM
	shell_pid=$$$$

	kv_set "$(statusf)" shell_pid $$shell_pid

	$(define_parse_rule)
	k=0
	while IFS= read -r rule; do
	    : $$((k++))

	    parse_rule "$$rule"
	    rulef="$(stats)/$$runid/$$ruleid"; > "$$rulef"
	    rule_log="$(logrun)/$$ruleid.log"
	    pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	    kv_set "$$rulef" rule "$$rule"
	    kv_set "$$rulef" ruleid $$ruleid
	    kv_set "$$rulef" progress "$$k/$$n ($$pct%)"

	    src="$(lpath)/$$path"
	    dst="$(rpath)/$$path"
	    program_cmd=("$(program_path)" $${opts:+-o "$$opts"} "$$src" "$$dst")
	    printf -v program_line "%s " "$${program_cmd[@]}"
	    program_line=$${program_line% }

	    kv_set "$$rulef" rule_src "$$src"
	    kv_set "$$rulef" rule_dst "$$dst"
	    kv_set "$$rulef" program_cmd "$$program_line"

	    kv_set "$(statusf)" current_ruleid $$ruleid
	    kv_set "$(statusf)" current_rule_src "$$src"
	    kv_set "$(statusf)" current_rule_dst "$$dst"

	    $(call log,[$$runid] rule '$$rule')
	    $(call log,[$$runid] ruleid '$$ruleid' ($$k/$$n$(,) $$pct%))
	    $(call log,[$$runid:$$ruleid] start '$(program_name)')
	    $(call log,[$$runid:$$ruleid] command line: $$program_line)

	    t1=$(t)
	    kv_set "$$rulef" rule_started_at_epoch $$t1
	    kv_set "$$rulef" rule_started_at $(call at,$$t1)

	    "$${program_cmd[@]}" &> "$$rule_log" & program_pid=$$!
	    kv_set "$(statusf)" program_pid $$program_pid
	    $(call watch_rclone,$$rulef)
	    rc=0; wait $$program_pid || rc=$$?
	    wait $$watcher_pid || true

	    t2=$(t)
	    rule_elapsed=$(call t_delta,$$t1,$$t2)

	    $(call append_rule_log,$$runid,$$ruleid,$$rule_log)
	    $(call save_rclone_stats,$$runid,$$ruleid,$$rulef,$$rule_log)
	    kv_set "$$rulef" rule_ended_at_epoch $$t2
	    kv_set "$$rulef" rule_ended_at $(call at,$$t2)
	    kv_set "$$rulef" rule_elapsed $$rule_elapsed
	    kv_set "$$rulef" rc $$rc

	    kv_set "$(statusf)" rules_done $$k
	    kv_set "$(statusf)" program_pid -
	    kv_set "$(statusf)" rclone_pid -

	    [ $$rc -ne 0 ] && warn=" (WARN)" || warn=
	    $(call log,[$$runid:$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call t_hms_ms,$$rule_elapsed)))

	    $(call stop_guard,$$runid,$$ruleid)
	done < <(sed 's/[[:space:]]*#.*//' "$(rules_list)" | awk 'NF')

end:
	@$(define_kv)
	runid=$$(kv_get $(statusf) runid)
	t0=$$(kv_get "$(statusf)" started_at_epoch)
	t3=$(t)
	kv_set "$(statusf)" ended_at_epoch $$t3
	kv_set "$(statusf)" ended_at $(call at,$$t3)
	kv_set "$(statusf)" total_elapsed $(call t_delta,$$t0,$$t3)
	k=$$(kv_get "$(statusf)" rules_done)
	n=$$(kv_get "$(statusf)" rules_total)
	if [ $$k -eq $$n ]; then
	    kv_set "$(statusf)" state "NOT RUNNING (completed)"
	    kv_set "$(statusf)" rc 0
	fi
	$(call log,[$$runid] end '$(project)' (runid=$$runid, rules=$$k/$$n) \
        (total elapsed: $(call t_delta_hms_ms,$$t0,$$t3)))

# stop & kill

stop:
	@$(define_kv)
	runid=$$(kv_get $(statusf) runid)
	printf "[%s] graceful stop requested (runid=%s): \
        exit after current rule\n" $(project) $$runid >&2
	> "$(stop)"
	$(call log,graceful stop requested: flag '$(stop)' created$(,) \
        exit after current rule)

kill:
	@$(define_kv)
	shell_pid=$$(kv_get "$(statusf)" shell_pid)
	program_pid=$$(kv_get "$(statusf)" program_pid)
	rclone_pid=$$(kv_get "$(statusf)" rclone_pid)
	printf "[%s] global kill requested (%s=%d, %s=%d, %s=%d)\n" \
        $(project) recipe_shell $$shell_pid \
        program $$program_pid rclone $$rclone_pid >&2
	$(call log,kill requested (recipe_shell=$$shell_pid$(,) \
        program=$$program_pid$(,) rclone=$$rclone_pid))
	for sig in INT TERM KILL; do
	    for pid in $$rclone_pid $$program_pid $$shell_pid; do
	         if kill -0 $$pid 2>/dev/null; then
	             printf "  send SIG%s to %d\n" $$sig $$pid >&2
	             kill -s $$sig $$pid 2>/dev/null || true
	         fi
	    done
	    sleep 1
	done
	$(call log,kill: sent signals to rclone=$$rclone_pid$(,) \
        program=$$program_pid$(,) recipe_shell=$$shell_pid)

# status

status status-v:
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1

	statusf="$(stats)/$$runid/.status"
	state=$$(kv_get "$$statusf" state)
	gstate=$(call get_gstate,$$state)

	k=$$(kv_get "$$statusf" rules_done)
	n=$$(kv_get "$$statusf" rules_total)
	pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	if [ $$gstate = running ]; then
	    t0=$(t)
	    started_at_epoch=$$(kv_get "$$statusf" started_at_epoch)
	    started_at=$$(kv_get "$$statusf" started_at)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$$t0)

	    current_ruleid=$$(kv_get "$$statusf" current_ruleid)
	    rulef="$(last)/$$current_ruleid"
	    rule_started_at_epoch=$$(kv_get "$$rulef" rule_started_at_epoch)
	    rule_elapsed=$(call t_delta_hms,$$rule_started_at_epoch,$$t0)

	    current_rule_src=$$(kv_get "$$statusf" current_rule_src)
	    current_rule_dst=$$(kv_get "$$statusf" current_rule_dst)

	    make_pid=$$(kv_get "$$statusf" make_pid)
	    shell_pid=$$(kv_get "$$statusf" shell_pid)
	    program_pid=$$(kv_get "$$statusf" program_pid)
	    rclone_pid=$$(kv_get "$$statusf" rclone_pid)
	    pids="make=$${make_pid:--}, shell=$${shell_pid:--}, "
	    pids+="rclone_sync=$${program_pid:--}, rclone=$${rclone_pid:--}"

	    printf "state        : $$_RED_%s$$RST\n" "$$state"
	    printf "runid        : %s\n" $$runid
	    printf "started at   : %s  (elapsed: %s)\n" $$started_at $$elapsed
	    printf "current rule : $$_RED_%s$$RST  (elapsed: %s)\n" \
                               $$current_ruleid $$rule_elapsed
	    printf "progress     : $$_RED_%d/%d$$RST (%.2f%%)\n" $$k $$n $$pct
	    printf "flow         : %s -> %s\n" \
                               "$$current_rule_src" "$$current_rule_dst"
	    printf "pids         : %s\n" "$$pids"
	    printf "rclone       : %s\n" $(rclone_ver)
	else
	    started_at=$$(kv_get "$$statusf" started_at)
	    ended_at=$$(kv_get "$$statusf" ended_at)
	    total_elapsed=$$(kv_get "$$statusf" total_elapsed)
	    elapsed=$(call t_hms,$$total_elapsed)

	    printf "state      : $$_RED_%s$$RST\n" "$$state"
	    printf "runid      : %s\n" $$runid
	    if [ $$gstate = completed ]; then
	        printf "rules      : $$_RED_%d$$RST\n" $$n
	    else
	        printf "rules      : $$_RED_%d (%d completed)$$RST\n" $$n $$k
	    fi
	    printf "started at : %s\n" $$started_at
	    printf "ended at   : %s\n" $$ended_at
	    printf "elapsed    : %s\n" $$elapsed
	    printf "flow       : %s -> %s\n" "$(lpath)" "$(rpath)"
	    printf "rclone     : %s\n" $(rclone_ver)
	fi

	if [ $@ = status-v ]; then
	    printf "\n"
	    w1=$$(($(rule_width)+1))
	    fmt="%-$${w1}s  %-5s  %-8s  %-8s  %-8s  %8s  %8s  %8s  %6s  %3s"
	    fmt_queue="$$MAG%-$${w1}s  %-5s$$RST"
	    fmt_run="$$_RED_%-$${w1}s  %-5s  %-8s  %-8s  %-8s$$RST"

	    printf "$$BLD$$fmt$$RST\n" \
            RULE STATE START END ELAPSED CHECKS XFER XFER_MiB DEL RC

	    sum_checks=0 sum_xfer=0 sum_xfer_mib=0 sum_del=0 sum_elapsed=0
	    rc_ok=0 rc_fail=0

	    if [ $$gstate = running ]; then
	        mapfile -t ruleids < "$(ruleids_list)"
	    else
	        mapfile -t ruleids < <(ls $(stats)/$$runid)
	    fi

	    queue=0
	    for ruleid in "$${ruleids[@]}"; do
	        rule=$(call truncate,$$ruleid,$(rule_width))
	        rulef="$(stats)/$$runid/$$ruleid"
	        rstate=$(call get_rstate,$$rulef,$$gstate)

	        if [ "$$rstate" = queue ]; then
	            : $$((queue++))
	            if [ $$queue -le $(rule_queue) ]; then
	                printf "$$fmt_queue\n" $$rule queue
	            fi
	            continue
	        fi

	        start=$$(kv_get "$$rulef" rule_started_at); start=$${start#*-}
	        end=$$(kv_get "$$rulef" rule_ended_at); end=$${end#*-}

	        if [ "$$rstate" = run ]; then
	            rule_started_at_epoch=$$(kv_get "$$rulef" \
                    rule_started_at_epoch)
	            elapsed=$(call t_hms_colon,$(call \
                    t_delta,$$rule_started_at_epoch,$(t)))
	            printf "$$fmt_run\n" $$rule $$rstate $$start "$$end" $$elapsed
	        else
	            rule_elapsed=$$(kv_get "$$rulef" rule_elapsed)
	            if [ -n "$$rule_elapsed" ]; then
	                elapsed=$(call t_hms_colon,$$rule_elapsed)
	            else
	                elapsed=
	            fi
	            checks=$$(kv_get "$$rulef" rclone_checks)
	            checks=$${checks%/*}
	            xfer=$$(kv_get "$$rulef" rclone_transferred)
	            xfer=$${xfer%/*}
	            xfer_mib=$$(kv_get "$$rulef" rclone_transferred_size)
	            xfer_mib=$(call iec2mib,$${xfer_mib%/*})
	            del=$$(kv_get "$$rulef" rclone_deleted)
	            rc=$$(kv_get "$$rulef" rc)

	            : $$((sum_checks+=checks))
	            : $$((sum_xfer+=xfer))
	            sum_xfer_mib=$$(echo "$$sum_xfer_mib+$${xfer_mib:=0}" | bc)
	            : $$((sum_del+=del))
	            sum_elapsed=$$(echo "$$sum_elapsed+$${rule_elapsed:=0}" | bc)
	            [ "$$rc" = 0 ] && : $$((rc_ok++)) || : $$((rc_fail++))

	            printf "$$fmt\n" $$rule $$rstate $$start "$$end" \
                    $$elapsed "$$checks" "$$xfer" "$$xfer_mib" "$$del" "$$rc"
	        fi
	    done

	    if [ $$queue -gt $(rule_queue) ]; then
	        printf "(+%d more rules remaining)\n" $$((queue - $(rule_queue)))
	    fi

	    printf "\n$$BLD%s$$RST\n" SUMMARY

	    if [ $$gstate = running ]; then
	        printf "    rules      : $$_RED_%d/%d$$RST (%.2f%%)\n" \
                $$k $$n $$pct
	    elif [ $$gstate = completed ]; then
	        printf "    rules      : $$_RED_%d$$RST\n" $$n
	    else
	        printf "    rules      : $$_RED_%d (%d completed)$$RST\n" $$n $$k
	    fi
	    printf "    checks     : %s\n" $(call num3,$$sum_checks)
	    printf "    xfer       : %s\n" $(call num3,$$sum_xfer)
	    printf "    xfer_size  : %s\n" "$(call mib2iec,$$sum_xfer_mib)"
	    printf "    deleted    : %s\n" $(call num3,$$sum_del)
	    printf "    elapsed    : %s\n" $(call t_hms,$$sum_elapsed)
	    printf "    rc         : ok=%d, fail=%d\n" $$rc_ok $$rc_fail
	fi

	$(call log,[$$runid] status: runid=$$runid$(,) state=$$gstate$(,) \
        rules=$$k/$$n (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# report

report:
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1

	statusf="$(stats)/$$runid/.status"
	state=$$(kv_get "$$statusf" state)
	gstate=$(call get_gstate,$$state)
	if [ $$gstate = running ]; then
	    if [ -t 1 ]; then
	        printf "[%s] $$_RED_%s is running$$RST: report skipped\n" \
                $(project) $(project)
	    fi
	    $(call log,$(project) is running: report skipped)
	    exit 0
	fi

	mkdir -p "$(reports)"
	reportf="$(reports)/report-$$runid.txt"
	[ -L "$(reports)/last" ] &&
	    ln -fns $$(readlink "$(reports)/last") "$(reports)/prev"
	ln -fns $${reportf##*/} "$(reports)/last"

	reportlog="$(reports)/report-$$runid.log"
	awk "
	    /-- begin rclone log (runid=$$runid,/ { flag = 1 } flag; /--
	    /-- end rclone log (runid=$$runid,/ { flag = 0 }" "$(logf)" \
        > "$$reportlog"
	$(call log,[$$runid] report log for runid='$$runid' saved to '$$reportlog')

	rules_done=$$(kv_get $$statusf rules_done)
	rules_total=$$(kv_get $$statusf rules_total)
	total_elapsed=$(call t_hms_ms,$$(kv_get $$statusf total_elapsed))
	{
	    printf "%s (v%s) @ %s (%s)\n" $(project) $(version) $(hostname) $$runid
	    printf "\n"
	    printf "home             : %s\n" "$(home)"
	    printf "project          : %s\n" "$(project)"
	    printf "version          : %s\n" "$(version)"
	    printf "program_name     : %s\n" "$(program_name)"
	    printf "program_path     : %s\n" "$(program_path)"
	    printf "hostname         : %s\n" "$(hostname)"
	    printf "ip               : %s\n" "$(ip)"
	    printf "rclone_ver       : %s\n" "$(rclone_ver)"
	    printf "lpath            : %s\n" "$(lpath)"
	    printf "rpath            : %s\n" "$(rpath)"
	    printf "runid            : %s\n" "$$runid"
	    printf "state            : %s\n" "$$gstate"
	    printf "started_at_epoch : %s\n" "$$(kv_get $$statusf started_at_epoch)"
	    printf "started_at       : %s\n" "$$(kv_get $$statusf started_at)"
	    printf "rules            : %s\n" "$$rules_done/$$rules_total"
	    printf "ended_at_epoch   : %s\n" "$$(kv_get $$statusf ended_at_epoch)"
	    printf "ended_at         : %s\n" "$$(kv_get $$statusf ended_at)"
	    printf "total_elapsed    : %s\n" "$$total_elapsed"
	    printf "rc               : %s\n" "$$(kv_get $$statusf rc)"
	    printf "\n"
	    printf -- "-------- rules summary (status-v) --------\n"
	    printf "\n"
	    $(MAKE) -s runid=$$runid status-v | sed -n '/^RULE/,$$p'
	} > "$$reportf"

	$(call log,[$$runid] report (runid=$$runid) saved to '$$reportf' \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# report by email

report-mail:
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1

	statusf="$(stats)/$$runid/.status"
	state=$$(kv_get "$$statusf" state)
	gstate=$(call get_gstate,$$state)

	reportf="$(reports)/report-$$runid.txt"
	if [ ! -f "$$reportf" ]; then
	    if [ -t 1 ]; then
	        printf "[%s] $${_RED_}report for runid '%s' does not exist$$RST: \
                report-mail skipped\n" $(project) $$runid
	    fi
	    $(call log,report for runid '$$runid' does not exist: \
            report-mail skipped)
	    exit 0
	fi

	reportlog="$(reports)/report-$$runid.log"
	if [ ! -f "$$reportlog" ]; then
	    $(call log,[$$runid] report log for runid '$$runid' does not exist)
	fi

	rules_done=$$(kv_get $$statusf rules_done)
	rules_total=$$(kv_get $$statusf rules_total)

	subject=$(printf "[%s@%s] rclone sync to %s:%s (runid %s, rules %s/%s)" \
        $(project) $(host) $(remote) $(bucket) $$runid \
        $$rules_done $$rules_total)

	$(call mime_report,$$reportf,$$reportlog)

	$(call log,[$$runid] report by email for runid '$$runid' \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# usage

usage:
	@$(define_kv)
	usagef="$(usage)/usage-$(t_znow)"; > "$$usagef"

	[ -L "$(usage)/last" ] &&
	    ln -fns $$(readlink "$(usage)/last") "$(usage)/prev"
	ln -fns $${usagef##*/} "$(usage)/last"

	{
	    printf "Bucket usage (%s, %s)\n" \
            $(hostname) "$$(date '+%a %d %b %Y')"
	    printf "    bucket: %s\n" $(bucket)
	    printf "    prefix: %s\n" "$(dst_root)"
	} >> $$usagef

	t0=$(t)
	$(call log,start bucket usage (excluding versions) \
        (bucket='$(bucket)', prefix='$(dst_root)'))
	{
	    printf "    excluding versions:\n"
	    $(rclone) --config "$(rclone_conf)" size "$(rpath)" |
	        sed 's/^/        /'
	} >> "$$usagef"
	$(call log,end bucket usage (excluding versions) \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

	t0=$(t)
	$(call log,start bucket usage (including versions) \
        (bucket='$(bucket)', prefix='$(dst_root)'))
	{
	    printf "    including versions:\n"
	    $(rclone) --config "$(rclone_conf)" size --s3-versions "$(rpath)" |
	        sed 's/^/        /'
	} >> "$$usagef"
	$(call log,end bucket usage (including versions) \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' "$(logf)" | tail -n 1 | cut -d: -f1)
	sed -n "$$start,/\[make(end):/p" "$(logf)"

# site targets

-include .site.mk


# vim: ts=4
