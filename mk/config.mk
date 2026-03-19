# Name: mk/config.mk - config for Makefile
# Usage: include mk/config.mk
# Author: Marco Broglia <marco.broglia@mutex.it>
# Date: 2026.03.19

#-----
# vars
#-----

# env

SHELL := /usr/bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

export LC_ALL := C

# main

home := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

project      := $(shell basename "$(home)")
version      := 2.0
program_name := rclone_sync
program_path := $(home)/bin/$(program_name)

hostname := $(shell hostname)
host     := $(shell hostname -s)
ip       := $(shell hostname -i)

# cmds

rclone   := /usr/bin/rclone
sendmail := /usr/sbin/sendmail

# rclone

rclone_conf := $(home)/etc/rclone.conf
rclone_ver  := $(shell rclone version | sed -n '1s/.* v//p')

# dirs and files

data    := $(home)/data
tmp     := $(home)/tmp
stats   := $(data)/stats
reports := $(data)/reports

usage  := $(data)/usage
stop   := $(tmp)/stop

logf   := $(home)/log/$(project).log
logrun := $(home)/log/run

# local/remote

remote := $(project)

lpath := $(src_root)
rpath := $(remote):$(bucket)$(dst_root)

# rules

rules_list   := $(home)/etc/rules.list
ruleids_list := $(home)/etc/ruleids.list

# run

watch_tries := 100
watch_delay := .05

# status

last := $(stats)/last
prev := $(stats)/prev

statusf := $(last)/.status

# colors

esc   := \033

bld   := $(esc)[1m
rst   := $(esc)[0m

red   := $(esc)[31m
grn   := $(esc)[32m
yel   := $(esc)[33m
blu   := $(esc)[34m
mag   := $(esc)[35m
cyn   := $(esc)[36m

_red_ := $(esc)[91m
_grn_ := $(esc)[92m
_yel_ := $(esc)[93m
_blu_ := $(esc)[94m
_mag_ := $(esc)[95m
_cyn_ := $(esc)[96m

# misc

fortytwo := Forty_two_said_Deep_Thought_with_infinite_majesty_and_calm
, := ,


# vim: ts=4
