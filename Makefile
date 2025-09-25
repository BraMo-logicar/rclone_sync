# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.08.19

include .include.mk

#
# targets
#

.PHONY: help start main end status

help:
	@echo Makefile: Please specify a target: start, main, end, ...

$(project): start main end

# main

start:
	@mkdir -p $(stats); > $(status)
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
        command=($(program_path) $${opts:+-o "$$opts"} $$src $$dst); \
        $(call set_status,command_line,$${command[*]}); \
        $(call write_stat,$$rulef,command_line,$${command[*]}); \
        $(call log,[$$ruleid] start '$(program_name)'); \
        $(call log,[$$ruleid] command line: $${command[*]}); \
        \
        t1=$(t); \
        \
        "$${command[@]}" &> $$rule_log & program_pid=$$!; \
        \
        ( \
            rclone_pid=$$($(call watch_child,$$program_pid,rclone, \
                $(strip $(watch_tries)),$(watch_delay))); \
            $(call set_status,rclone_pid,$$rclone_pid); \
        ) & watcher_pid=$$!; \
        \
        $(call set_status,program_pid,$$program_pid); \
        wait $$program_pid; rc=$$?; \
        wait $$watcher_pid || true; \
        $(call set_status,rc,$$rc); \
        $(call write_stat,$$rulef,rc,$$rc); \
        $(call set_status,program_pid,-); \
        elapsed=$(call since,$$t1); \
        \
        rclone_chk=$(call count_chk,$$rule_log); \
        rclone_xfer=$(call count_xfer,$$rule_log); \
        rclone_xfer_sz=$(call count_xfer_sz,$$rule_log); \
        rclone_xfer_new=$(call count_xfer_new,$$rule_log); \
        rclone_xfer_repl=$(call count_xfer_repl,$$rule_log); \
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
            echo "-- begin rclone log '$(logf)' --"; \
            cat $$rule_log >> $(logf); \
            echo "-- end rclone log --"; \
        ) >> $(logf); \
        $(call log,[$$ruleid] rclone stats: \
            checks=$$rclone_chk$(,) \
            transferred=$$rclone_xfer ($$rclone_xfer_sz) \
            (new=$$rclone_xfer_new$(,) replaced=$$rclone_xfer_repl)$(,) \
            deleted=$$rclone_del$(,) elapsed=$$rclone_elapsed); \
        \
        $(call write_stat,$$rulef,rule_end,$(now)); \
        $(call write_stat,$$rulef,elapsed,$${elapsed}s); \
        $(call log,[$$ruleid] end '$(program_name)': rc=$$rc \
            (elapsed: $${elapsed}s)); \
        \
        if [ $$rc -ne 0 ]; then exit $$rc; fi; \
    done < <(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF')

end:
	@t0=$(call get_status,start_epoch)
	cp $(status) $(tmp)
	rm -f $(status)
	$(call log,end '$(project)' (total elapsed: $(call since_hms,$$t0)))

status:
	@[ -f $(status) ] || { echo "$(program_name) not running"; exit 0; }
	echo $(project)/$(program_name) running

xstatus:
	@rulef='$(rulef)'; stats_root='data/stats'; last_link="$$stats_root/last"; \
	[ -f "$$rulef" ] || { echo "status: $(rulef) not found"; exit 0; }; \
	\
	# pull fields from rulef
	get(){ awk -F: -v k="^$$1:" '$$0 ~ k {sub(/^[^:]+:[ \t]*/,""); print; exit}' "$$rulef"; }; \
	start_epoch=$$(get start_epoch); \
	start=$$(get start); \
	rule=$$(get rule); \
	start=$$(get start); \
	start_epoch=$$(get start_epoch); \
	statdir=$$(get statdir); \
	rclone_pid=$$(get rclone_pid); \
	rclone_flags=$$(get rclone_flags); \
	# detect running: rclone pid alive?
	is_running=0; \
	if [ -n "$$rclone_pid" ] && [ "$$rclone_pid" != "-" ] && ps -p $$rclone_pid >/dev/null 2>&1; then \
	  is_running=1; \
	fi; \
	\
	if [ $$is_running -eq 1 ]; then \
	  echo "$(project) running"; \
	  if [ -n "$$start_epoch" ]; then \
	    now=$$(date +%s); base=$${start_epoch%.*}; dur=$$(( now - base )); \
	    printf "start : %s (%02dh%02dm%02ds)\n" "$$start" $$((dur/3600)) $$(((dur%3600)/60)) $$((dur%60)); \
	  else \
	    echo "start : $$start"; \
	  fi; \
	  echo "current rule : '$$rule'"; \
	  if [ -n "$$start_epoch" ]; then \
	    now=$$(date +%s); base=$${start_epoch%.*}; rdur=$$(( now - base )); \
	    printf "  rule start : %s (%02dh%02dm%02ds)\n" "$$start" $$((rdur/3600)) $$(((rdur%3600)/60)) $$((rdur%60)); \
	  elif [ -n "$$start" ]; then \
	    echo "  rule start : $$start"; \
	  fi; \
	  # hot CPU/RSS
	  read _ pcpu rss _ < <(ps -o pid= -o pcpu= -o rss= -o comm= -p $$rclone_pid | awk '{print $$1,$$2,$$3,$$4}'); \
	  rssmb=$$(awk 'BEGIN{printf("%.1f", '$$rss'/1024.0)}'); \
	  echo "  rclone pid : $$rclone_pid"; \
	  echo "  rclone cpu : $$pcpu%"; \
	  echo "  rclone mem : $$rssmb MB (RSS)"; \
	  # rclone version + flags
	  rv=$$($(RCLONE) --version 2>/dev/null | head -1); \
	  echo "rclone : $$rv"; \
	  echo "flags  : $$rclone_flags"; \
	  # statdir and processed rules
	  [ -n "$$statdir" ] && echo "statdir: $$statdir"; \
	  if [ -d "$$statdir" ]; then \
	    echo "ended|finished|processed rules"; \
	    i=1; \
	    for f in $$(find "$$statdir" -maxdepth 1 -type f -name '*.stat' | sort); do \
	      grep -q '^end:' "$$f" || continue; \
	      r=$$(basename "$$f" .stat); printf "  %d. %s\n" "$$i" "$$r"; i=$$((i+1)); \
	    done; \
	  fi; \
	else \
	  echo "$(project) not running"; \
	  echo "last run"; \
	  # resolve last stats dir
	  if [ -L "$$last_link" ] || [ -d "$$last_link" ]; then \
	    ldir=$$(readlink -f "$$last_link" 2>/dev/null || echo "$$last_link"); \
	    # times
	    start=$$(awk -F: '/^start:/{sub(/^[^:]+:[ \t]*/,""); print; exit}' "$$ldir/run.stat" 2>/dev/null); \
	    stop=$$(awk  -F: '/^end:/{sub(/^[^:]+:[ \t]*/,""); print; exit}'   "$$ldir/run.stat" 2>/dev/null); \
	    elapsed=$$(awk -F: '/^elapsed:/{sub(/^[^:]+:[ \t]*/,""); print; exit}' "$$ldir/run.stat" 2>/dev/null); \
	    [ -z "$$start" ] && start=$$(grep -h '^start:' "$$ldir"/*.stat 2>/dev/null | head -1 | sed 's/^start:[ \t]*//'); \
	    [ -z "$$stop"  ] && stop=$$(grep -h '^end:'   "$$ldir"/*.stat 2>/dev/null | tail -1 | sed 's/^end:[ \t]*//'); \
	    rules=$$(ls "$$ldir"/*.stat 2>/dev/null | wc -l | tr -d ' '); \
	    printf "  start   : %s\n" "$$start"; \
	    printf "  stop    : %s\n" "$$stop"; \
	    printf "  elapsed : %s\n" "$$elapsed"; \
	    printf "  rules   : %s\n" "$$rules"; \
	    printf "  statdir : %s -> %s\n" "$$stats_root/last" "$$ldir"; \
	    # totals: checks, files, size
	    total_chk=$$(awk -F: '/^rclone_?chk/ {gsub(/[^0-9]/,"",$$2); s+= $$2} END{print s+0}' "$$ldir"/*.stat 2>/dev/null); \
	    total_xfer=$$(awk -F: '/^rclone_?xfer:/ {gsub(/[^0-9]/,"",$$2); s+= $$2} END{print s+0}' "$$ldir"/*.stat 2>/dev/null); \
	    total_sz=$$(awk -F: '\
	      function parse(x){gsub(/^[ \t]+|[ \t]+$$/,"",x); \
	        if(x==""){return 0} \
	        if(x ~ /[Kk][Bb]?$$/){sub(/[Kk][Bb]?$$/,"",x); return x*1024} \
	        if(x ~ /[Mm][Bb]?$$/){sub(/[Mm][Bb]?$$/,"",x); return x*1024*1024} \
	        if(x ~ /[Gg][Bb]?$$/){sub(/[Gg][Bb]?$$/,"",x); return x*1024*1024*1024} \
	        if(x ~ /[Tt][Bb]?$$/){sub(/[Tt][Bb]?$$/,"",x); return x*1024*1024*1024*1024} \
	        gsub(/[^0-9]/,"",x); return x+0 } \
	      /^rclone_?xfer_?sz:/ { s += parse($$2) } END{print s+0}' "$$ldir"/*.stat 2>/dev/null); \
	    to_human() { \
	      b=$$1; \
	      if   [ $$b -ge 1099511627776 ]; then printf "%.2f TB\n" $$(awk 'BEGIN{print '$$b'/1099511627776}'); \
	      elif [ $$b -ge 1073741824 ]; then printf "%.2f GB\n" $$(awk 'BEGIN{print '$$b'/1073741824}'); \
	      elif [ $$b -ge 1048576 ]; then printf "%.2f MB\n" $$(awk 'BEGIN{print '$$b'/1048576}'); \
	      elif [ $$b -ge 1024 ]; then printf "%.2f KB\n" $$(awk 'BEGIN{print '$$b'/1024}'); \
	      else printf "%d B\n" $$b; fi; \
	    }; \
	    echo "totals:"; \
	    printf "  checks : %s\n" "$${total_chk:-0}"; \
	    printf "  files  : %s\n" "$${total_xfer:-0}"; \
	    printf "  size   : "; to_human $${total_sz:-0}; \
	    echo "ended|finished|processed rules"; \
	    i=1; for f in $$(find "$$ldir" -maxdepth 1 -type f -name '*.stat' | sort); do \
	      grep -q '^end:' "$$f" || continue; r=$$(basename "$$f" .stat); \
	      printf "  %d. %s\n" "$$i" "$$r"; i=$$((i+1)); \
	    done; \
	  else \
	    echo "  (no previous runs found)"; \
	  fi; \
	fi

# sync

#$(rclone) --config $(rclone_conf) size $(rpath)
#$(rclone) --config $(rclone_conf) size --s3-versions $(rpath)

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

# stats

#rclone_size:
#	@echo "Bucket usage:"
#	@$(rclone) --config $(rclone_conf) size $(rpath) | sed 's/^/  /'
#	@echo "Bucket usage (including versions):"
#	@$(rclone) --config $(rclone_conf) size --s3-versions $(rpath) | \
#        sed 's/^/  /'


# vim: ts=4
