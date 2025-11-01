# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.10.24

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
	ln -fns "stats/last/$(.status)" "$(status)"
	> "$(status)"

	rm -rf "$(logrun)"; mkdir -p "$(logrun)"

	kv_set "$(status)" state RUNNING
	kv_set "$(status)" runid $$runid
	kv_set "$(status)" started_at_epoch $$t0
	kv_set "$(status)" rules_done 0
	kv_set "$(status)" rules_total 0
	kv_set "$(status)" current_ruleid -
	kv_set "$(status)" current_rule_src -
	kv_set "$(status)" current_rule_dst -
	kv_set "$(status)" make_pid $$PPID
	kv_set "$(status)" shell_pid -
	kv_set "$(status)" program_pid -
	kv_set "$(status)" rclone_pid -
	kv_set "$(status)" ended_at_epoch -
	kv_set "$(status)" total_elapsed -
	kv_set "$(status)" rc 0

	$(call log,start '$(project)' (v$(version)) @ $(hostname) ($(ip)) \
        (runid=$$runid))

main:
	@$(define_kv)
	runid=$$(kv_get $(status) runid)
	n=$(count_rules)
	kv_set "$(status)" rules_total $$n
	$(call log,loop over '$(call relpath,$(rules_list))' ($$n rules))

	$(define_trap_on_signal)
	trap 'trap_on_signal SIGINT 2' INT
	trap 'trap_on_signal SIGTERM 15' TERM
	shell_pid=$$$$

	kv_set "$(status)" shell_pid $$shell_pid

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

	    kv_set "$(status)" current_ruleid $$ruleid
	    kv_set "$(status)" current_rule_src "$$src"
	    kv_set "$(status)" current_rule_dst "$$dst"

	    $(call log,rule '$$rule')
	    $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%))
	    $(call log,[$$ruleid] start '$(program_name)')
	    $(call log,[$$ruleid] command line: $$program_line)

	    t1=$(t)
	    kv_set "$$rulef" rule_started_at_epoch $$t1
	    kv_set "$$rulef" rule_started_at $(call at,$$t1)

	    "$${program_cmd[@]}" &> "$$rule_log" & program_pid=$$!
	    kv_set "$(status)" program_pid $$program_pid
	    $(watch_rclone)
	    rc=0; wait $$program_pid || rc=$$?
	    wait $$watcher_pid || true

	    t2=$(t)
	    rule_elapsed=$(call t_delta,$$t1,$$t2)

	    $(call append_rule_log,$$rule_log)
	    $(call rclone_stats,$$ruleid,$$rulef,$$rule_log)
	    kv_set "$$rulef" rule_ended_at_epoch $$t2
	    kv_set "$$rulef" rule_ended_at $(call at,$$t2)
	    kv_set "$$rulef" rule_elapsed $$rule_elapsed
	    kv_set "$$rulef" rc $$rc

	    kv_set "$(status)" rules_done $$k
	    kv_set "$(status)" program_pid -
	    kv_set "$(status)" rclone_pid -

	    [ $$rc -ne 0 ] && warn=" (WARN)" || warn=
	    $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call t_hms_ms,$$rule_elapsed)))

	    $(call stop_guard,$$ruleid);
	done < <(sed 's/[[:space:]]*#.*//' "$(rules_list)" | awk 'NF')
	kv_set "$(status)" rc 0

end:
	@$(define_kv)
	runid=$$(kv_get $(status) runid)
	t0=$$(kv_get "$(status)" started_at_epoch)
	t3=$(t)
	kv_set "$(status)" ended_at_epoch $$t3
	kv_set "$(status)" total_elapsed $(call t_delta,$$t0,$$t3)
	kv_set "$(status)" state "NOT RUNNING (completed)"
	$(call log,end '$(project)' (runid=$$runid) \
        (total elapsed: $(call t_delta_hms_ms,$$t0,$$t3)))

# stop & kill

stop:
	@printf "[%s] graceful stop requested: exit after current rule\n" \
        $(project)
	> "$(stop)"
	$(call log,graceful stop requested: flag '$(stop)' created$(,) \
        exit after current rule)
        

