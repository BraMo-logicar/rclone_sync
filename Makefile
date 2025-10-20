# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.10.16

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
	@> $(rules_list)
	if find $(src_root) -mindepth 1 -maxdepth 1 -type f | read; then
	    printf ". -- ruleid=root-files opts=\"--max-depth 1\"\n" \
            >> $(rules_list)
	fi
	find $(src_root) -mindepth 1 -maxdepth 1 -type d -printf "%f\n" |
	    sort >> $(rules_list)
	n=$$(wc -l < $(rules_list))
	$(call log,list $$n entries from '$(src_root)' to '$(rules_list)')

#	@mkdir -p "$(ETC_DIR)"
## 1) produce dir list like you already do (replace this line with your real code)
#	@your-dir-list-command >"$(RULES_FILE)"
## 2) produce ruleids using parse_rule for every line in rclone.list
# 	@$(RM) -f "$(RULEIDS_FILE)"
#	@$(foreach d,$(shell sed -n 's/[[:space:]]*#.*//; /^[[:space:]]*$$/d; p' "$(RULES_FILE)"), \
#	printf '%s\n' '$(call parse_rule,$(d))' >>"$(RULEIDS_FILE)";)

# main

start:
	@t0=$(t)
	mkdir -p $(stats); > $(status)

	$(call kv_set,$(status),state,RUNNING)
	$(call kv_set,$(status),project,$(project))
	$(call kv_set,$(status),version,$(version))
	$(call kv_set,$(status),runid,$(runid))

	$(call kv_set,$(status),started_at,$(call at,$$t0))
	$(call kv_set,$(status),started_at_epoch,$$t0)
	$(call kv_set,$(status),progress,0/0 (0%))

	$(call kv_set,$(status),current_rule,-)
	$(call kv_set,$(status),current_ruleid,-)
	$(call kv_set,$(status),current_rule_src,-)
	$(call kv_set,$(status),current_rule_dst,-)
	$(call kv_set,$(status),current_rule_started_at,-)
	$(call kv_set,$(status),current_rule_status,-)
	$(call kv_set,$(status),current_rule_log,-)

	$(call kv_set,$(status),program_name,$(program_name))
	$(call kv_set,$(status),program_path,$(program_path))
	$(call kv_set,$(status),program_cmd,-)
	$(call kv_set,$(status),rclone_cmd,-)
	$(call kv_set,$(status),rclone_ver,$(rclone_ver))

	$(call kv_set,$(status),make_pid,$$PPID)
	$(call kv_set,$(status),shell_pid,-)
	$(call kv_set,$(status),program_pid,-)
	$(call kv_set,$(status),rclone_pid,-)

	$(call kv_set,$(status),ended_at,-)
	$(call kv_set,$(status),total_elapsed,-)
	$(call kv_set,$(status),rc,0)

	$(call log,start '$(project)' (v$(version)) @ $(hostname) ($(ip)))

	[ -L $(stats)/last ] && ln -fns $$(readlink $(stats)/last) $(stats)/prev
	rm -rf $(logrun); mkdir -p $(logrun)
	mkdir -p $(stats)/$(runid)
	ln -fns $(runid) $(stats)/last

