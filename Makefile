# Name: Makefile - Makefile for rclone_bak
# Usage: (g)make [ all | <target> | clean ]
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2023.09.15

#
# vars
#

SHELL := /usr/bin/bash

proj := rclone_bak
host := $(shell hostname -s)

# dirs and files

home := /usr/local/$(proj)
tmp  := $(home)/tmp

logf := $(home)/log/$(proj).log
logt := $(logf).t

sizef := $(tmp)/rclone_size.out

# cmds

rclone      := /bin/rclone
rclone_sync := $(home)/bin/rclone_sync
sendmail    := /sbin/sendmail

# s3 bucket

s3_profile := e2
s3_bucket  := $(host)-backup

# backup

rclone_list := $(home)/etc/rclone.list
opts        := --skip-links -v -I $(rclone_list) -n
rpath       := $(s3_profile):$(s3_bucket)

# misc

fstype := xfs

, := ,

# email

mail_From := $(proj) system <backup-admin@emsquared.it>
mail_from := backup-admin@emsquared.it
#mail_To   := backup admin <backup-admin@emsquared.it>
#mail_to   := backup-admin@emsquared.it
mail_To   := Marco Broglia <marco.broglia@emsquared.it>
mail_to   := marco.broglia@emsquared.it

#
# funcs
#

# times

t = perl -MTime::HiRes=gettimeofday -e 'printf "%.3f\n", scalar gettimeofday'

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
    $(rclone_sync) $(opts) / $(rpath); \
    $(rclone) size $(rpath) > $(sizef); \
    $(rclone) size --s3-versions $(rpath) >> $(sizef); \
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
    xn=`grep -c "Copied (new)" $(logt)` ; \
    xr=`grep -c "Copied (replaced existing)" $(logt)` ; \
    s=`grep ^Transferred: $(logt) | grep 'ETA' | awk '{ print $$2, $$3 }'`; \
    d=`awk '/^Deleted:/ { print $$2 }' $(logt)`; \
    elapsed=`awk '/Elapsed time:/ { print $$3 }' $(logt)`; \
    subj="[$(proj)@$(host)] rclone sync to $(rpath)"; \
    subj+=" ($${xn-=0}+/$${xr-=0}=/$${d:-0}-)"; \
    (                                                           \
        echo "From: $(mail_From)";                              \
        echo "To: $(mail_To)";                                  \
        echo "Subject: $$subj";                                 \
        echo;                                                   \
        echo "Sync backup @ $(host): rclone sync to IDrive e2"; \
        echo;                                                   \
        echo "Host                : $(host)";                   \
        echo "Bucket              : $(s3_bucket)";              \
        echo "Objects checked     : $${c:-0}";                  \
        echo "Objects transferred : $${x:-0}";                  \
        echo "  new               : $${xn:-0}";                 \
        echo "  replaced          : $${xr:-0}";                 \
        echo "Data transferred    : $${s:-0}";                  \
        echo "Objects deleted     : $${d:-0}";                  \
        echo "Elapsed             : $$elapsed";                 \
        echo;                                                   \
        echo "Disk usage:";                                     \
        df -t $(fstype) -h | sed 's/^/  /';                     \
        echo;                                                   \
        echo "Bucket usage:";                                   \
        sed -n '1,2s/^/  /p' $(sizef);                          \
        echo "Bucket usage (including versions):";              \
        sed -n '3,4s/^/  /p' $(sizef);                          \
        echo;                                                   \
        echo "--- log ---";                                     \
        cat $(logt);                                            \
        echo;                                                   \
    ) | $(sendmail) -f $(mail_from) $(mail_to) | \
    $(call log,"mail sent (from: <$(mail_from)>, to: <$(mail_to)>)")

# stats

rclone_size:
	@echo "Bucket usage:"
	@$(rclone) size $(rpath) | sed 's/^/  /'
	@echo "Bucket usage (including versions):"
	@$(rclone) size --s3-versions $(rpath) | sed 's/^/  /'