kill:
	@$(define_kv)
	shell_pid=$$(kv_get "$(status)" shell_pid)
	program_pid=$$(kv_get "$(status)" program_pid)
	rclone_pid=$$(kv_get "$(status)" rclone_pid)
	printf "[%s] global kill requested (%s=%d, %s=%d, %s=%d)\n" \
        $(project) recipe_shell $$shell_pid \
        program $$program_pid rclone $$rclone_pid
	$(call log,kill requested (recipe_shell=$$shell_pid$(,) \
        program=$$program_pid$(,) rclone=$$rclone_pid))
	for sig in INT TERM KILL; do
	    for pid in $$rclone_pid $$program_pid $$shell_pid; do
	         if kill -0 $$pid 2>/dev/null; then
	             printf "  send SIG%s to %d\n" $$sig $$pid
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
	runid=$$($(get_runid)) || exit 0
	$(colors)

	status="$(stats)/$$runid/$(.status)"
	printf "$$BLD%s (v%s) @ %s (%s)$$RST\n\n" \
        $(project) $(version) $(hostname) $(t_now)

	gstate=$$(kv_get "$$status" state)
	[ "$$gstate" = RUNNING ] && running=true || running=false

	k=$$(kv_get "$$status" rules_done)
	n=$$(kv_get "$$status" rules_total)
	pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	if $$running; then
	    t0=$(t)
	    started_at_epoch=$$(kv_get "$$status" started_at_epoch)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$$t0)

	    current_ruleid=$$(kv_get "$$status" current_ruleid)
	    rulef="$(last)/$$current_ruleid"
	    rule_started_at_epoch=$$(kv_get "$$rulef" rule_started_at_epoch)
	    rule_elapsed=$(call t_delta_hms,$$rule_started_at_epoch,$$t0)

	    current_rule_src=$$(kv_get "$$status" current_rule_src)
	    current_rule_dst=$$(kv_get "$$status" current_rule_dst)

	    make_pid=$$(kv_get "$$status" make_pid)
	    shell_pid=$$(kv_get "$$status" shell_pid)
	    program_pid=$$(kv_get "$$status" program_pid)
	    rclone_pid=$$(kv_get "$$status" rclone_pid)
	    pids="make=$${make_pid:--}, shell=$${shell_pid:--}, "
	    pids+="rclone_sync=$${program_pid:--}, rclone=$${rclone_pid:--}"

	    printf "state        : $$_RED_%s$$RST\n" "$$gstate"
	    printf "runid        : %s\n" $$runid
	    printf "started at   : %s  (elapsed: %s)\n" \
                               $(call at,$$started_at_epoch) $$elapsed
	    printf "current rule : $$_RED_%s$$RST  (elapsed: %s)\n" \
                               $$current_ruleid $$rule_elapsed
	    printf "progress     : $$_RED_%d/%d$$RST (%.2f%%)\n" $$k $$n $$pct
	    printf "flow         : %s -> %s\n" \
                               "$$current_rule_src" "$$current_rule_dst"
	    printf "pids         : %s\n" "$$pids"
	    printf "rclone       : %s\n" $(rclone_ver)
	else
	    started_at_epoch=$$(kv_get "$$status" started_at_epoch)
	    ended_at_epoch=$$(kv_get "$$status" ended_at_epoch)
	    total_elapsed=$$(kv_get "$$status" total_elapsed)
	    elapsed=$(call t_hms,$$total_elapsed)

	    printf "state      : $$_RED_%s$$RST\n" "$$gstate"
	    printf "runid      : %s\n" $$runid
	    printf "rules      : $$_RED_%d$$RST\n" $$n
	    printf "started at : %s\n" $(call at,$$started_at_epoch)
	    printf "ended at   : %s\n" $(call at,$$ended_at_epoch)
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

	    queue=0
	    while IFS= read -r ruleid; do
	        rulef="$(last)/$$ruleid"
	        rule=$(call truncate,$$ruleid,$(rule_width))

	        if [ ! -f "$$rulef" ]; then
	            rstate=queue
	        else
	            rc=$$(kv_get "$$rulef" rc)
	            [ -z "$$rc" ] && rstate=run || rstate=done
	        fi

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
	            elapsed=$(call t_hms_colon,$$rule_elapsed)
	            checks=$$(kv_get "$$rulef" rclone_checks)
	            checks=$${checks%/*}
	            xfer=$$(kv_get "$$rulef" rclone_transferred)
	            xfer=$${xfer%/*}
	            xfer_mib=$$(kv_get "$$rulef" rclone_transferred_size)
	            xfer_mib=$(call mib,$${xfer_mib%/*})
	            del=$$(kv_get "$$rulef" rclone_deleted)

	            : $$((sum_checks+=checks))
	            : $$((sum_xfer+=xfer))
	            sum_xfer_mib=$$(echo "$$sum_xfer_mib+$$xfer_mib" | bc)
	            : $$((sum_del+=del))
	            sum_elapsed=$$(echo "$$sum_elapsed+$$rule_elapsed" | bc)
	            [ "$$rc" -eq 0 ] && : $$((rc_ok++)) || : $$((rc_fail++))

	            printf "$$fmt\n" $$rule $$rstate $$start "$$end" \
                    $$elapsed "$$checks" "$$xfer" "$$xfer_mib" "$$del" "$$rc"
	        fi
	    done < "$(ruleids_list)"

	    if [ $$queue -gt $(rule_queue) ]; then
	        printf "(+%d more rules remaining)\n" $$((queue - $(rule_queue)))
	    fi

	    printf "\n$$BLD%s$$RST\n" SUMMARY

	    if $$running; then
	        printf "    rules      : $$_RED_%d/%d$$RST (%.2f%%)\n" \
                $$k $$n $$pct
	    else
	        printf "    rules      : $$_RED_%d$$RST\n" $$n
	    fi
	    printf "    checks     : %s\n" $(call num3,$$sum_checks)
	    printf "    xfer       : %s\n" $(call num3,$$sum_xfer)
	    printf "    xfer_size  : %s\n" "$(call mib2iec,$$sum_xfer_mib)"
	    printf "    deleted    : %s\n" $(call num3,$$sum_del)
	    printf "    elapsed    : %s\n" $(call t_hms,$$sum_elapsed)
	    printf "    rc         : ok=%d, fail=%d\n" $$rc_ok $$rc_fail
	fi

	$(call log,status: runid=$$runid$(,) state=$$gstate$(,) progress=$$k/$$n \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# report

report:
	@mkdir -p "$(reports)"
	$(define_kv)
	$(get_runid)
	{
	  printf "project: %s\n"        "$(project)"
	  printf "version: %s\n"        "$(version)"
	  printf "program_name: %s\n"   "$(program_name)"
	  printf "program_path: %s\n"   "$(program_path)"
	  printf "rclone_ver: %s\n"     "$(rclone_ver)"
	  printf "runid: %s\n"          $$runid
	  printf "state: %s\n"          "$$(kv_get $$status state)"
	  printf "rules_total: %s\n"    "$$(kv_get $$status rules_total)"
	  printf "rules_done: %s\n"     "$$(kv_get $$status rules_done)"
	  printf "started_at: %s\n"     "$$(kv_get $$status started_at)"
	  printf "ended_at: %s\n"       "$$(kv_get $$status ended_at)"
	  printf "total_elapsed: %s\n"  "$$(kv_get $$status total_elapsed)"
	  printf "host: %s\n"           "$(hostname)"
	  printf "ip: %s\n"             "$(ip)"
	  printf "lpath: %s\n"          "$(lpath)"
	  printf "rpath: %s\n"          "$(rpath)"
	  printf "rc: %s\n"             "$$(kv_get $$status rc)"
	} > "$(reports)/..."
	$(call log,saved ...)

# usage

usage:
	@$(define_kv)
	usagef="$(usage)/usage-"; > "$$usagef"

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
        (bucket='$$bucket', prefix='$(dst_root)'))
	{
	    printf "    excluding versions:\n"
	    $(rclone) --config "$(rclone_conf)" size "$(rpath)" |
	        sed 's/^/        /'
	} >> "$$usagef"
	$(call log,end bucket usage (excluding versions) \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

	t0=$(t)
	$(call log,start bucket usage (including versions) \
        (bucket='$$bucket', prefix='$(dst_root)'))
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
