# Name: Makefile - Makefile for rclone_sync
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2023.09.15

include .include.mk

#
# funcs
#

# times

t       = date +%s.%3N
elapsed = echo "$(2) - $(1)" | bc | sed 's/^\./0./'

# logs

now = date +'%Y.%m.%d-%H:%M:%S'
log = echo "`$(now)` [`basename $(MAKE)`($@):$$$$]" $(1) >> $(logf)

# misc

mb = printf "%.0f" $$(echo "$(1) / 1048576" | bc -l)

#
# special targets
#

all: rclone_sync rclone_sync.mail

clean:

#
# targets
#

# sync

rclone_sync:
	@t0=`$(t)`; \
    $(rclone_sync) $(opts) $(lpath) $(rpath); \
    $(rclone) --config $(rclone_conf) size $(rpath) > $(sizef); \
    $(rclone) --config $(rclone_conf) size --s3-versions $(rpath) >> $(sizef); \
    n=`sed -En '1s/.*\(([0-9]*)\)/\1/p' $(sizef)`; \
    s=`sed -En '2s/.*\(([0-9]*).*\)/\1/p' $(sizef)`; \
    s=`$(call mb,$$s)`; \
    nv=`sed -En '3s/.*\(([0-9]*)\)/\1/p' $(sizef)`; \
    sv=`sed -En '4s/.*\(([0-9]*).*\)/\1/p' $(sizef)`; \
    sv=`$(call mb,$$sv)`; \
    $(call log,"$(rpath): $$n/$$nv objects$(,) $$s/$$sv MB size"); \
    dt=$$($(call elapsed,$$t0,`$(t)`)); \
    $(call log,"'$@' done ($${dt}s)")

rclone_sync.mail:
	@c=`awk '/^Checks:/ { print $$2 }' $(logt)`; \
    x=`grep ^Transferred: $(logt) | grep -v 'ETA' | awk '{ print $$2 }'`; \
    xn=`grep -c "Copied (new)" $(logt)`; \
    xr=`grep -c "Copied (replaced existing)" $(logt)`; \
    s=`grep ^Transferred: $(logt) | grep 'ETA' | awk '{ print $$2, $$3 }'`; \
    d=`awk '/^Deleted:/ { print $$2 }' $(logt)`; \
    elapsed=`awk '/Elapsed time:/ { print $$3 }' $(logt)`; \
    subj="[$(proj)@$(host)] rclone sync to s3 bucket $(remote)"; \
    subj+=" ($${xn-=0}+/$${xr-=0}=/$${d:-0}-)"; \
    (                                                            \
        echo "From: $(mail_From)";                               \
        echo "To: $(mail_To)";                                   \
        echo "Subject: $$subj";                                  \
        echo;                                                    \
        echo "Sync by rclone: '$(host):$(lpath)' -> '$(rpath)'"; \
        echo;                                                    \
        echo "Host                : $(hostname)";                \
        echo "Local path          : $(lpath)";                   \
        echo "Bucket              : $(bucket)";                  \
        echo "Prefix              : $(prefix)";                  \
        echo "Objects checked     : $${c:-0}";                   \
        echo "Objects transferred : $${x:-0}";                   \
        echo "  new               : $${xn:-0}";                  \
        echo "  replaced          : $${xr:-0}";                  \
        echo "Data transferred    : $${s:-0}";                   \
        echo "Objects deleted     : $${d:-0}";                   \
        echo "Elapsed             : $$elapsed";                  \
        echo;                                                    \
        echo "Disk usage:";                                      \
        df -t $(fstype) -h | sed 's/^/  /';                      \
        echo;                                                    \
        echo "Bucket usage:";                                    \
        sed -n '1,2s/^/  /p' $(sizef);                           \
        echo "Bucket usage (including versions):";               \
        sed -n '3,4s/^/  /p' $(sizef);                           \
        echo;                                                    \
        if [ $(mail_log) = "yes" ]; then                         \
            echo "--- log ---";                                  \
            cat $(logt);                                         \
            echo;                                                \
        fi;                                                      \
    ) | $(sendmail) -f $(mail_from) $(mail_to) && \
    $(call log,"mail sent (from: <$(mail_from)>, to: <$(mail_to)>)")

# stats

rclone_size:
	@echo "Bucket usage:"
	@$(rclone) --config $(rclone_conf) size $(rpath) | sed 's/^/  /'
	@echo "Bucket usage (including versions):"
	@$(rclone) --config $(rclone_conf) size --s3-versions $(rpath) | \
        sed 's/^/  /'
