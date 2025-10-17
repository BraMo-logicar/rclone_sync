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
	@: > $(rclone_list)
	if find $(src_root) -mindepth 1 -maxdepth 1 -type f | read; then
	    printf ". -- ruleid=root-files opts=\"--max-depth 1\"\n" \
            >> $(rclone_list)
	fi
	find $(src_root) -mindepth 1 -maxdepth 1 -type d -printf "%f\n" |
	    sort >> $(rclone_list)
	n=$$(wc -l < $(rclone_list))
	$(call log,list $$n entries from '$(src_root)' to '$(rclone_list)')

# main

start:
	@t0=$(t)
	mkdir -p $(stats); : > $(status)
	$(call set_status,state,RUNNING)
	$(call set_status,project,$(project))
	$(call set_status,version,$(version))
	$(call set_status,runid,$(runid))

	$(call set_status,started_at,$(call at,$$t0))
	$(call set_status,started_at_epoch,$$t0)
	$(call set_status,progress,0/0 (0%))

	$(call set_status,current_rule,-)
	$(call set_status,current_ruleid,-)
	$(call set_status,current_rule_src,-)
	$(call set_status,current_rule_dst,-)
	$(call set_status,current_rule_started_at,-)
	$(call set_status,current_rule_status,-)
	$(call set_status,current_rule_log,-)

	$(call set_status,program_name,$(program_name))
	$(call set_status,program_path,$(program_path))
	$(call set_status,program_cmd,-)
	$(call set_status,rclone_cmd,-)
	$(call set_status,rclone_ver,$(rclone_ver))

	$(call set_status,make_pid,$$PPID)
	$(call set_status,shell_pid,-)
	$(call set_status,program_pid,-)
	$(call set_status,rclone_pid,-)

	$(call set_status,ended_at,-)
	$(call set_status,total_elapsed,-)
	$(call set_status,rc,0)

	$(call log,start '$(project)' (v$(version)) @ $(hostname) ($(ip)))
	[ -L $(stats)/last ] && ln -fns $$(readlink $(stats)/last) $(stats)/prev
	rm -rf $(logrun); mkdir -p $(logrun)
	mkdir -p $(stats)/$(runid)
	ln -fns $(stats)/$(runid) $(stats)/last

