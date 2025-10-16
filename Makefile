# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.10.16

include .include.mk

#
# targets
#

.PHONY: help list start main end stop kill status usage

help:
	@echo Makefile: Please specify a target: start, main, end, ...

$(project): start main end

# list

list::
	@: > $(rclone_list)
	if find $(src_root) -mindepth 1 -maxdepth 1 -type f | read; then \
        printf ". ruleid=root-files opts=\"--max-depth 1\"\n" \
            >> $(rclone_list); \
    fi
	find $(src_root) -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | \
        sort >> $(rclone_list)
	n=$$(wc -l < $(rclone_list))
	$(call log,list $$n entries from '$(src_root)' to '$(rclone_list)')

# main

start:
	@t0=$(t)
	printf "\n" >> $(logf)
	mkdir -p $(stats); : > $(status)
	$(call set_status,status,RUNNING)
	$(call set_status,project,$(project))
	$(call set_status,program_name,$(program_name))
	$(call set_status,program_path,$(program_path))
	$(call set_status,runid,$(runid))
	$(call set_status,started_at,$(call at,$$t0))
	$(call set_status,started_at_epoch,$$t0)
	$(call set_status,stats_dir,$(stats))
	$(call set_status,progress,0/0 (0%))
	$(call set_status,current_rule,-)
	$(call set_status,current_ruleid,-)
	$(call set_status,current_rule_started_at,-)
	$(call set_status,current_rule_path,-)
	$(call set_status,current_rule_log,-)
	$(call set_status,program_cmd,-)
	$(call set_status,rclone_cmd,-)
	$(call set_status,make_pid,$$PPID)
	$(call set_status,shell_pid,-)
	$(call set_status,program_pid,-)
	$(call set_status,rclone_pid,-)
	$(call set_status,ended_at,-)
	$(call set_status,total_elapsed,-)
	$(call set_status,rc,0)

	$(call log,start '$(project)' @ $(hostname) ($(ip)))
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
	while read rule; do \
        k=$$((k+1)); \
        \
        $(call parse_rule,$$rule); \
        rulef=$(stats)/$(runid)/$$ruleid; \
        rule_log=$(logrun)/$$ruleid.log; \
        pct=$$(echo "scale=2; 100*$$k/$$n" | bc); \
        \
        $(call write_stat,$$rulef,rule,$$rule); \
        $(call write_stat,$$rulef,ruleid,$$ruleid); \
        $(call write_stat,$$rulef,progress,$$k/$$n ($$pct%)); \
        \
        $(call set_status,progress,$$k/$$n ($$pct%)); \
        $(call set_status,current_rule,$$rule); \
        $(call set_status,current_ruleid,$$ruleid); \
        $(call set_status,current_rule_path,$$rulef); \
        $(call set_status,current_rule_log,$$rule_log); \
        \
        src=$(lpath)/$$relpath; \
        dst=$(rpath)/$$relpath; \
        program_cmd=($(program_path) $${opts:+-o "$$opts"} $$src $$dst); \
        $(call write_stat,$$rulef,program_cmd,$${program_cmd[*]}); \
        $(call set_status,program_cmd,$${program_cmd[*]}); \
        \
        $(call log,rule '$$rule'); \
        $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%)); \
        $(call log,[$$ruleid] start '$(program_name)'); \
        $(call log,[$$ruleid] command line: $${program_cmd[*]}); \
        \
        t1=$(t); \
        rule_started_at=$(call at,$$t1); \
        $(call write_stat,$$rulef,rule_started_at,$$rule_started_at); \
        $(call set_status,current_rule_started_at,$$rule_started_at); \
        \
        "$${program_cmd[@]}" &> $$rule_log & program_pid=$$!; \
        $(watch_rclone); \
        $(call set_status,program_pid,$$program_pid); \
        rc=0; wait $$program_pid || rc=$$?; \
        wait $$watcher_pid || true; \
        \
        t2=$(t); \
        rule_ended_at=$(call at,$$t2); \
        rule_elapsed=$(call t_delta,$$t1,$$t2); \
        \
        $(call append_rule_log,$$rule_log); \
        $(call rclone_stats,$$ruleid,$$rulef,$$rule_log); \
        $(call write_stat,$$rulef,rule_ended_at,$$rule_ended_at); \
        $(call write_stat,$$rulef,rule_elapsed,$$rule_elapsed); \
        $(call write_stat,$$rulef,rc,$$rc); \
        \
        $(call set_status,program_pid,-); \
        $(call set_status,rclone_pid,-); \
        if [ $$rc -ne 0 ]; then $(call set_status,rc,$$rc); fi; \
        \
        [ $$rc -ne 0 ] && warn=" (WARN)" || warn=""; \
        $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call hms,$$rule_elapsed))); \
        \
        $(stop_guard); \
    done < <(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF')

end:
	@t0=$(call get_status,started_at_epoch)
	t3=$(t)
	$(call set_status,ended_at,$(call at,$$t3))
	$(call set_status,total_elapsed,$(call hms,$(call t_delta,$$t0,$$t3)))
	$(call set_status,status,NOT RUNNING (completed))
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
	for sig in INT TERM KILL; do \
        for pid in $$rclone_pid $$program_pid $$shell_pid; do \
             if kill -0 $$pid 2>/dev/null; then \
                 printf "  send SIG%s to %s\n" $$sig $$pid; \
                 kill -s $$sig $$pid 2>/dev/null || true; \
             fi; \
        done; \
        sleep 1; \
    done
	$(call log,global kill: sent signals to rclone=$$rclone_pid$(,) \
        program=$$program_pid$(,) recipe_shell=$$shell_pid)

# status

status:
	@[ -f $(status) ] || { echo "$(program_name) not running"; exit 0; }
	echo "$(project)/$(program_name) running"

# usage

usage:
	@t0=$(t)
	$(call log,start bucket usage (excluding versions))
	{ \
        printf "Bucket usage (%s, %s)\n" \
            $(hostname) "$$(date '+%a %d %b %Y')"; \
        printf "    bucket: %s\n" $(bucket); \
        printf "    prefix: %s\n" $(dst_root); \
    } > $(usage)
	{ \
        printf "    excluding versions:\n"; \
        $(rclone) --config $(rclone_conf) size $(rpath) | \
            sed 's/^/        /'; \
    } >> $(usage)
	$(call log,end bucket usage (excluding versions) \
        (elapsed: $(call t_delta_hms,$$t0,$(t))))
	t0=$(t)
	$(call log,start bucket usage (including versions))
	{ \
        printf "    including versions:\n"; \
        $(rclone) --config $(rclone_conf) size --s3-versions $(rpath) | \
            sed 's/^/        /'; \
    } >> $(usage)
	$(call log,end bucket usage (including versions) \
        (elapsed: $(call t_delta_hms,$$t0,$(t))))

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' $(logf) | tail -n 1 | cut -d: -f1)
	sed -n "$$start,/\[make(end):/p" $(logf)

# site targets

-include .site.mk


#rclone_sync.mail:
#	@c=`awk '/^Checks:/ { print $$2 }' $(logt)`; \
#    x=`grep ^Transferred: $(logt) | grep -v 'ETA' | awk '{ print $$2 }'`; \
#    xn=`grep -c "Copied (new)" $(logt)`; \
#    xr=`grep -c "Copied (replaced existing)" $(logt)`; \
#    s=`grep ^Transferred: $(logt) | grep 'ETA' | awk '{ print $$2, $$3 }'`; \
#    d=`awk '/^Deleted:/ { print $$2 }' $(logt)`; \
#    runat=`cat $(logts)`; \
#    elapsed=`awk '/Elapsed time:/ { print $$3 }' $(logt)`; \
#    subj="[$(project)@$(host)] rclone sync to s3 bucket $(remote)"; \
#    subj+=" ($${xn-=0}+/$${xr-=0}=/$${d:-0}-)"; \
#    (                                                            \
#        echo "From: $(mail_From)";                               \
#        echo "To: $(mail_To)";                                   \
#        echo "Subject: $$subj";                                  \
#        echo;                                                    \
#        echo "Sync by rclone: '$(host):$(lpath)' -> '$(rpath)'"; \
#        echo;                                                    \
#        echo "Host                : $(hostname)";                \
#        echo "Local path          : $(lpath)";                   \
#        echo "Bucket              : $(bucket)";                  \
#        echo "Prefix              : $(prefix)";                  \
#        echo "Objects checked     : $${c:-0}";                   \
#        echo "Objects transferred : $${x:-0}";                   \
#        echo "  new               : $${xn:-0}";                  \
#        echo "  replaced          : $${xr:-0}";                  \
#        echo "Data transferred    : $${s:-0}";                   \
#        echo "Objects deleted     : $${d:-0}";                   \
#        echo "Run at              : $$runat";                    \
#        echo "Elapsed             : $$elapsed";                  \
#        echo;                                                    \
#        echo "Disk usage:";                                      \
#        df -t $(fstype) -h | sed 's/^/  /';                      \
#        echo;                                                    \
#        echo "Bucket usage:";                                    \
#        sed -n '1,2s/^/  /p' $(sizef);                           \
#        echo "Bucket usage (including versions):";               \
#        sed -n '3,4s/^/  /p' $(sizef);                           \
#        echo;                                                    \
#        if [ $(mail_log) = "yes" ]; then                         \
#            echo "--- log ---";                                  \
#            cat $(logt);                                         \
#            echo;                                                \
#        fi;                                                      \
#    ) | $(sendmail) -f $(mail_from) $(mail_to) && \
#    $(call log,"mail sent (from: <$(mail_from)>, to: <$(mail_to)>)")

# vim: ts=4
