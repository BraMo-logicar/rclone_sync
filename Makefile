# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.08.19

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
	@printf ". ruleid=root opts=\"--max-depth 1\"\n" > $(rclone_list)
	find $(src_root) -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | \
        sort >> $(rclone_list)
	n=$$(wc -l < $(rclone_list)); \
    $(call log,list $$n entries from '$(src_root)' to '$(rclone_list)')

# main

start:
	@mkdir -p $(stats); : > $(status)
	$(call set_status,running,true)
	$(call set_status,project,$(project))
	$(call set_status,program_name,$(program_name))
	$(call set_status,program_path,$(program_path))
	$(call set_status,start,$(now))
	$(call set_status,start_epoch,$(t))
	$(call set_status,make_pid,$$PPID)
	$(call set_status,stats_dir,$(stats))
	$(call log,start '$(project)' @ $(hostname) ($(ip)))
	[ -L $(stats)/last ] && ln -fns $$(readlink $(stats)/last) $(stats)/prev
	rm -rf $(logrun); mkdir -p $(logrun)
	mkdir -p $(stats)/$(runid)
	ln -fns $(stats)/$(runid) $(stats)/last

main:
	@$(call log,loop over '$(call relpath,$(rclone_list))')
	trap 'rm -f $(status)' INT TERM
	recipe_shell_pid=$$$$
	$(call set_status,recipe_shell_pid,$$recipe_shell_pid)
	n=$$(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF' | wc -l); k=0
	while read rule; do \
        k=$$((k+1)); \
        \
        $(call parse_rule,$$rule); \
        \
        rulestart=$(now); \
        rulef=$(stats)/$(runid)/$$ruleid; \
        pct=$$(echo "scale=2; 100*$$k/$$n" | bc); \
        rule_log=$(logrun)/$$ruleid.log; \
        $(call set_status,current_rule,$$rule); \
        $(call set_status,current_rule_id,$$ruleid); \
        $(call set_status,current_rule_start,$$rulestart); \
        $(call set_status,current_rule_path,$$rulef); \
        $(call set_status,current_rule_log,$$rule_log); \
        $(call set_status,progress,$$k/$$n ($$pct%)); \
        $(call write_stat,$$rulef,rule,$$rule); \
        $(call write_stat,$$rulef,rule_id,$$ruleid); \
        $(call write_stat,$$rulef,rule_start,$$rulestart); \
        $(call write_stat,$$rulef,progress,$$k/$$n ($$pct%)); \
        $(call log,rule '$$rule'); \
        $(call log,ruleid '$$ruleid' ($$k/$$n$(,) $$pct%)); \
        \
        src=$(lpath)/$$relpath; \
        dst=$(rpath)/$$relpath; \
        program_cmd=($(program_path) $${opts:+-o "$$opts"} $$src $$dst); \
        $(call set_status,program_cmd,$${program_cmd[*]}); \
        $(call write_stat,$$rulef,program_cmd,$${program_cmd[*]}); \
        $(call log,[$$ruleid] start '$(program_name)'); \
        $(call log,[$$ruleid] command line: $${program_cmd[*]}); \
        \
        t1=$(t); \
        "$${program_cmd[@]}" &> $$rule_log & program_pid=$$!; \
        ( \
            rclone_pid=$$($(call watch_child,$$program_pid,rclone, \
                $(strip $(watch_tries)),$(watch_delay))); \
            $(call set_status,rclone_pid,$$rclone_pid); \
            rclone_cmd=$$($(call get_command_by_pid,$$rclone_pid)); \
            $(call write_stat,$$rulef,rclone_cmd,$$rclone_cmd); \
            $(call set_status,rclone_cmd,$$rclone_cmd); \
        ) & watcher_pid=$$!; \
        \
        $(call set_status,program_pid,$$program_pid); \
        rc=0; wait $$program_pid || rc=$$?; \
        wait $$watcher_pid || true; \
        $(call write_stat,$$rulef,rc,$$rc); \
        $(call set_status,program_pid,-); \
        elapsed=$(call since,$$t1); \
        \
        rclone_chk=$(call count_chk,$$rule_log); \
        rclone_xfer=$(call count_xfer,$$rule_log); \
        rclone_xfer_new=$(call count_xfer_new,$$rule_log); \
        rclone_xfer_repl=$(call count_xfer_repl,$$rule_log); \
        rclone_xfer_sz=$(call count_xfer_sz,$$rule_log); \
        rclone_del=$(call count_del,$$rule_log); \
        rclone_elapsed=$(call count_elapsed,$$rule_log); \
        \
        $(call write_stat,$$rulef,rclone_checks,$$rclone_chk); \
        $(call write_stat,$$rulef,rclone_transferred,$$rclone_xfer); \
        $(call write_stat,$$rulef,rclone_copied_new,$$rclone_xfer_new); \
        $(call write_stat,$$rulef,rclone_copied_replaced,$$rclone_xfer_repl); \
        $(call write_stat,$$rulef,rclone_transferred_size,$$rclone_xfer_sz); \
        $(call write_stat,$$rulef,rclone_deleted,$$rclone_del); \
        $(call write_stat,$$rulef,rclone_elapsed,$$rclone_elapsed); \
        \
        ( \
            printf -- "-- begin rclone log '%s' --\n" $(logf); \
            cat $$rule_log >> $(logf); \
            printf -- "-- end rclone log --\n"; \
        ) >> $(logf); \
        $(call log,[$$ruleid] rclone stats: \
            checks=$$rclone_chk$(,) \
            transferred=$$rclone_xfer ($$rclone_xfer_sz) \
            (new=$$rclone_xfer_new$(,) replaced=$$rclone_xfer_repl)$(,) \
            deleted=$$rclone_del$(,) elapsed=$$rclone_elapsed); \
        \
        $(call write_stat,$$rulef,rule_end,$(now)); \
        $(call write_stat,$$rulef,elapsed,$${elapsed}s); \
        [ $$rc -ne 0 ] && warn=" (WARN)" || warn=""; \
        $(call log,[$$ruleid]$$warn end '$(program_name)': rc=$$rc \
            (elapsed: $(call hms,$$elapsed))); \
        if [ -f $(stop) ]; then \
	        printf "[$(project)] stop flag found: exit after current rule\n"; \
	        rm -f $(stop); \
	        $(call log,stop flag found: exit after current rule); \
	        exit 0; \
	    fi; \
    done < <(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF')

end:
	@t0=$(call get_status,start_epoch)
	cp $(status) $(tmp)
	rm -f $(status)
	$(call log,end '$(project)' (total elapsed: $(call since_hms,$$t0)))

t:
	date > /tmp/x
	echo $(rclone_list) >> /tmp/x

# stop & kill

stop:
    @printf "[$(project)] graceful stop requested: exit after current rule\n"
	: > $(stop)
	$(call log,graceful stop requested: exit after current rule$(,) \
        flag '$(stop)' created)

kill:
	@recipe_shell_pid=$(call get_status,recipe_shell_pid); \
    program_pid=$(call get_status,program_pid); \
    rclone_pid=$(call get_status,rclone_pid); \
    printf "[%s] global kill requested (%s=%d, %s=%d, %s=%d)\n" \
        $(project) recipe_shell $$recipe_shell_pid \
        program $$program_pid rclone $$rclone_pid; \
    $(call log,global kill requested (recipe_shell=$$recipe_shell_pid$(,) \
        program=$$program_pid$(,) rclone=$$rclone_pid)); \
    for sig in INT TERM KILL; do \
        for pid in $$rclone_pid $$program_pid $$recipe_shell_pid; do \
             if kill -0 $$pid 2>/dev/null; then \
                 printf "  send SIG%s to %s\n" $$sig $$pid; \
                 kill -s $$sig $$pid 2>/dev/null || true; \
             fi; \
        done; \
        sleep 1; \
    done; \
    $(call log,global kill: sent signals to rclone=$$rclone_pid$(,) \
        program=$$program_pid$(,) recipe_shell=$$recipe_shell_pid)

# status

status:
	@[ -f $(status) ] || { echo "$(program_name) not running"; exit 0; }
	echo "$(project)/$(program_name) running"

# usage

usage:
	@t0=$(t); \
    $(call log,start bucket usage (excluding versions)); \
    ( \
        printf "Bucket usage (%s)\n" "$$(date '+%a %d %b %Y')"; \
        printf "    excluding versions:\n"; \
        $(rclone) --config $(rclone_conf) size $(rpath) | \
            sed 's/^/        /'; \
    ) > $(usage); \
    $(call log,end bucket usage (excluding versions) \
        (elapsed: $(call since_hms,$$t0))); \
    \
    t0=$(t); \
    $(call log,start bucket usage (including versions)); \
    ( \
        printf "    including versions:\n"; \
        $(rclone) --config $(rclone_conf) size --s3-versions $(rpath) | \
            sed 's/^/        /'; \
    ) >> $(usage); \
    $(call log,end bucket usage (including versions) \
        (elapsed: $(call since_hms,$$t0))); \

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' $(logf) | tail -n 1 | cut -d: -f1); \
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