main:
	@n=$$(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF' | wc -l)
	$(call log,loop over '$(call relpath,$(rclone_list))' ($$n rules))
	$(trap_on_signal)
	trap 'trap_on_signal SIGINT 2' INT
	trap 'trap_on_signal SIGTERM 15' TERM
	shell_pid=$$$$
	$(call set_status,shell_pid,$$shell_pid)

	k=0
	while read rule; do
	    k=$$((k+1));

	    $(call parse_rule,$$rule)
	    rulef=$(stats)/$(runid)/$$ruleid
	    rule_log=$(logrun)/$$ruleid.log
	    pct=$$(echo "scale=2; 100*$$k/$$n" | bc)

	    $(call write_stat,$$rulef,rule,$$rule)
	    $(call write_stat,$$rulef,ruleid,$$ruleid)
	    $(call write_stat,$$rulef,progress,$$k/$$n ($$pct%))

	    src="$(lpath)/$$path"
	    dst="$(rpath)/$$path"
	    program_cmd=($(program_path) $${opts:+-o "$$opts"} "$$src" "$$dst")
	    printf -v program_cmd_q "%q " "$${program_cmd[@]}"
	    program_cmd_q="$${program_cmd_q% }"

	    $(call write_stat,$$rulef,rule_src,$$src)
	    $(call write_stat,$$rulef,rule_dst,$$dst)
	    $(call write_stat,$$rulef,program_cmd,$$program_cmd_q)

	    $(call set_status,progress,$$k/$$n ($$pct%))
	    $(call set_status,current_rule,$$rule)
	    $(call set_status,current_ruleid,$$ruleid)
	    $(call set_status,current_rule_src,$$src)
	    $(call set_status,current_rule_dst,$$dst)
	    $(call set_status,current_rule_status,$$rulef)
	    $(call set_status,current_rule_log,$$rule_log)
	    $(call set_status,program_cmd,$$program_cmd_q)

	    $(call log,rule '$$rule')
	    $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%))
	    $(call log,[$$ruleid] start '$(program_name)')
	    $(call log,[$$ruleid] command line: $$program_cmd_q)

	    t1=$(t)
	    rule_started_at=$(call at,$$t1)
	    $(call write_stat,$$rulef,rule_started_at,$$rule_started_at)
	    $(call set_status,current_rule_started_at,$$rule_started_at)

	    "$${program_cmd[@]}" &> $$rule_log & program_pid=$$!
	    $(call set_status,program_pid,$$program_pid)
	    $(watch_rclone)
	    rc=0; wait $$program_pid || rc=$$?
	    wait $$watcher_pid || true

	    t2=$(t)
	    rule_ended_at=$(call at,$$t2)
	    rule_elapsed=$(call t_delta,$$t1,$$t2)

	    $(call append_rule_log,$$rule_log)
	    $(call rclone_stats,$$ruleid,$$rulef,$$rule_log)
	    $(call write_stat,$$rulef,rule_ended_at,$$rule_ended_at)
	    $(call write_stat,$$rulef,rule_elapsed,$$rule_elapsed)
	    $(call write_stat,$$rulef,rc,$$rc)

	    $(call set_status,program_pid,-)
	    $(call set_status,rclone_pid,-)
	    if [ $$rc -ne 0 ]; then $(call set_status,rc,$$rc); fi

	    [ $$rc -ne 0 ] && warn=" (WARN)" || warn=""
	    $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call hms,$$rule_elapsed)))

	    $(stop_guard);
	done < <(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF')

end:
	@t0=$(call get_status,started_at_epoch)
	t3=$(t)
	$(call set_status,ended_at,$(call at,$$t3))
	$(call set_status,total_elapsed,$(call hms,$(call t_delta,$$t0,$$t3)))
	$(call set_status,state,NOT RUNNING (completed))
	$(call log,end '$(project)' \
        (total elapsed: $(call t_delta_hms,$$t0,$$t3)))

# stop & kill

stop:
	@printf "[$(project)] graceful stop requested: exit after current rule\n"
	: > $(stop)
	$(call log,graceful stop requested: exit after current rule$(,) \
        flag '$(stop)' created)

kill:
	@shell_pid=$(call get_status,shell_pid)
	program_pid=$(call get_status,program_pid)
	rclone_pid=$(call get_status,rclone_pid)
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

	[ $@ = status-v ] && verbose=: || verbose=false
	state="$(call get_kv,state)"
	[ "$$state" = RUNNING ] && running=: || running=false

	started_at=$(call get_kv,started_at)
	current_ruleid="$(call get_kv,current_ruleid)"
	rclone_ver="$(rclone_ver)"

	if $$running; then
	    started_at_epoch=$(call get_kv,started_at_epoch)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$(t))
	    current_ruleid=$(call get_kv,current_ruleid)
	    progress=$$(echo $(call get_kv,progress) | sed 's/ (/, /;s/)//')
	    current_rule_src="$(call get_kv,current_rule_src)"
	    current_rule_dst="$(call get_kv,current_rule_dst)"
	    make_pid=$(call get_kv,make_pid)
	    shell_pid=$(call get_kv,shell_pid)
	    program_pid=$(call get_kv,program_pid)
	    rclone_pid=$(call get_kv,rclone_pid)
	    pids="make=$${make_pid:--}, shell=$${shell_pid:--}, "
	    pids+="rclone_sync=$${program_pid:--}, rclone=$${rclone_pid:--}"

	    printf "%-16s : $$RED%s$$RST\n" state "$$state"
	    printf "%-16s : %s\n" runid $(runid)
	    printf "%-16s : %s  (elapsed: %s)\n" "started at" \
            $$started_at $$elapsed
	    printf "%-16s : $$RED%s$$RST ($$RED%s$$RST)\n" "current rule" \
            $$current_ruleid "$$progress"
	    printf "%-16s : %s -> %s\n" flow \
            "$$current_rule_src" "$$current_rule_dst"
	    printf "%-16s : %s\n" pids "$$pids"
	    printf "%-16s : %s\n" rclone $(rclone_ver)
	else
	    ended_at=$(call get_kv,ended_at)
	    total_elapsed=$(call get_kv,total_elapsed)

	    printf "%-16s : $$RED%s$$RST\n" state "$$state"
	    printf "%-16s : %s\n" runid $(runid)
	    printf "%-16s : %s\n" "started at" $$started_at
	    printf "%-16s : %s\n" "ended at" $$ended_at
	    printf "%-16s : %s\n" elapsed $$total_elapsed
	    printf "%-16s : %s -> %s\n" flow $(lpath) $(rpath)
	    printf "%-16s : %s\n" rclone $(rclone_ver)
	fi

	printf "\n"

# usage

usage:
	@t0=$(t)
	$(call log,start bucket usage (excluding versions))
	{
	    printf "Bucket usage (%s, %s)\n" \
            $(hostname) "$$(date '+%a %d %b %Y')"
	    printf "    bucket: %s\n" $(bucket)
	    printf "    prefix: %s\n" $(dst_root)
	} > $(usage)
	{
	    printf "    excluding versions:\n"
	    $(rclone) --config $(rclone_conf) size $(rpath) |
	        sed 's/^/        /'
	} >> $(usage)
	$(call log,end bucket usage (excluding versions) \
        (elapsed: $(call t_delta_hms,$$t0,$(t))))
	t0=$(t)
	$(call log,start bucket usage (including versions))
	{
	    printf "    including versions:\n"
	    $(rclone) --config $(rclone_conf) size --s3-versions $(rpath) |
	        sed 's/^/        /'
	} >> $(usage)
	$(call log,end bucket usage (including versions) \
        (elapsed: $(call t_delta_hms,$$t0,$(t))))

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' $(logf) | tail -n 1 | cut -d: -f1)
	sed -n "$$start,/\[make(end):/p" $(logf)

# site targets

-include .site.mk


# vim: ts=4