main:
	@n=$$(sed 's/[[:space:]]*#.*//' $(rules_list) | awk 'NF' | wc -l)
	$(call log,loop over '$(call relpath,$(rules_list))' ($$n rules))

	$(trap_on_signal)
	trap 'trap_on_signal SIGINT 2' INT
	trap 'trap_on_signal SIGTERM 15' TERM
	shell_pid=$$$$

	$(call kv_set,$(status),shell_pid,$$shell_pid)

	k=0
	while read rule; do
	    k=$$((k+1));

	    $(call parse_rule,$$rule)
	    rulef=$(stats)/$(runid)/$$ruleid
	    rule_log=$(logrun)/$$ruleid.log
	    pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	    $(call kv_set,$$rulef,rule,$$rule)
	    $(call kv_set,$$rulef,ruleid,$$ruleid)
	    $(call kv_set,$$rulef,progress,$$k/$$n ($$pct%))

	    src="$(lpath)/$$path"
	    dst="$(rpath)/$$path"
	    program_cmd=($(program_path) $${opts:+-o "$$opts"} "$$src" "$$dst")
	    printf -v program_cmd_q "%q " "$${program_cmd[@]}"
	    program_cmd_q="$${program_cmd_q% }"

	    $(call kv_set,$$rulef,rule_src,$$src)
	    $(call kv_set,$$rulef,rule_dst,$$dst)
	    $(call kv_set,$$rulef,program_cmd,$$program_cmd_q)

	    $(call kv_set,$(status),progress,$$k/$$n ($$pct%))
	    $(call kv_set,$(status),current_rule,$$rule)
	    $(call kv_set,$(status),current_ruleid,$$ruleid)
	    $(call kv_set,$(status),current_rule_src,$$src)
	    $(call kv_set,$(status),current_rule_dst,$$dst)
	    $(call kv_set,$(status),current_rule_status,$$rulef)
	    $(call kv_set,$(status),current_rule_log,$$rule_log)
	    $(call kv_set,$(status),program_cmd,$$program_cmd_q)

	    $(call log,rule '$$rule')
	    $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%))
	    $(call log,[$$ruleid] start '$(program_name)')
	    $(call log,[$$ruleid] command line: $$program_cmd_q)

	    t1=$(t)
	    rule_started_at=$(call at,$$t1)
	    $(call kv_set,$$rulef,rule_started_at,$$rule_started_at)
	    $(call kv_set,$(status),current_rule_started_at,$$rule_started_at)

	    "$${program_cmd[@]}" &> $$rule_log & program_pid=$$!
	    $(call kv_set,$(status),program_pid,$$program_pid)
	    $(watch_rclone)
	    rc=0; wait $$program_pid || rc=$$?
	    wait $$watcher_pid || true

	    t2=$(t)
	    rule_ended_at=$(call at,$$t2)
	    rule_elapsed=$(call t_delta,$$t1,$$t2)

	    $(call append_rule_log,$$rule_log)
	    $(call rclone_stats,$$ruleid,$$rulef,$$rule_log)
	    $(call kv_set,$$rulef,rule_ended_at,$$rule_ended_at)
	    $(call kv_set,$$rulef,rule_elapsed,$$rule_elapsed)
	    $(call kv_set,$$rulef,rc,$$rc)

	    $(call kv_set,$(status),program_pid,-)
	    $(call kv_set,$(status),rclone_pid,-)
	    if [ $$rc -ne 0 ]; then $(call kv_set,$(status),rc,$$rc); fi

	    [ $$rc -ne 0 ] && warn=" (WARN)" || warn=""
	    $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call hms_ms,$$rule_elapsed)))

	    $(stop_guard);
	done < <(sed 's/[[:space:]]*#.*//' $(rules_list) | awk 'NF')

end:
	@t0=$(call kv_get,$(status),started_at_epoch)
	t3=$(t)
	$(call kv_set,$(status),ended_at,$(call at,$$t3))
	$(call kv_set,$(status),total_elapsed,$(call t_delta,$$t0,$$t3))
	$(call kv_set,$(status),state,NOT RUNNING (completed))
	$(call log,end '$(project)' \
        (total elapsed: $(call t_delta_hms_ms,$$t0,$$t3)))

# stop & kill

stop:
	@printf "[$(project)] graceful stop requested: exit after current rule\n"
	> $(stop)
	$(call log,graceful stop requested: exit after current rule$(,) \
        flag '$(stop)' created)

