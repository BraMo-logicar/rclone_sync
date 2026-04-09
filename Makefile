# Name: Makefile - Makefile for $(project)
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2026.04.07

include mk/config.mk
include mk/lib.mk

include .include.mk

#
# targets
#

.PHONY: help dirs \
        list run start main end stop kill \
        status status-v report report-mail \
        usage log-last

help:
	@echo "Makefile: Please specify a target:"
	echo "    list, run, stop, kill"
	echo "    status(-v) [runid=<runid>], report(-mail) [runid=<runid>],"
	echo "    usage, log-last"

$(project): start main end

# list

list:
	@: > "$(rules_list)"
	: > "$(ruleids_list)"

	if [ -f "$(exclude_list)" ]; then
	    while IFS= read -r xpat; do
	        case "$$xpat" in
	            ""|\#*) continue ;;
	            */*)    xpath+=("$$xpat") ;;
	            *)      xrule+=("$$xpat") ;;
	        esac
	    done < "$(exclude_list)"
	fi

	if find "$(src_root)" -mindepth 1 -maxdepth 1 -type f | read -r; then
	    printf ". -- ruleid=root-files opts=\"--max-depth 1\"\n" \
            >> "$(rules_list)"
	    printf "root-files\n" >> "$(ruleids_list)"
	fi

	while IFS= read -r path; do
	    skip=
	    for xpat in "$${xrule[@]}"; do
	        case "$$path" in
	            $$xpat)
	                skip=1
	                $(call log,exclude rule path '$$path' by pattern '$$xpat')
	                break ;;
	        esac
	    done
	    [ -n "$$skip" ] && continue

	    opts=
	    for xpat in "$${xpath[@]}"; do
	        head=$${xpat%%/*}
	        tail=$${xpat#*/}
	        [ "$$head" = "$$path" ] || continue
	        opts="$$opts --exclude '/$$tail'"
	        $(call log,modify rule path '$$path': append option --exclude '/$$tail')
	    done

	    if [ -n "$$opts" ]; then
	        printf "%s -- opts=\"%s\"\n" "$$path" "$${opts# }"
	    else
	        printf "%s\n" "$$path"
	    fi >> "$(rules_list)"
	    printf "%s\n" "$$path" | sed 's|/|_|g; s|[[:space:]]|_|g' \
	        >> "$(ruleids_list)"
	done < <(find "$(src_root)" -mindepth 1 -maxdepth 1 -type d \
        -printf "%f\n" | sort)

	n=$$(wc -l < "$(rules_list)")
	$(call log,list $$n rules from '$(src_root)' to '$(rules_list)')

	n=$$(wc -l < "$(ruleids_list)")
	$(call log,list $$n ruleids from '$(rules_list)' to '$(ruleids_list)')

xlist:
	@: > "$(rules_list)"
	@: > "$(ruleids_list)"

# run

run:
	@start_rc=0 main_rc=0
	$(MAKE) -s start || start_rc=$$?
	[ $$start_rc -eq 0 ] && { $(MAKE) -s main || main_rc=$$?; }
	$(MAKE) -s end main_rc=$$main_rc
	exit $$main_rc

# dirs

dirs:
	@mkdir -p "$(home)/log" "$(reports)" "$(stats)" "$(tmp)" "$(usage)"

# main

start: dirs
	@t0=$(t)
	$(define_kv)
	runid=$(t_znow)
	$(call run_paths,$$runid)

	mkdir -p "$$statsdir"
	$(call rotate_last_prev,$(last),$(prev),$$subdir/$$runid)
	ln -fns stats/last/.status data/status

	rm -rf "$(logrun)"; mkdir -p "$(logrun)"

	> "$(statusf)"
	kv_set "$(statusf)" gstate running
	kv_set "$(statusf)" runid $$runid
	kv_set "$(statusf)" started_at_epoch $$t0
	kv_set "$(statusf)" started_at $(call at,$$t0)
	kv_set "$(statusf)" rules_done 0
	kv_set "$(statusf)" rules_total 42
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
	kv_set "$(statusf)" result -
	kv_set "$(statusf)" rc -

	$(get_config)
	msg=
	[ -n "$$type" ]     && msg+="$${msg:+ }type=$$type"
	[ -n "$$provider" ] && msg+="$${msg:+ }provider=$$provider"
	[ -n "$$region" ]   && msg+="$${msg:+ }region=$$region"
	[ -n "$$endpoint" ] && msg+="$${msg:+ }endpoint=$$endpoint"

	$(call log,[$$runid] start '$(project)' ($(program_name) v$(version)) \
	    @ $(hostname) ($(ip)))
	$(call log,[$$runid] rclone remote: $$msg)

