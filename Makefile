# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.10.24

include .include.mk

#
# targets
#

.PHONY: help list start main end stop kill status status-v usage

help:
	@echo Makefile: Please specify a target: list, start, main, end, ...

$(project): start main end

# list

list::
	@> "$(rules_list)"
	if find "$(src_root)" -mindepth 1 -maxdepth 1 -type f | read; then
	    printf ". -- ruleid=root-files opts=\"--max-depth 1\"\n" \
            >> "$(rules_list)"
	fi
	find "$(src_root)" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" |
	    sort >> "$(rules_list)"
	n=$$(wc -l < "$(rules_list))"
	$(call log,list $$n rules from '$(src_root)' to '$(rules_list)')

	$(define_parse_rule)
	while IFS= read -r rule; do
	    parse_rule "$$rule"
	    printf "%s\n" $$ruleid
	done < "$(rules_list)" > "$(ruleids_list)"
	n=$$(wc -l < "$(ruleids_list))"
	$(call log,list $$n ruleids from '$(src_root)' to '$(ruleids_list)')

# main

start:
	@t0=$(t)
	mkdir -p "$(stats)"; > "$(status)"
	$(define_kv)

	kv_set "$(status)" state RUNNING
	kv_set "$(status)" project $(project)
	kv_set "$(status)" version $(version)
	kv_set "$(status)" runid $(runid)

	kv_set "$(status)" started_at_epoch $$t0
	kv_set "$(status)" started_at $(call at,$$t0)
	kv_set "$(status)" progress "0/0 (0%)"

	kv_set "$(status)" current_rule -
	kv_set "$(status)" current_ruleid -
	kv_set "$(status)" current_rule_src -
	kv_set "$(status)" current_rule_dst -
	kv_set "$(status)" current_rule_status -
	kv_set "$(status)" current_rule_log -

	kv_set "$(status)" program_name $(program_name)
	kv_set "$(status)" program_path "$(program_path)"
	kv_set "$(status)" program_cmd -
	kv_set "$(status)" rclone_cmd -
	kv_set "$(status)" rclone_ver $(rclone_ver)

	kv_set "$(status)" make_pid $$PPID
	kv_set "$(status)" shell_pid -
	kv_set "$(status)" program_pid -
	kv_set "$(status)" rclone_pid -

	kv_set "$(status)" ended_at_epoch -
	kv_set "$(status)" ended_at -
	kv_set "$(status)" total_elapsed -
	kv_set "$(status)" rc 0

	$(call log,start '$(project)' (v$(version)) @ $(hostname) ($(ip)))

	[ -L "$(stats)/last" ] &&
	    ln -fns $$(readlink "$(stats)/last") "$(stats)/prev"
	rm -rf "$(logrun)"; mkdir -p "$(logrun)"
	mkdir -p "$(stats)/$(runid)"
	ln -fns $(runid) "$(stats)/last"

main:
	@n=$$(sed 's/[[:space:]]*#.*//' "$(rules_list)" | awk 'NF' | wc -l)
	$(call log,loop over '$(call relpath,$(rules_list))' ($$n rules))

	$(define_trap_on_signal)
	trap 'trap_on_signal SIGINT 2' INT
	trap 'trap_on_signal SIGTERM 15' TERM
	shell_pid=$$$$

	$(define_kv)
	kv_set "$(status)" shell_pid $$shell_pid

	$(define_parse_rule)
	k=0
	while IFS= read -r rule; do
	    : $$((k++))

	    parse_rule "$$rule"
	    rulef="$(stats)/$(runid)/$$ruleid"; > "$$rulef"
	    rule_log="$(logrun)/$$ruleid.log"
	    pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	    kv_set "$$rulef" rule "$$rule"
	    kv_set "$$rulef" ruleid $$ruleid
	    kv_set "$$rulef" progress "$$k/$$n ($$pct%)"

	    src="$(lpath)/$$path"
	    dst="$(rpath)/$$path"
	    program_cmd=("$(program_path)" $${opts:+-o "$$opts"} "$$src" "$$dst")
	    printf -v program_cmd "%s " "$${program_cmd[@]}"
	    program_cmd=$${program_cmd% }

	    kv_set "$$rulef" rule_src "$$src"
	    kv_set "$$rulef" rule_dst "$$dst"
	    kv_set "$$rulef" program_cmd "$$program_cmd"

	    kv_set "$(status)" progress "$$k/$$n ($$pct%)"
	    kv_set "$(status)" current_rule "$$rule"
	    kv_set "$(status)" current_ruleid $$ruleid
	    kv_set "$(status)" current_rule_src "$$src"
	    kv_set "$(status)" current_rule_dst "$$dst"
	    kv_set "$(status)" current_rule_status "$$rulef"
	    kv_set "$(status)" current_rule_log "$$rule_log"
	    kv_set "$(status)" program_cmd "$$program_cmd"

	    $(call log,rule '$$rule')
	    $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%))
	    $(call log,[$$ruleid] start '$(program_name)')
	    $(call log,[$$ruleid] command line: $$program_cmd)

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
	    kv_set "$$rulef" rule_ended_at $(call at,$$t2)
	    kv_set "$$rulef" rule_elapsed $$rule_elapsed
	    kv_set "$$rulef" rc $$rc

	    kv_set "$(status)" program_pid -
	    kv_set "$(status)" rclone_pid -
	    if [ $$rc -ne 0 ]; then kv_set "$(status)" rc $$rc; fi

	    [ $$rc -ne 0 ] && warn=" (WARN)" || warn=
	    $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call hms_ms,$$rule_elapsed)))

	    $(call stop_guard,$$ruleid);
	done < <(sed 's/[[:space:]]*#.*//' "$(rules_list)" | awk 'NF')