kill:
	@shell_pid=$(call kv_get,$(status),shell_pid)
	program_pid=$(call kv_get,$(status),program_pid)
	rclone_pid=$(call kv_get,$(status),rclone_pid)
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
	@$(colors)
	printf "$$BLD%s (v%s) @ %s (%s)$$RST\n\n" \
        $(project) $(version) $(hostname) $(now)

	[ $@ = status-v ] && verbose=true || verbose=false
	state=$(call kv_get,$(status),state)
	[ "$$state" = RUNNING ] && running=true || running=false
	running=true

	started_at=$(call kv_get,$(status),started_at)
	current_ruleid="$(call kv_get,$(status),current_ruleid)"
	rclone_ver="$(rclone_ver)"

	if $$running; then
	    started_at_epoch=$(call kv_get,$(status),started_at_epoch)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$(t))
	    current_ruleid=$(call kv_get,$(status),current_ruleid)
	    progress=$$(echo $(call kv_get,$(status),progress) |
	        sed 's/ (/, /;s/)//')
	    current_rule_src="$(call kv_get,$(status),current_rule_src)"
	    current_rule_dst="$(call kv_get,$(status),current_rule_dst)"
	    make_pid=$(call kv_get,$(status),make_pid)
	    shell_pid=$(call kv_get,$(status),shell_pid)
	    program_pid=$(call kv_get,$(status),program_pid)
	    rclone_pid=$(call kv_get,$(status),rclone_pid)
	    pids="make=$${make_pid:--}, shell=$${shell_pid:--}, "
	    pids+="rclone_sync=$${program_pid:--}, rclone=$${rclone_pid:--}"

	    printf "%-12s : $$RED%s$$RST\n" state "$$state"
	    printf "%-12s : %s\n" runid $(runid)
	    printf "%-12s : %s  (elapsed: %s)\n" "started at" \
            $$started_at $$elapsed
	    printf "%-12s : $$RED%s$$RST ($$RED%s$$RST)\n" "current rule" \
            $$current_ruleid "$$progress"
	    printf "%-12s : %s -> %s\n" flow \
            "$$current_rule_src" "$$current_rule_dst"
	    printf "%-12s : %s\n" pids "$$pids"
	    printf "%-12s : %s\n" rclone $(rclone_ver)
	else
	    ended_at=$(call kv_get,$(status),ended_at)
	    total_elapsed=$(call kv_get,$(status),total_elapsed)

	    printf "%-10s : $$RED%s$$RST\n" state "$$state"
	    printf "%-10s : %s\n" runid $(runid)
	    printf "%-10s : %s\n" "started at" $$started_at
	    printf "%-10s : %s\n" "ended at" $$ended_at
	    printf "%-10s : %s\n" elapsed $$total_elapsed
	    printf "%-10s : %s -> %s\n" flow $(lpath) $(rpath)
	    printf "%-10s : %s\n" rclone $(rclone_ver)
	fi

	if $$verbose; then
	    printf "\n"
	    fmt_hdr=$$(printf "%%-%ds  %s" $$(($(rule_width)+1)) \
            "%-5s  %-8s  %-8s  %8s  %10s  %8s  %8s  %6s  %3s")
	    fmt_row=$$(printf "%%-%ds  %s" $$(($(rule_width)+1)) \
            "%-5s  %-8s  %-8s  %8s  %10d  %8d  %8s  %6d  %3d")

	    printf "$$BLD$$fmt_hdr$$RST\n" \
            RULE STATE START END ELAPSED CHECKS XFER XFER_MiB DEL RC

	    if $$running; then
	        for rid in $(stats)/last/*; do
	            rule=$(call kv_get,$$rid,ruleid)
	            rule=$(call truncate,$$rule,$(rule_width))
	            state=done
	            start=$(call kv_get,$$rid,rule_started_at)
	            start=$${start#*-}
	            end=$(call kv_get,$$rid,rule_ended_at)
	            end=$${end#*-}
	            elapsed=$(call kv_get,$$rid,rule_elapsed)
	            checks=$(call kv_get,$$rid,rclone_checks)
	            checks=$${checks%/*}
	            xfer=$(call kv_get,$$rid,rclone_transferred)
	            xfer=$${xfer%/*}
	            xfer_mib=$(call kv_get,$$rid,rclone_transferred_size)
	            xfer_mib=$(call mib,$${xfer_mib%/*}})
	            del=$(call kv_get,$$rid,rclone_deleted)
	            rc=$(call kv_get,$$rid,rc)
	            printf "$$fmt_row\n" $$rule $$state $$start $$end $$elapsed \
                    $$checks $$xfer $$xfer_mib $$del $$rc
	        done
	    else
	        for rid in $(stats)/last/*; do
	            rule=$(call kv_get,$$rid,ruleid)
	            rule=$(call truncate,$$rule,$(rule_width))
	            state=done
	            start=$(call kv_get,$$rid,rule_started_at)
	            start=$${start#*-}
	            end=$(call kv_get,$$rid,rule_ended_at)
	            end=$${end#*-}
	            elapsed=$(call kv_get,$$rid,rule_elapsed)
	            checks=$(call kv_get,$$rid,rclone_checks)
	            checks=$${checks%/*}
	            xfer=$(call kv_get,$$rid,rclone_transferred)
	            xfer=$${xfer%/*}
	            xfer_mib=$(call kv_get,$$rid,rclone_transferred_size)
	            xfer_mib=$(call mib,$${xfer_mib%/*}})
	            del=$(call kv_get,$$rid,rclone_deleted)
	            rc=$(call kv_get,$$rid,rc)
	            printf "$$fmt_row\n" $$rule $$state $$start $$end $$elapsed \
                    $$checks $$xfer $$xfer_mib $$del $$rc
	        done
	    fi
	fi

# usage

usage:
	@usagef=$(usage)/usage-$(runid); > $$usagef

	[ -L $(usage)/last ] && ln -fns $$(readlink $(usage)/last) $(usage)/prev
	ln -fns $${usagef##*/} $(usage)/last

	{
	    printf "Bucket usage (%s, %s)\n" \
            $(hostname) "$$(date '+%a %d %b %Y')"
	    printf "    bucket: %s\n" $(bucket)
	    printf "    prefix: %s\n" $(dst_root)
	} >> $$usagef

	t0=$(t)
	$(call log,start bucket usage (excluding versions))
	{
	    printf "    excluding versions:\n"
	    $(rclone) --config $(rclone_conf) size $(rpath) |
	        sed 's/^/        /'
	} >> $$usagef
	$(call log,end bucket usage (excluding versions) \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

	t0=$(t)
	$(call log,start bucket usage (including versions))
	{
	    printf "    including versions:\n"
	    $(rclone) --config $(rclone_conf) size --s3-versions $(rpath) |
	        sed 's/^/        /'
	} >> $$usagef
	$(call log,end bucket usage (including versions) \
        (elapsed: $(call t_delta_hms_ms,$$t0,$(t))))

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' $(logf) | tail -n 1 | cut -d: -f1)
	sed -n "$$start,/\[make(end):/p" $(logf)

# site targets

-include .site.mk


# vim: ts=4