main:
	@$(define_kv)
	runid=$$(kv_get "$(statusf)" runid)
	$(call run_paths,$$runid)

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
	    rulef="$$statsdir/$$ruleid"; > "$$rulef"
	    rule_log="$(logrun)/$$ruleid.log"
	    pct=$(call pct,$$k,$$n)

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
	    $(call log,[$$runid] ruleid '$$ruleid' ($$k/$$n $$pct%))
	    $(call log,[$$runid:$$ruleid] start '$(program_name)')
	    $(call log,[$$runid:$$ruleid] command line: $$program_line)

	    t1=$(t)
	    kv_set "$$rulef" rule_started_at_epoch $$t1
	    kv_set "$$rulef" rule_started_at $(call at,$$t1)

	    "$${program_cmd[@]}" &> "$$rule_log" & program_pid=$$!
	    kv_set "$(statusf)" program_pid $$program_pid
	    $(call watch_rclone,$$rulef,$$program_pid)
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
	        (elapsed=$(call t_hms_ms,$$rule_elapsed)))

	    $(call stop_guard,$$runid,$$ruleid)
	done < <(sed 's/[[:space:]]*#.*//' "$(rules_list)" | awk 'NF')

end:
	@$(define_kv)
	runid=$$(kv_get "$(statusf)" runid)
	t0=$$(kv_get "$(statusf)" started_at_epoch)
	t3=$(t)
	kv_set "$(statusf)" ended_at_epoch $$t3
	kv_set "$(statusf)" ended_at $(call at,$$t3)
	kv_set "$(statusf)" total_elapsed $(call t_delta,$$t0,$$t3)
	k=$$(kv_get "$(statusf)" rules_done)
	n=$$(kv_get "$(statusf)" rules_total)
	kv_set "$(statusf)" gstate idle
	result=$$(kv_get "$(statusf)" result)
	if [ "$$result" = stopped ] || [ $$result = killed ]; then
	    rc=$$(kv_get "$(statusf)" rc)
	else
	    if [ "$$k" -eq "$$n" ]; then
	        result=completed rc=0
	    else
	        result=failed rc=-1
	    fi
	    kv_set "$(statusf)" result $$result
	    kv_set "$(statusf)" rc $$rc
	fi
	$(call log,[$$runid] end '$(project)' \
	    (rules=$$k/$$n result=$$result rc=$$rc) \
	    (total_elapsed=$(call t_delta_hms_ms,$$t0,$$t3)))

# stop & kill

stop:
	@$(define_kv)
	runid=$$(kv_get "$(statusf)" runid)
	{
	    printf "[%s] graceful stop requested (runid=%s): " $(project) $$runid
	    printf "exit after current rule\n"
	} >&2
	> "$(stop_flag)"
	$(call log,[$$runid] graceful stop requested: \
	    flag '$(stop_flag)' created$(,) exit after current rule)

kill:
	@$(define_kv)
	runid=$$(kv_get "$(statusf)" runid)
	shell_pid=$$(kv_get "$(statusf)" shell_pid)
	program_pid=$$(kv_get "$(statusf)" program_pid)
	rclone_pid=$$(kv_get "$(statusf)" rclone_pid)
	printf "[%s] global kill requested (%s=%d %s=%d %s=%d)\n" \
	    $(project) recipe_shell $$shell_pid \
	    program $$program_pid rclone $$rclone_pid >&2
	$(call log,[$$runid] kill requested (recipe_shell=$$shell_pid \
	    program=$$program_pid rclone=$$rclone_pid))
	for sig in INT TERM KILL; do
	    for pid in $$rclone_pid $$program_pid $$shell_pid; do
	         if kill -0 $$pid 2>/dev/null; then
	             printf "  send SIG%s to %d\n" $$sig $$pid >&2
	             kill -s $$sig $$pid 2>/dev/null || true
	         fi
	    done
	    sleep 1
	done
	kv_set "$(statusf)" gstate idle
	$(call log,[$$runid] kill: sent signals to rclone=$$rclone_pid \
	    program=$$program_pid recipe_shell=$$shell_pid)

# status