end:
	@$(define_kv)
	t0=$$(kv_get "$(status)" started_at_epoch)
	t3=$(t)
	kv_set "$(status)" ended_at_epoch $$t3
	kv_set "$(status)" ended_at $(call at,$$t3)
	kv_set "$(status)" total_elapsed $(call t_delta,$$t0,$$t3)
	kv_set "$(status)" state "NOT RUNNING (completed)"
	$(call log,end '$(project)' \
        (total elapsed: $(call t_delta_hms_ms,$$t0,$$t3)))

# stop & kill

stop:
	@printf "[$(project)] graceful stop requested: exit after current rule\n"
	> "$(stop)"
	$(call log,graceful stop requested: exit after current rule$(,) \
        flag '$(stop)' created)

kill:
	@$(define_kv)
	shell_pid=$$(kv_get "$(status)" shell_pid)
	program_pid=$$(kv_get "$(status)" program_pid)
	rclone_pid=$$(kv_get "$(status)" rclone_pid)
	printf "[%s] global kill requested (%s=%d, %s=%d, %s=%d)\n" \
        $(project) recipe_shell $$shell_pid \
        program $$program_pid rclone $$rclone_pid
	$(call log,global kill requested (recipe_shell=$$shell_pid$(,) \
        program=$$program_pid$(,) rclone=$$rclone_pid))
	for sig in INT TERM KILL; do
	    for pid in $$rclone_pid $$program_pid $$shell_pid; do
	         if kill -0 $$pid 2>/dev/null; then
	             printf "  send SIG%s to %s\n" $$sig $$pid
	             kill -s $$sig $$pid 2>/dev/null || true
	         fi
	    done
	    sleep 1
	done
	$(call log,global kill: sent signals to rclone=$$rclone_pid$(,) \
        program=$$program_pid$(,) recipe_shell=$$shell_pid)

# status

