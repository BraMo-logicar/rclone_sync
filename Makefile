# Name: Makefile - Makefile for rclone_sync
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2025.08.19

include .include.mk

#
# targets
#

.PHONY: help start main end status

help:
	@echo Makefile: Please specify a target: rclone_sync, rclone_ ...

$(project): start main end

# main

start:
	@mkdir -p $(stats)
	rm -f $(status)
	trap 'rm -f $(status)' EXIT INT TERM
	$(call set_status,running,yes)
	$(call set_status,project,$(project))
	$(call set_status,progname,$(progname))
	$(call set_status,run_start,$(now))
	$(call set_status,run_start_epoch,$(t))
	$(call set_status,pid(make),$$)
	$(call set_status,statdir,$(stats))
	$(call log,start '$(project)' @ $(hostname) ($(ip)))
	[ -L $(stats)/last ] && ln -fns $$(readlink $(stats)/last) $(stats)/prev
	rm -rf $(logseg); mkdir -p $(logseg)
	mkdir -p $(stats)/$(runid)
	ln -fns $(stats)/$(runid) $(stats)/last

main:
	@$(call log,loop over '$(call relpath,$(rclone_list))')
	trap 'rm -f $(status)' EXIT INT TERM
	n=$$(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF' | wc -l); k=0
	while read rule; do \
        k=$$((k+1)); \
        \
        key=$(call key,$$rule); \
        keyf=$(stats)/$(runid)/$$key; \
        pct=$$(echo "scale=2; 100*$$k/$$n" | bc); \
        $(call set_status,rule,$$rule); \
        $(call set_status,key,$$key); \
        $(call set_status,key_file,$$keyf); \
        $(call set_status,progress,$$k/$$n ($$pct%)); \
        $(call write_stat,$$keyf,rule,$$rule); \
        $(call write_stat,$$keyf,key,$$key); \
        $(call write_stat,$$keyf,progress,$$k/$$n ($$pct%)); \
        $(call log,rule '$$rule'); \
        $(call log,key '$$key' ($$k/$$n ($$pct%))); \
        \
        filters="$(call filters,$$rule)"; \
        command="$(program) $$filters"; \
        $(call set_status,rule_start,$(now)); \
        $(call set_status,command,$$command); \
        $(call write_stat,$$keyf,rule_start,$(now)); \
        $(call write_stat,$$keyf,command,$$command); \
        $(call log,[$$key] start '$(progname)'); \
        $(call log,[$$key] command,$$command); \
        \
        klog=$(logseg)/$$key.log; \
        t1=$(t); \
        ( \
            pid=$$; \
            $(call set_status,rclone_pid,$$pid); \
            $(call write_stat,$$keyf,rclone_pid,$$pid); \
            exec $$command &> $$klog; \
        ); \
        rc=$$? \
        $(call set_status,rclone_pid,-); \
        elapsed=$(call since,$$t1); \
        \
        rclone_chk=$(call count_chk,$$klog); \
        rclone_xfer=$(call count_xfer,$$klog); \
        rclone_xfer_sz=$(call count_xfer_sz,$$klog); \
        rclone_xfer_new=$(call count_xfer_new,$$klog); \
        rclone_xfer_repl=$(call count_xfer_repl,$$klog); \
        rclone_del=$(call count_del,$$klog); \
        rclone_elapsed=$(call count_elapsed,$$klog); \
        \
        $(call write_stat,$$keyf,rclone_checks,$$rclone_chk); \
        $(call write_stat,$$keyf,rclone_transferred,$$rclone_xfer); \
        $(call write_stat,$$keyf,rclone_copied_new,$$rclone_xfer_new); \
        $(call write_stat,$$keyf,rclone_copied_replaced,$$rclone_xfer_repl); \
        $(call write_stat,$$keyf,rclone_transferred_size,$$rclone_xfer_sz); \
        $(call write_stat,$$keyf,rclone_deleted,$$rclone_del); \
        $(call write_stat,$$keyf,rclone_elapsed,$$rclone_elapsed); \
        $(call log,[$$key] rclone stats: \
            checks=$$rclone_chk$(,) \
            transferred=$$rclone_xfer ($$rclone_xfer_sz) \
            (new=$$rclone_xfer_new$(,) replaced=$$rclone_xfer_repl)$(,) \
            deleted=$$rclone_del$(,) elapsed=$$rclone_elapsed); \
        \
        cat $(logseg)/$$key.log >> $(logf); \
        \
        $(call write_stat,$$keyf,rule_end,$(now)); \
        $(call write_stat,$$keyf,rc,$$rc); \
        $(call write_stat,$$keyf,rule_elapsed,$${elapsed}s); \
        $(call log,[$$key] end '$(progname)': rc=$$rc \
            (elapsed: $${elapsed}s)); \
        \
        if [ $$rc -ne 0 ]; then exit $$rc; fi; \
    done < <(sed 's/[[:space:]]*#.*//' $(rclone_list) | awk 'NF')
	rm -f $(status)

end:
	@t0=$(call get_status,run_start_epoch)
	$(call set_status,run_end,$(now))
	$(call set_status,run_elapsed,$(call since_hms,$$t0))
	$(call log,end '$(project)' (total elapsed: $(call since_hms,$$t0)))

status:
	@[ -f $(status) ] || { echo "$(progname) not running"; exit 0; }
	echo $(project)/$(progname) running

xstatus:
	@keyf='$(keyf)'; stats_root='data/stats'; last_link="$$stats_root/last"; \
	[ -f "$$keyf" ] || { echo "status: $(keyf) not found"; exit 0; }; \
	\
	# pull fields from keyf
	get(){ awk -F: -v k="^$$1:" '$$0 ~ k {sub(/^[^:]+:[ \t]*/,""); print; exit}' "$$keyf"; }; \
	run_start_epoch=$$(get run_start_epoch); \
	run_start=$$(get start); \
	rule=$$(get rule); \
	rule_start=$$(get rule_start); \
	rule_start_epoch=$$(get rule_start_epoch); \
	statdir=$$(get statdir); \
	rclone_pid=$$(get rclone_pid); \
	rclone_flags=$$(get rclone_flags); \
	\
	# detect running: rclone pid alive?
	is_running=0; \
	if [ -n "$$rclone_pid" ] && [ "$$rclone_pid" != "-" ] && ps -p $$rclone_pid >/dev/null 2>&1; then \
	  is_running=1; \
	fi; \
	\
	if [ $$is_running -eq 1 ]; then \
	  echo "$(project) running"; \
	  if [ -n "$$run_start_epoch" ]; then \
	    now=$$(date +%s); base=$${run_start_epoch%.*}; dur=$$(( now - base )); \
	    printf "start : %s (%02dh%02dm%02ds)\n" "$$run_start" $$((dur/3600)) $$(((dur%3600)/60)) $$((dur%60)); \
	  else \
	    echo "start : $$run_start"; \
	  fi; \
	  echo "current rule : '$$rule'"; \
	  if [ -n "$$rule_start_epoch" ]; then \
	    now=$$(date +%s); base=$${rule_start_epoch%.*}; rdur=$$(( now - base )); \
	    printf "  rule start : %s (%02dh%02dm%02ds)\n" "$$rule_start" $$((rdur/3600)) $$(((rdur%3600)/60)) $$((rdur%60)); \
	  elif [ -n "$$rule_start" ]; then \
	    echo "  rule start : $$rule_start"; \
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