status status-v:
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1
	$(call run_paths,$$runid)

	gstate=$$(kv_get "$$statusf" gstate)
	[ -n "$$gstate" ] || gstate=idle

	k=$$(kv_get "$$statusf" rules_done)
	n=$$(kv_get "$$statusf" rules_total)
	pct=$(call pct,$$k,$$n)

	if [ "$$gstate" = running ]; then
	    t0=$(t)
	    started_at_epoch=$$(kv_get "$$statusf" started_at_epoch)
	    started_at=$$(kv_get "$$statusf" started_at)
	    elapsed=$(call t_delta_hms,$$started_at_epoch,$$t0)

	    current_ruleid=$$(kv_get "$$statusf" current_ruleid)
	    rulef="$$statsdir/$$current_ruleid"
	    rule_started_at_epoch=$$(kv_get "$$rulef" rule_started_at_epoch)
	    rule_elapsed=$(call t_delta_hms,$$rule_started_at_epoch,$$t0)

	    current_rule_src=$$(kv_get "$$statusf" current_rule_src)
	    current_rule_dst=$$(kv_get "$$statusf" current_rule_dst)

	    make_pid=$$(kv_get "$$statusf" make_pid)
	    shell_pid=$$(kv_get "$$statusf" shell_pid)
	    program_pid=$$(kv_get "$$statusf" program_pid)
	    rclone_pid=$$(kv_get "$$statusf" rclone_pid)
	    pids="make=$${make_pid:--} shell=$${shell_pid:--} "
	    pids+="rclone_sync=$${program_pid:--} rclone=$${rclone_pid:--}"

	    printf "state        : $$_RED_%s$$RST\n" $${gstate^^}
	    printf "runid        : %s\n" $$runid
	    printf "source       : %s\n" "$$current_rule_src"
	    printf "destination  : %s\n" "$$current_rule_dst"
	    printf "progress     : $$_RED_%d/%d$$RST (%.2f%%)\n" $$k $$n $$pct
	    printf "started at   : %s  (elapsed=%s)\n" $$started_at $$elapsed
	    printf "current rule : $$_RED_%s$$RST  (elapsed=%s)\n" \
	                           $$current_ruleid $$rule_elapsed
	    printf "pids         : %s\n" "$$pids"
	else
	    result=$$(kv_get "$$statusf" result)
	    started_at=$$(kv_get "$$statusf" started_at)
	    ended_at=$$(kv_get "$$statusf" ended_at)
	    elapsed=$(call t_hms,$$(kv_get "$$statusf" total_elapsed))

	    printf "state       : $$_RED_%s$$RST\n" $${gstate^^}
	    printf "result      : $$_RED_%s$$RST\n" $$result
	    printf "runid       : %s\n" $$runid
	    printf "source      : %s\n" "$(lpath)"
	    printf "destination : %s\n" "$(rpath)"
	    printf "rules       : $$_RED_%d/%d$$RST\n" $$k $$n
	    printf "started at  : %s\n" $$started_at
	    printf "ended at    : %s\n" $$ended_at
	    printf "elapsed     : %s\n" $$elapsed
	fi

	if [ $@ = status-v ]; then
	    printf "\n"
	    w1=$$(($(rule_width)+1))
	    fmt="%-$${w1}s  %-5s  %-8s  %-8s  %-8s  %8s  %8s  %10s  %6s  %3s"
	    fmt_queue="$$MAG%-$${w1}s  %-5s$$RST"
	    fmt_run="$$_RED_%-$${w1}s  %-5s  %-8s  %-8s  %-8s$$RST"

	    printf "$$BLD$$fmt$$RST\n" \
	        RULE STATE START END ELAPSED CHECKS XFER XFER_MiB DEL RC

	    sum_checks=0
	    sum_xfer=0 sum_xfer_new=0 sum_xfer_replaced=0 sum_xfer_mib=0
	    sum_del=0 sum_elapsed=0
	    rc_ok=0 rc_fail=0

	    if [ "$$gstate" = running ]; then
	        mapfile -t ruleids < "$(ruleids_list)"
	    else
	        mapfile -t ruleids < <(ls -A "$$statsdir" | grep -vx .status)
	    fi

	    queue=0
	    for ruleid in "$${ruleids[@]}"; do
	        rule=$(call truncate,$$ruleid,$(rule_width))
	        rulef="$$statsdir/$$ruleid"
	        rstate=$(call get_rstate,$$rulef,$$gstate)

	        if [ "$$rstate" = queue ]; then
	            : $$((queue++))
	            if [ "$$queue" -le "$(rule_queue)" ]; then
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
	            xfer=$$(kv_get "$$rulef" rclone_transferred) xfer=$${xfer%/*}
	            xfer_new=$$(kv_get "$$rulef" rclone_copied_new)
	            xfer_replaced=$$(kv_get "$$rulef" rclone_copied_replaced)
	            xfer_mib=$$(kv_get "$$rulef" rclone_transferred_size)
	            xfer_mib=$(call iec2mib,$${xfer_mib%/*})
	            del=$$(kv_get "$$rulef" rclone_deleted)
	            rc=$$(kv_get "$$rulef" rc)

	            : $$((sum_checks+=checks))
	            : $$((sum_xfer+=xfer))
	            : $$((sum_xfer_new+=xfer_new))
	            : $$((sum_xfer_replaced+=xfer_replaced))
	            sum_xfer_mib=$$(echo "$$sum_xfer_mib+$${xfer_mib:=0}" | bc)
	            : $$((sum_del+=del))
	            sum_elapsed=$$(echo "$$sum_elapsed+$${rule_elapsed:=0}" | bc)
	            [ "$$rc" = 0 ] && : $$((rc_ok++)) || : $$((rc_fail++))

	            printf "$$fmt\n" $$rule $$rstate $$start "$$end" \
	                $$elapsed "$$checks" "$$xfer" "$$xfer_mib" "$$del" "$$rc"
	        fi
	    done

	    if [ "$$queue" -gt "$(rule_queue)" ]; then
	        printf "(+%d more rules remaining)\n" $$((queue - $(rule_queue)))
	    fi

	    printf "\n$$BLD%s$$RST\n" SUMMARY

	    if [ "$$gstate" = running ]; then
	        printf "    rules         : $$_RED_%d/%d$$RST (%.2f%%)\n" \
	            $$k $$n $$pct
	    else
	        printf "    rules         : $$_RED_%d/%d$$RST\n" $$k $$n
	    fi
	    printf "    checks        : %s\n" $(call num3,$$sum_checks)
	    printf "    xfer          : %s\n" $(call num3,$$sum_xfer)
	    printf "      new         : %s\n" $(call num3,$$sum_xfer_new)
	    printf "      replaced    : %s\n" $(call num3,$$sum_xfer_replaced)
	    printf "    xfer size     : %s\n" "$(call mib2iec,$$sum_xfer_mib)"
	    printf "    deleted       : %s\n" $(call num3,$$sum_del)
	    printf "    rules elapsed : %s\n" $(call t_hms,$$sum_elapsed)
	    printf "    rules result  : ok=%d fail=%d\n" $$rc_ok $$rc_fail
	fi

# report

report: dirs
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1
	$(call run_paths,$$runid)

	gstate=$$(kv_get "$$statusf" gstate)
	if [ "$$gstate" = running ]; then
	    if [ -t 1 ]; then
	        printf "[%s] $$_RED_%s is running$$RST: report skipped\n" \
	            $(project) $(project)
	    fi
	    $(call log,[$$runid] $(project) is running: report skipped)
	    exit 0
	fi

	$(call report_paths,$$runid)
	mkdir -p "$$reportsdir"

	rules_done=$$(kv_get "$$statusf" rules_done)
	rules_total=$$(kv_get "$$statusf" rules_total)
	elapsed=$(call t_hms_ms,$$(kv_get "$$statusf" total_elapsed))

	{
	    printf "%s @ %s (%s)\n" $(project) $(hostname) $$runid
	    printf "\n"
	    printf "runid : %s\n" "$$runid"
	    printf "rules : %s\n" "$$rules_done/$$rules_total"
	    printf "\n"
	    awk '
	        /-- begin rclone log \(runid='$$runid' / {
	            sub(/.*ruleid=/, "# ruleid: "); sub(/\).*/, "")
	            sep = sprintf("#%*s", length-1, ""); gsub(/ /, "-", sep)
	            print sep; print; print sep
	            in_rule = 1; next
	        }
	        /-- end rclone log \(runid='$$runid' / {
	            print ""
	            in_rule = 0; next
	        }
	        in_rule
	    ' "$(logf)"
	} > "$$reportlog"
	$(call log,[$$runid] report log saved to '$$reportlog')

	$(get_config)
	{
	    printf "%s @ %s (%s)\n" $(project) $(hostname) $$runid
	    printf "\n"
	    printf "program     : %s (v%s)\n" "$(program_name)" $(version)
	    printf "host        : %s\n" "$(hostname) ($(ip))"
	    printf "runid       : %s\n" "$$runid"
	    printf "\n"
	    [ -n "$${type-}" ]     && printf "type        : %s\n" $$type
	    [ -n "$${provider-}" ] && printf "provider    : %s\n" $$provider
	    [ -n "$${region-}" ]   && printf "region      : %s\n" $$region
	    [ -n "$${endpoint-}" ] && printf "endpoint    : %s\n" $$endpoint
	    printf "\n"
	    printf "source      : %s\n" "$(lpath)"
	    printf "destination : %s\n" "$(rpath)"
	    printf "\n"
	    printf "started_at  : %s\n" "$$(kv_get "$$statusf" started_at)"
	    printf "ended_at    : %s\n" "$$(kv_get "$$statusf" ended_at)"
	    printf "elapsed     : %s\n" "$$elapsed"
	    printf "\n"
	    printf "rules       : %s\n" "$$rules_done/$$rules_total"
	    printf "result      : %s\n" "$$(kv_get "$$statusf" result)"
	    printf "\n"
	    printf -- "-------- rules summary (status-v) --------\n"
	    printf "\n"
	    $(MAKE) -s runid=$$runid status-v | sed -n '/^RULE/,$$p'
	} > "$$reportf"
	$(call log,[$$runid] report saved to '$$reportf' \
	    (elapsed=$(call t_delta_hms_ms,$$t0,$(t))))

	last=$$(readlink "$(last)")
	ln -fns "$$(dirname "$$last")/report-$$(basename "$$last").txt" \
	    "$(reports)/last"
	prev=$$(readlink "$(prev)")
	ln -fns "$$(dirname "$$prev")/report-$$(basename "$$prev").txt" \
	    "$(reports)/prev"