status status-v:
	@$(define_kv)
	$(colors)
	printf "$$BLD%s (v%s) @ %s (%s)$$RST\n\n" \
        $(project) $(version) $(hostname) $(now)

	state=$$(kv_get "$(status)" state)
	[ "$$state" = RUNNING ] && running=true || running=false

	started_at=$$(kv_get "$(status)" started_at)
	if $$running; then
	    started_at_epoch=$$(kv_get "$(status)" started_at_epoch)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$(t))
	    current_ruleid=$$(kv_get "$(status)" current_ruleid)
	    progress=$$(kv_get "$(status)" progress | sed 's/ (/, /;s/)//')
	    current_rule_src=$$(kv_get "$(status)" current_rule_src)
	    current_rule_dst=$$(kv_get "$(status)" current_rule_dst)
	    make_pid=$$(kv_get "$(status)" make_pid)
	    shell_pid=$$(kv_get "$(status)" shell_pid)
	    program_pid=$$(kv_get "$(status)" program_pid)
	    rclone_pid=$$(kv_get "$(status)" rclone_pid)
	    pids="make=$${make_pid:--}, shell=$${shell_pid:--}, "
	    pids+="rclone_sync=$${program_pid:--}, rclone=$${rclone_pid:--}"

	    printf "%-12s : $$_RED_%s$$RST\n" state "$$state"
	    printf "%-12s : %s\n" runid $(runid)
	    printf "%-12s : %s  (elapsed: %s)\n" "started at" \
            $$started_at $$elapsed
	    printf "%-12s : $$_RED_%s$$RST ($$_RED_%s$$RST)\n" "current rule" \
            $$current_ruleid "$$progress"
	    printf "%-12s : %s -> %s\n" flow \
            "$$current_rule_src" "$$current_rule_dst"
	    printf "%-12s : %s\n" pids "$$pids"
	    printf "%-12s : %s\n" rclone $(rclone_ver)
	else
	    ended_at=$$(kv_get "$(status)" ended_at)
	    total_elapsed=$$(kv_get "$(status)" total_elapsed)
	    elapsed=$(call hms,$$total_elapsed)

	    printf "%-10s : $$_RED_%s$$RST\n" state "$$state"
	    printf "%-10s : %s\n" runid $(runid)
	    printf "%-10s : %s\n" "started at" $$started_at
	    printf "%-10s : %s\n" "ended at" $$ended_at
	    printf "%-10s : %s\n" elapsed $$elapsed
	    printf "%-10s : %s -> %s\n" flow "$(lpath)" "$(rpath)"
	    printf "%-10s : %s\n" rclone $(rclone_ver)
	fi

	if [ $@ = status-v ]; then
	    printf "\n"
	    w1=$$(($(rule_width)+1))
	    fmt="%-$${w1}s  %-5s  %-8s  %-8s  %-8s  %8s  %8s  %8s  %6s  %3s"
	    fmt_queue="$$MAG%-$${w1}s  %-5s$$RST"

	    printf "$$BLD$$fmt$$RST\n" \
            RULE STATE START END ELAPSED CHECKS XFER XFER_MiB DEL RC

	    run=false
	    queue=0
	    while IFS= read -r ruleid; do
	        rulef="$(stats)/last/$$ruleid"
	        rule=$(call truncate,$$ruleid,$(rule_width))

	        if $$run || [ ! -f "$$rulef" ]; then
	            : $$((queue++))
	            if [ $$queue -le $(rule_queue) ]; then
	                printf "$$fmt_queue\n" $$rule queue
	            fi
	            continue
	        fi

	        start=$$(kv_get "$$rulef" rule_started_at); start=$${start#*-}
	        end=$$(kv_get "$$rulef" rule_ended_at); end=$${end#*-}

	        rc=$$(kv_get "$$rulef" rc)
	        if [ -z "$$rc" ]; then
	            state=run
	            run=true
	            rule_started_at_epoch=$$(kv_get "$$rulef" \
                    rule_started_at_epoch)
	            elapsed=$(call hms_colon,$(call \
                    t_delta,$$rule_started_at_epoch,$(t)))
	            col=$$_RED_ rst=$$RST
	        else
	            state=done
	            elapsed=$$(kv_get "$$rulef" rule_elapsed)
	            elapsed=$(call hms_colon,$$elapsed)
	            col= rst=
	        fi

	        checks=$$(kv_get "$$rulef" rclone_checks); checks=$${checks%/*}
	        xfer=$$(kv_get "$$rulef" rclone_transferred); xfer=$${xfer%/*}
	        xfer_mib=$$(kv_get "$$rulef" rclone_transferred_size)
	        xfer_mib=$(call mib,$${xfer_mib%/*})
	        del=$$(kv_get "$$rulef" rclone_deleted)

	        printf "$$col$$fmt$$rst\n" \
                $$rule $$state $$start "$$end" $$elapsed "$$checks" \
                "$$xfer" "$$xfer_mib" "$$del" "$$rc"
	    done < "$(ruleids_list)"

	    if [ $$queue -gt $(rule_queue) ]; then
	        printf "(+%d more rules remaining)\n" $$((queue - $(rule_queue)))
	    fi
	fi

	progress=$$(kv_get "$(status)" progress)
	progress=$${progress% *}
	$(call log,got status: state=$$state$(,) progress=$$progress)

# usage

usage:
	@usagef="$(usage)/usage-$(runid)"; > "$$usagef"

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