# report by email

report-mail:
	@t0=$(t)
	$(define_kv)
	$(colors)

	runid=$(get_runid) || exit 1
	$(call run_paths,$$runid)
	$(call report_paths,$$runid)

	if [ ! -f "$$reportf" ]; then
	    if [ -t 1 ]; then
	        printf "[%s] $$_RED_report for runid '%s' does not exist$$RST: " \
	            $(project) $$runid
	        printf "report-mail skipped\n"
	    fi
	    $(call log,[$$runid] report does not exist: report-mail skipped)
	    exit 0
	fi

	if [ ! -f "$$reportlog" ]; then
	    $(call log,[$$runid] report log does not exist)
	fi

	rules_done=$$(kv_get "$$statusf" rules_done)
	rules_total=$$(kv_get "$$statusf" rules_total)

	subject=$$(printf "[%s@%s] rclone sync to %s:%s (runid=%s rules=%s/%s)" \
	    $(project) $(host) $(remote) $(bucket) $$runid \
	    $$rules_done $$rules_total)

	$(call send_report,$$runid,$$reportf,$$reportlog,$$subject)

	$(call log,[$$runid] report by email to '$(mail_To)' \
	    (elapsed=$(call t_delta_hms_ms,$$t0,$(t))))

# usage

usage: dirs
	@$(define_kv)
	ts=$(t_znow)
	subdir=$${ts:0:4}
	usagedir="$(usage)/$$subdir"
	mkdir -p "$$usagedir"
	usagef="$$usagedir/usage-$$ts"; > "$$usagef"

	target=$$subdir/$${usagef##*/}
	$(call rotate_last_prev,$(usage)/last,$(usage)/prev,$$target)

	{
	    printf "Bucket usage\n"
	    printf "    host   : %s\n" $(hostname)
	    printf "    date   : %s\n" $$(date +%F)
	    printf "    bucket : %s\n" $(bucket)
	    printf "    prefix : %s\n" "$(dst_root)"
	} >> $$usagef

	t0=$(t)
	$(call log,start bucket usage (excluding versions) \
	    (bucket='$(bucket)' prefix='$(dst_root)'))
	{
	    printf "    excluding versions:\n"
	    $(rclone) --config "$(rclone_conf)" size "$(rpath)" |
	        sed 's/^/        /'
	} >> "$$usagef"
	$(call log,end bucket usage (excluding versions) \
	    (elapsed=$(call t_delta_hms_ms,$$t0,$(t))))

	t0=$(t)
	$(call log,start bucket usage (including versions) \
	    (bucket='$(bucket)' prefix='$(dst_root)'))
	{
	    printf "    including versions:\n"
	    $(rclone) --config "$(rclone_conf)" size --s3-versions "$(rpath)" |
	        sed 's/^/        /'
	} >> "$$usagef"
	$(call log,end bucket usage (including versions) \
	    (elapsed=$(call t_delta_hms_ms,$$t0,$(t))))

# logs

log-last:
	@start=$$(grep -Fn '[make(start):' "$(logf)" | tail -n 1 | cut -d: -f1)
	sed -n "$$start,/\[make(end):/p" "$(logf)"

# site targets

-include .site.mk


# vim: ts=4
